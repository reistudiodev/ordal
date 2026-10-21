//! Saved connections, persisted as `connections.json` in the app's config dir.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::config::ConnectionConfig;
use crate::error::{CoreError, Result};

pub(crate) struct ConnectionStore {
    path: PathBuf,
    items: Mutex<Vec<ConnectionConfig>>,
}

impl ConnectionStore {
    /// Loads `dir/connections.json`, or starts empty if it does not exist yet.
    pub(crate) fn open(dir: &Path) -> Result<Self> {
        let path = dir.join("connections.json");
        let items = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|e| CoreError::internal(format!("{} is damaged: {e}", path.display())))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(e.into()),
        };
        Ok(Self { path, items: Mutex::new(items) })
    }

    pub(crate) fn list(&self) -> Vec<ConnectionConfig> {
        self.items.lock().unwrap().clone()
    }

    pub(crate) fn get(&self, id: &str) -> Option<ConnectionConfig> {
        self.items.lock().unwrap().iter().find(|c| c.id == id).cloned()
    }

    /// Inserts or replaces by id, then writes the file.
    pub(crate) fn upsert(&self, config: ConnectionConfig) -> Result<()> {
        let mut items = self.items.lock().unwrap();
        match items.iter_mut().find(|c| c.id == config.id) {
            Some(existing) => *existing = config,
            None => items.push(config),
        }
        self.write(&items)
    }

    pub(crate) fn remove(&self, id: &str) -> Result<bool> {
        let mut items = self.items.lock().unwrap();
        let before = items.len();
        items.retain(|c| c.id != id);
        let removed = items.len() != before;
        if removed {
            self.write(&items)?;
        }
        Ok(removed)
    }

    /// Writes to a temp file and renames it, so a crash never leaves half a file.
    fn write(&self, items: &[ConnectionConfig]) -> Result<()> {
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = self.path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(items)?)?;
        std::fs::rename(&tmp, &self.path)?;
        Ok(())
    }
}
