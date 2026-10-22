//! MongoDB driver (official `mongodb` crate).
//! Browse tree: databases › collections › indexes.
//!
//! Queries are JSON command documents (MongoDB Extended JSON is accepted):
//! `{"find": "users", "filter": {"age": {"$gt": 30}}, "sort": {"_id": 1}, "limit": 50}`,
//! `{"aggregate": "orders", "pipeline": [...]}`, or any `runCommand` document.
//! Shell syntax (`db.users.find(...)`) is planned for a later phase.

use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use mongodb::bson::{doc, Bson, Document};
use mongodb::options::{ClientOptions, Credential, ServerAddress, Tls, TlsOptions};
use mongodb::{Client, Collection};
use tokio_util::sync::CancellationToken;

use super::{or_cancel, BrowseNode, Driver, NodeKind, ServerInfo, Sink, EXACT_COUNT_BELOW};
use crate::table::{
    assemble, CellEdit, ColumnMeta, Fetched, GraphColumn, GraphTable, PageCursor, PagingMode, Relation, SchemaGraph, SortSpec,
    TableMeta, TablePage,
};
use crate::config::{ConnectionConfig, TlsMode};
use crate::error::{CoreError, Result};
use crate::sql::StatementKind;
use crate::value::{ColumnInfo, Row, RowCount, Value, ValueKind};

pub(crate) struct MongoDriver {
    client: Client,
    default_db: String,
    read_only: bool,
}

impl MongoDriver {
    fn collection(&self, path: &[String]) -> Result<Collection<Document>> {
        match path {
            [db, coll, ..] => Ok(self.client.database(db).collection(coll)),
            _ => Err(CoreError::invalid("not a collection path")),
        }
    }

    /// The `_id` and the new value converted to the field's current BSON type.
    async fn edit_values(&self, coll: &Collection<Document>, e: &CellEdit) -> Result<(Bson, Bson)> {
        if e.column == "_id" {
            return Err(CoreError::unsupported("_id can't be edited"));
        }
        let id = key_to_bson(&e.key)?;
        let current = coll
            .find_one(doc! { "_id": id.clone() })
            .projection(doc! { e.column.clone(): 1 })
            .await?
            .ok_or_else(|| CoreError::not_found("document (it was deleted elsewhere)"))?;
        let value = value_to_bson(&e.value, current.get(&e.column))
            .map_err(|why| CoreError::query(format!("`{}`: {why}", e.column)))?;
        Ok((id, value))
    }

    pub(crate) async fn connect(config: &ConnectionConfig, password: Option<String>) -> Result<Self> {
        let mut opts = if config.option("srv") == Some("true") {
            ClientOptions::parse(format!("mongodb+srv://{}/", config.host)).await?
        } else {
            let hosts = config
                .host
                .split(',')
                .map(|h| match h.rsplit_once(':') {
                    Some((host, port)) => port
                        .parse()
                        .map(|p| ServerAddress::Tcp { host: host.to_string(), port: Some(p) })
                        .map_err(|_| CoreError::invalid(format!("bad port in `{h}`"))),
                    None => Ok(ServerAddress::Tcp { host: h.to_string(), port: Some(config.port) }),
                })
                .collect::<Result<Vec<_>>>()?;
            ClientOptions::builder().hosts(hosts).build()
        };
        if !config.username.is_empty() {
            opts.credential = Some(
                Credential::builder()
                    .username(config.username.clone())
                    .password(password)
                    .source(config.option("authSource").map(str::to_string))
                    .build(),
            );
        }
        match config.tls {
            TlsMode::Require => opts.tls = Some(Tls::Enabled(TlsOptions::default())),
            TlsMode::Disable => opts.tls = Some(Tls::Disabled),
            TlsMode::Prefer => {}
        }
        if let Some(rs) = config.option("replicaSet") {
            opts.repl_set_name = Some(rs.to_string());
        }
        if config.option("directConnection") == Some("true") {
            opts.direct_connection = Some(true);
        }
        opts.app_name = Some("dbclient".into());
        opts.server_selection_timeout = Some(Duration::from_secs(10));
        opts.connect_timeout = Some(Duration::from_secs(10));

        let client = Client::with_options(opts)?;
        // The driver connects lazily; ping so bad settings fail now.
        client.database("admin").run_command(doc! { "ping": 1 }).await?;
        let default_db = if config.database.is_empty() { "test".into() } else { config.database.clone() };
        Ok(Self { client, default_db, read_only: config.read_only })
    }
}

