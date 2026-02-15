//! Core types for credential management.

use serde::de::{self, Deserializer, MapAccess, Visitor};
use serde::ser::{SerializeMap, Serializer};
use serde::{Deserialize, Serialize};

/// Reference to a stored credential.
///
/// This enum represents different storage strategies for credentials:
/// - `Keychain`: Stored in platform keychain (macOS Keychain, Windows Credential Manager, etc.)
/// - `Plaintext`: Legacy plaintext storage (for migration compatibility)
/// - `None`: No credential configured
///
/// # Serialization
///
/// - `Plaintext("value")` serializes as `"value"` (bare string)
/// - `None` serializes as `""` (empty string, TOML-safe)
/// - `Keychain { service, account }` serializes as `{ service = "...", account = "..." }`
///
/// Deserialization is backward-compatible: a bare string in config is read as
/// `Plaintext` (non-empty) or `None` (empty).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
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
    Plaintext(String),
    /// No credential configured.
    #[default]
    None,
}

impl Serialize for CredentialRef {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            CredentialRef::Plaintext(value) => serializer.serialize_str(value),
            CredentialRef::None => serializer.serialize_str(""),
            CredentialRef::Keychain { service, account } => {
                let mut map = serializer.serialize_map(Some(2))?;
                map.serialize_entry("service", service)?;
                map.serialize_entry("account", account)?;
                map.end()
            }
        }
    }
}

impl<'de> Deserialize<'de> for CredentialRef {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct CredentialRefVisitor;

        impl<'de> Visitor<'de> for CredentialRefVisitor {
            type Value = CredentialRef;

            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("a string or a map with 'service' and 'account' keys")
            }

            fn visit_str<E: de::Error>(self, value: &str) -> Result<CredentialRef, E> {
                if value.is_empty() {
                    Ok(CredentialRef::None)
                } else {
                    Ok(CredentialRef::Plaintext(value.to_owned()))
                }
            }

            fn visit_map<M: MapAccess<'de>>(self, mut map: M) -> Result<CredentialRef, M::Error> {
                let mut service: Option<String> = Option::None;
                let mut account: Option<String> = Option::None;

                while let Some(key) = map.next_key::<String>()? {
                    match key.as_str() {
                        "service" => service = Some(map.next_value()?),
                        "account" => account = Some(map.next_value()?),
                        other => {
                            let _: de::IgnoredAny = map.next_value()?;
                            return Err(de::Error::unknown_field(other, &["service", "account"]));
                        }
                    }
                }

