//! Credential loading and batch resolution.
//!
//! Provides utilities to resolve [`CredentialRef`] values into actual secrets
//! using a [`CredentialManager`] backend, and to batch-resolve all credential
//! fields from a [`SpeechConfig`].

use crate::config::SpeechConfig;
use crate::credentials::CredentialManager;
use crate::credentials::types::{CredentialError, CredentialRef};
use std::fmt;

/// Resolved credential values ready for runtime use.
///
/// All secret fields are resolved to their plaintext `String` values.
/// This struct intentionally implements a custom [`Debug`] that redacts
/// all values to prevent accidental secret leakage in logs.
pub struct LoadedCredentials {
    /// Resolved LLM API key.
    pub llm_api_key: String,
    /// Resolved Discord bot token.
    pub discord_bot_token: String,
    /// Resolved WhatsApp access token.
    pub whatsapp_access_token: String,
    /// Resolved WhatsApp verification token.
    pub whatsapp_verify_token: String,
    /// Resolved gateway bearer token (`None` if not configured).
    pub gateway_bearer_token: Option<String>,
}

impl fmt::Debug for LoadedCredentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LoadedCredentials")
            .field("llm_api_key", &redact(&self.llm_api_key))
            .field("discord_bot_token", &redact(&self.discord_bot_token))
            .field(
                "whatsapp_access_token",
                &redact(&self.whatsapp_access_token),
            )
            .field(
                "whatsapp_verify_token",
                &redact(&self.whatsapp_verify_token),
            )
            .field(
                "gateway_bearer_token",
                &self.gateway_bearer_token.as_ref().map(|_| "[REDACTED]"),
            )
            .finish()
    }
}

fn redact(s: &str) -> &str {
    if s.is_empty() { "" } else { "[REDACTED]" }
}

/// Resolve a single [`CredentialRef`] to its plaintext value.
///
/// # Variants
///
/// - `Plaintext(s)` → returns the stored string
/// - `Keychain { .. }` → delegates to `manager.retrieve()`
/// - `None` → returns an empty string
///
/// # Errors
///
/// Returns [`CredentialError`] if a keychain lookup fails.
pub fn resolve_credential(
    cred_ref: &CredentialRef,
    manager: &dyn CredentialManager,
) -> Result<String, CredentialError> {
    match cred_ref {
        CredentialRef::Plaintext(s) => Ok(s.clone()),
        CredentialRef::None => Ok(String::new()),
        CredentialRef::Keychain { .. } => {
            let opt = manager.retrieve(cred_ref)?;
            Ok(opt.unwrap_or_default())
        }
    }
}

