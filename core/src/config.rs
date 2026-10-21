//! Saved connection settings and connection-URL parsing.
//! A `ConnectionConfig` never holds a password; passwords live in the OS keychain.

use std::collections::HashMap;
use std::fmt;

use serde::{Deserialize, Serialize};

use crate::error::{CoreError, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
pub enum DatabaseKind {
    Postgres,
    MySql,
    Sqlite,
    MongoDb,
    Redis,
}

impl DatabaseKind {
    pub fn default_port(self) -> u16 {
        match self {
            Self::Postgres => 5432,
            Self::MySql => 3306,
            Self::Sqlite => 0,
            Self::MongoDb => 27017,
            Self::Redis => 6379,
        }
    }
}

/// Where a connection points. Drives the colour tag and production guards.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, uniffi::Enum)]
pub enum EnvironmentTag {
    #[default]
    Local,
    Dev,
    Staging,
    Prod,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, uniffi::Enum)]
pub enum TlsMode {
    Disable,
    #[default]
    Prefer,
    Require,
}

/// Everything needed to open a connection, except the password.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct ConnectionConfig {
    /// Stable id; also the keychain account name. Empty means "assign one on save".
    pub id: String,
    pub name: String,
    pub kind: DatabaseKind,
    /// Host name. For SQLite, the database file path. For MongoDB, may be a
    /// comma-separated `host:port` list.
    pub host: String,
    pub port: u16,
    /// Default database. For Redis, the db index (`"0"`).
    pub database: String,
    pub username: String,
    #[serde(default)]
    pub environment: EnvironmentTag,
    #[serde(default)]
    pub color_tag: Option<String>,
    #[serde(default)]
    pub read_only: bool,
    #[serde(default)]
    pub tls: TlsMode,
    /// Engine-specific extras, e.g. `authSource`, `srv`.
    #[serde(default)]
    pub options: HashMap<String, String>,
}

impl ConnectionConfig {
    pub(crate) fn validate(&self) -> Result<()> {
        if self.name.trim().is_empty() {
            return Err(CoreError::invalid("name is empty"));
        }
        if self.host.trim().is_empty() {
            let what = if self.kind == DatabaseKind::Sqlite { "file path" } else { "host" };
            return Err(CoreError::invalid(format!("{what} is empty")));
        }
        Ok(())
    }

    pub(crate) fn option(&self, key: &str) -> Option<&str> {
        self.options.get(key).map(String::as_str)
    }
}

/// The result of parsing a pasted connection URL.
#[derive(Clone, PartialEq, uniffi::Record)]
pub struct ParsedConnection {
    pub config: ConnectionConfig,
    /// Taken out of the URL so the UI can hand it to the keychain.
    pub password: Option<String>,
}

impl fmt::Debug for ParsedConnection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ParsedConnection")
            .field("config", &self.config)
            .field("password", &self.password.as_ref().map(|_| "<redacted>"))
            .finish()
    }
}

/// Parses `postgres://`, `mysql://`, `mariadb://`, `sqlite:`, `mongodb://`,
/// `mongodb+srv://`, `redis://` and `rediss://` URLs.
#[uniffi::export]
pub fn parse_connection_url(url: String) -> Result<ParsedConnection> {
    let url = url.trim();
    let (scheme, rest) = url
        .split_once(':')
        .ok_or_else(|| CoreError::invalid("not a connection URL"))?;
    let scheme = scheme.to_ascii_lowercase();
    let kind = match scheme.as_str() {
        "postgres" | "postgresql" => DatabaseKind::Postgres,
        "mysql" | "mariadb" => DatabaseKind::MySql,
        "sqlite" | "sqlite3" => DatabaseKind::Sqlite,
        "mongodb" | "mongodb+srv" => DatabaseKind::MongoDb,
        "redis" | "rediss" => DatabaseKind::Redis,
        other => return Err(CoreError::invalid(format!("unknown scheme `{other}`"))),
    };

    let mut config = ConnectionConfig {
        id: String::new(),
        name: String::new(),
        kind,
        host: String::new(),
        port: kind.default_port(),
        database: String::new(),
        username: String::new(),
        environment: EnvironmentTag::Local,
        color_tag: None,
        read_only: false,
        tls: TlsMode::Prefer,
        options: HashMap::new(),
    };

    if kind == DatabaseKind::Sqlite {
        let path = rest.strip_prefix("//").unwrap_or(rest);
        let (path, _) = path.split_once('?').unwrap_or((path, ""));
        config.host = decode(path);
        config.database = "main".into();
        config.name = file_name(&config.host);
        config.validate()?;
        return Ok(ParsedConnection { config, password: None });
    }

    let rest = rest
        .strip_prefix("//")
        .ok_or_else(|| CoreError::invalid("expected `//` after the scheme"))?;
    let (rest, query) = rest.split_once('?').unwrap_or((rest, ""));
    let (authority, path) = rest.split_once('/').unwrap_or((rest, ""));
    let (userinfo, hosts) = match authority.rsplit_once('@') {
        Some((u, h)) => (Some(u), h),
        None => (None, authority),
    };

    let mut password = None;
    if let Some(userinfo) = userinfo {
        let (user, pass) = userinfo.split_once(':').unwrap_or((userinfo, ""));
        config.username = decode(user);
        if !pass.is_empty() {
            password = Some(decode(pass));
        }
    }

    if kind == DatabaseKind::MongoDb && (hosts.contains(',') || scheme == "mongodb+srv") {
        // Replica-set seed lists and SRV names are kept as written.
        config.host = hosts.to_string();
        if scheme == "mongodb+srv" {
            config.options.insert("srv".into(), "true".into());
        }
    } else {
        let (host, port) = split_host_port(hosts)?;
        config.host = host;
        if let Some(port) = port {
            config.port = port;
        }
    }

    config.database = decode(path.trim_end_matches('/'));
    if kind == DatabaseKind::Redis && config.database.is_empty() {
        config.database = "0".into();
    }
    if scheme == "rediss" {
        config.tls = TlsMode::Require;
    }

    for pair in query.split('&').filter(|p| !p.is_empty()) {
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        let (k, v) = (decode(k), decode(v));
        match k.as_str() {
            "sslmode" | "ssl-mode" | "ssl_mode" => config.tls = parse_tls(&v),
            "tls" | "ssl" => {
                config.tls = if v == "true" { TlsMode::Require } else { TlsMode::Disable }
            }
            _ => {
                config.options.insert(k, v);
            }
        }
    }

    let first_host = config.host.split(',').next().unwrap_or_default().to_string();
    config.name = if config.database.is_empty() || kind == DatabaseKind::Redis {
        first_host
    } else {
        format!("{} @ {first_host}", config.database)
    };
    config.validate()?;
    Ok(ParsedConnection { config, password })
}

