//! Saved connections, credentials, history, and opening sessions.

use std::path::PathBuf;
use std::sync::Arc;

use crate::config::ConnectionConfig;
use crate::drivers::{self, ServerInfo};
use crate::error::{CoreError, Result};
use crate::history::{History, HistoryEntry};
use crate::runtime::run;
use crate::secrets::{Keychain, MemorySecrets, SecretStore};
use crate::session::Session;
use crate::store::ConnectionStore;

#[derive(uniffi::Object)]
pub struct ConnectionManager {
    store: ConnectionStore,
    secrets: Arc<dyn SecretStore>,
    history: History,
}

impl ConnectionManager {
    fn build(config_dir: PathBuf, data_dir: PathBuf, secrets: Arc<dyn SecretStore>) -> Result<Arc<Self>> {
        Ok(Arc::new(Self {
            store: ConnectionStore::open(&config_dir)?,
            secrets,
            history: History::new(data_dir.join("history")),
        }))
    }

    /// The saved password, unless one was passed in explicitly.
    fn password_for(&self, config: &ConnectionConfig, given: Option<String>) -> Result<Option<String>> {
        match given {
            Some(p) => Ok(Some(p)),
            None if config.id.is_empty() => Ok(None),
            None => self.secrets.get(&config.id),
        }
    }
}

#[uniffi::export]
impl ConnectionManager {
    /// Uses the platform's config/data directories and the OS keychain.
    #[uniffi::constructor]
    pub fn new() -> Result<Arc<Self>> {
        let dirs = directories::ProjectDirs::from("dev", "dbclient", "dbclient")
            .ok_or_else(|| CoreError::internal("no home directory"))?;
        Self::build(dirs.config_dir().to_path_buf(), dirs.data_dir().to_path_buf(), Arc::new(Keychain))
    }

    /// Keeps everything under `dir`. With `use_keychain` false, passwords are
    /// held in memory only (tests, throwaway sessions).
    #[uniffi::constructor]
    pub fn with_directory(dir: String, use_keychain: bool) -> Result<Arc<Self>> {
        let dir = PathBuf::from(dir);
        let secrets: Arc<dyn SecretStore> =
            if use_keychain { Arc::new(Keychain) } else { Arc::new(MemorySecrets::default()) };
        Self::build(dir.clone(), dir, secrets)
    }

    pub fn list(&self) -> Vec<ConnectionConfig> {
        self.store.list()
    }

    pub fn get(&self, id: String) -> Option<ConnectionConfig> {
        self.store.get(&id)
    }

    /// Saves (or updates) a connection and returns it with its id.
    /// `password`: `None` keeps the stored one, `Some("")` removes it.
    pub fn save(&self, config: ConnectionConfig, password: Option<String>) -> Result<ConnectionConfig> {
        config.validate()?;
        let mut config = config;
        if config.id.is_empty() {
            config.id = uuid::Uuid::new_v4().to_string();
        }
        match password.as_deref() {
            Some("") => self.secrets.delete(&config.id)?,
            Some(p) => self.secrets.set(&config.id, p)?,
            None => {}
        }
        self.store.upsert(config.clone())?;
        Ok(config)
    }

    pub fn has_password(&self, id: String) -> Result<bool> {
        Ok(self.secrets.get(&id)?.is_some())
    }

    /// Removes the connection, its password and its history.
    pub fn delete(&self, id: String) -> Result<()> {
        if !self.store.remove(&id)? {
            return Err(CoreError::not_found("connection"));
        }
        self.secrets.delete(&id)?;
        self.history.clear(&id)
    }

    /// Connects, reads the server version and disconnects.
    /// `password: None` uses the saved one for an already-saved config.
    pub async fn test(&self, config: ConnectionConfig, password: Option<String>) -> Result<ServerInfo> {
        let password = self.password_for(&config, password)?;
        run(async move {
            let driver = drivers::connect(&config, password).await?;
            let info = driver.server_info().await;
            driver.close().await;
            info
        })
        .await
    }

    pub async fn open(&self, id: String) -> Result<Arc<Session>> {
        let config = self.store.get(&id).ok_or_else(|| CoreError::not_found("connection"))?;
        let password = self.password_for(&config, None)?;
        run(async move {
            let driver = drivers::connect(&config, password).await?;
            Ok(Arc::new(Session::new(config, driver)))
        })
        .await
    }

    /// Newest first.
    pub fn history(&self, id: String, limit: u32) -> Result<Vec<HistoryEntry>> {
        self.history.list(&id, limit)
    }

    pub fn add_history(&self, id: String, entry: HistoryEntry) -> Result<()> {
        self.history.add(&id, &entry)
    }
}
