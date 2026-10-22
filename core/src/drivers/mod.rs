//! The driver contract. Every engine implements [`Driver`]; nothing above this
//! module knows which engine it is talking to.

use std::time::{Duration, Instant};

use async_trait::async_trait;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::config::{ConnectionConfig, DatabaseKind};
use crate::error::{CoreError, Result};
use crate::sql::StatementKind;
use crate::table::{CellEdit, PageCursor, SchemaGraph, SortSpec, TableMeta, TablePage};
use crate::value::{ColumnInfo, Row, RowCount};

#[cfg(feature = "mongodb")]
mod mongodb;
#[cfg(feature = "mysql")]
mod mysql;
#[cfg(feature = "postgres")]
mod postgres;
#[cfg(feature = "redis")]
mod redis;
#[cfg(any(feature = "postgres", feature = "mysql", feature = "sqlite"))]
mod sql_paging;
#[cfg(any(feature = "postgres", feature = "mysql", feature = "sqlite"))]
mod sqlx_common;
#[cfg(feature = "sqlite")]
mod sqlite;

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ServerInfo {
    /// e.g. "PostgreSQL", "MariaDB", "Redis".
    pub engine: String,
    pub version: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NodeKind {
    Database,
    Schema,
    /// A grouping such as "Tables" or "Views".
    Folder,
    Table,
    View,
    Function,
    Column,
    Collection,
    Index,
    /// A Redis key prefix group (`user:`).
    KeyPrefix,
    Key,
}

/// One entry in the object browser. Its path is the parent path plus `name`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct BrowseNode {
    pub name: String,
    pub kind: NodeKind,
    pub has_children: bool,
    /// Secondary text: a column type, a key count, a Redis key type.
    pub detail: Option<String>,
}

impl BrowseNode {
    pub(crate) fn branch(name: impl Into<String>, kind: NodeKind) -> Self {
        Self { name: name.into(), kind, has_children: true, detail: None }
    }
    pub(crate) fn leaf(name: impl Into<String>, kind: NodeKind, detail: Option<String>) -> Self {
        Self { name: name.into(), kind, has_children: false, detail }
    }
    pub(crate) fn with_detail(mut self, detail: impl Into<String>) -> Self {
        self.detail = Some(detail.into());
        self
    }
}

/// Header details for a Redis key tab.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct KeyInfo {
    /// string, hash, list, set, zset, stream, ReJSON-RL...
    pub key_type: String,
    /// None when the key has no expiry.
    pub ttl_ms: Option<i64>,
    pub memory_bytes: Option<u64>,
}

/// `~1.2M rows`, `~12K rows`, `~950 rows` for browser details.
pub(crate) fn approx_rows(n: i64) -> String {
    let n = n.max(0) as f64;
    let (v, unit) = match n {
        n if n >= 1e9 => (n / 1e9, "B"),
        n if n >= 1e6 => (n / 1e6, "M"),
        n if n >= 1e3 => (n / 1e3, "K"),
        n => (n, ""),
    };
    if unit.is_empty() || v >= 10.0 {
        format!("~{v:.0}{unit} rows")
    } else {
        format!("~{:.1}{unit} rows", v).replace(".0", "")
    }
}

/// Above this, an engine's row estimate is good enough for a scrollbar.
pub(crate) const EXACT_COUNT_BELOW: i64 = 100_000;

pub(crate) const FOLDER_TABLES: &str = "Tables";
pub(crate) const FOLDER_VIEWS: &str = "Views";
pub(crate) const FOLDER_FUNCTIONS: &str = "Functions";

#[async_trait]
pub(crate) trait Driver: Send + Sync {
    async fn ping(&self) -> Result<()>;
    async fn server_info(&self) -> Result<ServerInfo>;
    /// Children of the node at `path` (empty path = the root level).
    async fn list_children(&self, path: &[String]) -> Result<Vec<BrowseNode>>;
    /// Runs `query` and streams its rows into `sink` until done or cancelled.
    async fn run_query(
        &self,
        query: &str,
        database: Option<&str>,
        sink: &mut Sink,
        cancel: &CancellationToken,
    ) -> Result<()>;
    /// Column types, keys and whether rows can be edited.
    async fn table_meta(&self, _path: &[String]) -> Result<TableMeta> {
        Err(CoreError::unsupported("this engine has no tables"))
    }
    /// One page of a table or collection (see `table` for the paging rules).
    async fn fetch_page(
        &self,
        _path: &[String],
        _cursor: &PageCursor,
        _size: u32,
        _sort: Option<&SortSpec>,
    ) -> Result<TablePage> {
        Err(CoreError::unsupported("this engine has no tables"))
    }
    /// The engine's estimate, or an exact count (bounded by a timeout) when asked.
    async fn row_count(&self, _path: &[String], _exact: bool) -> Result<RowCount> {
        Err(CoreError::unsupported("this engine has no tables"))
    }
    /// The statements `apply_edits` would run, for the review sheet.
    async fn preview_edits(&self, _path: &[String], _edits: &[CellEdit]) -> Result<Vec<String>> {
        Err(CoreError::unsupported("editing is not available for this engine"))
    }
    /// Applies all edits in one transaction; any missing row aborts them all.
    async fn apply_edits(&self, _path: &[String], _edits: &[CellEdit]) -> Result<u64> {
        Err(CoreError::unsupported("editing is not available for this engine"))
    }
    /// Tables and their relations under `path` (a schema or database).
    async fn schema_graph(&self, _path: &[String]) -> Result<SchemaGraph> {
        Err(CoreError::unsupported("relations are only available for SQL databases and MongoDB"))
    }
    /// Type, TTL and size of a key (key-value stores only).
    async fn key_info(&self, _path: &[String]) -> Result<KeyInfo> {
        Err(CoreError::unsupported("key details are only available for Redis"))
    }
    /// Safety classification in this engine's query language.
    fn classify(&self, query: &str) -> StatementKind;
    async fn close(&self);
}

