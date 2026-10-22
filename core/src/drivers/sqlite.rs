//! SQLite driver (sqlx). The connection's `host` is the database file path.
//! Browse tree: databases (main + attached) › Tables | Views › columns.

use std::collections::HashMap;
use std::str::FromStr;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions, SqliteRow};
use sqlx::{Executor, Row as _, SqlitePool, TypeInfo, ValueRef};
use tokio_util::sync::CancellationToken;

use super::sql_paging::{page_sql, split_hidden, update_statements, Dialect, KeyCol, SortCol};
use super::sqlx_common::{self, quote_ident, StreamEnd};
use super::{table_path, BrowseNode, Driver, NodeKind, ServerInfo, Sink, EXACT_COUNT_BELOW, FOLDER_TABLES, FOLDER_VIEWS};
use crate::config::ConnectionConfig;
use crate::error::{CoreError, Result};
use crate::sql::{classify_sql, StatementKind};
use crate::table::{
    assemble, CellEdit, ColumnMeta, GraphColumn, GraphTable, PageCursor, PagingMode, Relation, SchemaGraph, SortSpec, TableMeta,
    TablePage,
};
use crate::value::{Row, RowCount, Value, ValueKind};

pub(crate) struct SqliteDriver {
    pool: SqlitePool,
    read_only: bool,
    tables: tokio::sync::Mutex<HashMap<Vec<String>, Arc<LiteTable>>>,
}

