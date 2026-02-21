//! Integration tests for Python skill credential mediation.
//!
//! These tests use an in-memory `MockCredentialManager` — no real macOS
//! Keychain access is performed. This makes the suite fully hermetic and
//! runnable on any platform.
//!
//! Covered scenarios:
//!
//! 1. Full collect → retrieve → inject cycle
//! 2. Clear removes all credential entries
//! 3. Missing required credential fails collect
//! 4. Optional credential uses default when not provided
//! 5. inject_into sets environment variables correctly
//! 6. Collect overwrites an existing credential
//! 7. Invalid credential name rejected by manifest validation

#![allow(clippy::unwrap_used, clippy::expect_used)]

use fae::skills::credential_mediation::{
    FAE_SKILLS_KEYCHAIN_SERVICE, check_stored_credentials, clear_skill_credentials,
    collect_skill_credentials, retrieve_skill_credentials,
};
use fae::skills::manifest::CredentialSchema;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

// Re-use the mock from the unit tests (same logic, no Keychain).
use fae::credentials::{CredentialError, CredentialManager, CredentialRef};

// ── In-memory mock ─────────────────────────────────────────────────────────────

/// In-memory credential manager for integration tests.
#[derive(Default, Clone)]
struct MockCredentialManager {
    store: Arc<Mutex<HashMap<(String, String), String>>>,
}

impl MockCredentialManager {
    fn new() -> Self {
        Self::default()
    }

    fn stored_count(&self) -> usize {
        self.store.lock().unwrap().len()
    }

    fn get(&self, service: &str, account: &str) -> Option<String> {
        self.store
            .lock()
            .unwrap()
            .get(&(service.to_owned(), account.to_owned()))
            .cloned()
    }

    fn put(&self, account: &str, value: &str) {
        self.store.lock().unwrap().insert(
            (FAE_SKILLS_KEYCHAIN_SERVICE.to_owned(), account.to_owned()),
            value.to_owned(),
        );
    }
}

impl CredentialManager for MockCredentialManager {
    fn store(&self, account: &str, value: &str) -> Result<CredentialRef, CredentialError> {
        self.store.lock().unwrap().insert(
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
            CredentialRef::Keychain { service, account } => (service.as_str(), account.as_str()),
            CredentialRef::Plaintext(v) => return Ok(Some(v.clone())),
            CredentialRef::None => return Ok(None),
        };
        Ok(self
            .store
            .lock()
            .unwrap()
            .get(&(service.to_owned(), account.to_owned()))
            .cloned())
    }

    fn delete(&self, cred_ref: &CredentialRef) -> Result<(), CredentialError> {
        let (service, account) = match cred_ref {
            CredentialRef::Keychain { service, account } => (service.as_str(), account.as_str()),
            _ => return Ok(()),
        };
        self.store
            .lock()
            .unwrap()
            .remove(&(service.to_owned(), account.to_owned()));
        Ok(())
    }
}

// ── Schema helpers ─────────────────────────────────────────────────────────────

fn required(name: &str, env_var: &str) -> CredentialSchema {
    CredentialSchema {
        name: name.to_owned(),
        env_var: env_var.to_owned(),
        description: format!("Your {name}"),
        required: true,
        default: None,
    }
}

fn optional_with_default(name: &str, env_var: &str, default: &str) -> CredentialSchema {
    CredentialSchema {
        name: name.to_owned(),
        env_var: env_var.to_owned(),
        description: format!("Optional {name}"),
        required: false,
        default: Some(default.to_owned()),
    }
}

// ── Test: full collect → retrieve → inject cycle ───────────────────────────────

#[test]
fn full_collect_retrieve_inject_cycle() {
    let manager = MockCredentialManager::new();
    let schema = vec![
        required("bot_token", "DISCORD_BOT_TOKEN"),
        optional_with_default("guild_id", "DISCORD_GUILD_ID", "0"),
    ];

    // Collect phase: user provides bot_token, guild_id omitted (uses default).
    let mut values = HashMap::new();
    values.insert("bot_token".to_owned(), "xoxb-supersecret".to_owned());

    let collection = collect_skill_credentials("discord", &schema, &values, &manager)
        .expect("collect should succeed");

    assert_eq!(collection.skill_id, "discord");
    // bot_token collected from values; guild_id uses default.
    assert_eq!(collection.credentials.len(), 2);

    // Retrieve phase: load from store.
    let retrieved =
        retrieve_skill_credentials("discord", &schema, &manager).expect("retrieve should succeed");

    // bot_token should come from Keychain; guild_id from default.
    assert_eq!(retrieved.credentials.len(), 2);
    let tok = retrieved
        .credentials
        .iter()
        .find(|c| c.env_var == "DISCORD_BOT_TOKEN")
        .expect("DISCORD_BOT_TOKEN");
    assert_eq!(tok.value, "xoxb-supersecret");

    // Inject phase.
    let mut env = HashMap::new();
    retrieved.inject_into(&mut env);
    assert_eq!(
        env.get("DISCORD_BOT_TOKEN").map(String::as_str),
        Some("xoxb-supersecret")
    );
    assert_eq!(env.get("DISCORD_GUILD_ID").map(String::as_str), Some("0"));
}

// ── Test: clear removes all credential entries ─────────────────────────────────

#[test]
fn clear_removes_all_credential_entries() {
    let manager = MockCredentialManager::new();
    manager.put("discord.bot_token", "xoxb-secret");
    manager.put("discord.guild_id", "12345");
    assert_eq!(manager.stored_count(), 2);

    let schema = vec![
        required("bot_token", "DISCORD_BOT_TOKEN"),
        optional_with_default("guild_id", "DISCORD_GUILD_ID", "0"),
    ];

    clear_skill_credentials("discord", &schema, &manager).expect("clear");
    assert_eq!(manager.stored_count(), 0);
}

