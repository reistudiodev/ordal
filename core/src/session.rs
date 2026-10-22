//! FFI objects for an open connection and a running query.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::config::ConnectionConfig;
use crate::drivers::{BrowseNode, Driver, KeyInfo, Msg, ServerInfo, Sink, CHANNEL_CHUNKS};
use crate::error::{CoreError, Result};
use crate::runtime::{self, run};
use crate::sql::StatementKind;
use crate::table::{CellEdit, PageCursor, SchemaGraph, SortSpec, TableMeta, TablePage};
use crate::value::{ColumnInfo, Page, Row, RowCount};

/// One open connection (internally a small pool). Cheap to share between tabs.
#[derive(uniffi::Object)]
pub struct Session {
    config: ConnectionConfig,
    driver: Arc<dyn Driver>,
}

impl Session {
    pub(crate) fn new(config: ConnectionConfig, driver: Box<dyn Driver>) -> Self {
        Self { config, driver: Arc::from(driver) }
    }
}

#[uniffi::export]
impl Session {
    pub fn config(&self) -> ConnectionConfig {
        self.config.clone()
    }

    pub fn read_only(&self) -> bool {
        self.config.read_only
    }

    /// Round-trip time in milliseconds.
    pub async fn ping(&self) -> Result<f64> {
        let d = self.driver.clone();
        run(async move {
            let start = Instant::now();
            d.ping().await?;
            Ok(start.elapsed().as_secs_f64() * 1000.0)
        })
        .await
    }

    pub async fn server_info(&self) -> Result<ServerInfo> {
        let d = self.driver.clone();
        run(async move { d.server_info().await }).await
    }

    /// Children of the browse-tree node at `path`; `[]` is the root.
    pub async fn list_children(&self, path: Vec<String>) -> Result<Vec<BrowseNode>> {
        let d = self.driver.clone();
        run(async move { d.list_children(&path).await }).await
    }

    /// Classifies `query` in this engine's language, for confirmation prompts.
    pub fn classify(&self, query: String) -> StatementKind {
        self.driver.classify(&query)
    }

    /// Starts `query` and returns at once. Rows are pulled with
    /// [`QueryCursor::next_page`]; errors arrive there too.
    pub fn query(&self, query: String, database: Option<String>) -> Result<Arc<QueryCursor>> {
        if self.config.read_only && self.driver.classify(&query) != StatementKind::Read {
            return Err(CoreError::ReadOnly {
                message: "this connection is read-only; only read statements can run".into(),
            });
        }
        let (tx, rx) = mpsc::channel(CHANNEL_CHUNKS);
        let cancel = CancellationToken::new();
        let cursor = Arc::new(QueryCursor::new(rx, cancel.clone()));
        let driver = self.driver.clone();
        runtime::handle().spawn(async move {
            let mut sink = Sink::new(tx);
            let result = driver.run_query(&query, database.as_deref(), &mut sink, &cancel).await;
            sink.finish(result).await;
        });
        Ok(cursor)
    }

    /// Column types, keys and editability of a table or collection.
    pub async fn table_meta(&self, path: Vec<String>) -> Result<TableMeta> {
        let d = self.driver.clone();
        run(async move { d.table_meta(&path).await }).await
    }

    /// One page of a table or collection, optionally sorted on the server.
    pub async fn fetch_page(&self, path: Vec<String>, cursor: PageCursor, size: u32, sort: Option<SortSpec>) -> Result<TablePage> {
        let d = self.driver.clone();
        let size = size.clamp(1, 10_000);
        run(async move { d.fetch_page(&path, &cursor, size, sort.as_ref()).await }).await
    }

    /// The engine's estimate, or an exact count (bounded by a timeout) when `exact`.
    pub async fn row_count(&self, path: Vec<String>, exact: bool) -> Result<RowCount> {
        let d = self.driver.clone();
        run(async move { d.row_count(&path, exact).await }).await
    }

    /// The statements `apply_edits` would run, for the review sheet.
    pub async fn preview_edits(&self, path: Vec<String>, edits: Vec<CellEdit>) -> Result<Vec<String>> {
        let d = self.driver.clone();
        run(async move { d.preview_edits(&path, &edits).await }).await
    }

    /// Applies staged cell edits in one transaction. Returns how many were applied.
    pub async fn apply_edits(&self, path: Vec<String>, edits: Vec<CellEdit>) -> Result<u64> {
        if self.config.read_only {
            return Err(CoreError::ReadOnly { message: "this connection is read-only".into() });
        }
        let d = self.driver.clone();
        run(async move { d.apply_edits(&path, &edits).await }).await
    }

