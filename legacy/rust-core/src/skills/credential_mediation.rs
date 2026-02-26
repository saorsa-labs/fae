//! Keychain-mediated credential injection for Python skills.
//!
//! Python skills declare the credentials they need in `manifest.toml` under
//! the `[[credentials]]` array. This module handles the full lifecycle:
//!
//! 1. **Collect** — store credential values (from user or test) in the
//!    platform Keychain, keyed by `{skill_id}.{name}`.
//! 2. **Retrieve** — load all stored credentials for a skill.
//! 3. **Inject** — write credential values as environment variables into
//!    `HashMap<String, String>` for subprocess spawning.
//! 4. **Clear** — delete all stored credentials for a skill.
//!
//! Skills never see raw Keychain storage. They receive their secrets only
//! as environment variables in their subprocess environment.
//!
//! # Security model
//!
//! - Credentials stored under service `"com.saorsalabs.fae.skills"` with
//!   account `"{skill_id}.{name}"`.
//! - Injection writes to a `HashMap` that is merged into the process
//!   environment — the Python script reads `os.environ["MY_VAR"]`, never
//!   touching Keychain directly.
//! - Raw values are not stored in the registry, logs, or config files.

use super::manifest::CredentialSchema;
use crate::credentials::{CredentialManager, CredentialRef};
use std::collections::HashMap;
use std::fmt;

// ── Constants ─────────────────────────────────────────────────────────────────

/// Keychain service name under which all Fae skill credentials are stored.
pub const FAE_SKILLS_KEYCHAIN_SERVICE: &str = "com.saorsalabs.fae.skills";

// ── Account key helper ────────────────────────────────────────────────────────

/// Returns the Keychain account key for a credential.
///
/// Format: `"{skill_id}.{name}"`, e.g. `"discord-bot.bot_token"`.
#[must_use]
pub fn credential_account(skill_id: &str, name: &str) -> String {
    format!("{skill_id}.{name}")
}

// ── Error type ────────────────────────────────────────────────────────────────

/// Errors from credential mediation operations.
#[derive(Debug)]
pub enum CredentialMediationError {
    /// A required credential has no value and no default.
    MissingRequired {
        /// Credential name from the manifest schema.
        name: String,
    },
    /// Platform credential storage (Keychain) returned an error.
    StorageError(crate::credentials::CredentialError),
    /// Credential name is syntactically invalid.
    InvalidName(String),
}

impl fmt::Display for CredentialMediationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingRequired { name } => {
                write!(f, "required credential `{name}` is missing")
            }
            Self::StorageError(e) => write!(f, "credential storage error: {e}"),
            Self::InvalidName(s) => write!(f, "invalid credential name: `{s}`"),
        }
    }
}

impl std::error::Error for CredentialMediationError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::StorageError(e) => Some(e),
            _ => None,
        }
    }
}

impl From<crate::credentials::CredentialError> for CredentialMediationError {
    fn from(e: crate::credentials::CredentialError) -> Self {
        Self::StorageError(e)
    }
}

// ── Status types ──────────────────────────────────────────────────────────────

/// Status of a single credential for a skill.
#[derive(Debug, Clone)]
pub struct CredentialStatus {
    /// Credential name from the manifest schema.
    pub name: String,
    /// Environment variable name to inject into the subprocess.
    pub env_var: String,
    /// Whether a value is currently stored in the Keychain.
    pub is_stored: bool,
    /// Whether this credential is required by the skill.
    pub required: bool,
}

// ── Collected credential ──────────────────────────────────────────────────────

/// A single credential value ready for subprocess injection.
///
/// The `value` field contains the raw secret. Values are cleared from memory
/// when this struct is dropped.
#[derive(Debug)]
pub struct CollectedCredential {
    /// Environment variable name (from `CredentialSchema::env_var`).
    pub env_var: String,
    /// The resolved secret value.
    ///
    /// This is the only point in the Rust code where the raw value is held.
    /// It is injected into the subprocess environment and must not be logged.
    ///
    /// # Security note
    ///
    /// Do not pass this field to logging, metrics, or any external system.
    /// It is exposed as `pub` for testing and injection purposes only.
    pub value: String,
}

// ── Collection result ─────────────────────────────────────────────────────────

/// All credentials collected for a single skill, ready for injection.
#[derive(Debug)]
pub struct CredentialCollection {
    /// Skill identifier (from `PythonSkillManifest::id`).
    pub skill_id: String,
    /// Collected credentials in schema declaration order.
    pub credentials: Vec<CollectedCredential>,
}

