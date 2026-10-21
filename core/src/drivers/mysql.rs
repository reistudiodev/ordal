//! MySQL 8.x and MariaDB 10.6+ driver (sqlx). One code path; the engine name
//! comes from `VERSION()`.
//! Browse tree: databases › Tables | Views | Functions › columns.

use std::collections::HashMap;
use std::time::Duration;

use async_trait::async_trait;
use sqlx::mysql::{MySqlConnectOptions, MySqlPoolOptions, MySqlRow, MySqlSslMode};
use sqlx::{Executor, MySqlPool, Row as _};
use tokio_util::sync::CancellationToken;

use super::sqlx_common::{self, quote_ident, Pools, StreamEnd, EXACT_COUNT_BELOW};
use super::{approx_rows, table_path, BrowseNode, Driver, NodeKind, ServerInfo, Sink};
use super::{FOLDER_FUNCTIONS, FOLDER_TABLES, FOLDER_VIEWS};
use crate::config::{ConnectionConfig, TlsMode};
use crate::error::{CoreError, Result};
use crate::sql::{classify_sql, StatementKind};
use crate::value::{Row, RowCount, Value, ValueKind, Window};

pub(crate) struct MySqlDriver {
    pools: Pools<sqlx::MySql>,
    keys: tokio::sync::Mutex<HashMap<(String, String), Vec<String>>>,
}