    /// Tables and relations under a schema or database, for the diagram.
    pub async fn schema_graph(&self, path: Vec<String>) -> Result<SchemaGraph> {
        let d = self.driver.clone();
        run(async move { d.schema_graph(&path).await }).await
    }

    /// Type, TTL and memory of the key at `path` (Redis).
    pub async fn key_info(&self, path: Vec<String>) -> Result<KeyInfo> {
        let d = self.driver.clone();
        run(async move { d.key_info(&path).await }).await
    }

    pub async fn close(&self) {
        let d = self.driver.clone();
        let _ = run(async move {
            d.close().await;
            Ok(())
        })
        .await;
    }
}

/// A running query. Dropping it cancels the query.
#[derive(uniffi::Object)]
pub struct QueryCursor {
    cancel: CancellationToken,
    started: Instant,
    state: tokio::sync::Mutex<CursorState>,
    summary: Mutex<Summary>,
}

struct CursorState {
    rx: mpsc::Receiver<Msg>,
    columns: Option<Vec<ColumnInfo>>,
    buffer: VecDeque<Row>,
}

#[derive(Default)]
struct Summary {
    finished: Option<Duration>,
    rows_affected: Option<u64>,
}

impl QueryCursor {
    fn new(rx: mpsc::Receiver<Msg>, cancel: CancellationToken) -> Self {
        Self {
            cancel,
            started: Instant::now(),
            state: tokio::sync::Mutex::new(CursorState { rx, columns: None, buffer: VecDeque::new() }),
            summary: Mutex::new(Summary::default()),
        }
    }

    fn is_finished(&self) -> bool {
        self.summary.lock().unwrap().finished.is_some()
    }

    fn apply(&self, state: &mut CursorState, msg: Option<Msg>) -> Result<()> {
        let finish = |rows_affected| {
            let mut s = self.summary.lock().unwrap();
            s.finished.get_or_insert(self.started.elapsed());
            s.rows_affected = rows_affected;
        };
        match msg {
            Some(Msg::Columns(c)) => state.columns = Some(c),
            Some(Msg::Rows(r)) => state.buffer.extend(r),
            Some(Msg::Done { rows_affected }) => finish(rows_affected),
            Some(Msg::Failed(e)) => {
                finish(None);
                return Err(e);
            }
            None => finish(None),
        }
        Ok(())
    }
}

#[uniffi::export]
impl QueryCursor {
    /// Waits until the result's columns are known. Empty for statements
    /// that return no rows.
    pub async fn columns(&self) -> Result<Vec<ColumnInfo>> {
        let mut state = self.state.lock().await;
        while state.columns.is_none() && !self.is_finished() {
            let msg = state.rx.recv().await;
            self.apply(&mut state, msg)?;
        }
        Ok(state.columns.clone().unwrap_or_default())
    }

    /// Up to `max_rows` rows. Waits for at least one row (or the end), then
    /// returns whatever has arrived, so the first rows show up quickly.
    pub async fn next_page(&self, max_rows: u32) -> Result<Page> {
        let max = max_rows.max(1) as usize;
        let mut state = self.state.lock().await;
        while state.buffer.is_empty() && !self.is_finished() {
            let msg = state.rx.recv().await;
            self.apply(&mut state, msg)?;
        }
        while state.buffer.len() < max && !self.is_finished() {
            match state.rx.try_recv() {
                Ok(msg) => self.apply(&mut state, Some(msg))?,
                Err(mpsc::error::TryRecvError::Empty) => break,
                Err(mpsc::error::TryRecvError::Disconnected) => self.apply(&mut state, None)?,
            }
        }
        let n = max.min(state.buffer.len());
        let rows: Vec<Row> = state.buffer.drain(..n).collect();
        let done = state.buffer.is_empty() && self.is_finished();
        Ok(Page { rows, done })
    }

    /// Stops the query, on the server too where the engine supports it.
    pub fn cancel(&self) {
        self.cancel.cancel();
    }

    /// Set once the query has finished; for writes, the rows changed.
    pub fn rows_affected(&self) -> Option<u64> {
        self.summary.lock().unwrap().rows_affected
    }

    /// Time until the last row arrived, or the time so far while running.
    pub fn elapsed_ms(&self) -> u64 {
        let s = self.summary.lock().unwrap();
        s.finished.unwrap_or_else(|| self.started.elapsed()).as_millis() as u64
    }

    pub fn is_done(&self) -> bool {
        self.is_finished()
    }
}

impl Drop for QueryCursor {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}
