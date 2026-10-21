//! Query history: one append-only JSON-lines file per connection.

use std::io::Write;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::error::Result;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct HistoryEntry {
    pub query: String,
    /// Unix time in milliseconds.
    pub executed_at_ms: i64,
    pub duration_ms: u64,
    pub rows: Option<u64>,
    pub succeeded: bool,
}

pub(crate) struct History {
    dir: PathBuf,
}

impl History {
    pub(crate) fn new(dir: PathBuf) -> Self {
        Self { dir }
    }

    fn file(&self, connection_id: &str) -> PathBuf {
        // Ids are UUIDs we generate, but never trust them as path components.
        let safe: String = connection_id
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '-')
            .collect();
        self.dir.join(format!("{safe}.jsonl"))
    }

    pub(crate) fn add(&self, connection_id: &str, entry: &HistoryEntry) -> Result<()> {
        std::fs::create_dir_all(&self.dir)?;
        let mut line = serde_json::to_vec(entry)?;
        line.push(b'\n');
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.file(connection_id))?
            .write_all(&line)?;
        Ok(())
    }

    /// Newest first. Lines that fail to parse are skipped.
    pub(crate) fn list(&self, connection_id: &str, limit: u32) -> Result<Vec<HistoryEntry>> {
        let text = match std::fs::read_to_string(self.file(connection_id)) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e.into()),
        };
        Ok(text
            .lines()
            .rev()
            .filter_map(|l| serde_json::from_str(l).ok())
            .take(limit as usize)
            .collect())
    }

    pub(crate) fn clear(&self, connection_id: &str) -> Result<()> {
        match std::fs::remove_file(self.file(connection_id)) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.into()),
            _ => Ok(()),
        }
    }
}
