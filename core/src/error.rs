//! The core's single error type. Every driver error is mapped into it with a
//! message a user can act on. Messages never contain URLs or passwords.

#[derive(Debug, Clone, PartialEq, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("not implemented yet: {message}")]
    NotImplemented { message: String },
    #[error("invalid configuration: {message}")]
    InvalidConfig { message: String },
    #[error("could not connect: {message}")]
    Connection { message: String },
    #[error("authentication failed: {message}")]
    Auth { message: String },
    #[error("{message}")]
    Query { message: String, position: Option<u32> },
    #[error("query cancelled")]
    Cancelled,
    #[error("timed out: {message}")]
    Timeout { message: String },
    #[error("credential store: {message}")]
    Secret { message: String },
    #[error("not supported: {message}")]
    Unsupported { message: String },
    #[error("not found: {message}")]
    NotFound { message: String },
    #[error("blocked: {message}")]
    ReadOnly { message: String },
    #[error("internal error: {message}")]
    Internal { message: String },
}

impl CoreError {
    pub(crate) fn invalid(message: impl Into<String>) -> Self {
        Self::InvalidConfig { message: message.into() }
    }
    pub(crate) fn connection(message: impl Into<String>) -> Self {
        Self::Connection { message: message.into() }
    }
    pub(crate) fn query(message: impl Into<String>) -> Self {
        Self::Query { message: message.into(), position: None }
    }
    pub(crate) fn unsupported(message: impl Into<String>) -> Self {
        Self::Unsupported { message: message.into() }
    }
    pub(crate) fn not_found(message: impl Into<String>) -> Self {
        Self::NotFound { message: message.into() }
    }
    pub(crate) fn internal(message: impl Into<String>) -> Self {
        Self::Internal { message: message.into() }
    }
}

pub type Result<T, E = CoreError> = std::result::Result<T, E>;

impl From<std::io::Error> for CoreError {
    fn from(e: std::io::Error) -> Self {
        Self::internal(e.to_string())
    }
}

impl From<serde_json::Error> for CoreError {
    fn from(e: serde_json::Error) -> Self {
        Self::internal(format!("bad JSON: {e}"))
    }
}

#[cfg(any(feature = "postgres", feature = "mysql", feature = "sqlite"))]
impl From<sqlx::Error> for CoreError {
    fn from(e: sqlx::Error) -> Self {
        use sqlx::Error as E;
        match e {
            E::Database(db) => {
                // SQLSTATE class 28 (Postgres) and MySQL 1045 / 28000 are auth failures.
                let code = db.code().map(|c| c.into_owned()).unwrap_or_default();
                if code.starts_with("28") || code == "1045" {
                    return Self::Auth { message: db.message().to_string() };
                }
                // 57014 = query_canceled (Postgres), 1317 = ER_QUERY_INTERRUPTED (MySQL).
                if code == "57014" || code == "1317" || code == "70100" {
                    return Self::Cancelled;
                }
                let position = postgres_position(db.as_ref());
                Self::Query { message: db.message().to_string(), position }
            }
            E::Io(io) => Self::connection(io.to_string()),
            E::Tls(t) => Self::connection(format!("TLS: {t}")),
            E::PoolTimedOut => Self::Timeout { message: "no connection became available".into() },
            E::PoolClosed => Self::connection("connection is closed"),
            E::Configuration(c) => Self::invalid(c.to_string()),
            E::RowNotFound => Self::not_found("no rows returned"),
            E::Protocol(p) => Self::connection(format!("protocol error: {p}")),
            other => Self::query(other.to_string()),
        }
    }
}

#[cfg(any(feature = "postgres", feature = "mysql", feature = "sqlite"))]
fn postgres_position(_db: &dyn sqlx::error::DatabaseError) -> Option<u32> {
    #[cfg(feature = "postgres")]
    if let Some(pg) = _db.try_downcast_ref::<sqlx::postgres::PgDatabaseError>() {
        return match pg.position() {
            Some(sqlx::postgres::PgErrorPosition::Original(p)) => u32::try_from(p).ok(),
            _ => None,
        };
    }
    None
}

#[cfg(feature = "mongodb")]
impl From<mongodb::error::Error> for CoreError {
    fn from(e: mongodb::error::Error) -> Self {
        use mongodb::error::ErrorKind as K;
        match e.kind.as_ref() {
            K::Authentication { message, .. } => Self::Auth { message: message.clone() },
            K::ServerSelection { message, .. } => Self::connection(message.clone()),
            K::Io(io) => Self::connection(io.to_string()),
            K::DnsResolve { message, .. } => Self::connection(message.clone()),
            K::InvalidArgument { message, .. } => Self::query(message.clone()),
            K::Command(c) => Self::query(format!("{} ({})", c.message, c.code_name)),
            _ => Self::query(e.to_string()),
        }
    }
}

#[cfg(feature = "redis")]
impl From<redis::RedisError> for CoreError {
    fn from(e: redis::RedisError) -> Self {
        use redis::ErrorKind as K;
        match e.kind() {
            K::AuthenticationFailed => Self::Auth { message: e.to_string() },
            K::IoError => Self::connection(e.to_string()),
            K::InvalidClientConfig => Self::invalid(e.to_string()),
            _ => Self::query(e.to_string()),
        }
    }
}