struct LiteTable {
    meta: TableMeta,
    relation: String,
    is_view: bool,
    /// The table has no declared primary key and pages/edits by rowid.
    by_rowid: bool,
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
        Ok(Self { pool: pool_opts.connect_with(opts).await?, read_only: config.read_only, tables: Default::default() })
    }

    async fn load_table(&self, path: &[String]) -> Result<Arc<LiteTable>> {
        let (db, _, table) = table_path(path, false)?;
        let sql = format!("SELECT type FROM {}.sqlite_master WHERE name = ?1", quote_ident(db, '"'));
        let kind: String = sqlx::query_scalar(&sql)
            .bind(table)
            .fetch_optional(&self.pool)
            .await?
            .ok_or_else(|| CoreError::not_found(format!("table `{table}`")))?;
        let is_view = kind == "view";
        let cols: Vec<(String, String, bool, Option<String>, i64, i64)> = sqlx::query_as(
            "SELECT name, type, \"notnull\", dflt_value, pk, hidden FROM pragma_table_xinfo(?1, ?2) ORDER BY cid",
        )
        .bind(table)
        .bind(db)
        .fetch_all(&self.pool)
        .await?;
        let indexed: Vec<String> = sqlx::query_scalar(
            "SELECT ii.name FROM pragma_index_list(?1, ?2) il, pragma_index_info(il.name, ?2) ii WHERE ii.seqno = 0",
        )
        .bind(table)
        .bind(db)
        .fetch_all(&self.pool)
        .await?;
        let mut pk: Vec<(i64, String)> = cols.iter().filter(|c| c.4 > 0).map(|c| (c.4, c.0.clone())).collect();
        pk.sort();
        let mut key_columns: Vec<String> = pk.into_iter().map(|(_, n)| n).collect();
        let by_rowid = key_columns.is_empty() && !is_view;
        if by_rowid {
            key_columns.push("rowid".into());
        }
        let read_only_reason = if self.read_only {
            Some("This connection is read-only.".to_string())
        } else if is_view {
            Some("Views can't be edited here.".to_string())
        } else {
            None
        };
        let editable = read_only_reason.is_none();
        let columns = cols
            .into_iter()
            .map(|(name, ty, not_null, default, pk, hidden)| {
                let is_key = pk > 0;
                ColumnMeta {
                    kind: kind_of(&ty),
                    type_name: if ty.is_empty() { "any".into() } else { ty.to_lowercase() },
                    nullable: !not_null && !is_key,
                    has_default: default.is_some(),
                    is_key,
                    enum_values: Vec::new(),
                    // hidden 2/3 = generated columns.
                    editable: editable && !is_key && hidden == 0,
                    indexed: is_key || indexed.contains(&name),
                    name,
                }
            })
            .collect();
        let paging = if key_columns.is_empty() { PagingMode::Offset } else { PagingMode::Keyset };
        let t = Arc::new(LiteTable {
            meta: TableMeta { columns, paging, key_columns, editable, read_only_reason },
            relation: format!("{}.{}", quote_ident(db, '"'), quote_ident(table, '"')),
            is_view,
            by_rowid,
        });
        self.tables.lock().await.insert(path.to_vec(), t.clone());
        Ok(t)
    }

    async fn table(&self, path: &[String]) -> Result<Arc<LiteTable>> {
        if let Some(t) = self.tables.lock().await.get(path) {
            return Ok(t.clone());
        }
        self.load_table(path).await
    }

    fn statements(t: &LiteTable, edits: &[CellEdit]) -> Result<Vec<String>> {
        if let Some(reason) = &t.meta.read_only_reason {
            return Err(CoreError::ReadOnly { message: reason.clone() });
        }
        let types = |c: &str| {
            if t.by_rowid && c == "rowid" {
                return Some("integer".to_string());
            }
            t.meta.columns.iter().find(|m| m.name == c).map(|m| m.type_name.clone())
        };
        update_statements(Dialect::Sqlite, &t.relation, &t.meta.key_columns, &types, edits)
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

    async fn table_meta(&self, path: &[String]) -> Result<TableMeta> {
        Ok(self.load_table(path).await?.meta.clone())
    }

    async fn fetch_page(&self, path: &[String], cursor: &PageCursor, size: u32, sort: Option<&SortSpec>) -> Result<TablePage> {
        let t = self.table(path).await?;
        let key_col = |name: &str| KeyCol {
            expr: if t.by_rowid && name == "rowid" { "rowid".into() } else { quote_ident(name, '"') },
            cast: None,
        };
        let keys: Vec<KeyCol> = t.meta.key_columns.iter().map(|k| key_col(k)).collect();
        let sort_col = match sort {
            Some(s) if t.meta.columns.iter().any(|c| c.name == s.column) => Some((key_col(&s.column), s.descending, t.meta.columns.iter().find(|c| c.name == s.column).is_none_or(|c| c.nullable))),
            Some(s) => return Err(CoreError::not_found(format!("column `{}`", s.column))),
            None => None,
        };
        let sort = sort_col.as_ref().map(|(col, descending, nullable)| SortCol { col, descending: *descending, nullable: *nullable });
        let (sql, hidden) = page_sql(Dialect::Sqlite, &t.relation, &keys, sort, cursor, size)?;
        let mut window = sqlx_common::collect(&self.pool, &sql, kind_of, decode).await?;
        if window.columns.is_empty() {
            let probe = format!("SELECT * FROM {} LIMIT 0", t.relation);
            let cols = sqlx_common::describe(&self.pool, &probe, kind_of).await.unwrap_or_default();
            window.columns = std::iter::repeat_n(cols.first().cloned(), hidden).flatten().chain(cols).collect();
        }
        let fetched = split_hidden(window, hidden, hidden > keys.len(), t.meta.editable);
        Ok(assemble(fetched, cursor, size as usize, !keys.is_empty()))
    }

    async fn row_count(&self, path: &[String], exact: bool) -> Result<RowCount> {
        let t = self.table(path).await?;
        if !exact && !t.is_view {
            // max(rowid) is one index lookup; close enough for a scrollbar.
            let has_rowid: Option<i64> = sqlx::query_scalar(&format!("SELECT max(rowid) FROM {}", t.relation))
                .fetch_one(&self.pool)
                .await
                .unwrap_or(None);
            if let Some(n) = has_rowid.filter(|&n| n >= EXACT_COUNT_BELOW) {
                return Ok(RowCount { count: n as u64, exact: false });
            }
        }
        let mut conn = self.pool.acquire().await?;
        {
            // Bounded: interrupt an exact count after a minute.
            let deadline = std::time::Instant::now() + Duration::from_secs(60);
            conn.lock_handle().await?.set_progress_handler(100_000, move || std::time::Instant::now() < deadline);
        }
        let count: Result<i64> = sqlx::query_scalar(&format!("SELECT count(*) FROM {}", t.relation))
            .fetch_one(&mut *conn)
            .await
            .map_err(|e| match e {
                sqlx::Error::Database(_) => CoreError::Timeout { message: "counting took longer than a minute".into() },
                other => other.into(),
            });
        if let Ok(mut h) = conn.lock_handle().await {
            h.remove_progress_handler();
        }
        Ok(RowCount { count: count? as u64, exact: true })
    }

    async fn preview_edits(&self, path: &[String], edits: &[CellEdit]) -> Result<Vec<String>> {
        Self::statements(&*self.table(path).await?, edits)
    }

    async fn apply_edits(&self, path: &[String], edits: &[CellEdit]) -> Result<u64> {
        let t = self.table(path).await?;
        let statements = Self::statements(&t, edits)?;
        let mut tx = self.pool.begin().await?;
        for (i, sql) in statements.iter().enumerate() {
            if tx.execute(sql.as_str()).await?.rows_affected() != 1 {
                return Err(CoreError::query(format!(
                    "change {} matched no row (it was changed or deleted elsewhere); nothing was saved",
                    i + 1
                )));
            }
        }
        tx.commit().await?;
        Ok(statements.len() as u64)
    }

    async fn schema_graph(&self, path: &[String]) -> Result<SchemaGraph> {
        let db = path.first().map(String::as_str).unwrap_or("main");
        let names: Vec<String> = sqlx::query_scalar(&format!(
            "SELECT name FROM {}.sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
            quote_ident(db, '"')
        ))
        .fetch_all(&self.pool)
        .await?;
        let mut tables = Vec::new();
        let mut relations = Vec::new();
        for name in &names {
            let cols: Vec<(String, String, bool, i64)> =
                sqlx::query_as("SELECT name, type, \"notnull\", pk FROM pragma_table_info(?1, ?2) ORDER BY cid")
                    .bind(name)
                    .bind(db)
                    .fetch_all(&self.pool)
                    .await?;
            let unique: Vec<String> = sqlx::query_scalar(
                "SELECT ii.name FROM pragma_index_list(?1, ?2) il, pragma_index_info(il.name, ?2) ii \
                 WHERE il.\"unique\" = 1 AND il.origin <> 'pk' \
                   AND (SELECT count(*) FROM pragma_index_info(il.name, ?2)) = 1",
            )
            .bind(name)
            .bind(db)
            .fetch_all(&self.pool)
            .await?;
            let pk_count = cols.iter().filter(|c| c.3 > 0).count();
            let fks: Vec<(i64, String, String, Option<String>)> =
                sqlx::query_as("SELECT id, \"table\", \"from\", \"to\" FROM pragma_foreign_key_list(?1, ?2) ORDER BY id, seq")
                    .bind(name)
                    .bind(db)
                    .fetch_all(&self.pool)
                    .await?;
            for (id, target, from, to) in fks {
                match relations.last_mut() {
                    Some(Relation { name: n, from_table, from_columns, to_columns, .. })
                        if *n == format!("{name}_fk{id}") && from_table == name =>
                    {
                        from_columns.push(from);
                        to_columns.push(to.unwrap_or_default());
                    }
                    _ => relations.push(Relation {
                        name: format!("{name}_fk{id}"),
                        from_table: name.clone(),
                        from_columns: vec![from],
                        to_table: target,
                        to_columns: vec![to.unwrap_or_default()],
                        inferred: false,
                    }),
                }
            }
            tables.push(GraphTable {
                name: name.clone(),
                path: vec![db.into(), FOLDER_TABLES.into(), name.clone()],
                columns: cols
                    .into_iter()
                    .map(|(n, ty, not_null, pk)| GraphColumn {
                        // A lone INTEGER PRIMARY KEY is the rowid: the database assigns it.
                        is_identity: pk > 0 && pk_count == 1 && ty.eq_ignore_ascii_case("integer"),
                        is_unique: unique.contains(&n),
                        type_name: ty.to_lowercase(),
                        is_key: pk > 0,
                        nullable: !not_null && pk == 0,
                        name: n,
                    })
                    .collect(),
                estimated_rows: None,
            });
        }
        // `REFERENCES parent` without columns points at the parent's primary key.
        for rel in &mut relations {
            if rel.to_columns.iter().any(String::is_empty) {
                if let Some(parent) = tables.iter().find(|t: &&GraphTable| t.name == rel.to_table) {
                    rel.to_columns = parent.columns.iter().filter(|c| c.is_key).map(|c| c.name.clone()).collect();
                }
            }
        }
        Ok(SchemaGraph { tables, relations })
    }

    fn classify(&self, query: &str) -> StatementKind {
        classify_sql(query)
    }

    async fn close(&self) {
        self.pool.close().await;
    }
}
