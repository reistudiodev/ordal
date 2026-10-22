//! PostgreSQL driver (sqlx).
//! Browse tree: databases › schemas › Tables | Views | Functions › columns.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use sqlx::postgres::{PgConnectOptions, PgPoolOptions, PgRow, PgSslMode};
use sqlx::{Executor, Row as _, ValueRef};
use tokio_util::sync::CancellationToken;

use super::sql_paging::{page_sql, split_hidden, update_statements, Dialect, KeyCol, SortCol};
use super::sqlx_common::{self, quote_ident, Pools, StreamEnd, EXACT_COUNT_BELOW};
use super::{approx_rows, table_path, BrowseNode, Driver, NodeKind, ServerInfo, Sink};
use super::{FOLDER_FUNCTIONS, FOLDER_TABLES, FOLDER_VIEWS};
use crate::config::{ConnectionConfig, TlsMode};
use crate::error::{CoreError, Result};
use crate::sql::{classify_sql, StatementKind};
use crate::table::{
    assemble, sql_string, CellEdit, ColumnMeta, GraphColumn, GraphTable, PageCursor, PagingMode, Relation, SchemaGraph, SortSpec,
    TableMeta, TablePage,
};
use crate::value::{decode_pg_hex, Row, RowCount, Value, ValueKind};

pub(crate) struct PgDriver {
    pools: Pools<sqlx::Postgres>,
    read_only: bool,
    /// Column types and keys per table path, loaded on first use.
    tables: tokio::sync::Mutex<HashMap<Vec<String>, Arc<PgTable>>>,
}

/// What paging and editing need to know about one relation.
struct PgTable {
    meta: TableMeta,
    relation: String,
    relkind: String,
    /// Cast for literals compared with or assigned to each column (no typmod,
    /// so an over-long value errors instead of being silently cut).
    casts: HashMap<String, String>,
}

impl PgDriver {
    pub(crate) async fn connect(config: &ConnectionConfig, password: Option<String>) -> Result<Self> {
        let mut base = PgConnectOptions::new()
            .host(&config.host)
            .port(config.port)
            .username(&config.username)
            .application_name(config.option("application_name").unwrap_or("ordal"))
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
                            // Page and edit literals rely on quotes being the only escape.
                            conn.execute("SET standard_conforming_strings = on").await?;
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
        Ok(Self { pools, read_only, tables: Default::default() })
    }

    /// Loads (or reloads) a table's metadata.
    async fn load_table(&self, path: &[String]) -> Result<Arc<PgTable>> {
        let (db, schema, table) = table_path(path, true)?;
        let schema = schema.unwrap_or("public");
        let pool = self.pools.get(Some(db)).await?;
        let relkind: String = sqlx::query_scalar("SELECT relkind::text FROM pg_class WHERE oid = format('%I.%I', $1, $2)::regclass")
            .bind(schema)
            .bind(table)
            .fetch_one(&pool)
            .await?;
        let pk: Vec<String> = sqlx::query_scalar(
            "SELECT a.attname::text FROM pg_index i \
             JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey) \
             WHERE i.indrelid = format('%I.%I', $1, $2)::regclass AND i.indisprimary \
             ORDER BY array_position(i.indkey, a.attnum)",
        )
        .bind(schema)
        .bind(table)
        .fetch_all(&pool)
        .await?;
        type Col = (String, String, String, String, bool, bool, Vec<String>, bool, bool);
        let cols: Vec<Col> = sqlx::query_as(
            "SELECT a.attname::text, format_type(a.atttypid, a.atttypmod), format_type(a.atttypid, NULL), \
               upper(t.typname)::text, NOT a.attnotnull, a.atthasdef, \
               COALESCE((SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e \
                         WHERE e.enumtypid = a.atttypid), '{}'), \
               (a.attgenerated <> '' OR a.attidentity = 'a'), \
               EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = a.attrelid AND i.indkey[0] = a.attnum) \
             FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid \
             WHERE a.attrelid = format('%I.%I', $1, $2)::regclass AND a.attnum > 0 AND NOT a.attisdropped \
             ORDER BY a.attnum",
        )
        .bind(schema)
        .bind(table)
        .fetch_all(&pool)
        .await?;

        let is_table = matches!(relkind.as_str(), "r" | "p");
        let read_only_reason = if self.read_only {
            Some("This connection is read-only.".to_string())
        } else if !is_table {
            Some("Views and other non-table relations can't be edited here.".to_string())
        } else if pk.is_empty() {
            Some("This table has no primary key, so a row can't be identified safely.".to_string())
        } else {
            None
        };
        let editable = read_only_reason.is_none();
        let mut casts = HashMap::new();
        let columns = cols
            .into_iter()
            .map(|(name, full, base, typname, nullable, has_default, enum_values, generated, indexed)| {
                casts.insert(name.clone(), base);
                let is_key = pk.contains(&name);
                ColumnMeta {
                    kind: if enum_values.is_empty() { kind_of(&typname) } else { ValueKind::Text },
                    editable: editable && !is_key && !generated,
                    name,
                    type_name: full,
                    nullable,
                    is_key,
                    has_default,
                    enum_values,
                    indexed,
                }
            })
            .collect();
        let paging = if !pk.is_empty() || matches!(relkind.as_str(), "r" | "p" | "m") { PagingMode::Keyset } else { PagingMode::Offset };
        let t = Arc::new(PgTable {
            meta: TableMeta { columns, paging, key_columns: pk, editable, read_only_reason },
            relation: format!("{}.{}", quote_ident(schema, '"'), quote_ident(table, '"')),
            relkind,
            casts,
        });
        self.tables.lock().await.insert(path.to_vec(), t.clone());
        Ok(t)
    }

