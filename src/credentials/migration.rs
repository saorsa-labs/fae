//! Plaintext credential detection and migration to secure storage.
//!
//! Scans a [`SpeechConfig`] for credentials stored as [`CredentialRef::Plaintext`]
//! and migrates them to the platform keychain via a [`CredentialManager`].

use crate::config::SpeechConfig;
use crate::credentials::CredentialManager;
use crate::credentials::types::{CredentialError, CredentialRef};
use std::fmt;

/// A plaintext credential discovered during detection.
///
/// The [`Debug`] implementation redacts the secret value.
pub struct PlaintextCredential {
    /// Credential account identifier (e.g. `"llm.api_key"`).
    pub account: String,
    /// The plaintext secret value.
    pub value: String,
}

impl fmt::Debug for PlaintextCredential {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PlaintextCredential")
            .field("account", &self.account)
            .field("value", &"[REDACTED]")
            .finish()
    }
}

/// Scan a config for credentials stored as plaintext.
///
/// Checks the following fields:
/// - `channels.discord.bot_token` (if discord configured)
/// - `channels.whatsapp.access_token` (if whatsapp configured)
/// - `channels.whatsapp.verify_token` (if whatsapp configured)
/// - `channels.gateway.bearer_token`
#[must_use]
pub fn detect_plaintext_credentials(config: &SpeechConfig) -> Vec<PlaintextCredential> {
    let mut found = Vec::new();

    if let Some(dc) = &config.channels.discord
        && let CredentialRef::Plaintext(v) = &dc.bot_token
    {
        found.push(PlaintextCredential {
            account: "discord.bot_token".to_owned(),
            value: v.clone(),
        });
    }

    if let Some(wa) = &config.channels.whatsapp
        && let CredentialRef::Plaintext(v) = &wa.access_token
    {
        found.push(PlaintextCredential {
            account: "whatsapp.access_token".to_owned(),
            value: v.clone(),
        });
    }

    if let Some(wa) = &config.channels.whatsapp
        && let CredentialRef::Plaintext(v) = &wa.verify_token
    {
        found.push(PlaintextCredential {
            account: "whatsapp.verify_token".to_owned(),
            value: v.clone(),
        });
    }

    if let Some(CredentialRef::Plaintext(v)) = &config.channels.gateway.bearer_token {
        found.push(PlaintextCredential {
            account: "gateway.bearer_token".to_owned(),
            value: v.clone(),
        });
    }

    found
}

/// Migrate a single credential field from plaintext to keychain.
///
/// Returns `true` if the field was migrated, `false` if it was not plaintext.
///
/// # Errors
///
/// Returns [`CredentialError`] if the keychain store operation fails.
fn migrate_single(
    field: &mut CredentialRef,
    account: &str,
    manager: &dyn CredentialManager,
) -> Result<bool, CredentialError> {
    if let CredentialRef::Plaintext(value) = field {
        let new_ref = manager.store(account, value)?;
        *field = new_ref;
        Ok(true)
    } else {
        Ok(false)
    }
}