async fn collect_docs(mut cursor: mongodb::Cursor<Document>) -> Result<Vec<Document>> {
    let mut out = Vec::new();
    while let Some(d) = cursor.next().await {
        out.push(d?);
    }
    Ok(out)
}

fn key_to_bson(key: &[Value]) -> Result<Bson> {
    match key {
        [Value::Json { v }] => {
            let json: serde_json::Value = serde_json::from_str(v)?;
            Bson::try_from(json).map_err(|e| CoreError::invalid(format!("bad _id: {e}")))
        }
        _ => Err(CoreError::invalid("a document key is one _id")),
    }
}

/// A grid column built from document fields.
struct FieldColumn {
    name: String,
    kind: ValueKind,
    type_name: String,
}

/// Top-level fields in first-seen order (`_id` first). A field whose values
/// have different BSON types becomes `mixed`.
fn flatten_columns(docs: &[Document]) -> Vec<FieldColumn> {
    let mut cols: Vec<FieldColumn> = Vec::new();
    for d in docs {
        for (k, v) in d {
            if matches!(v, Bson::Null) {
                if !cols.iter().any(|c| &c.name == k) {
                    cols.push(FieldColumn { name: k.clone(), kind: ValueKind::Other, type_name: String::new() });
                }
                continue;
            }
            let (_, kind, ty) = bson_to_value(v);
            match cols.iter_mut().find(|c| &c.name == k) {
                Some(c) if c.type_name.is_empty() => {
                    c.kind = kind;
                    c.type_name = ty.into();
                }
                Some(c) if c.type_name != ty && c.type_name != "mixed" => {
                    c.kind = ValueKind::Other;
                    c.type_name = "mixed".into();
                }
                Some(_) => {}
                None => cols.push(FieldColumn { name: k.clone(), kind, type_name: ty.into() }),
            }
        }
    }
    if let Some(i) = cols.iter().position(|c| c.name == "_id") {
        let id = cols.remove(i);
        cols.insert(0, id);
    }
    cols
}

/// A BSON value as a grid cell, with its kind and BSON type name.
fn bson_to_value(b: &Bson) -> (Value, ValueKind, &'static str) {
    match b {
        Bson::Double(v) => (Value::Float { v: *v }, ValueKind::Float, "double"),
        Bson::String(v) => (Value::Text { v: v.clone() }, ValueKind::Text, "string"),
        Bson::Boolean(v) => (Value::Bool { v: *v }, ValueKind::Bool, "bool"),
        Bson::Int32(v) => (Value::Int { v: *v as i64 }, ValueKind::Int, "int"),
        Bson::Int64(v) => (Value::Int { v: *v }, ValueKind::Int, "long"),
        Bson::Decimal128(v) => (Value::Decimal { v: v.to_string() }, ValueKind::Decimal, "decimal"),
        Bson::ObjectId(v) => (Value::Text { v: v.to_hex() }, ValueKind::Text, "objectId"),
        Bson::DateTime(v) => (
            Value::Timestamp { v: v.try_to_rfc3339_string().unwrap_or_else(|_| v.to_string()), has_tz: true },
            ValueKind::TimestampTz,
            "date",
        ),
        Bson::Binary(v) => (Value::Bytes { v: v.bytes.clone() }, ValueKind::Bytes, "binData"),
        Bson::Null | Bson::Undefined => (Value::Null, ValueKind::Other, "null"),
        Bson::Document(_) => (Value::Json { v: b.clone().into_relaxed_extjson().to_string() }, ValueKind::Json, "object"),
        Bson::Array(_) => (Value::Json { v: b.clone().into_relaxed_extjson().to_string() }, ValueKind::Json, "array"),
        other => (Value::Json { v: other.clone().into_relaxed_extjson().to_string() }, ValueKind::Json, "other"),
    }
}

