//! macOS Keychain Services credential backend.
//!
//! Uses the Security framework to store credentials in the macOS Keychain,
//! which provides encrypted storage with OS-level access control.

use super::{CredentialError, CredentialManager, CredentialRef};

/// Service name for all Fae credentials in the keychain.
const SERVICE_NAME: &str = "com.saorsalabs.fae";

/// Credential manager using macOS Keychain Services.
pub struct KeychainCredentialManager;

impl KeychainCredentialManager {
    /// Create a new Keychain credential manager.
    #[must_use]
    pub fn new() -> Self {
        Self
    }
}

impl Default for KeychainCredentialManager {
    fn default() -> Self {
        Self::new()
    }
}

impl CredentialManager for KeychainCredentialManager {
    fn store(&self, account: &str, value: &str) -> Result<CredentialRef, CredentialError> {
        security_framework::passwords::set_generic_password(
            SERVICE_NAME,
            account,
            value.as_bytes(),
        )
        .map_err(|e| CredentialError::KeychainAccess(format!("Failed to store credential: {e}")))?;

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
                match security_framework::passwords::get_generic_password(service, account) {
                    Ok(data) => {
                        let value = String::from_utf8(data).map_err(|e| {
                            CredentialError::InvalidReference(format!(
                                "Credential contains invalid UTF-8: {e}"
                            ))
                        })?;
                        Ok(Some(value))
                    }
                    Err(e) => {
                        // Check if this is a "not found" error vs other keychain errors
                        let err_str = format!("{e:?}");
                        if err_str.contains("errSecItemNotFound") || err_str.contains("-25300") {
                            Err(CredentialError::NotFound)
                        } else {
                            Err(CredentialError::KeychainAccess(format!(
                                "Failed to retrieve credential: {e}"
                            )))
                        }
                    }
                }
            }
        }
    }

    fn delete(&self, cred_ref: &CredentialRef) -> Result<(), CredentialError> {
        match cred_ref {
            CredentialRef::None | CredentialRef::Plaintext(_) => {
                // Nothing to delete from keychain
                Ok(())
            }
            CredentialRef::Keychain { service, account } => {
                match security_framework::passwords::delete_generic_password(service, account) {
                    Ok(()) => Ok(()),
                    Err(e) => {
                        // Deleting a non-existent item is not an error (idempotent delete)
                        let err_str = format!("{e:?}");
                        if err_str.contains("errSecItemNotFound") || err_str.contains("-25300") {
                            return Ok(()); // Idempotent: already deleted
                        }
                        Err(CredentialError::KeychainAccess(format!(
                            "Failed to delete credential: {e}"
                        )))
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_ACCOUNT: &str = "fae.test.credential";

    /// Helper to clean up test credential.
    fn cleanup_test_credential() {
        let manager = KeychainCredentialManager::new();
        let cred_ref = CredentialRef::Keychain {
            service: SERVICE_NAME.to_owned(),
            account: TEST_ACCOUNT.to_owned(),
        };
        let _ = manager.delete(&cred_ref);
    }

    #[test]
    #[ignore] // Requires macOS Keychain access, run manually
    fn test_store_retrieve_delete() {
        cleanup_test_credential();

        let manager = KeychainCredentialManager::new();
        let test_value = "test-secret-value-12345";

        // Store
        let cred_ref = manager
            .store(TEST_ACCOUNT, test_value)
            .expect("Failed to store credential");

        assert!(matches!(cred_ref, CredentialRef::Keychain { .. }));

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

        cleanup_test_credential();
    }

    #[test]
    fn test_retrieve_none() {
        let manager = KeychainCredentialManager::new();
        let result = manager
            .retrieve(&CredentialRef::None)
            .expect("Failed to retrieve None");
        assert_eq!(result, None);
    }

    #[test]
    fn test_retrieve_plaintext() {
        let manager = KeychainCredentialManager::new();
        let value = "plaintext-value";
        let result = manager
            .retrieve(&CredentialRef::Plaintext(value.to_owned()))
            .expect("Failed to retrieve plaintext");
        assert_eq!(result, Some(value.to_owned()));
    }

    #[test]
    fn test_delete_none() {
        let manager = KeychainCredentialManager::new();
        manager
            .delete(&CredentialRef::None)
            .expect("Failed to delete None");
    }

    #[test]
    fn test_delete_plaintext() {
        let manager = KeychainCredentialManager::new();
        manager
            .delete(&CredentialRef::Plaintext("test".to_owned()))
            .expect("Failed to delete plaintext");
    }
}
