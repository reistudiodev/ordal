//! PostgreSQL driver (sqlx).
//! Browse tree: databases › schemas › Tables | Views | Functions › columns.

use std::collections::HashMap;
use std::time::Duration;

use async_trait::async_trait;
use sqlx::postgres::{PgConnectOptions, PgPoolOptions, PgRow, PgSslMode};
use sqlx::{Executor, PgPool, Row as _, ValueRef};
use tokio_util::sync::CancellationToken;

use super::sqlx_common::{self, quote_ident, Pools, StreamEnd, EXACT_COUNT_BELOW};
use super::{approx_rows, table_path, BrowseNode, Driver, NodeKind, ServerInfo, Sink};
use super::{FOLDER_FUNCTIONS, FOLDER_TABLES, FOLDER_VIEWS};
use crate::config::{ConnectionConfig, TlsMode};
use crate::error::{CoreError, Result};
use crate::sql::{classify_sql, StatementKind};
use crate::value::{decode_pg_hex, Row, RowCount, Value, ValueKind, Window};

pub(crate) struct PgDriver {
    pools: Pools<sqlx::Postgres>,
    /// Primary-key columns per (db, schema, table), for stable window ordering.
    keys: tokio::sync::Mutex<HashMap<(String, String, String), Vec<String>>>,
}

impl PgDriver {
    pub(crate) async fn connect(config: &ConnectionConfig, password: Option<String>) -> Result<Self> {
        let mut base = PgConnectOptions::new()
            .host(&config.host)
            .port(config.port)
            .username(&config.username)
            .application_name(config.option("application_name").unwrap_or("dbclient"))
            .ssl_mode(match config.tls {
                TlsMode::Disable => PgSslMode::Disable,
                TlsMode::Prefer => PgSslMode::Prefer,
                TlsMode::Require => PgSslMode::Require,
            });
        if let Some(p) = password.as_deref() {
            base = base.password(p);
        }
        let read_only = config.read_only;
        let default_db = if config.database.is_empty() { "postgres".to_string() } else { config.database.clone() };
        let pools = Pools::new(default_db, move |db| {
            let opts = base.clone().database(&db);
            Box::pin(async move {
                PgPoolOptions::new()
                    .max_connections(5)
                    .acquire_timeout(Duration::from_secs(15))
                    .idle_timeout(Duration::from_secs(300))
                    .after_connect(move |conn, _| {
                        Box::pin(async move {
                            if read_only {
                                // Enforced by the server, not just by our classifier.
                                conn.execute("SET default_transaction_read_only = on").await?;
                            }
                            Ok(())
                        })
                    })
                    .connect_with(opts)
                    .await
            })
        })
        .await?;
        Ok(Self { pools, keys: Default::default() })
    }

    async fn primary_key(&self, pool: &PgPool, db: &str, schema: &str, table: &str) -> Result<Vec<String>> {
        let key = (db.to_string(), schema.to_string(), table.to_string());
        if let Some(k) = self.keys.lock().await.get(&key) {
            return Ok(k.clone());
        }
        let cols: Vec<String> = sqlx::query_scalar(
            "SELECT a.attname::text FROM pg_index i \
             JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey) \
             WHERE i.indrelid = format('%I.%I', $1, $2)::regclass AND i.indisprimary \
             ORDER BY array_position(i.indkey, a.attnum)",
        )
        .bind(schema)
        .bind(table)
        .fetch_all(pool)
        .await?;
        self.keys.lock().await.insert(key, cols.clone());
        Ok(cols)
    }
}

pub(crate) fn kind_of(type_name: &str) -> ValueKind {
    match type_name {
        "BOOL" => ValueKind::Bool,
        "INT2" | "INT4" | "INT8" | "OID" => ValueKind::Int,
        "FLOAT4" | "FLOAT8" => ValueKind::Float,
        "NUMERIC" | "MONEY" => ValueKind::Decimal,
        "DATE" => ValueKind::Date,
        "TIME" | "TIMETZ" => ValueKind::Time,
        "TIMESTAMP" => ValueKind::Timestamp,
        "TIMESTAMPTZ" => ValueKind::TimestampTz,
        "UUID" => ValueKind::Uuid,
        "JSON" | "JSONB" => ValueKind::Json,
        "BYTEA" => ValueKind::Bytes,
        "TEXT" | "VARCHAR" | "BPCHAR" | "NAME" | "CHAR" | "CITEXT" => ValueKind::Text,
        _ => ValueKind::Other,
    }
}

