//! Cross-platform encrypted credential storage.
//!
//! Uses the `keyring` crate which provides OS-appropriate secure storage:
//! - **Linux**: Secret Service API (GNOME Keyring, KWallet)
//! - **Windows**: Windows Credential Manager
//! - **Other**: Encrypted file-based storage

use super::{CredentialError, CredentialManager, CredentialRef};

/// Service name for all Fae credentials in the platform credential store.
const SERVICE_NAME: &str = "fae-credentials";

/// Credential manager using platform-specific encrypted storage via `keyring`.
pub struct EncryptedCredentialManager;

impl EncryptedCredentialManager {
    /// Create a new encrypted credential manager.
    #[must_use]
    pub fn new() -> Self {
        Self
    }
}

impl Default for EncryptedCredentialManager {
    fn default() -> Self {
        Self::new()
    }
}

impl CredentialManager for EncryptedCredentialManager {
    fn store(&self, account: &str, value: &str) -> Result<CredentialRef, CredentialError> {
        let entry = keyring::Entry::new(SERVICE_NAME, account).map_err(|e| {
            CredentialError::StorageError(format!("Failed to create keyring entry: {e}"))
        })?;

        entry.set_password(value).map_err(|e| {
            CredentialError::StorageError(format!("Failed to store credential: {e}"))
        })?;

        Ok(CredentialRef::Keychain {
            service: SERVICE_NAME.to_owned(),
            account: account.to_owned(),
        })
    }

    fn retrieve(&self, cred_ref: &CredentialRef) -> Result<Option<String>, CredentialError> {
        match cred_ref {
            CredentialRef::None => Ok(None),
            CredentialRef::Plaintext(value) => Ok(Some(value.clone())),
            CredentialRef::Keychain { service, account } => {
                let entry = keyring::Entry::new(service, account).map_err(|e| {
                    CredentialError::StorageError(format!("Failed to create keyring entry: {e}"))
                })?;

                match entry.get_password() {
                    Ok(password) => Ok(Some(password)),
                    Err(keyring::Error::NoEntry) => Err(CredentialError::NotFound),
                    Err(e) => Err(CredentialError::StorageError(format!(
                        "Failed to retrieve credential: {e}"
                    ))),
                }
            }
        }
    }

    fn delete(&self, cred_ref: &CredentialRef) -> Result<(), CredentialError> {
        match cred_ref {
            CredentialRef::None | CredentialRef::Plaintext(_) => {
                // Nothing to delete from encrypted storage
                Ok(())
            }
            CredentialRef::Keychain { service, account } => {
                let entry = keyring::Entry::new(service, account).map_err(|e| {
                    CredentialError::StorageError(format!("Failed to create keyring entry: {e}"))
                })?;

                match entry.delete_credential() {
                    Ok(()) => Ok(()),
                    Err(keyring::Error::NoEntry) => Ok(()), // Idempotent: already deleted
                    Err(e) => Err(CredentialError::StorageError(format!(
                        "Failed to delete credential: {e}"
                    ))),
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_create_manager() {
        let _manager = EncryptedCredentialManager::new();
        // Manager creation should not fail
    }

    #[test]
    fn test_retrieve_none() {
        let manager = EncryptedCredentialManager::new();
        let result = manager
            .retrieve(&CredentialRef::None)
            .expect("Failed to retrieve None");
        assert_eq!(result, None);
    }

    #[test]
    fn test_retrieve_plaintext() {
        let manager = EncryptedCredentialManager::new();
        let value = "plaintext-value";
        let result = manager
            .retrieve(&CredentialRef::Plaintext(value.to_owned()))
            .expect("Failed to retrieve plaintext");
        assert_eq!(result, Some(value.to_owned()));
    }

    #[test]
    fn test_delete_none() {
        let manager = EncryptedCredentialManager::new();
        manager
            .delete(&CredentialRef::None)
            .expect("Failed to delete None");
    }

    #[test]
    fn test_delete_plaintext() {
        let manager = EncryptedCredentialManager::new();
        manager
            .delete(&CredentialRef::Plaintext("test".to_owned()))
            .expect("Failed to delete plaintext");
    }

    // Integration test for actual storage - marked #[ignore] as it requires
    // platform credential store access and can interfere with real credentials.
    #[test]
    #[ignore]
    fn test_store_retrieve_delete_integration() {
        let manager = EncryptedCredentialManager::new();
        let test_account = "fae.test.encrypted.credential";
        let test_value = "test-secret-12345";

        // Clean up any existing test credential
        let cleanup_ref = CredentialRef::Keychain {
            service: SERVICE_NAME.to_owned(),
            account: test_account.to_owned(),
        };
        let _ = manager.delete(&cleanup_ref);

        // Store
        let cred_ref = manager
            .store(test_account, test_value)
            .expect("Failed to store credential");

        // Retrieve
        let retrieved = manager
            .retrieve(&cred_ref)
            .expect("Failed to retrieve credential");
        assert_eq!(retrieved, Some(test_value.to_owned()));

        // Delete
        manager
            .delete(&cred_ref)
            .expect("Failed to delete credential");

        // Verify deleted
        let result = manager.retrieve(&cred_ref);
        assert!(matches!(result, Err(CredentialError::NotFound)));
    }
}
