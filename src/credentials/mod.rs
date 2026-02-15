//! Secure credential storage and management.
//!
//! This module provides a platform-agnostic interface for storing and retrieving
//! sensitive credentials (API keys, tokens, passwords) with platform-specific
//! backends:
//!
//! - **macOS**: Keychain Services (encrypted, OS-managed)
//! - **Other platforms**: Encrypted storage via `keyring` crate
//!
//! ## Usage
//!
//! ```no_run
//! use fae::credentials::{CredentialManager, CredentialRef};
//!
//! # fn example() -> Result<(), Box<dyn std::error::Error>> {
//! let manager = fae::credentials::create_manager();
//! let cred_ref = manager.store("llm.api_key", "sk-...")?;
//!
//! // Later, retrieve the credential
//! if let Some(value) = manager.retrieve(&cred_ref)? {
//!     println!("Retrieved: {}", value);
//! }
//! # Ok(())
//! # }
//! ```

#[cfg(target_os = "macos")]
mod keychain;
mod types;

pub use types::{CredentialError, CredentialRef};

/// Manages secure storage and retrieval of credentials.
///
/// Implementations are platform-specific but provide a consistent interface
/// for credential lifecycle operations.
pub trait CredentialManager {
    /// Store a credential securely and return a reference to it.
    ///
    /// # Arguments
    ///
    /// * `account` - Unique identifier for this credential (e.g., "llm.api_key")
    /// * `value` - The secret value to store
    ///
    /// # Returns
    ///
    /// A `CredentialRef` that can be used to retrieve the credential later.
    ///
    /// # Errors
    ///
    /// Returns `CredentialError::StorageError` if the platform storage fails.
    fn store(&self, account: &str, value: &str) -> Result<CredentialRef, CredentialError>;

    /// Retrieve a credential's value using its reference.
    ///
    /// # Arguments
    ///
    /// * `cred_ref` - Reference to the credential (from `store()`)
    ///
    /// # Returns
    ///
    /// - `Ok(Some(value))` if the credential exists
    /// - `Ok(None)` if the credential reference is `CredentialRef::None`
    /// - `Ok(Some(value))` if the reference is `CredentialRef::Plaintext` (returns the plaintext)
    ///
    /// # Errors
    ///
    /// Returns `CredentialError::NotFound` if a keychain reference points to a non-existent entry.
    /// Returns `CredentialError::KeychainAccess` if platform storage access fails.
    fn retrieve(&self, cred_ref: &CredentialRef) -> Result<Option<String>, CredentialError>;

    /// Delete a credential from secure storage.
    ///
    /// # Arguments
    ///
    /// * `cred_ref` - Reference to the credential to delete
    ///
    /// # Returns
    ///
    /// `Ok(())` if the credential was deleted or didn't exist.
    ///
    /// # Errors
    ///
    /// Returns `CredentialError::KeychainAccess` if platform storage access fails.
    fn delete(&self, cred_ref: &CredentialRef) -> Result<(), CredentialError>;
}

/// Stub credential manager for non-macOS platforms.
///
/// This will be replaced with encrypted storage in Task 3.
#[cfg(not(target_os = "macos"))]
struct StubCredentialManager;

#[cfg(not(target_os = "macos"))]
impl CredentialManager for StubCredentialManager {
    fn store(&self, _account: &str, _value: &str) -> Result<CredentialRef, CredentialError> {
        Err(CredentialError::StorageError(
            "Encrypted credential storage not yet implemented for this platform".to_owned(),
        ))
    }

    fn retrieve(&self, cred_ref: &CredentialRef) -> Result<Option<String>, CredentialError> {
        match cred_ref {
            CredentialRef::None => Ok(None),
            CredentialRef::Plaintext(value) => Ok(Some(value.clone())),
            CredentialRef::Keychain { .. } => Err(CredentialError::StorageError(
                "Encrypted credential storage not yet implemented for this platform".to_owned(),
            )),
        }
    }

    fn delete(&self, _cred_ref: &CredentialRef) -> Result<(), CredentialError> {
        Err(CredentialError::StorageError(
            "Encrypted credential storage not yet implemented for this platform".to_owned(),
        ))
    }
}

/// Create a platform-appropriate credential manager.
///
/// - **macOS**: Returns a Keychain Services-backed manager
/// - **Other platforms**: Returns an encrypted storage manager (Task 3)
///
/// # Example
///
/// ```no_run
/// let manager = fae::credentials::create_manager();
/// ```
#[must_use]
pub fn create_manager() -> Box<dyn CredentialManager> {
    #[cfg(target_os = "macos")]
    {
        Box::new(keychain::KeychainCredentialManager::new())
    }

    #[cfg(not(target_os = "macos"))]
    {
        Box::new(StubCredentialManager)
    }
}
