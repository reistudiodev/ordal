//! SQLite driver (sqlx). The connection's `host` is the database file path.
//! Browse tree: databases (main + attached) › Tables | Views › columns.

use std::str::FromStr;
use std::time::Duration;

use async_trait::async_trait;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions, SqliteRow};
use sqlx::{Executor, Row as _, SqlitePool, TypeInfo, ValueRef};
use tokio_util::sync::CancellationToken;

use super::sqlx_common::{self, quote_ident, StreamEnd};
use super::{table_path, BrowseNode, Driver, NodeKind, ServerInfo, Sink, FOLDER_TABLES, FOLDER_VIEWS};
use crate::config::ConnectionConfig;
use crate::error::{CoreError, Result};
use crate::sql::{classify_sql, StatementKind};
use crate::value::{Row, RowCount, Value, ValueKind, Window};

pub(crate) struct SqliteDriver {
    pool: SqlitePool,
}

impl SqliteDriver {
    pub(crate) async fn connect(config: &ConnectionConfig) -> Result<Self> {
        let memory = config.host == ":memory:";
        let opts = if memory {
            SqliteConnectOptions::from_str("sqlite::memory:")?
        } else {
            // Never create a stray file because of a typo in the path.
            SqliteConnectOptions::new().filename(&config.host).create_if_missing(false)
        };
        let opts = opts.read_only(config.read_only).busy_timeout(Duration::from_secs(5));
        let pool_opts = SqlitePoolOptions::new().acquire_timeout(Duration::from_secs(15));
        // An in-memory database lives and dies with its one connection.
        let pool_opts = if memory {
            pool_opts.max_connections(1).min_connections(1).idle_timeout(None).max_lifetime(None)
        } else {
            pool_opts.max_connections(4)
        };
        Ok(Self { pool: pool_opts.connect_with(opts).await? })
    }

    async fn primary_key(&self, db: &str, table: &str) -> Result<Vec<String>> {
        let rows: Vec<(String,)> =
            sqlx::query_as("SELECT name FROM pragma_table_info(?1, ?2) WHERE pk > 0 ORDER BY pk")
                .bind(table)
                .bind(db)
                .fetch_all(&self.pool)
                .await?;
        Ok(rows.into_iter().map(|(n,)| n).collect())
    }
}

/// Maps a declared column type using SQLite's affinity rules.
pub(crate) fn kind_of(declared: &str) -> ValueKind {
    let t = declared.to_ascii_uppercase();
    if t.contains("BOOL") {
        ValueKind::Bool
    } else if t.contains("INT") {
        ValueKind::Int
    } else if t.contains("REAL") || t.contains("FLOA") || t.contains("DOUB") {
        ValueKind::Float
    } else if t.contains("NUMERIC") || t.contains("DECIMAL") {
        ValueKind::Decimal
    } else if t.contains("DATETIME") || t.contains("TIMESTAMP") {
        ValueKind::Timestamp
    } else if t.contains("DATE") {
        ValueKind::Date
    } else if t.contains("TIME") {
        ValueKind::Time
    } else if t.contains("JSON") {
        ValueKind::Json
    } else if t.contains("BLOB") {
        ValueKind::Bytes
    } else if t.contains("CHAR") || t.contains("CLOB") || t.contains("TEXT") {
        ValueKind::Text
    } else {
        ValueKind::Other
    }
}

/// SQLite values are dynamically typed, so decode by each value's storage
/// class and use the declared kind only to refine text and booleans.
fn decode(row: &SqliteRow, kinds: &[ValueKind]) -> Row {
    let cells = kinds
        .iter()
        .enumerate()
        .map(|(i, &kind)| {
            let storage = match row.try_get_raw(i) {
                Ok(v) if v.is_null() => return Value::Null,
                Ok(v) => v.type_info().name().to_string(),
                Err(e) => return Value::text(format!("<{e}>")),
            };
            match storage.as_str() {
                "INTEGER" => match row.try_get_unchecked::<i64, _>(i) {
                    Ok(v) if kind == ValueKind::Bool => Value::Bool { v: v != 0 },
                    Ok(v) => Value::Int { v },
                    Err(e) => Value::text(format!("<{e}>")),
                },
                "REAL" => row.try_get_unchecked::<f64, _>(i).map_or(Value::Null, |v| Value::Float { v }),
                "BLOB" => row.try_get_unchecked::<Vec<u8>, _>(i).map_or(Value::Null, |v| Value::Bytes { v }),
                _ => match row.try_get_unchecked::<String, _>(i) {
                    Ok(s) => Value::from_text(kind, &s),
                    Err(e) => Value::text(format!("<{e}>")),
                },
            }
        })
        .collect();
    Row { cells }
}

fn affected(r: &sqlx::sqlite::SqliteQueryResult) -> u64 {
    r.rows_affected()
}

#[async_trait]
impl Driver for SqliteDriver {
    async fn ping(&self) -> Result<()> {
        self.pool.execute("SELECT 1").await?;
        Ok(())
    }

    async fn server_info(&self) -> Result<ServerInfo> {
        let version: String = sqlx::query_scalar("SELECT sqlite_version()").fetch_one(&self.pool).await?;
        Ok(ServerInfo { engine: "SQLite".into(), version })
    }