/// Converts an edited value to the BSON type the field has now, so a number
/// stays a number and an ObjectId stays an ObjectId. New or null fields
/// take the natural type of the value.
fn value_to_bson(v: &Value, current: Option<&Bson>) -> std::result::Result<Bson, String> {
    use mongodb::bson::{oid::ObjectId, DateTime, Decimal128};
    if matches!(v, Value::Null) {
        return Ok(Bson::Null);
    }
    let text = crate::table::value_text(v).unwrap_or_default();
    let int = || text.trim().parse::<i64>().map_err(|_| format!("`{text}` is not a whole number"));
    let date = || {
        let t = text.trim().replacen(' ', "T", 1);
        DateTime::parse_rfc3339_str(&t)
            .or_else(|_| DateTime::parse_rfc3339_str(format!("{t}Z")))
            .or_else(|_| DateTime::parse_rfc3339_str(format!("{t}:00")))
            .or_else(|_| DateTime::parse_rfc3339_str(format!("{t}T00:00:00Z")))
            .map(Bson::DateTime)
            .map_err(|_| format!("`{text}` is not a date like 2026-01-31T12:00:00Z"))
    };
    let json = || -> std::result::Result<Bson, String> {
        let j: serde_json::Value = serde_json::from_str(&text).map_err(|e| format!("not valid JSON: {e}"))?;
        Bson::try_from(j).map_err(|e| format!("not valid Extended JSON: {e}"))
    };
    match current {
        Some(Bson::Int32(_)) => i32::try_from(int()?).map(Bson::Int32).map_err(|_| "too large for a 32-bit int".into()),
        Some(Bson::Int64(_)) => int().map(Bson::Int64),
        Some(Bson::Double(_)) => text.trim().parse::<f64>().map(Bson::Double).map_err(|_| format!("`{text}` is not a number")),
        Some(Bson::Decimal128(_)) => text.trim().parse::<Decimal128>().map(Bson::Decimal128).map_err(|_| format!("`{text}` is not a decimal")),
        Some(Bson::Boolean(_)) => match v {
            Value::Bool { v } => Ok(Bson::Boolean(*v)),
            _ => match text.trim() {
                "true" => Ok(Bson::Boolean(true)),
                "false" => Ok(Bson::Boolean(false)),
                _ => Err("must be true or false".into()),
            },
        },
        Some(Bson::ObjectId(_)) => ObjectId::parse_str(text.trim()).map(Bson::ObjectId).map_err(|_| "not a 24-character ObjectId".into()),
        Some(Bson::DateTime(_)) => date(),
        Some(Bson::Document(_)) => match json()? {
            d @ Bson::Document(_) => Ok(d),
            _ => Err("must be a JSON object".into()),
        },
        Some(Bson::Array(_)) => match json()? {
            a @ Bson::Array(_) => Ok(a),
            _ => Err("must be a JSON array".into()),
        },
        Some(Bson::String(_)) => Ok(Bson::String(text)),
        _ => Ok(match v {
            Value::Bool { v } => Bson::Boolean(*v),
            Value::Int { v } => i32::try_from(*v).map(Bson::Int32).unwrap_or(Bson::Int64(*v)),
            Value::Float { v } => Bson::Double(*v),
            Value::Decimal { .. } => Bson::Decimal128(text.parse::<Decimal128>().map_err(|_| "not a decimal".to_string())?),
            Value::Timestamp { .. } | Value::Date { .. } => date()?,
            Value::Json { .. } => json()?,
            Value::Bytes { v } => Bson::Binary(mongodb::bson::Binary { subtype: mongodb::bson::spec::BinarySubtype::Generic, bytes: v.clone() }),
            _ => Bson::String(text),
        }),
    }
}

