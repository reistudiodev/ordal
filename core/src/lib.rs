//! dbclient-core: everything that is not UI lives here.
//!
//! The Swift apps on macOS, Windows and Linux talk to this crate only through
//! the UniFFI-generated bindings, so anything marked `#[uniffi::export]`
//! (or deriving a `uniffi::` type) is the public API of the app's brain.

use std::sync::Mutex;

uniffi::setup_scaffolding!();

/// Database engines the client will support. Drivers come later.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DatabaseKind {
    Postgres,
    MySql,
    Sqlite,
}

/// Everything needed to open a connection.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ConnectionConfig {
    pub name: String,
    pub kind: DatabaseKind,
    pub host: String,
    pub port: u16,
    pub database: String,
    pub username: String,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("not implemented yet: {0}")]
    NotImplemented(String),
    #[error("invalid configuration: {0}")]
    InvalidConfig(String),
}

/// Version of the core library, handy for an About screen.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Smoke test for the bindings: the UI calls this on launch.
#[uniffi::export]
pub fn greet(name: String) -> String {
    format!("Hello {name}, the Rust core is alive.")
}

/// Holds the saved connections. Placeholder for the real connection manager.
#[derive(uniffi::Object, Default)]
pub struct ConnectionManager {
    connections: Mutex<Vec<ConnectionConfig>>,
}

#[uniffi::export]
impl ConnectionManager {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn add(&self, config: ConnectionConfig) -> Result<(), CoreError> {
        if config.name.trim().is_empty() {
            return Err(CoreError::InvalidConfig("name is empty".into()));
        }
        self.connections.lock().unwrap().push(config);
        Ok(())
    }

    pub fn list(&self) -> Vec<ConnectionConfig> {
        self.connections.lock().unwrap().clone()
    }

    pub fn test_connection(&self, _config: ConnectionConfig) -> Result<(), CoreError> {
        Err(CoreError::NotImplemented("database drivers".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> ConnectionConfig {
        ConnectionConfig {
            name: "local".into(),
            kind: DatabaseKind::Postgres,
            host: "localhost".into(),
            port: 5432,
            database: "postgres".into(),
            username: "postgres".into(),
        }
    }

    #[test]
    fn add_and_list() {
        let manager = ConnectionManager::new();
        manager.add(sample()).unwrap();
        assert_eq!(manager.list(), vec![sample()]);
    }

    #[test]
    fn rejects_empty_name() {
        let manager = ConnectionManager::new();
        let config = ConnectionConfig { name: " ".into(), ..sample() };
        assert!(matches!(manager.add(config), Err(CoreError::InvalidConfig(_))));
    }
}