/// Opens a driver for `config`. Connects eagerly so bad settings fail here.
pub(crate) async fn connect(config: &ConnectionConfig, password: Option<String>) -> Result<Box<dyn Driver>> {
    config.validate()?;
    match config.kind {
        #[cfg(feature = "postgres")]
        DatabaseKind::Postgres => Ok(Box::new(postgres::PgDriver::connect(config, password).await?)),
        #[cfg(feature = "mysql")]
        DatabaseKind::MySql => Ok(Box::new(mysql::MySqlDriver::connect(config, password).await?)),
        #[cfg(feature = "sqlite")]
        DatabaseKind::Sqlite => Ok(Box::new(sqlite::SqliteDriver::connect(config).await?)),
        #[cfg(feature = "mongodb")]
        DatabaseKind::MongoDb => Ok(Box::new(mongodb::MongoDriver::connect(config, password).await?)),
        #[cfg(feature = "redis")]
        DatabaseKind::Redis => Ok(Box::new(redis::RedisDriver::connect(config, password).await?)),
        #[allow(unreachable_patterns)]
        other => Err(CoreError::unsupported(format!("{other:?} support was not compiled in"))),
    }
}

/// Messages from a running query to its cursor.
pub(crate) enum Msg {
    Columns(Vec<ColumnInfo>),
    Rows(Vec<Row>),
    Done { rows_affected: Option<u64> },
    Failed(CoreError),
}

/// Rows are sent in chunks; the channel holds a few, so a slow reader
/// applies back-pressure and the core never buffers a whole result.
pub(crate) const CHUNK_ROWS: usize = 256;
pub(crate) const CHANNEL_CHUNKS: usize = 4;
const FLUSH_AFTER: Duration = Duration::from_millis(100);

/// Where a driver writes a query's output.
pub(crate) struct Sink {
    tx: mpsc::Sender<Msg>,
    chunk: Vec<Row>,
    chunk_started: Instant,
    columns_sent: bool,
    rows_affected: Option<u64>,
}

impl Sink {
    pub(crate) fn new(tx: mpsc::Sender<Msg>) -> Self {
        Self {
            tx,
            chunk: Vec::with_capacity(CHUNK_ROWS),
            chunk_started: Instant::now(),
            columns_sent: false,
            rows_affected: None,
        }
    }

    /// Announces the result's columns. Only the first call counts.
    pub(crate) async fn columns(&mut self, cols: Vec<ColumnInfo>) -> bool {
        if self.columns_sent {
            return true;
        }
        self.columns_sent = true;
        self.tx.send(Msg::Columns(cols)).await.is_ok()
    }

    /// Adds a row. Returns false once nobody is reading any more.
    pub(crate) async fn push(&mut self, row: Row) -> bool {
        if self.chunk.is_empty() {
            self.chunk_started = Instant::now();
        }
        self.chunk.push(row);
        if self.chunk.len() >= CHUNK_ROWS || self.chunk_started.elapsed() >= FLUSH_AFTER {
            return self.flush().await;
        }
        true
    }

    pub(crate) async fn flush(&mut self) -> bool {
        if self.chunk.is_empty() {
            return !self.tx.is_closed();
        }
        let rows = std::mem::replace(&mut self.chunk, Vec::with_capacity(CHUNK_ROWS));
        self.tx.send(Msg::Rows(rows)).await.is_ok()
    }

    pub(crate) fn add_affected(&mut self, n: u64) {
        self.rows_affected = Some(self.rows_affected.unwrap_or(0) + n);
    }

    /// Sends the final message for `result`.
    pub(crate) async fn finish(mut self, result: Result<()>) {
        let last = match result {
            Ok(()) => {
                self.flush().await;
                if !self.columns_sent {
                    let _ = self.tx.send(Msg::Columns(Vec::new())).await;
                }
                Msg::Done { rows_affected: self.rows_affected }
            }
            Err(e) => Msg::Failed(e),
        };
        let _ = self.tx.send(last).await;
    }
}

/// Splits a browse path for engines whose table paths look like
/// `[db, schema, "Tables", table]`. Returns (db, schema, table).
pub(crate) fn table_path(path: &[String], with_schema: bool) -> Result<(&str, Option<&str>, &str)> {
    let bad = || CoreError::invalid("not a table or view path");
    if with_schema {
        match path {
            [db, schema, folder, table] if is_relation_folder(folder) => Ok((db, Some(schema), table)),
            _ => Err(bad()),
        }
    } else {
        match path {
            [db, folder, table] if is_relation_folder(folder) => Ok((db, None, table)),
            _ => Err(bad()),
        }
    }
}

fn is_relation_folder(f: &str) -> bool {
    f == FOLDER_TABLES || f == FOLDER_VIEWS
}

/// Runs a future (or a driver's `IntoFuture` action) until it finishes or `cancel` fires.
pub(crate) async fn or_cancel<F, T>(cancel: &CancellationToken, fut: F) -> Option<T>
where
    F: std::future::IntoFuture<Output = T>,
{
    tokio::select! {
        biased;
        _ = cancel.cancelled() => None,
        v = fut.into_future() => Some(v),
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn approx_rows() {
        assert_eq!(super::approx_rows(950), "~950 rows");
        assert_eq!(super::approx_rows(1_000_000), "~1M rows");
        assert_eq!(super::approx_rows(1_250_000), "~1.2M rows");
        assert_eq!(super::approx_rows(12_345), "~12K rows");
    }
}
