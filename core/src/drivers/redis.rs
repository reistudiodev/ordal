//! Redis driver (redis-rs, async, RESP2).
//! Browse tree: db0..dbN › key prefixes grouped by `:` › keys.
//! Queries are Redis commands as typed in redis-cli: `HGETALL user:1`.

use std::collections::{BTreeMap, HashMap};
use std::time::Duration;

use async_trait::async_trait;
use redis::aio::MultiplexedConnection;
use redis::{ConnectionAddr, ConnectionInfo, ProtocolVersion, RedisConnectionInfo};
use tokio_util::sync::CancellationToken;

use super::{or_cancel, BrowseNode, Driver, KeyInfo, NodeKind, ServerInfo, Sink};
use crate::config::{ConnectionConfig, TlsMode};
use crate::error::{CoreError, Result};
use crate::sql::StatementKind;
use crate::value::{ColumnInfo, Row, RowCount, Value, ValueKind, Window};

/// Stop scanning a level after this many keys; the browser says so.
const SCAN_CAP: usize = 10_000;
const SEP: char = ':';

pub(crate) struct RedisDriver {
    info: ConnectionInfo,
    default_db: i64,
    conns: tokio::sync::Mutex<HashMap<i64, MultiplexedConnection>>,
}

impl RedisDriver {
    pub(crate) async fn connect(config: &ConnectionConfig, password: Option<String>) -> Result<Self> {
        let addr = match config.tls {
            TlsMode::Require => {
                ConnectionAddr::TcpTls { host: config.host.clone(), port: config.port, insecure: false, tls_params: None }
            }
            _ => ConnectionAddr::Tcp(config.host.clone(), config.port),
        };
        let default_db = parse_db(&config.database)?;
        let info = ConnectionInfo {
            addr,
            redis: RedisConnectionInfo {
                db: default_db,
                username: Some(config.username.clone()).filter(|u| !u.is_empty()),
                password,
                protocol: ProtocolVersion::RESP2,
            },
        };
        let driver = Self { info, default_db, conns: Default::default() };
        driver.conn(default_db).await?;
        Ok(driver)
    }

    /// One multiplexed connection per database index, opened on first use.
    async fn conn(&self, db: i64) -> Result<MultiplexedConnection> {
        let mut conns = self.conns.lock().await;
        if let Some(c) = conns.get(&db) {
            return Ok(c.clone());
        }
        let mut info = self.info.clone();
        info.redis.db = db;
        let client = redis::Client::open(info)?;
        let conn = tokio::time::timeout(Duration::from_secs(10), client.get_multiplexed_async_connection())
            .await
            .map_err(|_| CoreError::Timeout { message: "connecting to Redis".into() })??;
        conns.insert(db, conn.clone());
        Ok(conn)
    }

    async fn dedicated(&self, db: i64) -> Result<MultiplexedConnection> {
        let mut info = self.info.clone();
        info.redis.db = db;
        Ok(redis::Client::open(info)?.get_multiplexed_async_connection().await?)
    }

    async fn database_count(&self) -> i64 {
        let Ok(mut c) = self.conn(self.default_db).await else { return 16 };
        let reply: redis::RedisResult<Vec<String>> =
            redis::cmd("CONFIG").arg("GET").arg("databases").query_async(&mut c).await;
        // Managed services often disable CONFIG; 16 is the server default.
        reply.ok().and_then(|v| v.get(1).and_then(|n| n.parse().ok())).unwrap_or(16)
    }
}

/// `"3"`, `"db3"` or `""` (= 0).
fn parse_db(s: &str) -> Result<i64> {
    let n = s.trim().trim_start_matches("db");
    if n.is_empty() {
        return Ok(0);
    }
    n.parse().map_err(|_| CoreError::invalid(format!("Redis database must be a number, got `{s}`")))
}

fn is_blocking(upper: &str, args: &[String]) -> bool {
    matches!(
        upper,
        "BLPOP" | "BRPOP" | "BRPOPLPUSH" | "BLMOVE" | "BLMPOP" | "BZPOPMIN" | "BZPOPMAX" | "BZMPOP" | "WAIT" | "WAITAOF"
    ) || (matches!(upper, "XREAD" | "XREADGROUP") && args.iter().any(|a| a.eq_ignore_ascii_case("BLOCK")))
}