fn parse_tls(v: &str) -> TlsMode {
    match v.to_ascii_lowercase().as_str() {
        "disable" | "disabled" | "false" => TlsMode::Disable,
        "require" | "required" | "verify-ca" | "verify-full" | "verify_ca" | "verify_identity" => {
            TlsMode::Require
        }
        _ => TlsMode::Prefer,
    }
}

fn split_host_port(s: &str) -> Result<(String, Option<u16>)> {
    // [::1]:5432
    if let Some(rest) = s.strip_prefix('[') {
        let (host, after) = rest
            .split_once(']')
            .ok_or_else(|| CoreError::invalid("unclosed `[` in host"))?;
        let port = match after.strip_prefix(':') {
            Some(p) => Some(parse_port(p)?),
            None => None,
        };
        return Ok((host.to_string(), port));
    }
    match s.rsplit_once(':') {
        Some((h, p)) => Ok((decode(h), Some(parse_port(p)?))),
        None => Ok((decode(s), None)),
    }
}

fn parse_port(p: &str) -> Result<u16> {
    p.parse().map_err(|_| CoreError::invalid(format!("bad port `{p}`")))
}

fn decode(s: &str) -> String {
    percent_encoding::percent_decode_str(s).decode_utf8_lossy().into_owned()
}

fn file_name(path: &str) -> String {
    std::path::Path::new(path)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(url: &str) -> ParsedConnection {
        parse_connection_url(url.into()).unwrap()
    }

    #[test]
    fn postgres_url() {
        let p = parse("postgres://al%40ice:p%3Ass@db.example.com:6543/app?sslmode=require&application_name=x");
        assert_eq!(p.config.kind, DatabaseKind::Postgres);
        assert_eq!(p.config.username, "al@ice");
        assert_eq!(p.password.as_deref(), Some("p:ss"));
        assert_eq!(p.config.host, "db.example.com");
        assert_eq!(p.config.port, 6543);
        assert_eq!(p.config.database, "app");
        assert_eq!(p.config.tls, TlsMode::Require);
        assert_eq!(p.config.option("application_name"), Some("x"));
        assert_eq!(p.config.name, "app @ db.example.com");
    }

    #[test]
    fn mysql_defaults() {
        let p = parse("mariadb://root@localhost/shop");
        assert_eq!(p.config.kind, DatabaseKind::MySql);
        assert_eq!(p.config.port, 3306);
        assert_eq!(p.password, None);
    }

    #[test]
    fn ipv6_host() {
        let p = parse("postgresql://[::1]:5433/postgres");
        assert_eq!(p.config.host, "::1");
        assert_eq!(p.config.port, 5433);
    }

    #[test]
    fn sqlite_paths() {
        assert_eq!(parse("sqlite:///tmp/app.db").config.host, "/tmp/app.db");
        assert_eq!(parse("sqlite:data/app.db").config.host, "data/app.db");
        assert_eq!(parse("sqlite::memory:").config.host, ":memory:");
        assert_eq!(parse("sqlite:///tmp/app.db").config.name, "app.db");
    }

    #[test]
    fn mongo_seed_list_and_srv() {
        let p = parse("mongodb://u:p@a:27017,b:27018/admin?replicaSet=rs0");
        assert_eq!(p.config.host, "a:27017,b:27018");
        assert_eq!(p.config.option("replicaSet"), Some("rs0"));
        let s = parse("mongodb+srv://u:p@cluster0.example.net/app");
        assert_eq!(s.config.host, "cluster0.example.net");
        assert_eq!(s.config.option("srv"), Some("true"));
    }

    #[test]
    fn redis_db_and_tls() {
        let p = parse("rediss://:secret@cache:6380/2");
        assert_eq!(p.config.kind, DatabaseKind::Redis);
        assert_eq!(p.config.database, "2");
        assert_eq!(p.config.tls, TlsMode::Require);
        assert_eq!(p.password.as_deref(), Some("secret"));
        assert_eq!(parse("redis://localhost").config.database, "0");
    }

    #[test]
    fn rejects_garbage() {
        assert!(parse_connection_url("ftp://x".into()).is_err());
        assert!(parse_connection_url("postgres://h:notaport/db".into()).is_err());
        assert!(parse_connection_url("nothing".into()).is_err());
    }

    #[test]
    fn debug_redacts_password() {
        let p = parse("postgres://u:hunter2@h/db");
        let shown = format!("{p:?}");
        assert!(!shown.contains("hunter2"));
        assert!(shown.contains("<redacted>"));
    }
}
