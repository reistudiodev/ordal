//! One-time move of data saved under the app's old name ("dbclient"):
//! saved connections, query history and keychain passwords.

use std::path::{Path, PathBuf};

use crate::config::ConnectionConfig;
use crate::error::Result;
use crate::secrets::SecretStore;

/// The app's name before it became Ordal.
pub(crate) const LEGACY_NAME: &str = "dbclient";

/// The old config and data directories, if the platform has a home directory.
pub(crate) fn legacy_dirs() -> Option<(PathBuf, PathBuf)> {
    let dirs = directories::ProjectDirs::from("dev", LEGACY_NAME, LEGACY_NAME)?;
    Some((dirs.config_dir().to_path_buf(), dirs.data_dir().to_path_buf()))
}

#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Report {
    pub connections: usize,
    pub passwords: usize,
    pub history_files: usize,
}

/// Copies old connections and history into the new directories and moves
/// passwords to the new keychain service. Runs only while the new location
/// has no connections yet, so it happens once and never overwrites anything.
/// Old files stay where they are; an old password is removed only after the
/// copy was read back successfully.
pub(crate) fn migrate(
    (old_config, old_data): &(PathBuf, PathBuf),
    (new_config, new_data): &(&Path, &Path),
    old_secrets: &dyn SecretStore,
    new_secrets: &dyn SecretStore,
) -> Result<Report> {
    let mut report = Report::default();
    let old_file = old_config.join("connections.json");
    let new_file = new_config.join("connections.json");
    if new_file.exists() || !old_file.exists() || old_config.as_path() == *new_config {
        return Ok(report);
    }

    let bytes = std::fs::read(&old_file)?;
    let configs: Vec<ConnectionConfig> = serde_json::from_slice(&bytes)?;
    std::fs::create_dir_all(new_config)?;
    std::fs::write(&new_file, &bytes)?;
    report.connections = configs.len();

    for c in &configs {
        let Ok(Some(password)) = old_secrets.get(&c.id) else { continue };
        if new_secrets.get(&c.id)?.is_some() {
            continue;
        }
        new_secrets.set(&c.id, &password)?;
        if new_secrets.get(&c.id)?.as_deref() == Some(password.as_str()) {
            let _ = old_secrets.delete(&c.id);
            report.passwords += 1;
        }
    }

    let (old_history, new_history) = (old_data.join("history"), new_data.join("history"));
    if let Ok(entries) = std::fs::read_dir(&old_history) {
        std::fs::create_dir_all(&new_history)?;
        for entry in entries.flatten() {
            let target = new_history.join(entry.file_name());
            if !target.exists() && std::fs::copy(entry.path(), &target).is_ok() {
                report.history_files += 1;
            }
        }
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::parse_connection_url;
    use crate::secrets::MemorySecrets;

    #[test]
    fn moves_connections_history_and_passwords_once() {
        let old = tempfile::tempdir().unwrap();
        let new = tempfile::tempdir().unwrap();
        let mut config = parse_connection_url("postgres://u@h/db".into()).unwrap().config;
        config.id = "c1".into();
        std::fs::write(old.path().join("connections.json"), serde_json::to_vec(&vec![config]).unwrap()).unwrap();
        std::fs::create_dir_all(old.path().join("history")).unwrap();
        std::fs::write(old.path().join("history/c1.jsonl"), "{}\n").unwrap();
        let (old_secrets, new_secrets) = (MemorySecrets::default(), MemorySecrets::default());
        old_secrets.set("c1", "s3cret").unwrap();

        let dirs = (old.path().to_path_buf(), old.path().to_path_buf());
        let target = (new.path(), new.path());
        let report = migrate(&dirs, &target, &old_secrets, &new_secrets).unwrap();
        assert_eq!(report, Report { connections: 1, passwords: 1, history_files: 1 });
        assert_eq!(new_secrets.get("c1").unwrap().as_deref(), Some("s3cret"));
        assert_eq!(old_secrets.get("c1").unwrap(), None, "moved, not duplicated");
        assert!(new.path().join("history/c1.jsonl").exists());
        assert!(old.path().join("connections.json").exists(), "old files are kept");

        // Second launch: the new location has data, so nothing happens.
        old_secrets.set("c1", "other").unwrap();
        assert_eq!(migrate(&dirs, &target, &old_secrets, &new_secrets).unwrap(), Report::default());
        assert_eq!(new_secrets.get("c1").unwrap().as_deref(), Some("s3cret"));
    }

    #[test]
    fn nothing_to_move_is_fine() {
        let old = tempfile::tempdir().unwrap();
        let new = tempfile::tempdir().unwrap();
        let report = migrate(
            &(old.path().to_path_buf(), old.path().to_path_buf()),
            &(new.path(), new.path()),
            &MemorySecrets::default(),
            &MemorySecrets::default(),
        )
        .unwrap();
        assert_eq!(report, Report::default());
        assert!(!new.path().join("connections.json").exists());
    }
}