// ── Test: missing required credential fails collect ────────────────────────────

#[test]
fn missing_required_credential_fails() {
    let manager = MockCredentialManager::new();
    let schema = vec![required("api_key", "MY_API_KEY")];
    let values = HashMap::new(); // no values provided

    let result = collect_skill_credentials("my-skill", &schema, &values, &manager);
    assert!(result.is_err());
    let msg = result.unwrap_err().to_string();
    assert!(msg.contains("api_key"), "expected api_key in error: {msg}");
    // Nothing should be stored.
    assert_eq!(manager.stored_count(), 0);
}

// ── Test: optional credential uses default when not provided ───────────────────

#[test]
fn optional_credential_uses_default() {
    let manager = MockCredentialManager::new();
    let schema = vec![optional_with_default("timeout_ms", "TIMEOUT_MS", "5000")];
    let values = HashMap::new();

    let collection =
        collect_skill_credentials("my-skill", &schema, &values, &manager).expect("collect");

    assert_eq!(collection.credentials.len(), 1);
    assert_eq!(collection.credentials[0].env_var, "TIMEOUT_MS");
    assert_eq!(collection.credentials[0].value, "5000");
    // Default values are NOT persisted to Keychain.
    assert_eq!(manager.stored_count(), 0);
}

// ── Test: inject_into sets env vars ───────────────────────────────────────────

#[test]
fn inject_into_sets_env_vars() {
    let manager = MockCredentialManager::new();
    let schema = vec![
        required("token_a", "TOKEN_A"),
        required("token_b", "TOKEN_B"),
    ];
    let mut values = HashMap::new();
    values.insert("token_a".to_owned(), "value-a".to_owned());
    values.insert("token_b".to_owned(), "value-b".to_owned());

    let collection =
        collect_skill_credentials("skill", &schema, &values, &manager).expect("collect");

    let mut env = HashMap::new();
    env.insert("PREEXISTING".to_owned(), "stays".to_owned());
    collection.inject_into(&mut env);

    assert_eq!(env.get("TOKEN_A").map(String::as_str), Some("value-a"));
    assert_eq!(env.get("TOKEN_B").map(String::as_str), Some("value-b"));
    assert_eq!(env.get("PREEXISTING").map(String::as_str), Some("stays"));
}

// ── Test: collect overwrites existing credential ───────────────────────────────

#[test]
fn collect_overwrites_existing_credential() {
    let manager = MockCredentialManager::new();
    let schema = vec![required("token", "MY_TOKEN")];

    let mut v1 = HashMap::new();
    v1.insert("token".to_owned(), "first-value".to_owned());
    collect_skill_credentials("skill", &schema, &v1, &manager).expect("first collect");

    assert_eq!(
        manager.get(FAE_SKILLS_KEYCHAIN_SERVICE, "skill.token"),
        Some("first-value".to_owned())
    );

    let mut v2 = HashMap::new();
    v2.insert("token".to_owned(), "second-value".to_owned());
    let coll = collect_skill_credentials("skill", &schema, &v2, &manager).expect("second collect");

    assert_eq!(coll.credentials[0].value, "second-value");
    assert_eq!(
        manager.get(FAE_SKILLS_KEYCHAIN_SERVICE, "skill.token"),
        Some("second-value".to_owned())
    );
}

// ── Test: invalid credential name rejected by manifest validation ──────────────

#[test]
fn invalid_credential_name_rejected_by_manifest_validation() {
    let schema = CredentialSchema {
        name: "Bad-Name".to_owned(), // hyphens not allowed in name
        env_var: "VALID_VAR".to_owned(),
        description: "desc".to_owned(),
        required: true,
        default: None,
    };

    let result = schema.validate();
    assert!(result.is_err());
    let msg = result.unwrap_err().to_string();
    assert!(
        msg.contains("name"),
        "expected name validation error, got: {msg}"
    );
}

// ── Test: check_stored shows correct status ────────────────────────────────────

#[test]
fn check_stored_credentials_shows_correct_status() {
    let manager = MockCredentialManager::new();
    manager.put("discord.bot_token", "xoxb");

    let schema = vec![
        required("bot_token", "DISCORD_BOT_TOKEN"),
        required("api_key", "DISCORD_API_KEY"),
    ];

    let statuses = check_stored_credentials("discord", &schema, &manager).expect("check");

    assert_eq!(statuses.len(), 2);

    let bot = statuses
        .iter()
        .find(|s| s.name == "bot_token")
        .expect("bot_token");
    assert!(bot.is_stored);
    assert!(bot.required);
    assert_eq!(bot.env_var, "DISCORD_BOT_TOKEN");

    let api = statuses
        .iter()
        .find(|s| s.name == "api_key")
        .expect("api_key");
    assert!(!api.is_stored);
    assert!(api.required);
}

// ── Test: retrieve missing required returns error ──────────────────────────────

#[test]
fn retrieve_missing_required_returns_error() {
    let manager = MockCredentialManager::new();
    let schema = vec![required("secret_key", "SECRET_KEY")];

    let result = retrieve_skill_credentials("my-skill", &schema, &manager);
    assert!(result.is_err());
    let msg = result.unwrap_err().to_string();
    assert!(
        msg.contains("secret_key"),
        "expected secret_key in error: {msg}"
    );
}
