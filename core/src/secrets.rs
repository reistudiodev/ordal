//! Passwords live in the OS credential store (Keychain, Windows Credential
//! Manager, libsecret), keyed by connection id. They are never written to the
//! config file and never logged.

use std::collections::HashMap;
use std::sync::Mutex;

use crate::error::{CoreError, Result};

const SERVICE: &str = "dbclient";

pub(crate) trait SecretStore: Send + Sync {
    fn get(&self, id: &str) -> Result<Option<String>>;
    fn set(&self, id: &str, secret: &str) -> Result<()>;
    fn delete(&self, id: &str) -> Result<()>;
}

/// The real OS credential store.
pub(crate) struct Keychain;

fn keychain_error(e: keyring::Error) -> CoreError {
    CoreError::Secret { message: e.to_string() }
}

impl SecretStore for Keychain {
    fn get(&self, id: &str) -> Result<Option<String>> {
        let entry = keyring::Entry::new(SERVICE, id).map_err(keychain_error)?;
        match entry.get_password() {
            Ok(p) => Ok(Some(p)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(keychain_error(e)),
        }
    }

    fn set(&self, id: &str, secret: &str) -> Result<()> {
        let entry = keyring::Entry::new(SERVICE, id).map_err(keychain_error)?;
        entry.set_password(secret).map_err(keychain_error)
    }

    fn delete(&self, id: &str) -> Result<()> {
        let entry = keyring::Entry::new(SERVICE, id).map_err(keychain_error)?;
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(keychain_error(e)),
        }
    }
}

/// In-process store for tests and throwaway sessions.
#[derive(Default)]
pub(crate) struct MemorySecrets(Mutex<HashMap<String, String>>);

impl SecretStore for MemorySecrets {
    fn get(&self, id: &str) -> Result<Option<String>> {
        Ok(self.0.lock().unwrap().get(id).cloned())
    }

    fn set(&self, id: &str, secret: &str) -> Result<()> {
        self.0.lock().unwrap().insert(id.to_string(), secret.to_string());
        Ok(())
    }

    fn delete(&self, id: &str) -> Result<()> {
        self.0.lock().unwrap().remove(id);
        Ok(())
    }
}