    async fn list_children(&self, path: &[String]) -> Result<Vec<BrowseNode>> {
        match path {
            [] => {
                let rows: Vec<(i64, String)> = sqlx::query_as("SELECT seq, name FROM pragma_database_list")
                    .fetch_all(&self.pool)
                    .await?;
                Ok(rows
                    .into_iter()
                    .filter(|(_, n)| n != "temp")
                    .map(|(_, n)| BrowseNode::branch(n, NodeKind::Database))
                    .collect())
            }
            [_] => Ok(vec![
                BrowseNode::branch(FOLDER_TABLES, NodeKind::Folder),
                BrowseNode::branch(FOLDER_VIEWS, NodeKind::Folder),
            ]),
            [db, folder] => {
                let (ty, kind) = match folder.as_str() {
                    FOLDER_TABLES => ("table", NodeKind::Table),
                    FOLDER_VIEWS => ("view", NodeKind::View),
                    other => return Err(CoreError::not_found(format!("folder `{other}`"))),
                };
                let sql = format!(
                    "SELECT name FROM {}.sqlite_master WHERE type = ?1 AND name NOT LIKE 'sqlite_%' ORDER BY name",
                    quote_ident(db, '"')
                );
                let rows: Vec<(String,)> = sqlx::query_as(&sql).bind(ty).fetch_all(&self.pool).await?;
                Ok(rows.into_iter().map(|(n,)| BrowseNode::branch(n, kind)).collect())
            }
            [db, _, table] => {
                let rows: Vec<(String, String, bool, i64)> =
                    sqlx::query_as("SELECT name, type, \"notnull\", pk FROM pragma_table_info(?1, ?2) ORDER BY cid")
                        .bind(table)
                        .bind(db)
                        .fetch_all(&self.pool)
                        .await?;
                Ok(rows
                    .into_iter()
                    .map(|(name, ty, not_null, pk)| {
                        let mut detail = if ty.is_empty() { "any".to_string() } else { ty.to_lowercase() };
                        if pk > 0 {
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
        _database: Option<&str>,
        sink: &mut Sink,
        cancel: &CancellationToken,
    ) -> Result<()> {
        let mut conn = self.pool.acquire().await?;
        {
            // There is no server to cancel on: have SQLite abort a statement
            // stuck inside one step (e.g. a long aggregate) once cancelled.
            let token = cancel.clone();
            conn.lock_handle().await?.set_progress_handler(10_000, move || !token.is_cancelled());
        }
        let end = sqlx_common::stream(&mut *conn, query, sink, cancel, kind_of, decode, affected).await;
        if let Ok(mut handle) = conn.lock_handle().await {
            handle.remove_progress_handler();
        }
        let end = match end {
            // The progress handler's abort surfaces as an "interrupted" error.
            Err(_) if cancel.is_cancelled() => StreamEnd::Cancelled,
            other => other?,
        };
        match end {
            StreamEnd::Finished { saw_rows } => {
                if !saw_rows && classify_sql(query) == StatementKind::Read {
                    if let Some(cols) = sqlx_common::describe(&mut *conn, query, kind_of).await {
                        sink.columns(cols).await;
                    }
                }
                Ok(())
            }
            // Dropping the stream stops stepping the statement; there is no server.
            StreamEnd::Cancelled => Err(CoreError::Cancelled),
            StreamEnd::ReaderGone => Ok(()),
        }
    }

    async fn fetch_window(&self, path: &[String], offset: u64, limit: u32) -> Result<Window> {
        let (db, _, table) = table_path(path, false)?;
        let relation = format!("{}.{}", quote_ident(db, '"'), quote_ident(table, '"'));
        let pk = self.primary_key(db, table).await?;
        let order = if !pk.is_empty() {
            let cols: Vec<String> = pk.iter().map(|c| quote_ident(c, '"')).collect();
            format!(" ORDER BY {}", cols.join(", "))
        } else if path[1] == FOLDER_TABLES {
            " ORDER BY rowid".to_string()
        } else {
            String::new()
        };
        let sql = format!("SELECT * FROM {relation}{order} LIMIT {limit} OFFSET {offset}");
        let mut window = sqlx_common::collect(&self.pool, &sql, kind_of, decode).await?;
        if window.columns.is_empty() {
            let probe = format!("SELECT * FROM {relation} LIMIT 0");
            window.columns = sqlx_common::describe(&self.pool, &probe, kind_of).await.unwrap_or_default();
        }
        Ok(window)
    }

    async fn row_count(&self, path: &[String]) -> Result<RowCount> {
        let (db, _, table) = table_path(path, false)?;
        let sql = format!("SELECT count(*) FROM {}.{}", quote_ident(db, '"'), quote_ident(table, '"'));
        let count: i64 = sqlx::query_scalar(&sql).fetch_one(&self.pool).await?;
        Ok(RowCount { count: count as u64, exact: true })
    }

    fn classify(&self, query: &str) -> StatementKind {
        classify_sql(query)
    }

    async fn close(&self) {
        self.pool.close().await;
    }
}