/// Migrate all plaintext credentials in the config to keychain storage.
///
/// For each plaintext credential:
/// 1. Stores the value in the keychain via `manager.store()`
/// 2. Replaces the config field with the returned `CredentialRef::Keychain`
///
/// Returns the number of credentials that were migrated.
///
/// # Errors
///
/// Returns [`CredentialError`] if any keychain store operation fails.
/// Already-migrated fields are not rolled back on partial failure.
pub fn migrate_to_keychain(
    config: &mut SpeechConfig,
    manager: &dyn CredentialManager,
) -> Result<usize, CredentialError> {
    let mut count = 0usize;

    if let Some(dc) = &mut config.channels.discord
        && migrate_single(&mut dc.bot_token, "discord.bot_token", manager)?
    {
        count += 1;
    }

    if let Some(wa) = &mut config.channels.whatsapp {
        if migrate_single(&mut wa.access_token, "whatsapp.access_token", manager)? {
            count += 1;
        }
        if migrate_single(&mut wa.verify_token, "whatsapp.verify_token", manager)? {
            count += 1;
        }
    }

    if let Some(ref mut cred_ref) = config.channels.gateway.bearer_token
        && migrate_single(cred_ref, "gateway.bearer_token", manager)?
    {
        count += 1;
    }

    Ok(count)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use crate::config::{DiscordChannelConfig, WhatsAppChannelConfig};
    use crate::credentials::CredentialManager;
    use std::collections::HashMap;
    use std::sync::Mutex;

    struct MockManager {
        store: Mutex<HashMap<String, String>>,
    }

    impl MockManager {
        fn new() -> Self {
            Self {
                store: Mutex::new(HashMap::new()),
            }
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
    fn detect_finds_plaintext_fields() {
        let mut config = SpeechConfig::default();
        config.channels.discord = Some(DiscordChannelConfig {
            bot_token: CredentialRef::Plaintext("tok1".to_owned()),
            ..Default::default()
        });
        config.channels.whatsapp = Some(WhatsAppChannelConfig {
            access_token: CredentialRef::Plaintext("wa-at".to_owned()),
            verify_token: CredentialRef::Plaintext("wa-vt".to_owned()),
            ..Default::default()
        });
        config.channels.gateway.bearer_token = Some(CredentialRef::Plaintext("bearer".to_owned()));

        let found = detect_plaintext_credentials(&config);
        assert_eq!(found.len(), 4);
        assert_eq!(found[0].account, "discord.bot_token");
        assert_eq!(found[1].account, "whatsapp.access_token");
        assert_eq!(found[2].account, "whatsapp.verify_token");
        assert_eq!(found[3].account, "gateway.bearer_token");
    }

    #[test]
    fn detect_skips_non_plaintext() {
        let config = SpeechConfig::default();
        // discord/whatsapp default to None (no adapter configured)
        let found = detect_plaintext_credentials(&config);
        assert!(found.is_empty());
    }

    #[test]
    fn detect_empty_config() {
        let config = SpeechConfig::default();
        let found = detect_plaintext_credentials(&config);
        assert!(found.is_empty());
    }

    #[test]
    fn migrate_converts_plaintext_to_keychain() {
        let mgr = MockManager::new();
        let mut config = SpeechConfig::default();
        config.channels.discord = Some(DiscordChannelConfig {
            bot_token: CredentialRef::Plaintext("discord-tok".to_owned()),
            ..Default::default()
        });

        let count = migrate_to_keychain(&mut config, &mgr).unwrap();
        assert_eq!(count, 1);

        // Verify field is now a Keychain ref
        assert!(
            config
                .channels
                .discord
                .as_ref()
                .unwrap()
                .bot_token
                .is_keychain()
        );

        // Verify value is stored in the mock
        let store = mgr.store.lock().unwrap();
        assert_eq!(store.get("discord.bot_token").unwrap(), "discord-tok");
    }

    #[test]
    fn migrate_skips_non_plaintext() {
        let mgr = MockManager::new();
        let mut config = SpeechConfig::default();
        // All fields are None by default
        let count = migrate_to_keychain(&mut config, &mgr).unwrap();
        assert_eq!(count, 0);
    }

    #[test]
    fn migrate_partial() {
        let mgr = MockManager::new();
        let mut config = SpeechConfig::default();
        config.channels.discord = Some(DiscordChannelConfig {
            bot_token: CredentialRef::Keychain {
                service: "svc".to_owned(),
                account: "acc".to_owned(),
            },
            ..Default::default()
        });
        // whatsapp not configured

        let count = migrate_to_keychain(&mut config, &mgr).unwrap();
        // Discord is already Keychain, so nothing to migrate
        assert_eq!(count, 0);
        // Discord stays as Keychain (not re-migrated)
        assert!(
            config
                .channels
                .discord
                .as_ref()
                .unwrap()
                .bot_token
                .is_keychain()
        );
    }

    #[test]
    fn plaintext_credential_debug_redacts() {
        let cred = PlaintextCredential {
            account: "llm.api_key".to_owned(),
            value: "super-secret-key".to_owned(),
        };
        let debug = format!("{cred:?}");
        assert!(debug.contains("llm.api_key"));
        assert!(!debug.contains("super-secret-key"));
        assert!(debug.contains("[REDACTED]"));
    }
}