    async fn table(&self, path: &[String]) -> Result<Arc<PgTable>> {
        if let Some(t) = self.tables.lock().await.get(path) {
            return Ok(t.clone());
        }
        self.load_table(path).await
    }

    fn statements(t: &PgTable, edits: &[CellEdit]) -> Result<Vec<String>> {
        if let Some(reason) = &t.meta.read_only_reason {
            return Err(CoreError::ReadOnly { message: reason.clone() });
        }
        let types = |c: &str| t.casts.get(c).cloned();
        update_statements(Dialect::Postgres, &t.relation, &t.meta.key_columns, &types, edits)
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

    async fn table_meta(&self, path: &[String]) -> Result<TableMeta> {
        Ok(self.load_table(path).await?.meta.clone())
    }

    async fn fetch_page(&self, path: &[String], cursor: &PageCursor, size: u32, sort: Option<&SortSpec>) -> Result<TablePage> {
        let t = self.table(path).await?;
        let pool = self.pools.get(Some(&path[0])).await?;
        let key_col = |name: &str| KeyCol { expr: quote_ident(name, '"'), cast: t.casts.get(name).cloned() };
        let keys: Vec<KeyCol> = if !t.meta.key_columns.is_empty() {
            t.meta.key_columns.iter().map(|k| key_col(k)).collect()
        } else if t.meta.paging == PagingMode::Keyset {
            // No primary key: the physical row id still pages (TID range scans).
            vec![KeyCol { expr: "ctid".into(), cast: Some("tid".into()) }]
        } else {
            Vec::new()
        };
        let sort_col = match sort {
            Some(s) if t.casts.contains_key(&s.column) => Some((key_col(&s.column), s.descending, t.meta.columns.iter().find(|c| c.name == s.column).is_none_or(|c| c.nullable))),
            Some(s) => return Err(CoreError::not_found(format!("column `{}`", s.column))),
            None => None,
        };
        let sort = sort_col.as_ref().map(|(col, descending, nullable)| SortCol { col, descending: *descending, nullable: *nullable });
        let (sql, hidden) = page_sql(Dialect::Postgres, &t.relation, &keys, sort, cursor, size)?;
        let mut window = sqlx_common::collect(&pool, &sql, kind_of, decode).await?;
        if window.columns.is_empty() {
            let probe = format!("SELECT * FROM {} LIMIT 0", t.relation);
            let cols = sqlx_common::describe(&pool, &probe, kind_of).await.unwrap_or_default();
            window.columns = std::iter::repeat_n(cols.first().cloned(), hidden).flatten().chain(cols).collect();
        }
        let fetched = split_hidden(window, hidden, hidden > keys.len(), !t.meta.key_columns.is_empty());
        Ok(assemble(fetched, cursor, size as usize, !keys.is_empty()))
    }

    async fn row_count(&self, path: &[String], exact: bool) -> Result<RowCount> {
        let t = self.table(path).await?;
        let pool = self.pools.get(Some(&path[0])).await?;
        let estimate: i64 = sqlx::query_scalar(&format!("SELECT reltuples::int8 FROM pg_class WHERE oid = {}::regclass", sql_string(&t.relation)))
            .fetch_one(&pool)
            .await?;
        if !exact && estimate >= EXACT_COUNT_BELOW && t.relkind != "v" {
            return Ok(RowCount { count: estimate as u64, exact: false });
        }
        // Bounded: an exact count of a huge table must not run forever.
        let mut tx = pool.begin().await?;
        tx.execute("SET LOCAL statement_timeout = '60s'").await?;
        let count: i64 = sqlx::query_scalar(&format!("SELECT count(*) FROM {}", t.relation)).fetch_one(&mut *tx).await?;
        tx.commit().await?;
        Ok(RowCount { count: count as u64, exact: true })
    }

    async fn preview_edits(&self, path: &[String], edits: &[CellEdit]) -> Result<Vec<String>> {
        Self::statements(&*self.table(path).await?, edits)
    }

    async fn apply_edits(&self, path: &[String], edits: &[CellEdit]) -> Result<u64> {
        let t = self.table(path).await?;
        let statements = Self::statements(&t, edits)?;
        let mut tx = self.pools.get(Some(&path[0])).await?.begin().await?;
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
        let (db, schema) = match path {
            [db] => (db.as_str(), "public"),
            [db, schema, ..] => (db.as_str(), schema.as_str()),
            [] => return Err(CoreError::invalid("choose a database or schema")),
        };
        let pool = self.pools.get(Some(db)).await?;
        type Col = (String, String, String, bool, bool, bool, bool, i64);
        let cols: Vec<Col> = sqlx::query_as(
            "SELECT c.relname::text, a.attname::text, \
               CASE WHEN t.typcategory = 'A' THEN substr(t.typname, 2) || '[]' ELSE t.typname END::text, \
               NOT a.attnotnull, COALESCE(a.attnum = ANY(pk.indkey), false), \
               (a.attidentity <> '' OR COALESCE(pg_get_expr(d.adbin, d.adrelid) LIKE 'nextval(%', false)), \
               EXISTS (SELECT 1 FROM pg_index u WHERE u.indrelid = c.oid AND u.indisunique AND NOT u.indisprimary \
                       AND u.indnatts = 1 AND u.indkey[0] = a.attnum), \
               c.reltuples::int8 \
             FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace \
             JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped \
             JOIN pg_type t ON t.oid = a.atttypid \
             LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum \
             LEFT JOIN pg_index pk ON pk.indrelid = c.oid AND pk.indisprimary \
             WHERE n.nspname = $1 AND c.relkind IN ('r', 'p') ORDER BY c.relname, a.attnum",
        )
        .bind(schema)
        .fetch_all(&pool)
        .await?;
        type Fk = (String, String, String, Vec<String>, String, String, Vec<String>);
        let fks: Vec<Fk> = sqlx::query_as(
            "SELECT c.conname::text, sn.nspname::text, s.relname::text, \
               ARRAY(SELECT a.attname::text FROM unnest(c.conkey) WITH ORDINALITY k(n, o) \
                     JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.n ORDER BY k.o), \
               dn.nspname::text, d.relname::text, \
               ARRAY(SELECT a.attname::text FROM unnest(c.confkey) WITH ORDINALITY k(n, o) \
                     JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k.n ORDER BY k.o) \
             FROM pg_constraint c \
             JOIN pg_class s ON s.oid = c.conrelid JOIN pg_namespace sn ON sn.oid = s.relnamespace \
             JOIN pg_class d ON d.oid = c.confrelid JOIN pg_namespace dn ON dn.oid = d.relnamespace \
             WHERE c.contype = 'f' AND (sn.nspname = $1 OR dn.nspname = $1) ORDER BY 1",
        )
        .bind(schema)
        .fetch_all(&pool)
        .await?;

        let mut tables: Vec<GraphTable> = Vec::new();
        for (table, column, type_name, nullable, is_key, is_identity, is_unique, est) in cols {
            if tables.last().is_none_or(|t| t.name != table) {
                tables.push(GraphTable {
                    path: vec![db.into(), schema.into(), FOLDER_TABLES.into(), table.clone()],
                    name: table,
                    columns: Vec::new(),
                    estimated_rows: (est >= 0).then_some(est as u64),
                });
            }
            tables.last_mut().unwrap().columns.push(GraphColumn { name: column, type_name, is_key, is_identity, is_unique, nullable });
        }
        let qualify = |ns: &str, rel: &str| if ns == schema { rel.to_string() } else { format!("{ns}.{rel}") };
        let mut relations = Vec::new();
        for (name, sns, src, from_columns, dns, dst, to_columns) in fks {
            for (ns, rel, cols) in [(&sns, &src, &from_columns), (&dns, &dst, &to_columns)] {
                // Tables in other schemas appear as stubs with just the linked columns.
                let q = qualify(ns, rel);
                if !tables.iter().any(|t| t.name == q) {
                    tables.push(GraphTable {
                        path: vec![db.into(), ns.clone(), FOLDER_TABLES.into(), rel.clone()],
                        name: q,
                        columns: cols.iter().map(|c| GraphColumn::stub(c.clone(), false)).collect(),
                        estimated_rows: None,
                    });
                }
            }
            relations.push(Relation {
                name,
                from_table: qualify(&sns, &src),
                from_columns,
                to_table: qualify(&dns, &dst),
                to_columns,
                inferred: false,
            });
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
