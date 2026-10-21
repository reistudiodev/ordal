//! dbclient-core: everything that is not UI lives here.
//!
//! The Swift apps on macOS, Windows and Linux talk to this crate only through
//! the UniFFI-generated bindings, so anything marked `#[uniffi::export]`
//! (or deriving a `uniffi::` type) is the public API of the app's brain.
//!
//! Layout: `manager` (saved connections, keychain, history) opens a
//! `session::Session`, which wraps one `drivers::Driver`. Queries stream
//! through `session::QueryCursor` in pages of `value::Row`.

uniffi::setup_scaffolding!();

mod config;
mod drivers;
mod error;
mod history;
mod manager;
mod runtime;
mod secrets;
mod session;
mod sql;
mod store;
mod value;

pub use config::{parse_connection_url, ConnectionConfig, DatabaseKind, EnvironmentTag, ParsedConnection, TlsMode};
pub use drivers::{BrowseNode, KeyInfo, NodeKind, ServerInfo};
pub use error::CoreError;
pub use history::HistoryEntry;
pub use manager::ConnectionManager;
pub use session::{QueryCursor, Session};
pub use sql::{classify_statement, StatementKind};
pub use value::{ColumnInfo, Page, Row, RowCount, Value, ValueKind, Window};

/// Version of the core library, handy for an About screen.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> ConnectionConfig {
        parse_connection_url("postgres://postgres@localhost:5432/postgres".into()).unwrap().config
    }

    fn manager() -> (tempfile::TempDir, std::sync::Arc<ConnectionManager>) {
        let dir = tempfile::tempdir().unwrap();
        let m = ConnectionManager::with_directory(dir.path().to_string_lossy().into(), false).unwrap();
        (dir, m)
    }

    #[test]
    fn save_assigns_id_and_persists() {
        let (dir, m) = manager();
        let saved = m.save(sample(), Some("pw".into())).unwrap();
        assert!(!saved.id.is_empty());
        assert_eq!(m.list(), vec![saved.clone()]);
        assert!(m.has_password(saved.id.clone()).unwrap());

        // A second manager over the same directory sees the connection.
        let again = ConnectionManager::with_directory(dir.path().to_string_lossy().into(), false).unwrap();
        assert_eq!(again.list(), vec![saved.clone()]);

        let file = std::fs::read_to_string(dir.path().join("connections.json")).unwrap();
        assert!(!file.contains("pw\""), "password must not reach the config file");
    }

    #[test]
    fn save_updates_in_place() {
        let (_dir, m) = manager();
        let mut saved = m.save(sample(), None).unwrap();
        saved.name = "renamed".into();
        m.save(saved.clone(), None).unwrap();
        assert_eq!(m.list(), vec![saved]);
    }

    #[test]
    fn rejects_empty_name() {
        let (_dir, m) = manager();
        let config = ConnectionConfig { name: " ".into(), ..sample() };
        assert!(matches!(m.save(config, None), Err(CoreError::InvalidConfig { .. })));
    }

    #[test]
    fn delete_removes_password_and_history() {
        let (_dir, m) = manager();
        let saved = m.save(sample(), Some("pw".into())).unwrap();
        let entry = HistoryEntry {
            query: "select 1".into(),
            executed_at_ms: 1,
            duration_ms: 2,
            rows: Some(1),
            succeeded: true,
        };
        m.add_history(saved.id.clone(), entry.clone()).unwrap();
        assert_eq!(m.history(saved.id.clone(), 10).unwrap(), vec![entry]);
        m.delete(saved.id.clone()).unwrap();
        assert!(m.list().is_empty());
        assert!(!m.has_password(saved.id.clone()).unwrap());
        assert!(m.history(saved.id, 10).unwrap().is_empty());
    }
}
