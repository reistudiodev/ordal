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
use mongodb::Client;
use tokio_util::sync::CancellationToken;

use super::{or_cancel, BrowseNode, Driver, NodeKind, ServerInfo, Sink, EXACT_COUNT_BELOW};
use crate::config::{ConnectionConfig, TlsMode};
use crate::error::{CoreError, Result};
use crate::sql::StatementKind;
use crate::value::{ColumnInfo, Row, RowCount, Value, ValueKind, Window};

pub(crate) struct MongoDriver {
    client: Client,
    default_db: String,
}

impl MongoDriver {
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
        Ok(Self { client, default_db })
    }
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

    async fn fetch_window(&self, path: &[String], offset: u64, limit: u32) -> Result<Window> {
        let [db, coll] = path else { return Err(CoreError::invalid("not a collection path")) };
        let coll = self.client.database(db).collection::<Document>(coll);
        let mut cursor = coll.find(doc! {}).sort(doc! { "_id": 1 }).skip(offset).limit(limit as i64).await?;
        let mut rows = Vec::with_capacity(limit as usize);
        while let Some(doc) = cursor.next().await {
            rows.push(doc_row(doc?));
        }
        Ok(Window { columns: document_column(), rows })
    }

    async fn row_count(&self, path: &[String]) -> Result<RowCount> {
        let [db, coll] = path else { return Err(CoreError::invalid("not a collection path")) };
        let coll = self.client.database(db).collection::<Document>(coll);
        let estimate = coll.estimated_document_count().await?;
        if estimate >= EXACT_COUNT_BELOW as u64 {
            return Ok(RowCount { count: estimate, exact: false });
        }
        Ok(RowCount { count: coll.count_documents(doc! {}).await?, exact: true })
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
    fn parses_extended_json() {
        let d = parse_command(r#"{"find": "u", "filter": {"_id": {"$oid": "65f000000000000000000000"}}}"#).unwrap();
        let filter = d.get_document("filter").unwrap();
        assert!(matches!(filter.get("_id"), Some(Bson::ObjectId(_))));
        assert!(parse_command("db.users.find({})").is_err());
        assert!(parse_command("[]").is_err());
    }
}