/// Batch-resolve all credential fields from a [`SpeechConfig`].
///
/// Iterates over every credential-bearing config field, resolving each
/// through the supplied [`CredentialManager`].
///
/// # Errors
///
/// Returns [`CredentialError`] if any individual credential resolution fails.
pub fn load_all_credentials(
    config: &SpeechConfig,
    manager: &dyn CredentialManager,
) -> Result<LoadedCredentials, CredentialError> {
    let llm_api_key = resolve_credential(&config.llm.api_key, manager)?;
    let discord_bot_token = match &config.channels.discord {
        Some(dc) => resolve_credential(&dc.bot_token, manager)?,
        None => String::new(),
    };
    let whatsapp_access_token = match &config.channels.whatsapp {
        Some(wa) => resolve_credential(&wa.access_token, manager)?,
        None => String::new(),
    };
    let whatsapp_verify_token = match &config.channels.whatsapp {
        Some(wa) => resolve_credential(&wa.verify_token, manager)?,
        None => String::new(),
    };

    let gateway_bearer_token = match &config.channels.gateway.bearer_token {
        Some(cred_ref) => {
            let resolved = resolve_credential(cred_ref, manager)?;
            if resolved.is_empty() {
                None
            } else {
                Some(resolved)
            }
        }
        None => None,
    };

    Ok(LoadedCredentials {
        llm_api_key,
        discord_bot_token,
        whatsapp_access_token,
        whatsapp_verify_token,
        gateway_bearer_token,
    })
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use crate::credentials::CredentialManager;
    use std::collections::HashMap;
    use std::sync::Mutex;

    /// In-memory mock credential manager for testing.
    struct MockManager {
        store: Mutex<HashMap<String, String>>,
    }

    impl MockManager {
        fn new() -> Self {
            Self {
                store: Mutex::new(HashMap::new()),
            }
        }

        fn with_entry(self, account: &str, value: &str) -> Self {
            self.store
                .lock()
                .unwrap()
                .insert(account.to_owned(), value.to_owned());
            self
        }
    }

    impl CredentialManager for MockManager {
        fn store(&self, account: &str, value: &str) -> Result<CredentialRef, CredentialError> {
            self.store
                .lock()
                .unwrap()
                .insert(account.to_owned(), value.to_owned());
            Ok(CredentialRef::Keychain {
                service: "com.saorsalabs.fae".to_owned(),
                account: account.to_owned(),
            })
        }

        fn retrieve(&self, cred_ref: &CredentialRef) -> Result<Option<String>, CredentialError> {
            match cred_ref {
                CredentialRef::Keychain { account, .. } => {
                    let guard = self.store.lock().unwrap();
                    Ok(guard.get(account).cloned())
                }
                CredentialRef::Plaintext(s) => Ok(Some(s.clone())),
                CredentialRef::None => Ok(None),
            }
        }

        fn delete(&self, cred_ref: &CredentialRef) -> Result<(), CredentialError> {
            if let CredentialRef::Keychain { account, .. } = cred_ref {
                self.store.lock().unwrap().remove(account);
            }
            Ok(())
        }
    }

    #[test]
    fn resolve_plaintext_variant() {
        let mgr = MockManager::new();
        let cred = CredentialRef::Plaintext("sk-test".to_owned());
        let result = resolve_credential(&cred, &mgr).unwrap();
        assert_eq!(result, "sk-test");
    }

    #[test]
    fn resolve_none_variant() {
        let mgr = MockManager::new();
        let cred = CredentialRef::None;
        let result = resolve_credential(&cred, &mgr).unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn resolve_keychain_variant() {
        let mgr = MockManager::new().with_entry("llm.api_key", "sk-from-keychain");
        let cred = CredentialRef::Keychain {
            service: "com.saorsalabs.fae".to_owned(),
            account: "llm.api_key".to_owned(),
        };
        let result = resolve_credential(&cred, &mgr).unwrap();
        assert_eq!(result, "sk-from-keychain");
    }

    #[test]
    fn resolve_keychain_missing_returns_empty() {
        let mgr = MockManager::new();
        let cred = CredentialRef::Keychain {
            service: "com.saorsalabs.fae".to_owned(),
            account: "nonexistent".to_owned(),
        };
        let result = resolve_credential(&cred, &mgr).unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn load_all_default_config() {
        let mgr = MockManager::new();
        let config = SpeechConfig::default();
        let loaded = load_all_credentials(&config, &mgr).unwrap();
        assert!(loaded.llm_api_key.is_empty());
        assert!(loaded.discord_bot_token.is_empty());
        assert!(loaded.whatsapp_access_token.is_empty());
        assert!(loaded.whatsapp_verify_token.is_empty());
        assert!(loaded.gateway_bearer_token.is_none());
    }

    #[test]
    fn load_all_mixed_refs() {
        let mgr = MockManager::new().with_entry("llm.api_key", "from-keychain");
        let mut config = SpeechConfig::default();
        config.llm.api_key = CredentialRef::Keychain {
            service: "com.saorsalabs.fae".to_owned(),
            account: "llm.api_key".to_owned(),
        };
        config.channels.discord = Some(crate::config::DiscordChannelConfig {
            bot_token: CredentialRef::Plaintext("discord-plain".to_owned()),
            ..Default::default()
        });
        // whatsapp stays None
        config.channels.gateway.bearer_token =
            Some(CredentialRef::Plaintext("bearer-val".to_owned()));

        let loaded = load_all_credentials(&config, &mgr).unwrap();
        assert_eq!(loaded.llm_api_key, "from-keychain");
        assert_eq!(loaded.discord_bot_token, "discord-plain");
        assert!(loaded.whatsapp_access_token.is_empty());
        assert!(loaded.whatsapp_verify_token.is_empty());
        assert_eq!(loaded.gateway_bearer_token.as_deref(), Some("bearer-val"));
    }

    #[test]
    fn debug_redacts_values() {
        let loaded = LoadedCredentials {
            llm_api_key: "sk-secret".to_owned(),
            discord_bot_token: "bot-secret".to_owned(),
            whatsapp_access_token: String::new(),
            whatsapp_verify_token: "verify-secret".to_owned(),
            gateway_bearer_token: Some("bearer-secret".to_owned()),
        };
        let debug = format!("{loaded:?}");
        assert!(!debug.contains("sk-secret"));
        assert!(!debug.contains("bot-secret"));
        assert!(!debug.contains("verify-secret"));
        assert!(!debug.contains("bearer-secret"));
        assert!(debug.contains("[REDACTED]"));
    }

    #[test]
    fn debug_empty_fields_not_redacted() {
        let loaded = LoadedCredentials {
            llm_api_key: String::new(),
            discord_bot_token: String::new(),
            whatsapp_access_token: String::new(),
            whatsapp_verify_token: String::new(),
            gateway_bearer_token: None,
        };
        let debug = format!("{loaded:?}");
        // Empty strings show as empty, not [REDACTED]
        assert!(debug.contains("llm_api_key: \"\""));
    }
}