/// `userId`, `user_id`, `authorIds` → does it name `collection`?
fn names_match(field: &str, collection: &str) -> bool {
    let lower = field.to_ascii_lowercase();
    let stem = ["_ids", "ids", "_id", "id"]
        .iter()
        .find_map(|s| lower.strip_suffix(s))
        .unwrap_or(&lower)
        .trim_end_matches('_');
    if stem.is_empty() {
        return false;
    }
    let c = collection.to_ascii_lowercase();
    let plural = if let Some(base) = stem.strip_suffix('y') { format!("{base}ies") } else { format!("{stem}s") };
    c == stem || c == plural || c == format!("{stem}es")
}

fn parse_command(query: &str) -> Result<Document> {
    let trimmed = query.trim();
    if trimmed.starts_with("db.") {
        return Err(CoreError::unsupported(
            "shell syntax is coming later; use a JSON command such as {\"find\": \"users\", \"filter\": {}}",
        ));
    }
    let json: serde_json::Value =
        serde_json::from_str(trimmed).map_err(|e| CoreError::query(format!("not valid JSON: {e}")))?;
    match Bson::try_from(json).map_err(|e| CoreError::query(format!("not valid Extended JSON: {e}")))? {
        Bson::Document(d) if !d.is_empty() => Ok(d),
        _ => Err(CoreError::query("expected a JSON object with a command name as its first key")),
    }
}

fn document_column() -> Vec<ColumnInfo> {
    vec![ColumnInfo { name: "document".into(), type_name: "document".into(), kind: ValueKind::Json }]
}

fn doc_row(d: Document) -> Row {
    Row { cells: vec![Value::Json { v: Bson::Document(d).into_relaxed_extjson().to_string() }] }
}

fn sub_doc(cmd: &Document, key: &str) -> Result<Option<Document>> {
    match cmd.get(key) {
        None | Some(Bson::Null) => Ok(None),
        Some(Bson::Document(d)) => Ok(Some(d.clone())),
        Some(_) => Err(CoreError::query(format!("`{key}` must be an object"))),
    }
}

fn int(cmd: &Document, key: &str) -> Option<i64> {
    match cmd.get(key)? {
        Bson::Int32(v) => Some(*v as i64),
        Bson::Int64(v) => Some(*v),
        Bson::Double(v) => Some(*v as i64),
        _ => None,
    }
}

/// Classifies a JSON command by its name (the first key).
pub(crate) fn classify_command(query: &str) -> StatementKind {
    let Ok(cmd) = parse_command(query) else { return StatementKind::Write };
    let name = cmd.keys().next().map(|k| k.to_ascii_lowercase()).unwrap_or_default();
    let empty_filter = |list: &str, field: &str| {
        cmd.get_array(list).is_ok_and(|ops| {
            ops.iter().any(|op| op.as_document().is_some_and(|d| d.get_document(field).is_ok_and(|q| q.is_empty())))
        })
    };
    match name.as_str() {
        "aggregate" => {
            let writes = cmd.get_array("pipeline").is_ok_and(|p| {
                p.iter().any(|s| s.as_document().is_some_and(|d| d.contains_key("$out") || d.contains_key("$merge")))
            });
            if writes { StatementKind::Write } else { StatementKind::Read }
        }
        "find" | "count" | "distinct" | "listcollections" | "listindexes" | "listdatabases" | "dbstats"
        | "collstats" | "serverstatus" | "buildinfo" | "ping" | "hello" | "ismaster" | "explain" | "getmore"
        | "connectionstatus" | "hostinfo" | "getlog" | "currentop" | "validate" => StatementKind::Read,
        "drop" | "dropdatabase" | "dropindexes" | "dropallusersfromdatabase" => StatementKind::Destructive,
        "delete" if empty_filter("deletes", "q") => StatementKind::Destructive,
        "update" if empty_filter("updates", "q") => StatementKind::Destructive,
        "create" | "createindexes" | "renamecollection" | "collmod" | "createview" => StatementKind::Ddl,
        _ => StatementKind::Write,
    }
}

