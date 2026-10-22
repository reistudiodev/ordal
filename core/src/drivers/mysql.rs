//! MySQL 8.x and MariaDB 10.6+ driver (sqlx). One code path; the engine name
//! comes from `VERSION()`.
//! Browse tree: databases › Tables | Views | Functions › columns.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use sqlx::mysql::{MySqlConnectOptions, MySqlPoolOptions, MySqlRow, MySqlSslMode};
use sqlx::{Executor, Row as _};
use tokio_util::sync::CancellationToken;

use super::sql_paging::{page_sql, split_hidden, update_statements, Dialect, KeyCol, SortCol};
use super::sqlx_common::{self, quote_ident, Pools, StreamEnd, EXACT_COUNT_BELOW};
use super::{approx_rows, table_path, BrowseNode, Driver, NodeKind, ServerInfo, Sink};
use super::{FOLDER_FUNCTIONS, FOLDER_TABLES, FOLDER_VIEWS};
use crate::config::{ConnectionConfig, TlsMode};
use crate::error::{CoreError, Result};
use crate::sql::{classify_sql, StatementKind};
use crate::table::{
    assemble, CellEdit, ColumnMeta, GraphColumn, GraphTable, PageCursor, PagingMode, Relation, SchemaGraph, SortSpec, TableMeta,
    TablePage,
};
use crate::value::{Row, RowCount, Value, ValueKind};

pub(crate) struct MySqlDriver {
    pools: Pools<sqlx::MySql>,
    read_only: bool,
    mariadb: bool,
    tables: tokio::sync::Mutex<HashMap<Vec<String>, Arc<MyTable>>>,
}