impl MySqlDriver {
    pub(crate) async fn connect(config: &ConnectionConfig, password: Option<String>) -> Result<Self> {
        let mut base = MySqlConnectOptions::new()
            .host(&config.host)
            .port(config.port)
            .username(&config.username)
            .charset("utf8mb4")
            .ssl_mode(match config.tls {
                TlsMode::Disable => MySqlSslMode::Disabled,
                TlsMode::Prefer => MySqlSslMode::Preferred,
                TlsMode::Require => MySqlSslMode::Required,
            });
        if let Some(p) = password.as_deref() {
            base = base.password(p);
        }
        let read_only = config.read_only;
        let pools = Pools::new(config.database.clone(), move |db| {
            let opts = if db.is_empty() { base.clone() } else { base.clone().database(&db) };
            Box::pin(async move {
                MySqlPoolOptions::new()
                    .max_connections(5)
                    .acquire_timeout(Duration::from_secs(15))
                    .idle_timeout(Duration::from_secs(300))
                    .after_connect(move |conn, _| {
                        Box::pin(async move {
                            if read_only {
                                conn.execute("SET SESSION TRANSACTION READ ONLY").await?;
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

    async fn primary_key(&self, pool: &MySqlPool, db: &str, table: &str) -> Result<Vec<String>> {
        let key = (db.to_string(), table.to_string());
        if let Some(k) = self.keys.lock().await.get(&key) {
            return Ok(k.clone());
        }
        let rows = sqlx::query(
            "SELECT COLUMN_NAME FROM information_schema.STATISTICS \
             WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND INDEX_NAME = 'PRIMARY' ORDER BY SEQ_IN_INDEX",
        )
        .bind(db)
        .bind(table)
        .fetch_all(pool)
        .await?;
        let cols: Vec<String> = rows.iter().map(|r| text(r, 0)).collect();
        self.keys.lock().await.insert(key, cols.clone());
        Ok(cols)
    }

    /// Runs a catalog query and returns its rows as text.
    async fn catalog(&self, sql: &str, binds: &[&str]) -> Result<Vec<Vec<String>>> {
        let mut q = sqlx::query(sql);
        for b in binds {
            q = q.bind(*b);
        }
        let rows = q.fetch_all(&self.pools.get(None).await?).await?;
        Ok(rows.iter().map(|r| (0..r.len()).map(|i| text(r, i)).collect()).collect())
    }
}

/// Reads any column as text without type checks. MySQL 8 reports some
/// information_schema columns as binary strings, which typed decoding rejects.
fn text(row: &MySqlRow, i: usize) -> String {
    match row.try_get_unchecked::<Option<Vec<u8>>, _>(i) {
        Ok(Some(b)) => String::from_utf8_lossy(&b).into_owned(),
        _ => String::new(),
    }
}

pub(crate) fn kind_of(type_name: &str) -> ValueKind {
    let base = type_name.split(' ').next().unwrap_or(type_name);
    match base {
        "BOOLEAN" => ValueKind::Bool,
        "TINYINT" | "SMALLINT" | "MEDIUMINT" | "INT" | "BIGINT" | "YEAR" => ValueKind::Int,
        "FLOAT" | "DOUBLE" => ValueKind::Float,
        "DECIMAL" => ValueKind::Decimal,
        "DATE" => ValueKind::Date,
        "TIME" => ValueKind::Time,
        "DATETIME" | "TIMESTAMP" => ValueKind::Timestamp,
        "JSON" => ValueKind::Json,
        "BINARY" | "VARBINARY" | "BLOB" | "TINYBLOB" | "MEDIUMBLOB" | "LONGBLOB" | "BIT" | "GEOMETRY" => {
            ValueKind::Bytes
        }
        "CHAR" | "VARCHAR" | "TEXT" | "TINYTEXT" | "MEDIUMTEXT" | "LONGTEXT" | "ENUM" | "SET" => ValueKind::Text,
        _ => ValueKind::Other,
    }
}

/// Decodes a text-protocol row (see `sqlx_common`).
fn decode(row: &MySqlRow, kinds: &[ValueKind]) -> Row {
    let cells = kinds
        .iter()
        .enumerate()
        .map(|(i, &kind)| match row.try_get_unchecked::<Option<Vec<u8>>, _>(i) {
            Ok(None) => Value::Null,
            Ok(Some(v)) if kind == ValueKind::Bytes => Value::Bytes { v },
            Ok(Some(v)) => Value::from_text(kind, &String::from_utf8_lossy(&v)),
            Err(e) => Value::text(format!("<{e}>")),
        })
        .collect();
    Row { cells }
}

fn affected(r: &sqlx::mysql::MySqlQueryResult) -> u64 {
    r.rows_affected()
}

#[async_trait]
impl Driver for MySqlDriver {
    async fn ping(&self) -> Result<()> {
        self.pools.get(None).await?.execute("SELECT 1").await?;
        Ok(())
    }

    async fn server_info(&self) -> Result<ServerInfo> {
        let rows = self.catalog("SELECT VERSION()", &[]).await?;
        let version = rows.into_iter().next().and_then(|r| r.into_iter().next()).unwrap_or_default();
        let engine = if version.contains("MariaDB") { "MariaDB" } else { "MySQL" };
        Ok(ServerInfo { engine: engine.into(), version })
    }

    async fn list_children(&self, path: &[String]) -> Result<Vec<BrowseNode>> {
        match path {
            [] => Ok(self
                .catalog("SELECT SCHEMA_NAME FROM information_schema.SCHEMATA ORDER BY SCHEMA_NAME", &[])
                .await?
                .into_iter()
                .map(|r| BrowseNode::branch(&r[0], NodeKind::Database))
                .collect()),
            [_] => Ok(vec![
                BrowseNode::branch(FOLDER_TABLES, NodeKind::Folder),
                BrowseNode::branch(FOLDER_VIEWS, NodeKind::Folder),
                BrowseNode::branch(FOLDER_FUNCTIONS, NodeKind::Folder),
            ]),
            [db, folder] => match folder.as_str() {
                FOLDER_TABLES => Ok(self
                    .catalog(
                        "SELECT TABLE_NAME, TABLE_ROWS FROM information_schema.TABLES \
                         WHERE TABLE_SCHEMA = ? AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME",
                        &[db],
                    )
                    .await?
                    .into_iter()
                    .map(|r| {
                        let n = BrowseNode::branch(&r[0], NodeKind::Table);
                        match r[1].parse() {
                            Ok(est) => n.with_detail(approx_rows(est)),
                            Err(_) => n,
                        }
                    })
                    .collect()),
                FOLDER_VIEWS => Ok(self
                    .catalog(
                        "SELECT TABLE_NAME FROM information_schema.TABLES \
                         WHERE TABLE_SCHEMA = ? AND TABLE_TYPE IN ('VIEW', 'SYSTEM VIEW') ORDER BY TABLE_NAME",
                        &[db],
                    )
                    .await?
                    .into_iter()
                    .map(|r| BrowseNode::branch(&r[0], NodeKind::View))
                    .collect()),
                FOLDER_FUNCTIONS => Ok(self
                    .catalog(
                        "SELECT ROUTINE_NAME, ROUTINE_TYPE FROM information_schema.ROUTINES \
                         WHERE ROUTINE_SCHEMA = ? ORDER BY ROUTINE_NAME",
                        &[db],
                    )
                    .await?
                    .into_iter()
                    .map(|r| BrowseNode::leaf(&r[0], NodeKind::Function, Some(r[1].to_lowercase())))
                    .collect()),
                other => Err(CoreError::not_found(format!("folder `{other}`"))),
            },
            [db, _, table] => Ok(self
                .catalog(
                    "SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY FROM information_schema.COLUMNS \
                     WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION",
                    &[db, table],
                )
                .await?
                .into_iter()
                .map(|r| {
                    let mut detail = r[1].clone();
                    if r[3] == "PRI" {
                        detail.push_str(" · PK");
                    } else if r[2] == "NO" {
                        detail.push_str(" · not null");
                    }
                    BrowseNode::leaf(&r[0], NodeKind::Column, Some(detail))
                })
                .collect()),
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
        let id: u64 = sqlx::query_scalar("SELECT CONNECTION_ID()").fetch_one(&mut *conn).await?;

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
                let _ = pool.execute(format!("KILL QUERY {id}").as_str()).await;
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
        let (db, _, table) = table_path(path, false)?;
        let pool = self.pools.get(None).await?;
        let relation = format!("{}.{}", quote_ident(db, '`'), quote_ident(table, '`'));
        let pk = self.primary_key(&pool, db, table).await?;
        let order = if pk.is_empty() {
            String::new()
        } else {
            let cols: Vec<String> = pk.iter().map(|c| quote_ident(c, '`')).collect();
            format!(" ORDER BY {}", cols.join(", "))
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
        let (db, _, table) = table_path(path, false)?;
        let est = self
            .catalog(
                "SELECT TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?",
                &[db, table],
            )
            .await?
            .into_iter()
            .next()
            .and_then(|r| r[0].parse::<i64>().ok());
        if let Some(est) = est.filter(|&e| e >= EXACT_COUNT_BELOW) {
            return Ok(RowCount { count: est as u64, exact: false });
        }
        let sql = format!("SELECT COUNT(*) FROM {}.{}", quote_ident(db, '`'), quote_ident(table, '`'));
        let count: i64 = sqlx::query_scalar(&sql).fetch_one(&self.pools.get(None).await?).await?;
        Ok(RowCount { count: count as u64, exact: true })
    }

    fn classify(&self, query: &str) -> StatementKind {
        classify_sql(query)
    }

    async fn close(&self) {
        self.pools.close().await;
    }
}