/// Decodes a text-format row (see `sqlx_common`).
fn decode(row: &PgRow, kinds: &[ValueKind]) -> Row {
    let cells = kinds
        .iter()
        .enumerate()
        .map(|(i, &kind)| match row.try_get_raw(i) {
            Ok(v) if v.is_null() => Value::Null,
            Ok(v) => match v.as_str() {
                Ok(s) if kind == ValueKind::Bytes => decode_pg_hex(s)
                    .map(|v| Value::Bytes { v })
                    .unwrap_or_else(|| Value::text(s)),
                Ok(s) => Value::from_text(kind, s),
                Err(_) => Value::text("<binary>"),
            },
            Err(e) => Value::text(format!("<{e}>")),
        })
        .collect();
    Row { cells }
}

fn affected(r: &sqlx::postgres::PgQueryResult) -> u64 {
    r.rows_affected()
}

#[async_trait]
impl Driver for PgDriver {
    async fn ping(&self) -> Result<()> {
        self.pools.get(None).await?.execute("SELECT 1").await?;
        Ok(())
    }

    async fn server_info(&self) -> Result<ServerInfo> {
        let version: String = sqlx::query_scalar("SELECT current_setting('server_version')")
            .fetch_one(&self.pools.get(None).await?)
            .await?;
        Ok(ServerInfo { engine: "PostgreSQL".into(), version })
    }

    async fn list_children(&self, path: &[String]) -> Result<Vec<BrowseNode>> {
        let names = |rows: Vec<String>, kind| rows.into_iter().map(|n| BrowseNode::branch(n, kind)).collect();
        match path {
            [] => {
                let rows = sqlx::query_scalar(
                    "SELECT datname::text FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY 1",
                )
                .fetch_all(&self.pools.get(None).await?)
                .await?;
                Ok(names(rows, NodeKind::Database))
            }
            [db] => {
                let rows = sqlx::query_scalar(
                    "SELECT nspname::text FROM pg_namespace \
                     WHERE nspname NOT LIKE 'pg_toast%' AND nspname NOT LIKE 'pg_temp_%' \
                     ORDER BY nspname IN ('pg_catalog', 'information_schema'), nspname",
                )
                .fetch_all(&self.pools.get(Some(db)).await?)
                .await?;
                Ok(names(rows, NodeKind::Schema))
            }
            [_, _] => Ok(vec![
                BrowseNode::branch(FOLDER_TABLES, NodeKind::Folder),
                BrowseNode::branch(FOLDER_VIEWS, NodeKind::Folder),
                BrowseNode::branch(FOLDER_FUNCTIONS, NodeKind::Folder),
            ]),
            [db, schema, folder] => {
                let pool = self.pools.get(Some(db)).await?;
                match folder.as_str() {
                    FOLDER_TABLES | FOLDER_VIEWS => {
                        let (kinds, node) = if folder == FOLDER_TABLES {
                            ("{r,p,f}", NodeKind::Table)
                        } else {
                            ("{v,m}", NodeKind::View)
                        };
                        let rows: Vec<(String, i64, String)> = sqlx::query_as(
                            "SELECT c.relname::text, c.reltuples::int8, c.relkind::text FROM pg_class c \
                             JOIN pg_namespace n ON n.oid = c.relnamespace \
                             WHERE n.nspname = $1 AND c.relkind = ANY($2::char[]) ORDER BY 1",
                        )
                        .bind(schema)
                        .bind(kinds)
                        .fetch_all(&pool)
                        .await?;
                        Ok(rows
                            .into_iter()
                            .map(|(name, est, relkind)| {
                                let n = BrowseNode::branch(name, node);
                                match relkind.as_str() {
                                    "m" => n.with_detail("materialized"),
                                    _ if est >= 0 && node == NodeKind::Table => n.with_detail(approx_rows(est)),
                                    _ => n,
                                }
                            })
                            .collect())
                    }
                    FOLDER_FUNCTIONS => {
                        let rows: Vec<String> = sqlx::query_scalar(
                            "SELECT p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' \
                             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace \
                             WHERE n.nspname = $1 ORDER BY 1",
                        )
                        .bind(schema)
                        .fetch_all(&pool)
                        .await?;
                        Ok(rows.into_iter().map(|n| BrowseNode::leaf(n, NodeKind::Function, None)).collect())
                    }
                    other => Err(CoreError::not_found(format!("folder `{other}`"))),
                }
            }
            [db, schema, _, table] => {
                let rows: Vec<(String, String, bool, bool)> = sqlx::query_as(
                    "SELECT a.attname::text, format_type(a.atttypid, a.atttypmod), a.attnotnull, \
                       EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = a.attrelid \
                               AND i.indisprimary AND a.attnum = ANY(i.indkey)) \
                     FROM pg_attribute a \
                     WHERE a.attrelid = format('%I.%I', $1, $2)::regclass AND a.attnum > 0 AND NOT a.attisdropped \
                     ORDER BY a.attnum",
                )
                .bind(schema)
                .bind(table)
                .fetch_all(&self.pools.get(Some(db)).await?)
                .await?;
                Ok(rows
                    .into_iter()
                    .map(|(name, ty, not_null, pk)| {
                        let mut detail = ty;
                        if pk {
                            detail.push_str(" · PK");
                        } else if not_null {
                            detail.push_str(" · not null");
                        }
                        BrowseNode::leaf(name, NodeKind::Column, Some(detail))
                    })
                    .collect())
            }
            _ => Ok(Vec::new()),
        }
    }