                match (service, account) {
                    (Some(s), Some(a)) => Ok(CredentialRef::Keychain {
                        service: s,
                        account: a,
                    }),
                    _ => Err(de::Error::missing_field("service or account")),
                }
            }
        }

        deserializer.deserialize_any(CredentialRefVisitor)
    }
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

    /// View this credential as a string slice.
    ///
    /// For `Plaintext`, returns the stored value.
    /// For `Keychain` and `None`, returns an empty string.
    ///
    /// Useful in GUI display and format strings where a `&str` is needed.
    #[must_use]
    pub fn as_str(&self) -> &str {
        match self {
            CredentialRef::Plaintext(value) => value.as_str(),
            CredentialRef::Keychain { .. } | CredentialRef::None => "",
        }
    }

    /// Resolve the credential to a string value asynchronously.
    ///
    /// # Arguments
    ///
    /// * `manager` - The credential manager to use for retrieving keychain credentials
    ///
    /// # Returns
    ///
    /// - For `Plaintext`: returns the stored value directly
    /// - For `Keychain`: retrieves the value from the credential manager
    /// - For `None`: returns `CredentialError::NotFound`
    ///
    /// # Errors
    ///
    /// Returns `CredentialError::NotFound` if the credential is `None` or not found in storage.
    /// Returns `CredentialError::KeychainAccess` if platform storage access fails.
    pub async fn resolve(
        &self,
        manager: &dyn super::CredentialManager,
    ) -> Result<String, CredentialError> {
        match self {
            CredentialRef::Plaintext(value) => Ok(value.clone()),
            CredentialRef::Keychain { .. } => {
                // Use direct retrieve with the keychain reference
                manager.retrieve(self)?.ok_or(CredentialError::NotFound)
            }
            CredentialRef::None => Err(CredentialError::NotFound),
        }
    }

    /// Resolve the credential to a string value.
    ///
    /// For `Plaintext` variants, returns the stored value.
    /// For `Keychain` and `None` variants, returns an empty string.
    ///
    /// # Deprecated
    ///
    /// This method returns empty strings for keychain references, causing silent
    /// authentication failures. Use `resolve()` with a `CredentialManager` instead.
    ///
    /// This is a transitional method for callers that need a `String`
    /// while the full `CredentialManager::retrieve()` infrastructure
    /// is wired through the runtime. New code should prefer
    /// `CredentialManager::retrieve()` for secure keychain resolution.
    #[deprecated(
        since = "0.3.1",
        note = "Use resolve() with CredentialManager instead - this returns empty strings for keychain refs"
    )]
    #[must_use]
    pub fn resolve_plaintext(&self) -> String {
        match self {
            CredentialRef::Plaintext(value) => value.clone(),
            CredentialRef::Keychain { .. } | CredentialRef::None => String::new(),
        }
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
    fn credential_ref_serde_keychain_json() {
        let cred_ref = CredentialRef::Keychain {
            service: "com.saorsalabs.fae".to_owned(),
            account: "llm.api_key".to_owned(),
        };

        let serialized = serde_json::to_string(&cred_ref);
        assert!(serialized.is_ok());
        let json = match serialized {
            Ok(s) => s,
            Err(_) => unreachable!(),
        };
        let deserialized: Result<CredentialRef, _> = serde_json::from_str(&json);
        assert!(deserialized.is_ok());
        assert_eq!(cred_ref, deserialized.unwrap_or_default());
    }

    #[test]
    fn credential_ref_serde_plaintext_json() {
        let cred_ref = CredentialRef::Plaintext("sk-test-key".to_owned());

        let serialized = serde_json::to_string(&cred_ref);
        assert!(serialized.is_ok());
        let json = match serialized {
            Ok(s) => s,
            Err(_) => unreachable!(),
        };
        assert_eq!(json, "\"sk-test-key\"");
        let deserialized: Result<CredentialRef, _> = serde_json::from_str(&json);
        assert!(deserialized.is_ok());
        assert_eq!(cred_ref, deserialized.unwrap_or_default());
    }

    #[test]
    fn credential_ref_serde_none_json() {
        let cred_ref = CredentialRef::None;

        let serialized = serde_json::to_string(&cred_ref);
        assert!(serialized.is_ok());
        let json = match serialized {
            Ok(s) => s,
            Err(_) => unreachable!(),
        };
        // None serializes as empty string
        assert_eq!(json, "\"\"");
        let deserialized: Result<CredentialRef, _> = serde_json::from_str(&json);
        assert!(deserialized.is_ok());
        assert_eq!(cred_ref, deserialized.unwrap_or_default());
    }

    #[test]
    fn credential_ref_toml_round_trip() {
        #[derive(Serialize, Deserialize, PartialEq, Debug, Clone)]
        struct Wrapper {
            key: CredentialRef,
        }

        // Plaintext round-trips through TOML
        let w = Wrapper {
            key: CredentialRef::Plaintext("sk-key".to_owned()),
        };
        let toml_str = toml::to_string(&w);
        assert!(toml_str.is_ok());
        let parsed: Result<Wrapper, _> = toml::from_str(&toml_str.unwrap_or_default());
        assert!(parsed.is_ok());
        assert_eq!(parsed.unwrap_or(w.clone()), w);

        // None round-trips through TOML as empty string
        let w2 = Wrapper {
            key: CredentialRef::None,
        };
        let toml_str2 = toml::to_string(&w2);
        assert!(toml_str2.is_ok());
        let parsed2: Result<Wrapper, _> = toml::from_str(&toml_str2.unwrap_or_default());
        assert!(parsed2.is_ok());
        assert_eq!(parsed2.unwrap_or(w2.clone()), w2);
    }

    #[test]
    fn credential_ref_from_plain_string() {
        // A bare string in config should deserialize as Plaintext
        let result: Result<CredentialRef, _> = serde_json::from_str("\"my-api-key\"");
        assert!(result.is_ok());
        assert_eq!(
            result.unwrap_or_default(),
            CredentialRef::Plaintext("my-api-key".to_owned())
        );
    }

    #[test]
    fn credential_ref_from_empty_string() {
        // Empty string should deserialize as None
        let result: Result<CredentialRef, _> = serde_json::from_str("\"\"");
        assert!(result.is_ok());
        assert_eq!(result.unwrap_or_default(), CredentialRef::None);
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

    #[tokio::test]
    async fn credential_ref_resolve_plaintext() {
        use crate::credentials::CredentialManager;

        struct MockManager;
        impl CredentialManager for MockManager {
            fn store(
                &self,
                _account: &str,
                _value: &str,
            ) -> Result<CredentialRef, CredentialError> {
                unimplemented!()
            }
            fn retrieve(
                &self,
                _cred_ref: &CredentialRef,
            ) -> Result<Option<String>, CredentialError> {
                unimplemented!()
            }
            fn delete(&self, _cred_ref: &CredentialRef) -> Result<(), CredentialError> {
                unimplemented!()
            }
        }

        let manager = MockManager;
        let cred_ref = CredentialRef::Plaintext("test-value".to_owned());
        let result = cred_ref.resolve(&manager).await;
        assert!(result.is_ok());
        match result {
            Ok(value) => assert_eq!(value, "test-value"),
            Err(_) => unreachable!(),
        }
    }

    #[tokio::test]
    async fn credential_ref_resolve_none() {
        use crate::credentials::CredentialManager;

        struct MockManager;
        impl CredentialManager for MockManager {
            fn store(
                &self,
                _account: &str,
                _value: &str,
            ) -> Result<CredentialRef, CredentialError> {
                unimplemented!()
            }
            fn retrieve(
                &self,
                _cred_ref: &CredentialRef,
            ) -> Result<Option<String>, CredentialError> {
                unimplemented!()
            }
            fn delete(&self, _cred_ref: &CredentialRef) -> Result<(), CredentialError> {
                unimplemented!()
            }
        }

        let manager = MockManager;
        let cred_ref = CredentialRef::None;
        let result = cred_ref.resolve(&manager).await;
        assert!(result.is_err());
        match result {
            Err(CredentialError::NotFound) => {}
            _ => unreachable!(),
        }
    }

    #[tokio::test]
    async fn credential_ref_resolve_keychain() {
        use crate::credentials::CredentialManager;

        struct MockManager;
        impl CredentialManager for MockManager {
            fn store(
                &self,
                _account: &str,
                _value: &str,
            ) -> Result<CredentialRef, CredentialError> {
                unimplemented!()
            }
            fn retrieve(
                &self,
                cred_ref: &CredentialRef,
            ) -> Result<Option<String>, CredentialError> {
                match cred_ref {
                    CredentialRef::Keychain { service, account }
                        if service == "test-svc" && account == "test-acc" =>
                    {
                        Ok(Some("retrieved-value".to_owned()))
                    }
                    _ => Ok(Option::None),
                }
            }
            fn delete(&self, _cred_ref: &CredentialRef) -> Result<(), CredentialError> {
                unimplemented!()
            }
        }

        let manager = MockManager;
        let cred_ref = CredentialRef::Keychain {
            service: "test-svc".to_owned(),
            account: "test-acc".to_owned(),
        };
        let result = cred_ref.resolve(&manager).await;
        assert!(result.is_ok());
        match result {
            Ok(value) => assert_eq!(value, "retrieved-value"),
            Err(_) => unreachable!(),
        }
    }
}
