//! Core types for credential management.

use serde::{Deserialize, Serialize};

/// Reference to a stored credential.
///
/// This enum represents different storage strategies for credentials:
/// - `Keychain`: Stored in platform keychain (macOS Keychain, Windows Credential Manager, etc.)
/// - `Plaintext`: Legacy plaintext storage (for migration compatibility)
/// - `None`: No credential configured
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(untagged)]
pub enum CredentialRef {
    /// Credential stored in platform keychain.
    Keychain {
        /// Service name (e.g., "com.saorsalabs.fae")
        service: String,
        /// Account identifier (e.g., "llm.api_key", "discord.bot_token")
        account: String,
    },
    /// Plaintext credential value (legacy, for migration).
    ///
    /// This variant exists to support migration from old configs that stored
    /// credentials as plain strings. New code should never create this variant.
    /// Serialized as a plain string for backward compatibility.
    Plaintext(String),
    /// No credential configured.
    /// Serialized as `null`.
    #[default]
    None,
}

impl CredentialRef {
    /// Check if this reference points to an actual credential.
    ///
    /// Returns `false` for `CredentialRef::None`, `true` otherwise.
    #[must_use]
    pub fn is_set(&self) -> bool {
        !matches!(self, CredentialRef::None)
    }

    /// Check if this is a plaintext credential (needs migration).
    #[must_use]
    pub fn is_plaintext(&self) -> bool {
        matches!(self, CredentialRef::Plaintext(_))
    }

    /// Check if this is a keychain reference.
    #[must_use]
    pub fn is_keychain(&self) -> bool {
        matches!(self, CredentialRef::Keychain { .. })
    }
}

/// Errors that can occur during credential operations.
#[derive(Debug, thiserror::Error)]
pub enum CredentialError {
    /// Platform keychain access failed.
    #[error("Keychain access error: {0}")]
    KeychainAccess(String),

    /// Credential not found in storage.
    #[error("Credential not found")]
    NotFound,

    /// Invalid credential reference (malformed or corrupted).
    #[error("Invalid credential reference: {0}")]
    InvalidReference(String),

    /// Generic storage error.
    #[error("Storage error: {0}")]
    StorageError(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn credential_ref_serde_keychain() {
        let cred_ref = CredentialRef::Keychain {
            service: "com.saorsalabs.fae".to_owned(),
            account: "llm.api_key".to_owned(),
        };

        let serialized = serde_json::to_string(&cred_ref).expect("serialization failed");
        let deserialized: CredentialRef =
            serde_json::from_str(&serialized).expect("deserialization failed");

        assert_eq!(cred_ref, deserialized);
    }

    #[test]
    fn credential_ref_serde_plaintext() {
        let cred_ref = CredentialRef::Plaintext("sk-test-key".to_owned());

        let serialized = serde_json::to_string(&cred_ref).expect("serialization failed");
        let deserialized: CredentialRef =
            serde_json::from_str(&serialized).expect("deserialization failed");

        assert_eq!(cred_ref, deserialized);
    }

    #[test]
    fn credential_ref_serde_none() {
        let cred_ref = CredentialRef::None;

        let serialized = serde_json::to_string(&cred_ref).expect("serialization failed");
        let deserialized: CredentialRef =
            serde_json::from_str(&serialized).expect("deserialization failed");

        assert_eq!(cred_ref, deserialized);
    }

    #[test]
    fn credential_ref_is_set() {
        assert!(!CredentialRef::None.is_set());
        assert!(CredentialRef::Plaintext("key".to_owned()).is_set());
        assert!(
            CredentialRef::Keychain {
                service: "svc".to_owned(),
                account: "acc".to_owned()
            }
            .is_set()
        );
    }

    #[test]
    fn credential_ref_is_plaintext() {
        assert!(!CredentialRef::None.is_plaintext());
        assert!(CredentialRef::Plaintext("key".to_owned()).is_plaintext());
        assert!(
            !CredentialRef::Keychain {
                service: "svc".to_owned(),
                account: "acc".to_owned()
            }
            .is_plaintext()
        );
    }

    #[test]
    fn credential_ref_is_keychain() {
        assert!(!CredentialRef::None.is_keychain());
        assert!(!CredentialRef::Plaintext("key".to_owned()).is_keychain());
        assert!(
            CredentialRef::Keychain {
                service: "svc".to_owned(),
                account: "acc".to_owned()
            }
            .is_keychain()
        );
    }

    #[test]
    fn credential_ref_default() {
        assert_eq!(CredentialRef::default(), CredentialRef::None);
    }
}