impl CredentialCollection {
    /// Injects all credential values into `env` as environment variables.
    ///
    /// Existing entries with the same key are overwritten. This ensures
    /// credentials are always fresh from the Keychain and cannot be
    /// shadowed by the parent process environment.
    pub fn inject_into(&self, env: &mut HashMap<String, String>) {
        for cred in &self.credentials {
            env.insert(cred.env_var.clone(), cred.value.clone());
        }
    }
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Checks which credentials are already stored in the Keychain.
///
/// Returns a [`CredentialStatus`] for each entry in `schema`, indicating
/// whether a value is present in storage.
///
/// # Errors
///
/// Returns [`CredentialMediationError::StorageError`] if the Keychain cannot
/// be accessed.
pub fn check_stored_credentials(
    skill_id: &str,
    schema: &[CredentialSchema],
    manager: &dyn CredentialManager,
) -> Result<Vec<CredentialStatus>, CredentialMediationError> {
    let mut statuses = Vec::with_capacity(schema.len());
    for cred in schema {
        let account = credential_account(skill_id, &cred.name);
        let keychain_ref = CredentialRef::Keychain {
            service: FAE_SKILLS_KEYCHAIN_SERVICE.to_owned(),
            account,
        };
        let is_stored = manager
            .retrieve(&keychain_ref)
            .map(|opt| opt.is_some())
            .unwrap_or(false);
        statuses.push(CredentialStatus {
            name: cred.name.clone(),
            env_var: cred.env_var.clone(),
            is_stored,
            required: cred.required,
        });
    }
    Ok(statuses)
}

/// Stores credential values in the Keychain and returns a [`CredentialCollection`].
///
/// `values` is a map from credential `name` (per schema) to the secret value.
/// For each schema entry, the function:
/// 1. Looks up `values[name]`.
/// 2. If found: stores it in the Keychain and records the value.
/// 3. If not found but `required`: returns [`CredentialMediationError::MissingRequired`].
/// 4. If not found and optional: uses `schema.default` if present, skips otherwise.
///
/// # Errors
///
/// - [`CredentialMediationError::MissingRequired`] if a required credential has no value.
/// - [`CredentialMediationError::StorageError`] if the Keychain store fails.
pub fn collect_skill_credentials(
    skill_id: &str,
    schema: &[CredentialSchema],
    values: &HashMap<String, String>,
    manager: &dyn CredentialManager,
) -> Result<CredentialCollection, CredentialMediationError> {
    let mut credentials = Vec::with_capacity(schema.len());

    for cred in schema {
        let value = if let Some(v) = values.get(&cred.name) {
            // Store this value in the Keychain for future retrieval.
            let account = credential_account(skill_id, &cred.name);
            manager
                .store(&account, v)
                .map_err(CredentialMediationError::from)?;
            v.clone()
        } else if let Some(default) = &cred.default {
            // Optional credential with a default — use the default; don't store in Keychain.
            default.clone()
        } else if cred.required {
            return Err(CredentialMediationError::MissingRequired {
                name: cred.name.clone(),
            });
        } else {
            // Optional and no default — skip.
            continue;
        };

        credentials.push(CollectedCredential {
            env_var: cred.env_var.clone(),
            value,
        });
    }

    Ok(CredentialCollection {
        skill_id: skill_id.to_owned(),
        credentials,
    })
}

/// Retrieves all stored credentials for a skill from the Keychain.
///
/// For each schema entry:
/// 1. Looks up the value in the Keychain.
/// 2. If found: includes it in the collection.
/// 3. If not found and `required`: returns [`CredentialMediationError::MissingRequired`].
/// 4. If not found and optional with default: uses the default.
/// 5. If not found, optional, and no default: skips.
///
/// # Errors
///
/// - [`CredentialMediationError::MissingRequired`] if a required credential is missing.
/// - [`CredentialMediationError::StorageError`] if the Keychain cannot be accessed.
pub fn retrieve_skill_credentials(
    skill_id: &str,
    schema: &[CredentialSchema],
    manager: &dyn CredentialManager,
) -> Result<CredentialCollection, CredentialMediationError> {
    let mut credentials = Vec::with_capacity(schema.len());

    for cred in schema {
        let account = credential_account(skill_id, &cred.name);
        let keychain_ref = CredentialRef::Keychain {
            service: FAE_SKILLS_KEYCHAIN_SERVICE.to_owned(),
            account,
        };
        let stored = manager
            .retrieve(&keychain_ref)
            .map_err(CredentialMediationError::from)?;

        let value = match stored {
            Some(v) => v,
            None if cred.required => {
                // Check if there's a default for required fields too
                if let Some(default) = &cred.default {
                    default.clone()
                } else {
                    return Err(CredentialMediationError::MissingRequired {
                        name: cred.name.clone(),
                    });
                }
            }
            None => {
                // Optional — use default if present, skip otherwise.
                if let Some(default) = &cred.default {
                    default.clone()
                } else {
                    continue;
                }
            }
        };

        credentials.push(CollectedCredential {
            env_var: cred.env_var.clone(),
            value,
        });
    }

    Ok(CredentialCollection {
        skill_id: skill_id.to_owned(),
        credentials,
    })
}

/// Clears all stored credentials for a skill from the Keychain.
///
/// Iterates over `schema` and deletes each entry from the Keychain.
/// Missing entries are silently ignored.
///
/// # Errors
///
/// Returns [`CredentialMediationError::StorageError`] if deletion fails for
/// any credential.
pub fn clear_skill_credentials(
    skill_id: &str,
    schema: &[CredentialSchema],
    manager: &dyn CredentialManager,
) -> Result<(), CredentialMediationError> {
    for cred in schema {
        let account = credential_account(skill_id, &cred.name);
        let keychain_ref = CredentialRef::Keychain {
            service: FAE_SKILLS_KEYCHAIN_SERVICE.to_owned(),
            account,
        };
        manager
            .delete(&keychain_ref)
            .map_err(CredentialMediationError::from)?;
    }
    Ok(())
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
pub(crate) mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use crate::credentials::{CredentialError, CredentialRef};
    use std::sync::{Arc, Mutex};

    // ── Mock credential manager ──

    /// In-memory credential manager for testing.
    /// Stores credentials as `HashMap<(service, account), value>`.
    #[derive(Default, Clone)]
    pub(crate) struct MockCredentialManager {
        store: Arc<Mutex<HashMap<(String, String), String>>>,
    }

    impl MockCredentialManager {
        pub fn new() -> Self {
            Self::default()
        }

        pub fn stored_count(&self) -> usize {
            self.store.lock().unwrap_or_else(|e| e.into_inner()).len()
        }

        pub fn get(&self, service: &str, account: &str) -> Option<String> {
            self.store
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(&(service.to_owned(), account.to_owned()))
                .cloned()
        }
    }

    impl crate::credentials::CredentialManager for MockCredentialManager {
        fn store(&self, account: &str, value: &str) -> Result<CredentialRef, CredentialError> {
            self.store.lock().unwrap_or_else(|e| e.into_inner()).insert(
                (FAE_SKILLS_KEYCHAIN_SERVICE.to_owned(), account.to_owned()),
                value.to_owned(),
            );
            Ok(CredentialRef::Keychain {
                service: FAE_SKILLS_KEYCHAIN_SERVICE.to_owned(),
                account: account.to_owned(),
            })
        }

        fn retrieve(&self, cred_ref: &CredentialRef) -> Result<Option<String>, CredentialError> {
            let (service, account) = match cred_ref {
                CredentialRef::Keychain { service, account } => {
                    (service.as_str(), account.as_str())
                }
                CredentialRef::Plaintext(v) => return Ok(Some(v.clone())),
                CredentialRef::None => return Ok(None),
            };
            Ok(self
                .store
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .get(&(service.to_owned(), account.to_owned()))
                .cloned())
        }

        fn delete(&self, cred_ref: &CredentialRef) -> Result<(), CredentialError> {
            let (service, account) = match cred_ref {
                CredentialRef::Keychain { service, account } => {
                    (service.as_str(), account.as_str())
                }
                _ => return Ok(()),
            };
            self.store
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(&(service.to_owned(), account.to_owned()));
            Ok(())
        }
    }

    // ── Schema helpers ──

    fn make_required(name: &str, env_var: &str) -> CredentialSchema {
        CredentialSchema {
            name: name.to_owned(),
            env_var: env_var.to_owned(),
            description: format!("Your {name}"),
            required: true,
            default: None,
        }
    }

    fn make_optional(name: &str, env_var: &str, default: &str) -> CredentialSchema {
        CredentialSchema {
            name: name.to_owned(),
            env_var: env_var.to_owned(),
            description: format!("Optional {name}"),
            required: false,
            default: Some(default.to_owned()),
        }
    }

    fn make_optional_no_default(name: &str, env_var: &str) -> CredentialSchema {
        CredentialSchema {
            name: name.to_owned(),
            env_var: env_var.to_owned(),
            description: format!("Optional {name} with no default"),
            required: false,
            default: None,
        }
    }

    // ── credential_account ──

    #[test]
    fn credential_account_format() {
        assert_eq!(
            credential_account("discord-bot", "bot_token"),
            "discord-bot.bot_token"
        );
        assert_eq!(
            credential_account("my-skill", "api_key"),
            "my-skill.api_key"
        );
    }

    // ── collect_skill_credentials ──

    #[test]
    fn collect_stores_credentials_in_keychain() {
        let manager = MockCredentialManager::new();
        let schema = vec![make_required("bot_token", "DISCORD_BOT_TOKEN")];
        let mut values = HashMap::new();
        values.insert("bot_token".to_owned(), "xoxb-secret".to_owned());

        let collection =
            collect_skill_credentials("discord", &schema, &values, &manager).expect("collect");

        assert_eq!(collection.skill_id, "discord");
        assert_eq!(collection.credentials.len(), 1);
        assert_eq!(collection.credentials[0].env_var, "DISCORD_BOT_TOKEN");
        assert_eq!(collection.credentials[0].value, "xoxb-secret");

        // Value should be in the mock store.
        assert_eq!(
            manager.get(FAE_SKILLS_KEYCHAIN_SERVICE, "discord.bot_token"),
            Some("xoxb-secret".to_owned())
        );
    }

    #[test]
    fn collect_missing_required_returns_error() {
        let manager = MockCredentialManager::new();
        let schema = vec![make_required("api_key", "MY_API_KEY")];
        let values = HashMap::new(); // empty — missing required

        let result = collect_skill_credentials("my-skill", &schema, &values, &manager);
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(err.contains("api_key"), "expected api_key in error: {err}");
    }

    #[test]
    fn collect_optional_uses_default_when_not_provided() {
        let manager = MockCredentialManager::new();
        let schema = vec![make_optional("guild_id", "DISCORD_GUILD_ID", "12345")];
        let values = HashMap::new(); // not provided

        let collection =
            collect_skill_credentials("discord", &schema, &values, &manager).expect("collect");

        assert_eq!(collection.credentials.len(), 1);
        assert_eq!(collection.credentials[0].value, "12345");
        // Default values are NOT stored in Keychain.
        assert_eq!(manager.stored_count(), 0);
    }

    #[test]
    fn collect_optional_with_no_default_is_skipped_when_not_provided() {
        let manager = MockCredentialManager::new();
        let schema = vec![make_optional_no_default("extra", "EXTRA_VAR")];
        let values = HashMap::new();

        let collection =
            collect_skill_credentials("my-skill", &schema, &values, &manager).expect("collect");

        // Skipped — no credential in collection.
        assert!(collection.credentials.is_empty());
    }

    #[test]
    fn collect_overwrites_existing_credential() {
        let manager = MockCredentialManager::new();
        let schema = vec![make_required("token", "MY_TOKEN")];

        let mut v1 = HashMap::new();
        v1.insert("token".to_owned(), "old-value".to_owned());
        collect_skill_credentials("skill", &schema, &v1, &manager).expect("first collect");

        let mut v2 = HashMap::new();
        v2.insert("token".to_owned(), "new-value".to_owned());
        let coll =
            collect_skill_credentials("skill", &schema, &v2, &manager).expect("second collect");

        assert_eq!(coll.credentials[0].value, "new-value");
        assert_eq!(
            manager.get(FAE_SKILLS_KEYCHAIN_SERVICE, "skill.token"),
            Some("new-value".to_owned())
        );
    }

    // ── retrieve_skill_credentials ──

    #[test]
    fn retrieve_loads_all_credentials() {
        let manager = MockCredentialManager::new();
        // Pre-populate the mock store.
        manager
            .store("discord.bot_token", "xoxb-abc")
            .expect("store");

        let schema = vec![make_required("bot_token", "DISCORD_BOT_TOKEN")];
        let collection =
            retrieve_skill_credentials("discord", &schema, &manager).expect("retrieve");

        assert_eq!(collection.credentials.len(), 1);
        assert_eq!(collection.credentials[0].value, "xoxb-abc");
    }

    #[test]
    fn retrieve_missing_optional_uses_default() {
        let manager = MockCredentialManager::new();
        let schema = vec![make_optional("guild_id", "DISCORD_GUILD_ID", "99999")];
        let collection =
            retrieve_skill_credentials("discord", &schema, &manager).expect("retrieve");

        assert_eq!(collection.credentials.len(), 1);
        assert_eq!(collection.credentials[0].value, "99999");
    }

    #[test]
    fn retrieve_missing_optional_no_default_is_skipped() {
        let manager = MockCredentialManager::new();
        let schema = vec![make_optional_no_default("extra", "EXTRA")];
        let collection =
            retrieve_skill_credentials("discord", &schema, &manager).expect("retrieve");

        assert!(collection.credentials.is_empty());
    }

    #[test]
    fn retrieve_missing_required_returns_error() {
        let manager = MockCredentialManager::new();
        let schema = vec![make_required("bot_token", "DISCORD_BOT_TOKEN")];

        let result = retrieve_skill_credentials("discord", &schema, &manager);
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(
            err.contains("bot_token"),
            "expected bot_token in error: {err}"
        );
    }

    // ── clear_skill_credentials ──

    #[test]
    fn clear_deletes_all_stored_credentials() {
        let manager = MockCredentialManager::new();
        manager.store("discord.bot_token", "xoxb").expect("store");
        manager.store("discord.guild_id", "123").expect("store");
        assert_eq!(manager.stored_count(), 2);

        let schema = vec![
            make_required("bot_token", "DISCORD_BOT_TOKEN"),
            make_optional("guild_id", "DISCORD_GUILD_ID", "0"),
        ];
        clear_skill_credentials("discord", &schema, &manager).expect("clear");

        assert_eq!(manager.stored_count(), 0);
    }

    #[test]
    fn clear_missing_credentials_is_idempotent() {
        let manager = MockCredentialManager::new();
        let schema = vec![make_required("token", "TOKEN")];

        // Nothing stored — should not error.
        let result = clear_skill_credentials("skill", &schema, &manager);
        assert!(result.is_ok());
    }

    // ── check_stored_credentials ──

    #[test]
    fn check_stored_shows_missing_and_present() {
        let manager = MockCredentialManager::new();
        manager.store("my-skill.token_a", "value-a").expect("store");

        let schema = vec![
            make_required("token_a", "TOKEN_A"),
            make_required("token_b", "TOKEN_B"),
        ];
        let statuses = check_stored_credentials("my-skill", &schema, &manager).expect("check");

        assert_eq!(statuses.len(), 2);
        assert_eq!(statuses[0].name, "token_a");
        assert!(statuses[0].is_stored);
        assert_eq!(statuses[1].name, "token_b");
        assert!(!statuses[1].is_stored);
    }

    // ── inject_into ──

    #[test]
    fn inject_into_adds_env_vars() {
        let collection = CredentialCollection {
            skill_id: "discord".to_owned(),
            credentials: vec![
                CollectedCredential {
                    env_var: "DISCORD_BOT_TOKEN".to_owned(),
                    value: "xoxb-secret".to_owned(),
                },
                CollectedCredential {
                    env_var: "DISCORD_GUILD_ID".to_owned(),
                    value: "12345".to_owned(),
                },
            ],
        };

        let mut env = HashMap::new();
        env.insert("EXISTING_VAR".to_owned(), "existing".to_owned());
        collection.inject_into(&mut env);

        assert_eq!(
            env.get("DISCORD_BOT_TOKEN").map(String::as_str),
            Some("xoxb-secret")
        );
        assert_eq!(
            env.get("DISCORD_GUILD_ID").map(String::as_str),
            Some("12345")
        );
        // Existing vars preserved.
        assert_eq!(
            env.get("EXISTING_VAR").map(String::as_str),
            Some("existing")
        );
    }

    #[test]
    fn inject_into_overwrites_existing_var() {
        let collection = CredentialCollection {
            skill_id: "skill".to_owned(),
            credentials: vec![CollectedCredential {
                env_var: "MY_VAR".to_owned(),
                value: "new-value".to_owned(),
            }],
        };

        let mut env = HashMap::new();
        env.insert("MY_VAR".to_owned(), "old-value".to_owned());
        collection.inject_into(&mut env);

        assert_eq!(env.get("MY_VAR").map(String::as_str), Some("new-value"));
    }
}