#[async_trait]
impl Driver for MongoDriver {
    async fn ping(&self) -> Result<()> {
        self.client.database("admin").run_command(doc! { "ping": 1 }).await?;
        Ok(())
    }

    async fn server_info(&self) -> Result<ServerInfo> {
        let info = self.client.database("admin").run_command(doc! { "buildInfo": 1 }).await?;
        let version = info.get_str("version").unwrap_or("unknown").to_string();
        Ok(ServerInfo { engine: "MongoDB".into(), version })
    }

    async fn list_children(&self, path: &[String]) -> Result<Vec<BrowseNode>> {
        match path {
            [] => {
                // Users without listDatabases still see their default database.
                let names = match self.client.list_database_names().await {
                    Ok(n) => n,
                    Err(_) => vec![self.default_db.clone()],
                };
                Ok(names.into_iter().map(|n| BrowseNode::branch(n, NodeKind::Database)).collect())
            }
            [db] => {
                let mut names = self.client.database(db).list_collection_names().await?;
                names.sort();
                Ok(names.into_iter().map(|n| BrowseNode::branch(n, NodeKind::Collection)).collect())
            }
            [db, coll] => {
                let names = self.client.database(db).collection::<Document>(coll).list_index_names().await?;
                Ok(names.into_iter().map(|n| BrowseNode::leaf(n, NodeKind::Index, None)).collect())
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
        let cmd = parse_command(query)?;
        let db = self.client.database(database.filter(|d| !d.is_empty()).unwrap_or(&self.default_db));
        let name = cmd.keys().next().cloned().unwrap_or_default();

        let mut cursor = match name.as_str() {
            "find" => {
                let coll = db.collection::<Document>(cmd.get_str("find").map_err(|_| CoreError::query("`find` needs a collection name"))?);
                let mut find = coll.find(sub_doc(&cmd, "filter")?.unwrap_or_default());
                if let Some(sort) = sub_doc(&cmd, "sort")? {
                    find = find.sort(sort);
                }
                if let Some(p) = sub_doc(&cmd, "projection")? {
                    find = find.projection(p);
                }
                if let Some(n) = int(&cmd, "limit") {
                    find = find.limit(n);
                }
                if let Some(n) = int(&cmd, "skip") {
                    find = find.skip(n.max(0) as u64);
                }
                or_cancel(cancel, find).await.ok_or(CoreError::Cancelled)??
            }
            "aggregate" => {
                let coll = db.collection::<Document>(
                    cmd.get_str("aggregate").map_err(|_| CoreError::query("`aggregate` needs a collection name"))?,
                );
                let pipeline: Vec<Document> = cmd
                    .get_array("pipeline")
                    .map_err(|_| CoreError::query("`aggregate` needs a `pipeline` array"))?
                    .iter()
                    .filter_map(|s| s.as_document().cloned())
                    .collect();
                or_cancel(cancel, coll.aggregate(pipeline)).await.ok_or(CoreError::Cancelled)??
            }
            _ => {
                let reply = or_cancel(cancel, db.run_command(cmd)).await.ok_or(CoreError::Cancelled)??;
                sink.columns(document_column()).await;
                sink.push(doc_row(reply)).await;
                return Ok(());
            }
        };

        sink.columns(document_column()).await;
        loop {
            match or_cancel(cancel, cursor.next()).await {
                None => return Err(CoreError::Cancelled), // dropping the cursor kills it server-side
                Some(None) => return Ok(()),
                Some(Some(doc)) => {
                    if !sink.push(doc_row(doc?)).await {
                        return Ok(());
                    }
                }
            }
        }
    }

    async fn table_meta(&self, path: &[String]) -> Result<TableMeta> {
        let coll = self.collection(path)?;
        let sample: Vec<Document> = collect_docs(coll.find(doc! {}).limit(100).await?).await?;
        let indexed: Vec<String> = match coll.list_indexes().await {
            Ok(cursor) => cursor
                .filter_map(|i| async move { i.ok().and_then(|i| i.keys.keys().next().cloned()) })
                .collect()
                .await,
            Err(_) => Vec::new(),
        };
        let read_only_reason = self.read_only.then(|| "This connection is read-only.".to_string());
        let editable = read_only_reason.is_none();
        let columns = flatten_columns(&sample)
            .into_iter()
            .map(|c| ColumnMeta {
                is_key: c.name == "_id",
                editable: editable && c.name != "_id",
                nullable: c.name != "_id",
                has_default: false,
                enum_values: Vec::new(),
                indexed: indexed.contains(&c.name),
                kind: c.kind,
                type_name: c.type_name,
                name: c.name,
            })
            .collect();
        Ok(TableMeta { columns, paging: PagingMode::Keyset, key_columns: vec!["_id".into()], editable, read_only_reason })
    }

    async fn fetch_page(&self, path: &[String], cursor: &PageCursor, size: u32, sort: Option<&SortSpec>) -> Result<TablePage> {
        let coll = self.collection(path)?;
        let limit = size as i64 + 1;
        let docs = match (sort, cursor) {
            // Sorted by a field: BSON compares across types, so seek with skip.
            (Some(s), _) => {
                let dir = if s.descending { -1 } else { 1 };
                let skip = match cursor {
                    PageCursor::First => 0,
                    PageCursor::Offset { offset } => *offset,
                    _ => return Err(CoreError::unsupported("sorted collections page by offset")),
                };
                collect_docs(coll.find(doc! {}).sort(doc! { s.column.clone(): dir, "_id": 1 }).skip(skip).limit(limit).await?).await?
            }
            (None, PageCursor::Offset { offset }) => {
                collect_docs(coll.find(doc! {}).sort(doc! { "_id": 1 }).skip(*offset).limit(limit).await?).await?
            }
            (None, c) => {
                let (filter, dir) = match c {
                    PageCursor::First => (doc! {}, 1),
                    PageCursor::Last => (doc! {}, -1),
                    PageCursor::After { key } => (doc! { "_id": { "$gt": key_to_bson(key)? } }, 1),
                    PageCursor::Before { key } => (doc! { "_id": { "$lt": key_to_bson(key)? } }, -1),
                    PageCursor::Offset { .. } => unreachable!(),
                };
                collect_docs(coll.find(filter).sort(doc! { "_id": dir }).limit(limit).await?).await?
            }
        };
        let columns = flatten_columns(&docs);
        let keys: Vec<Vec<Value>> = docs
            .iter()
            .map(|d| vec![Value::Json { v: d.get("_id").cloned().unwrap_or(Bson::Null).into_canonical_extjson().to_string() }])
            .collect();
        let rows = docs
            .iter()
            .map(|d| Row { cells: columns.iter().map(|c| d.get(&c.name).map_or(Value::Null, |b| bson_to_value(b).0)).collect() })
            .collect();
        let fetched = Fetched {
            columns: columns.into_iter().map(|c| ColumnInfo { name: c.name, type_name: c.type_name, kind: c.kind }).collect(),
            rows,
            edit_keys: if self.read_only { Vec::new() } else { keys.clone() },
            paging_keys: keys,
        };
        Ok(assemble(fetched, cursor, size as usize, sort.is_none()))
    }

    async fn row_count(&self, path: &[String], exact: bool) -> Result<RowCount> {
        let coll = self.collection(path)?;
        let estimate = coll.estimated_document_count().await?;
        if !exact && estimate >= EXACT_COUNT_BELOW as u64 {
            return Ok(RowCount { count: estimate, exact: false });
        }
        let count = coll.count_documents(doc! {}).max_time(Duration::from_secs(60)).await?;
        Ok(RowCount { count, exact: true })
    }

    async fn preview_edits(&self, path: &[String], edits: &[CellEdit]) -> Result<Vec<String>> {
        let coll = self.collection(path)?;
        let mut out = Vec::new();
        for e in edits {
            let (id, value) = self.edit_values(&coll, e).await?;
            out.push(format!(
                "db.{}.updateOne({{\"_id\": {}}}, {{\"$set\": {{{}: {}}}}})",
                coll.name(),
                id.into_relaxed_extjson(),
                serde_json::Value::String(e.column.clone()),
                value.into_relaxed_extjson()
            ));
        }
        Ok(out)
    }

    /// Applied one by one (standalone servers have no transactions). Every
    /// row is checked first, so a missing row stops the batch before any write.
    async fn apply_edits(&self, path: &[String], edits: &[CellEdit]) -> Result<u64> {
        if self.read_only {
            return Err(CoreError::ReadOnly { message: "this connection is read-only".into() });
        }
        let coll = self.collection(path)?;
        let mut planned = Vec::new();
        for e in edits {
            planned.push((e.column.clone(), self.edit_values(&coll, e).await?));
        }
        for (i, (field, (id, value))) in planned.into_iter().enumerate() {
            let r = coll.update_one(doc! { "_id": id }, doc! { "$set": { field: value } }).await?;
            if r.matched_count != 1 {
                return Err(CoreError::query(format!(
                    "change {} matched no document; the {} before it were saved",
                    i + 1,
                    i
                )));
            }
        }
        Ok(edits.len() as u64)
    }

    async fn schema_graph(&self, path: &[String]) -> Result<SchemaGraph> {
        let db_name = path.first().ok_or_else(|| CoreError::invalid("choose a database"))?;
        let db = self.client.database(db_name);
        let mut names = db.list_collection_names().await?;
        names.retain(|n| !n.starts_with("system."));
        names.sort();
        names.truncate(200);

        let mut tables = Vec::new();
        let mut samples = Vec::new();
        for name in &names {
            let coll = db.collection::<Document>(name);
            let docs = collect_docs(coll.find(doc! {}).limit(50).await?).await?;
            // Single-field unique indexes mark unique fields.
            let unique: Vec<String> = match coll.list_indexes().await {
                Ok(cursor) => cursor
                    .filter_map(|i| async move {
                        let i = i.ok()?;
                        let is_unique = i.options.as_ref().and_then(|o| o.unique).unwrap_or(false);
                        (is_unique && i.keys.len() == 1).then(|| i.keys.keys().next().cloned()).flatten()
                    })
                    .collect()
                    .await,
                Err(_) => Vec::new(),
            };
            tables.push(GraphTable {
                name: name.clone(),
                path: vec![db_name.clone(), name.clone()],
                columns: flatten_columns(&docs)
                    .into_iter()
                    .map(|c| GraphColumn {
                        is_key: c.name == "_id",
                        is_identity: false,
                        is_unique: unique.contains(&c.name),
                        nullable: c.name != "_id",
                        name: c.name,
                        type_name: c.type_name,
                    })
                    .collect(),
                estimated_rows: coll.estimated_document_count().await.ok(),
            });
            samples.push(docs);
        }

        // MongoDB has no foreign keys: infer them from fields that hold
        // ObjectIds and are named after another collection (userId → users),
        // then confirm that some of those ids really exist there.
        let mut relations = Vec::new();
        for (name, docs) in names.iter().zip(&samples) {
            for field in flatten_columns(docs).into_iter().map(|c| c.name).filter(|f| f != "_id") {
                let ids: Vec<Bson> = docs
                    .iter()
                    .filter_map(|d| d.get(&field))
                    .flat_map(|b| match b {
                        Bson::Array(a) => a.clone(),
                        other => vec![other.clone()],
                    })
                    .filter(|b| matches!(b, Bson::ObjectId(_)))
                    .take(5)
                    .collect();
                if ids.is_empty() {
                    continue;
                }
                for target in names.iter().filter(|t| *t != name && names_match(&field, t)) {
                    let hits = db.collection::<Document>(target).count_documents(doc! { "_id": { "$in": ids.clone() } }).await.unwrap_or(0);
                    if hits > 0 {
                        relations.push(Relation {
                            name: format!("{name}.{field}"),
                            from_table: name.clone(),
                            from_columns: vec![field.clone()],
                            to_table: target.clone(),
                            to_columns: vec!["_id".into()],
                            inferred: true,
                        });
                        break;
                    }
                }
            }
        }
        Ok(SchemaGraph { tables, relations })
    }

    fn classify(&self, query: &str) -> StatementKind {
        classify_command(query)
    }

    async fn close(&self) {
        self.client.clone().shutdown().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_commands() {
        use StatementKind::*;
        assert_eq!(classify_command(r#"{"find": "users", "filter": {}}"#), Read);
        assert_eq!(classify_command(r#"{"aggregate": "o", "pipeline": [{"$match": {}}]}"#), Read);
        assert_eq!(classify_command(r#"{"aggregate": "o", "pipeline": [{"$out": "x"}]}"#), Write);
        assert_eq!(classify_command(r#"{"insert": "u", "documents": [{}]}"#), Write);
        assert_eq!(classify_command(r#"{"delete": "u", "deletes": [{"q": {"a": 1}, "limit": 1}]}"#), Write);
        assert_eq!(classify_command(r#"{"delete": "u", "deletes": [{"q": {}, "limit": 0}]}"#), Destructive);
        assert_eq!(classify_command(r#"{"dropDatabase": 1}"#), Destructive);
        assert_eq!(classify_command(r#"{"createIndexes": "u", "indexes": []}"#), Ddl);
        assert_eq!(classify_command("not json"), Write);
    }

    #[test]
    fn edits_keep_the_field_type() {
        let int = Bson::Int32(1);
        assert_eq!(value_to_bson(&Value::Text { v: "42".into() }, Some(&int)), Ok(Bson::Int32(42)));
        assert!(value_to_bson(&Value::Text { v: "4.5".into() }, Some(&int)).is_err());
        assert!(value_to_bson(&Value::Int { v: 1 << 40 }, Some(&int)).is_err());
        let oid = Bson::ObjectId(mongodb::bson::oid::ObjectId::new());
        assert!(matches!(value_to_bson(&Value::Text { v: "65f000000000000000000000".into() }, Some(&oid)), Ok(Bson::ObjectId(_))));
        let date = Bson::DateTime(mongodb::bson::DateTime::now());
        assert!(matches!(value_to_bson(&Value::Text { v: "2026-01-02 03:04:05".into() }, Some(&date)), Ok(Bson::DateTime(_))));
        assert_eq!(value_to_bson(&Value::Int { v: 7 }, None), Ok(Bson::Int32(7)));
        assert_eq!(value_to_bson(&Value::Null, Some(&int)), Ok(Bson::Null));
    }

    #[test]
    fn infers_relation_names() {
        assert!(names_match("userId", "users"));
        assert!(names_match("category_id", "categories"));
        assert!(names_match("tagIds", "tags"));
        assert!(!names_match("id", "ids"));
        assert!(!names_match("ownerId", "users"));
    }

    #[test]
    fn mixed_fields_are_marked() {
        let docs = vec![doc! { "_id": 1, "a": 1, "b": "x" }, doc! { "_id": 2, "a": "one" }];
        let cols = flatten_columns(&docs);
        assert_eq!(cols.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["_id", "a", "b"]);
        assert_eq!(cols[1].type_name, "mixed");
    }

    #[test]
    fn parses_extended_json() {
        let d = parse_command(r#"{"find": "u", "filter": {"_id": {"$oid": "65f000000000000000000000"}}}"#).unwrap();
        let filter = d.get_document("filter").unwrap();
        assert!(matches!(filter.get("_id"), Some(Bson::ObjectId(_))));
        assert!(parse_command("db.users.find({})").is_err());
        assert!(parse_command("[]").is_err());
    }
}