struct MyTable {
    meta: TableMeta,
    relation: String,
    is_view: bool,
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
        let version: String = sqlx::query_scalar("SELECT VERSION()").fetch_one(&pools.get(None).await?).await?;
        Ok(Self { pools, read_only, mariadb: version.contains("MariaDB"), tables: Default::default() })
    }

    async fn load_table(&self, path: &[String]) -> Result<Arc<MyTable>> {
        let (db, _, table) = table_path(path, false)?;
        let kind = self
            .catalog("SELECT TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?", &[db, table])
            .await?
            .into_iter()
            .next()
            .ok_or_else(|| CoreError::not_found(format!("table `{table}`")))?;
        let is_view = kind[0] != "BASE TABLE";
        let pk: Vec<String> = self
            .catalog(
                "SELECT COLUMN_NAME FROM information_schema.STATISTICS \
                 WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND INDEX_NAME = 'PRIMARY' ORDER BY SEQ_IN_INDEX",
                &[db, table],
            )
            .await?
            .into_iter()
            .map(|r| r[0].clone())
            .collect();
        let cols = self
            .catalog(
                "SELECT c.COLUMN_NAME, c.COLUMN_TYPE, UPPER(c.DATA_TYPE), c.IS_NULLABLE, \
                   IF(c.COLUMN_DEFAULT IS NULL, 'NO', 'YES'), c.EXTRA, \
                   IF(EXISTS (SELECT 1 FROM information_schema.STATISTICS s WHERE s.TABLE_SCHEMA = c.TABLE_SCHEMA \
                     AND s.TABLE_NAME = c.TABLE_NAME AND s.COLUMN_NAME = c.COLUMN_NAME AND s.SEQ_IN_INDEX = 1), 'YES', 'NO') \
                 FROM information_schema.COLUMNS c WHERE c.TABLE_SCHEMA = ? AND c.TABLE_NAME = ? ORDER BY c.ORDINAL_POSITION",
                &[db, table],
            )
            .await?;
        let read_only_reason = if self.read_only {
            Some("This connection is read-only.".to_string())
        } else if is_view {
            Some("Views can't be edited here.".to_string())
        } else if pk.is_empty() {
            Some("This table has no primary key, so a row can't be identified safely.".to_string())
        } else {
            None
        };
        let editable = read_only_reason.is_none();
        let columns = cols
            .into_iter()
            .map(|r| {
                let column_type = r[1].clone();
                let is_key = pk.contains(&r[0]);
                let enum_values = enum_values(&column_type);
                let kind = if column_type == "tinyint(1)" {
                    ValueKind::Bool
                } else if !enum_values.is_empty() {
                    ValueKind::Text
                } else {
                    kind_of(&r[2])
                };
                ColumnMeta {
                    name: r[0].clone(),
                    kind,
                    nullable: r[3] == "YES",
                    has_default: r[4] == "YES",
                    editable: editable && !is_key && !r[5].to_uppercase().contains("GENERATED"),
                    is_key,
                    enum_values,
                    indexed: r[6] == "YES",
                    type_name: column_type,
                }
            })
            .collect();
        let paging = if pk.is_empty() { PagingMode::Offset } else { PagingMode::Keyset };
        let t = Arc::new(MyTable {
            meta: TableMeta { columns, paging, key_columns: pk, editable, read_only_reason },
            relation: format!("{}.{}", quote_ident(db, '`'), quote_ident(table, '`')),
            is_view,
        });
        self.tables.lock().await.insert(path.to_vec(), t.clone());
        Ok(t)
    }

    async fn table(&self, path: &[String]) -> Result<Arc<MyTable>> {
        if let Some(t) = self.tables.lock().await.get(path) {
            return Ok(t.clone());
        }
        self.load_table(path).await
    }

    fn statements(t: &MyTable, edits: &[CellEdit]) -> Result<Vec<String>> {
        if let Some(reason) = &t.meta.read_only_reason {
            return Err(CoreError::ReadOnly { message: reason.clone() });
        }
        let types = |c: &str| t.meta.columns.iter().find(|m| m.name == c).map(|m| m.type_name.clone());
        update_statements(Dialect::MySql, &t.relation, &t.meta.key_columns, &types, edits)
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

/// `enum('a','b''c')` → ["a", "b'c"].
fn enum_values(column_type: &str) -> Vec<String> {
    let Some(inner) = column_type.strip_prefix("enum(").and_then(|r| r.strip_suffix(')')) else { return Vec::new() };
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut chars = inner.chars().peekable();
    let mut quoted = false;
    while let Some(c) = chars.next() {
        match c {
            '\'' if quoted && chars.peek() == Some(&'\'') => {
                cur.push('\'');
                chars.next();
            }
            '\'' => {
                quoted = !quoted;
                if !quoted {
                    out.push(std::mem::take(&mut cur));
                }
            }
            c if quoted => cur.push(c),
            _ => {}
        }
    }
    out
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
            // Text with a binary collation (utf8mb4_bin) arrives flagged as
            // binary; keep real bytes as bytes and show text as text.
            Ok(Some(v)) if kind == ValueKind::Bytes => match String::from_utf8(v) {
                Ok(text) => Value::Text { v: text },
                Err(e) => Value::Bytes { v: e.into_bytes() },
            },
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

    async fn table_meta(&self, path: &[String]) -> Result<TableMeta> {
        Ok(self.load_table(path).await?.meta.clone())
    }

    async fn fetch_page(&self, path: &[String], cursor: &PageCursor, size: u32, sort: Option<&SortSpec>) -> Result<TablePage> {
        let t = self.table(path).await?;
        let pool = self.pools.get(None).await?;
        let key_col = |name: &str| KeyCol { expr: quote_ident(name, '`'), cast: None };
        let keys: Vec<KeyCol> = t.meta.key_columns.iter().map(|k| key_col(k)).collect();
        let sort_col = match sort {
            Some(s) if t.meta.columns.iter().any(|c| c.name == s.column) => Some((key_col(&s.column), s.descending, t.meta.columns.iter().find(|c| c.name == s.column).is_none_or(|c| c.nullable))),
            Some(s) => return Err(CoreError::not_found(format!("column `{}`", s.column))),
            None => None,
        };
        let sort = sort_col.as_ref().map(|(col, descending, nullable)| SortCol { col, descending: *descending, nullable: *nullable });
        let (sql, hidden) = page_sql(Dialect::MySql, &t.relation, &keys, sort, cursor, size)?;
        let mut window = sqlx_common::collect(&pool, &sql, kind_of, decode).await?;
        if window.columns.is_empty() {
            let probe = format!("SELECT * FROM {} LIMIT 0", t.relation);
            let cols = sqlx_common::describe(&pool, &probe, kind_of).await.unwrap_or_default();
            window.columns = std::iter::repeat_n(cols.first().cloned(), hidden).flatten().chain(cols).collect();
        }
        let fetched = split_hidden(window, hidden, hidden > keys.len(), !keys.is_empty());
        Ok(assemble(fetched, cursor, size as usize, !keys.is_empty()))
    }

    async fn row_count(&self, path: &[String], exact: bool) -> Result<RowCount> {
        let (db, _, table) = table_path(path, false)?;
        let t = self.table(path).await?;
        let est = self
            .catalog(
                "SELECT TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?",
                &[db, table],
            )
            .await?
            .into_iter()
            .next()
            .and_then(|r| r[0].parse::<i64>().ok());
        if let Some(est) = est.filter(|&e| !exact && !t.is_view && e >= EXACT_COUNT_BELOW) {
            return Ok(RowCount { count: est as u64, exact: false });
        }
        // Bounded: an exact count of a huge table must not run forever.
        let sql = if self.mariadb {
            format!("SET STATEMENT max_statement_time = 60 FOR SELECT COUNT(*) FROM {}", t.relation)
        } else {
            format!("SELECT /*+ MAX_EXECUTION_TIME(60000) */ COUNT(*) FROM {}", t.relation)
        };
        let count: i64 = sqlx::query_scalar(&sql).fetch_one(&self.pools.get(None).await?).await?;
        Ok(RowCount { count: count as u64, exact: true })
    }

    async fn preview_edits(&self, path: &[String], edits: &[CellEdit]) -> Result<Vec<String>> {
        Self::statements(&*self.table(path).await?, edits)
    }

    async fn apply_edits(&self, path: &[String], edits: &[CellEdit]) -> Result<u64> {
        let t = self.table(path).await?;
        let statements = Self::statements(&t, edits)?;
        let mut tx = self.pools.get(None).await?.begin().await?;
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
        let db = path.first().ok_or_else(|| CoreError::invalid("choose a database"))?;
        let cols = self
            .catalog(
                "SELECT c.TABLE_NAME, c.COLUMN_NAME, c.COLUMN_TYPE, c.IS_NULLABLE, c.COLUMN_KEY, t.TABLE_ROWS, c.EXTRA \
                 FROM information_schema.COLUMNS c JOIN information_schema.TABLES t \
                   ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME \
                 WHERE c.TABLE_SCHEMA = ? AND t.TABLE_TYPE = 'BASE TABLE' \
                 ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION",
                &[db],
            )
            .await?;
        let fks = self
            .catalog(
                "SELECT CONSTRAINT_NAME, TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_SCHEMA, REFERENCED_TABLE_NAME, \
                   REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE \
                 WHERE TABLE_SCHEMA = ? AND REFERENCED_TABLE_NAME IS NOT NULL \
                 ORDER BY TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION",
                &[db],
            )
            .await?;
        let mut tables: Vec<GraphTable> = Vec::new();
        for r in cols {
            if tables.last().is_none_or(|t| t.name != r[0]) {
                tables.push(GraphTable {
                    path: vec![db.clone(), FOLDER_TABLES.into(), r[0].clone()],
                    name: r[0].clone(),
                    columns: Vec::new(),
                    estimated_rows: r[5].parse().ok(),
                });
            }
            tables.last_mut().unwrap().columns.push(GraphColumn {
                name: r[1].clone(),
                type_name: r[2].clone(),
                nullable: r[3] == "YES",
                is_key: r[4] == "PRI",
                is_identity: r[6].to_lowercase().contains("auto_increment"),
                is_unique: r[4] == "UNI",
            });
        }
        let mut relations: Vec<Relation> = Vec::new();
        for r in fks {
            let to_table = if &r[3] == db { r[4].clone() } else { format!("{}.{}", r[3], r[4]) };
            if !tables.iter().any(|t| t.name == to_table) {
                tables.push(GraphTable {
                    path: vec![r[3].clone(), FOLDER_TABLES.into(), r[4].clone()],
                    name: to_table.clone(),
                    columns: vec![GraphColumn::stub(r[5].clone(), true)],
                    estimated_rows: None,
                });
            }
            match relations.last_mut() {
                Some(rel) if rel.name == r[0] && rel.from_table == r[1] => {
                    rel.from_columns.push(r[2].clone());
                    rel.to_columns.push(r[5].clone());
                }
                _ => relations.push(Relation {
                    name: r[0].clone(),
                    from_table: r[1].clone(),
                    from_columns: vec![r[2].clone()],
                    to_table,
                    to_columns: vec![r[5].clone()],
                    inferred: false,
                }),
            }
        }
        Ok(SchemaGraph { tables, relations })
    }

    fn classify(&self, query: &str) -> StatementKind {
        classify_sql(query)
    }

    async fn close(&self) {
        self.pools.close().await;
    }
}