    async fn run_query(
        &self,
        query: &str,
        database: Option<&str>,
        sink: &mut Sink,
        cancel: &CancellationToken,
    ) -> Result<()> {
        let pool = self.pools.get(database).await?;
        let mut conn = pool.acquire().await?;
        let pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()").fetch_one(&mut *conn).await?;

        let end = sqlx_common::stream(&mut *conn, query, sink, cancel, kind_of, decode, affected).await?;
        match end {
            StreamEnd::Finished { saw_rows } => {
                if !saw_rows && classify_sql(query) == StatementKind::Read {
                    if let Some(cols) = sqlx_common::describe(&mut *conn, query, kind_of).await {
                        sink.columns(cols).await;
                    }
                }
                Ok(())
            }
            StreamEnd::Cancelled | StreamEnd::ReaderGone => {
                // Stop the work on the server, then drop this connection rather
                // than return it to the pool mid-result.
                let _ = sqlx::query("SELECT pg_cancel_backend($1)").bind(pid).execute(&pool).await;
                drop(conn.detach());
                if matches!(end, StreamEnd::Cancelled) {
                    Err(CoreError::Cancelled)
                } else {
                    Ok(())
                }
            }
        }
    }

    async fn fetch_window(&self, path: &[String], offset: u64, limit: u32) -> Result<Window> {
        let (db, schema, table) = table_path(path, true)?;
        let schema = schema.unwrap_or("public");
        let pool = self.pools.get(Some(db)).await?;
        let relation = format!("{}.{}", quote_ident(schema, '"'), quote_ident(table, '"'));
        let pk = self.primary_key(&pool, db, schema, table).await?;
        let order = if !pk.is_empty() {
            let cols: Vec<String> = pk.iter().map(|c| quote_ident(c, '"')).collect();
            format!(" ORDER BY {}", cols.join(", "))
        } else if path[2] == FOLDER_TABLES {
            " ORDER BY ctid".to_string()
        } else {
            String::new()
        };
        let sql = format!("SELECT * FROM {relation}{order} LIMIT {limit} OFFSET {offset}");
        let mut window = sqlx_common::collect(&pool, &sql, kind_of, decode).await?;
        if window.columns.is_empty() {
            let probe = format!("SELECT * FROM {relation} LIMIT 0");
            window.columns = sqlx_common::describe(&pool, &probe, kind_of).await.unwrap_or_default();
        }
        Ok(window)
    }

    async fn row_count(&self, path: &[String]) -> Result<RowCount> {
        let (db, schema, table) = table_path(path, true)?;
        let schema = schema.unwrap_or("public");
        let pool = self.pools.get(Some(db)).await?;
        let estimate: i64 = sqlx::query_scalar("SELECT reltuples::int8 FROM pg_class WHERE oid = format('%I.%I', $1, $2)::regclass")
            .bind(schema)
            .bind(table)
            .fetch_one(&pool)
            .await?;
        if estimate >= EXACT_COUNT_BELOW {
            return Ok(RowCount { count: estimate as u64, exact: false });
        }
        let sql = format!("SELECT count(*) FROM {}.{}", quote_ident(schema, '"'), quote_ident(table, '"'));
        let count: i64 = sqlx::query_scalar(&sql).fetch_one(&pool).await?;
        Ok(RowCount { count: count as u64, exact: true })
    }

    fn classify(&self, query: &str) -> StatementKind {
        classify_sql(query)
    }

    async fn close(&self) {
        self.pools.close().await;
    }
}