/// Escapes glob characters so a key prefix matches literally in SCAN MATCH.
fn glob_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if matches!(c, '*' | '?' | '[' | ']' | '\\') {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// Groups keys under `prefix` into the next path segment.
/// Returns (sub-prefix -> key count, leaf keys).
fn group_keys(prefix: &str, keys: &[String]) -> (BTreeMap<String, usize>, Vec<String>) {
    let mut groups = BTreeMap::new();
    let mut leaves = Vec::new();
    for key in keys {
        let Some(rest) = key.strip_prefix(prefix) else { continue };
        match rest.split_once(SEP) {
            Some((head, _)) => *groups.entry(head.to_string()).or_insert(0) += 1,
            None => leaves.push(key.clone()),
        }
    }
    leaves.sort();
    (groups, leaves)
}

/// Splits a command line like redis-cli does: whitespace, "double" and 'single' quotes.
pub(crate) fn split_command(line: &str) -> Result<Vec<String>> {
    let mut args = Vec::new();
    let mut cur = String::new();
    let mut chars = line.trim().chars().peekable();
    let mut in_word = false;
    while let Some(c) = chars.next() {
        match c {
            '"' | '\'' => {
                in_word = true;
                let q = c;
                loop {
                    match chars.next() {
                        None => return Err(CoreError::query("unbalanced quotes")),
                        Some(c) if c == q => break,
                        Some('\\') if q == '"' => match chars.next() {
                            Some('n') => cur.push('\n'),
                            Some('t') => cur.push('\t'),
                            Some(c) => cur.push(c),
                            None => return Err(CoreError::query("unbalanced quotes")),
                        },
                        Some(c) => cur.push(c),
                    }
                }
            }
            c if c.is_whitespace() => {
                if in_word {
                    args.push(std::mem::take(&mut cur));
                    in_word = false;
                }
            }
            c => {
                in_word = true;
                cur.push(c);
            }
        }
    }
    if in_word {
        args.push(cur);
    }
    Ok(args)
}

const READ_COMMANDS: &[&str] = &[
    "GET", "MGET", "GETRANGE", "STRLEN", "EXISTS", "TYPE", "TTL", "PTTL", "EXPIRETIME", "KEYS", "SCAN", "DBSIZE",
    "RANDOMKEY", "HGET", "HGETALL", "HMGET", "HKEYS", "HVALS", "HLEN", "HEXISTS", "HSCAN", "HSTRLEN", "LRANGE",
    "LLEN", "LINDEX", "LPOS", "SMEMBERS", "SCARD", "SISMEMBER", "SMISMEMBER", "SSCAN", "SRANDMEMBER", "SINTER",
    "SUNION", "SDIFF", "ZRANGE", "ZRANGEBYSCORE", "ZRANGEBYLEX", "ZREVRANGE", "ZREVRANGEBYSCORE", "ZCARD",
    "ZSCORE", "ZMSCORE", "ZRANK", "ZREVRANK", "ZCOUNT", "ZSCAN", "XRANGE", "XREVRANGE", "XLEN", "XINFO", "XREAD",
    "XPENDING", "INFO", "PING", "ECHO", "TIME", "LASTSAVE", "MEMORY", "OBJECT", "SLOWLOG", "LATENCY", "COMMAND",
    "DUMP", "GETBIT", "BITCOUNT", "BITPOS", "PFCOUNT", "GEOPOS", "GEODIST", "GEOSEARCH", "GEOHASH", "JSON.GET",
    "JSON.TYPE", "JSON.OBJKEYS", "JSON.ARRLEN", "JSON.STRLEN",
];

/// Classifies a redis-cli command line.
pub(crate) fn classify_command(line: &str) -> StatementKind {
    let Ok(args) = split_command(line) else { return StatementKind::Write };
    let Some(name) = args.first().map(|a| a.to_ascii_uppercase()) else { return StatementKind::Read };
    let sub = args.get(1).map(|a| a.to_ascii_uppercase()).unwrap_or_default();
    match name.as_str() {
        "FLUSHALL" | "FLUSHDB" | "SHUTDOWN" | "SWAPDB" | "DEBUG" => StatementKind::Destructive,
        "CONFIG" if sub == "GET" => StatementKind::Read,
        "CLIENT" if matches!(sub.as_str(), "LIST" | "INFO" | "GETNAME" | "ID") => StatementKind::Read,
        n if READ_COMMANDS.contains(&n) => StatementKind::Read,
        _ => StatementKind::Write,
    }
}

fn to_json(v: &redis::Value) -> serde_json::Value {
    use redis::Value as R;
    use serde_json::Value as J;
    match v {
        R::Nil => J::Null,
        R::Int(i) => J::from(*i),
        R::Double(f) => J::from(*f),
        R::Boolean(b) => J::Bool(*b),
        R::BulkString(b) => J::String(String::from_utf8_lossy(b).into_owned()),
        R::SimpleString(s) => J::String(s.clone()),
        R::VerbatimString { text, .. } => J::String(text.clone()),
        R::Okay => J::String("OK".into()),
        R::BigNumber(n) => J::String(n.to_string()),
        R::Array(items) | R::Set(items) => J::Array(items.iter().map(to_json).collect()),
        R::Map(pairs) => J::Object(
            pairs
                .iter()
                .map(|(k, v)| (to_json(k).as_str().map(str::to_string).unwrap_or_else(|| to_json(k).to_string()), to_json(v)))
                .collect(),
        ),
        other => J::String(format!("{other:?}")),
    }
}

fn to_value(v: &redis::Value) -> Value {
    use redis::Value as R;
    match v {
        R::Nil => Value::Null,
        R::Int(v) => Value::Int { v: *v },
        R::Double(v) => Value::Float { v: *v },
        R::Boolean(v) => Value::Bool { v: *v },
        R::BulkString(b) => match std::str::from_utf8(b) {
            Ok(s) => Value::text(s),
            Err(_) => Value::Bytes { v: b.clone() },
        },
        R::SimpleString(s) => Value::text(s.clone()),
        R::VerbatimString { text, .. } => Value::text(text.clone()),
        R::Okay => Value::text("OK"),
        R::BigNumber(n) => Value::Decimal { v: n.to_string() },
        other => Value::Json { v: to_json(other).to_string() },
    }
}

fn col(name: &str, kind: ValueKind) -> ColumnInfo {
    ColumnInfo { name: name.into(), type_name: String::new(), kind }
}

/// Lays a reply out as rows: lists get an index column, field/value replies
/// (HGETALL, CONFIG GET, RESP3 maps) get two columns, scalars get one row.
fn reply_rows(command: &str, reply: &redis::Value) -> (Vec<ColumnInfo>, Vec<Row>) {
    use redis::Value as R;
    let pairs = |items: &[R]| -> Vec<Row> {
        items.chunks(2).map(|p| Row { cells: p.iter().map(to_value).collect() }).collect()
    };
    match reply {
        R::Map(map) => (
            vec![col("field", ValueKind::Text), col("value", ValueKind::Other)],
            map.iter().map(|(k, v)| Row { cells: vec![to_value(k), to_value(v)] }).collect(),
        ),
        R::Array(items) if matches!(command, "HGETALL" | "CONFIG") && items.len() % 2 == 0 => {
            (vec![col("field", ValueKind::Text), col("value", ValueKind::Other)], pairs(items))
        }
        R::Array(items) | R::Set(items) => (
            vec![col("#", ValueKind::Int), col("value", ValueKind::Other)],
            items
                .iter()
                .enumerate()
                .map(|(i, v)| Row { cells: vec![Value::Int { v: i as i64 + 1 }, to_value(v)] })
                .collect(),
        ),
        other => (vec![col("value", ValueKind::Other)], vec![Row { cells: vec![to_value(other)] }]),
    }
}

/// `["db3", "user", "1"]` -> (3, "user:1").
fn key_path(path: &[String]) -> Result<(i64, String)> {
    let [db, rest @ ..] = path else { return Err(CoreError::invalid("not a key path")) };
    Ok((parse_db(db)?, rest.join(&SEP.to_string())))
}

#[async_trait]
impl Driver for RedisDriver {
    async fn ping(&self) -> Result<()> {
        let mut c = self.conn(self.default_db).await?;
        redis::cmd("PING").query_async::<()>(&mut c).await?;
        Ok(())
    }

    async fn server_info(&self) -> Result<ServerInfo> {
        let mut c = self.conn(self.default_db).await?;
        let info: String = redis::cmd("INFO").arg("server").query_async(&mut c).await?;
        let field = |name: &str| {
            info.lines().find_map(|l| l.strip_prefix(name).and_then(|r| r.strip_prefix(':'))).map(|v| v.trim().to_string())
        };
        let (engine, version) = match field("valkey_version") {
            Some(v) => ("Valkey", v),
            None => ("Redis", field("redis_version").unwrap_or_else(|| "unknown".into())),
        };
        Ok(ServerInfo { engine: engine.into(), version })
    }

    async fn list_children(&self, path: &[String]) -> Result<Vec<BrowseNode>> {
        if path.is_empty() {
            let mut c = self.conn(self.default_db).await?;
            let keyspace: String = redis::cmd("INFO").arg("keyspace").query_async(&mut c).await?;
            let counts: HashMap<i64, String> = keyspace
                .lines()
                .filter_map(|l| {
                    let (db, rest) = l.strip_prefix("db")?.split_once(':')?;
                    let keys = rest.split(',').find_map(|kv| kv.strip_prefix("keys="))?;
                    Some((db.parse().ok()?, keys.to_string()))
                })
                .collect();
            return Ok((0..self.database_count().await)
                .map(|i| {
                    let n = BrowseNode::branch(format!("db{i}"), NodeKind::Database);
                    match counts.get(&i) {
                        Some(k) => n.with_detail(format!("{k} keys")),
                        None => n.with_detail("empty"),
                    }
                })
                .collect());
        }

        let (db, joined) = key_path(path)?;
        let prefix = if path.len() > 1 { format!("{joined}{SEP}") } else { String::new() };
        let pattern = format!("{}*", glob_escape(&prefix));
        let mut c = self.conn(db).await?;
        let mut keys = Vec::new();
        let mut cursor: u64 = 0;
        loop {
            let (next, batch): (u64, Vec<String>) =
                redis::cmd("SCAN").arg(cursor).arg("MATCH").arg(&pattern).arg("COUNT").arg(1000).query_async(&mut c).await?;
            keys.extend(batch);
            cursor = next;
            if cursor == 0 || keys.len() >= SCAN_CAP {
                break;
            }
        }
        let truncated = cursor != 0;
        let (groups, leaves) = group_keys(&prefix, &keys);

        // Key types in one round trip.
        let mut pipe = redis::pipe();
        for k in &leaves {
            pipe.cmd("TYPE").arg(k);
        }
        let types: Vec<String> = if leaves.is_empty() { Vec::new() } else { pipe.query_async(&mut c).await? };

        let mut out: Vec<BrowseNode> = groups
            .into_iter()
            .map(|(g, n)| BrowseNode::branch(g, NodeKind::KeyPrefix).with_detail(format!("{n} keys")))
            .collect();
        out.extend(leaves.iter().zip(types.into_iter().chain(std::iter::repeat(String::new()))).map(|(k, t)| {
            let name = k.strip_prefix(&prefix).unwrap_or(k).to_string();
            BrowseNode::leaf(name, NodeKind::Key, Some(t).filter(|t| !t.is_empty()))
        }));
        if truncated {
            out.push(BrowseNode::leaf("…", NodeKind::Folder, Some(format!("first {SCAN_CAP} keys shown"))));
        }
        Ok(out)
    }

    async fn run_query(
        &self,
        query: &str,
        database: Option<&str>,
        sink: &mut Sink,
        cancel: &CancellationToken,
    ) -> Result<()> {
        let args = split_command(query)?;
        let Some((name, rest)) = args.split_first() else { return Err(CoreError::query("empty command")) };
        let upper = name.to_ascii_uppercase();
        match upper.as_str() {
            "SELECT" => return Err(CoreError::unsupported("pick the database in the browser instead of SELECT")),
            "SUBSCRIBE" | "PSUBSCRIBE" | "SSUBSCRIBE" | "MONITOR" => {
                return Err(CoreError::unsupported("subscriptions open their own view (coming later)"))
            }
            _ => {}
        }
        let db = match database {
            Some(d) if !d.is_empty() => parse_db(d)?,
            _ => self.default_db,
        };
        // A blocking command would stall every other command on the shared
        // connection, so it gets its own, dropped (and so unblocked) on cancel.
        let mut c = if is_blocking(&upper, rest) { self.dedicated(db).await? } else { self.conn(db).await? };
        let mut cmd = redis::cmd(name);
        for a in rest {
            cmd.arg(a);
        }
        let reply: redis::Value = or_cancel(cancel, cmd.query_async(&mut c)).await.ok_or(CoreError::Cancelled)??;
        if let redis::Value::ServerError(e) = &reply {
            return Err(redis::RedisError::from(e.clone()).into());
        }
        let (cols, rows) = reply_rows(&upper, &reply);
        sink.columns(cols).await;
        for r in rows {
            if !sink.push(r).await {
                break;
            }
        }
        Ok(())
    }

    async fn fetch_window(&self, _path: &[String], _offset: u64, _limit: u32) -> Result<Window> {
        Err(CoreError::unsupported("Redis keys open in a key viewer, not a table"))
    }

    async fn row_count(&self, _path: &[String]) -> Result<RowCount> {
        Err(CoreError::unsupported("Redis keys open in a key viewer, not a table"))
    }

    async fn key_info(&self, path: &[String]) -> Result<KeyInfo> {
        let (db, key) = key_path(path)?;
        let mut c = self.conn(db).await?;
        let (key_type, ttl, memory): (String, i64, Option<u64>) = redis::pipe()
            .cmd("TYPE")
            .arg(&key)
            .cmd("PTTL")
            .arg(&key)
            .cmd("MEMORY")
            .arg("USAGE")
            .arg(&key)
            .query_async(&mut c)
            .await?;
        if key_type == "none" {
            return Err(CoreError::not_found(format!("key `{key}`")));
        }
        Ok(KeyInfo { key_type, ttl_ms: (ttl >= 0).then_some(ttl), memory_bytes: memory })
    }

    fn classify(&self, query: &str) -> StatementKind {
        classify_command(query)
    }

    async fn close(&self) {
        self.conns.lock().await.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_like_redis_cli() {
        assert_eq!(split_command(r#"SET "a key" 'it''s' x"#).unwrap(), vec!["SET", "a key", "its", "x"]);
        assert_eq!(split_command(r#"SET k "line\nbreak""#).unwrap(), vec!["SET", "k", "line\nbreak"]);
        assert_eq!(split_command(r#"SET k """#).unwrap(), vec!["SET", "k", ""]);
        assert!(split_command(r#"GET "oops"#).is_err());
    }

    #[test]
    fn groups_by_prefix() {
        let keys: Vec<String> = ["user:1", "user:2", "user:1:posts", "session:x", "plain"].map(String::from).into();
        let (groups, leaves) = group_keys("", &keys);
        assert_eq!(groups.get("user"), Some(&3));
        assert_eq!(groups.get("session"), Some(&1));
        assert_eq!(leaves, vec!["plain"]);
        let (groups, leaves) = group_keys("user:", &keys);
        assert_eq!(groups.get("1"), Some(&1));
        assert_eq!(leaves, vec!["user:1", "user:2"]);
    }

    #[test]
    fn classifies_commands() {
        assert_eq!(classify_command("hgetall user:1"), StatementKind::Read);
        assert_eq!(classify_command("CONFIG GET maxmemory"), StatementKind::Read);
        assert_eq!(classify_command("CONFIG SET maxmemory 1"), StatementKind::Write);
        assert_eq!(classify_command("SET a b"), StatementKind::Write);
        assert_eq!(classify_command("flushall"), StatementKind::Destructive);
    }

    #[test]
    fn escapes_globs() {
        assert_eq!(glob_escape("a*b?[c]"), "a\\*b\\?\\[c\\]");
        assert_eq!(parse_db("db3").unwrap(), 3);
        assert_eq!(parse_db("").unwrap(), 0);
        assert!(parse_db("x").is_err());
    }

    #[test]
    fn lays_out_replies() {
        use redis::Value as R;
        let flat = R::Array(vec![R::BulkString(b"f".to_vec()), R::Int(1)]);
        let (cols, rows) = reply_rows("HGETALL", &flat);
        assert_eq!(cols[0].name, "field");
        assert_eq!(rows[0].cells, vec![Value::text("f"), Value::Int { v: 1 }]);
        let (cols, rows) = reply_rows("LRANGE", &flat);
        assert_eq!(cols[0].name, "#");
        assert_eq!(rows.len(), 2);
        let (_, rows) = reply_rows("GET", &R::Nil);
        assert_eq!(rows[0].cells, vec![Value::Null]);
    }
}
