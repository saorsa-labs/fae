# Phase 8.4: Credential Mediation

## Goal

Python skills need API keys, tokens, and passwords but must never see or store raw secrets.
This phase adds:
- Credential schema in `manifest.toml` (`[[credentials]]` table)
- Secure Keychain storage keyed by `{service}.{skill_id}.{name}`
- `collect_skill_credentials()` — interactive collection flow (prompts in plain English)
- `inject_skill_credentials()` — secure env var injection into `SkillProcessConfig`
- Host command wiring: `skill.credential.collect` and `skill.credential.clear`
- Integration tests (no real Keychain access — use in-memory mock)

## Architecture

```
manifest.toml
  [[credentials]]
  name = "bot_token"
  env_var = "DISCORD_BOT_TOKEN"
  description = "Your Discord bot token"
  required = true

↓

CredentialSchema (in manifest)
  - name, env_var, description, required, default

↓

collect_skill_credentials(skill_id, schema, manager)
  - for each required credential not yet stored → prompt user
  - stores via manager.store("com.saorsalabs.fae.skills", "{skill_id}.{name}", value)
  - returns CredentialCollection { credentials: Vec<CollectedCredential> }

↓

inject_skill_credentials(collection, config: &mut SkillProcessConfig)
  - injects env vars into config.env_overrides
  - Python subprocess inherits these; raw Keychain never exposed

↓

Host commands: skill.credential.collect / skill.credential.clear
```

## Tasks

### Task 1: CredentialSchema type + manifest integration

**File**: `src/skills/manifest.rs`

Add `CredentialSchema` struct:
```rust
pub struct CredentialSchema {
    pub name: String,           // identifier (lowercase, underscore)
    pub env_var: String,        // env var name to inject (UPPERCASE_WITH_UNDERSCORES)
    pub description: String,    // plain English prompt for user
    pub required: bool,         // default true
    pub default: Option<String>, // optional default value
}
```

Update `PythonSkillManifest`:
- Add `pub credentials: Vec<CredentialSchema>`
- Default to empty Vec

Add `validate()` extensions:
- `name` must be `[a-z0-9_]+`, non-empty
- `env_var` must be `[A-Z0-9_]+`, non-empty

Tests:
- Parse manifest with `[[credentials]]` table
- Validate invalid credential name chars
- Validate invalid env_var chars
- Default credentials to empty vec

### Task 2: CredentialMediator trait + SkillCredentialStore

**File**: `src/skills/credential_mediation.rs` (new)

```rust
pub const FAE_SKILLS_KEYCHAIN_SERVICE: &str = "com.saorsalabs.fae.skills";

/// Account key for Keychain storage.
pub fn credential_account(skill_id: &str, name: &str) -> String {
    format!("{skill_id}.{name}")
}

/// A single collected credential ready for injection.
pub struct CollectedCredential {
    pub env_var: String,
    pub value: String,  // never exposed outside inject path
}

/// Result of credential collection for a skill.
pub struct CredentialCollection {
    pub skill_id: String,
    pub credentials: Vec<CollectedCredential>,
}

impl CredentialCollection {
    /// Injects credential values as environment variables into process config.
    pub fn inject_into(&self, env: &mut std::collections::HashMap<String, String>)
}

/// Checks which credentials are already stored.
pub fn check_stored_credentials(
    skill_id: &str,
    schema: &[CredentialSchema],
    manager: &dyn CredentialManager,
) -> Vec<CredentialStatus>

pub struct CredentialStatus {
    pub name: String,
    pub env_var: String,
    pub is_stored: bool,
    pub required: bool,
}

/// Collects credentials that are not yet stored, using provided values.
/// In production: values come from user dialog.
/// In tests: values passed directly.
pub fn collect_skill_credentials(
    skill_id: &str,
    schema: &[CredentialSchema],
    values: &std::collections::HashMap<String, String>,  // name → value
    manager: &dyn CredentialManager,
) -> Result<CredentialCollection, CredentialMediationError>

/// Retrieves all stored credentials for a skill and builds a CredentialCollection.
pub fn retrieve_skill_credentials(
    skill_id: &str,
    schema: &[CredentialSchema],
    manager: &dyn CredentialManager,
) -> Result<CredentialCollection, CredentialMediationError>

/// Clears all stored credentials for a skill from the Keychain.
pub fn clear_skill_credentials(
    skill_id: &str,
    schema: &[CredentialSchema],
    manager: &dyn CredentialManager,
) -> Result<(), CredentialMediationError>

pub enum CredentialMediationError {
    MissingRequired { name: String },
    StorageError(CredentialError),
    InvalidName(String),
}
```

Tests (all use `MockCredentialManager` — no real Keychain):
- `collect_stores_credentials_in_keychain`
- `collect_missing_required_returns_error`
- `retrieve_loads_all_credentials`
- `retrieve_missing_optional_uses_default`
- `retrieve_missing_required_returns_error`
- `clear_deletes_all_stored_credentials`
- `check_stored_shows_missing_and_present`
- `inject_into_adds_env_vars`

### Task 3: env_overrides in SkillProcessConfig

**File**: `src/skills/python_runner.rs`

Add `env_overrides: HashMap<String, String>` to `SkillProcessConfig`.
Default to empty map.

In `spawn()`: merge `env_overrides` into `tokio::process::Command` via `.env_remove("...")` + `.env(...)`:
- Do NOT inherit credentials from parent env (start from clean env)
- Inject only the explicitly provided env_overrides

Add doc comment explaining the security model.

Tests (unit, no subprocess):
- `env_overrides_populated_in_config` — struct field accessible and defaults to empty
- `config_with_env_overrides` — can set env var values

### Task 4: Host command wiring

**File**: `src/host/contract.rs`
Add: `SkillCredentialCollect` → `"skill.credential.collect"`
     `SkillCredentialClear`   → `"skill.credential.clear"`

**File**: `src/host/channel.rs`
Add trait methods `python_skill_credential_collect()` and `python_skill_credential_clear()`
Add handler dispatch.

**File**: `src/host/handler.rs`
Implement both methods in `FaeDeviceTransferHandler`:
- `collect`: parse `{"skill_id": "...", "credentials": {"name": "value",...}}` → `collect_skill_credentials` → emit event
- `clear`: parse `{"skill_id": "..."}` → `clear_skill_credentials` → emit event

### Task 5: Integration tests

**File**: `tests/python_skill_credentials.rs` (new)

Tests using `MockCredentialManager` (in-memory HashMap, no Keychain):
- `full_collect_retrieve_inject_cycle`
- `clear_removes_all_credential_entries`
- `missing_required_credential_fails`
- `optional_credential_uses_default`
- `inject_into_sets_env_vars`
- `collect_overwrites_existing_credential`
- `invalid_credential_name_rejected_by_manifest`

## Non-goals

- No real Keychain access in tests (use mock)
- No interactive terminal prompting in this phase (values passed directly)
- No Swift UI changes (credential collection dialog is Phase 8.6+)
- No changes to existing Discord/WhatsApp credential paths

## Files

- `src/skills/manifest.rs` (modified: add CredentialSchema + manifest field)
- `src/skills/credential_mediation.rs` (new)
- `src/skills/mod.rs` (modified: expose new types)
- `src/skills/python_runner.rs` (modified: env_overrides in config)
- `src/host/contract.rs` (modified: 2 new CommandName variants)
- `src/host/channel.rs` (modified: 2 new trait methods + dispatch)
- `src/host/handler.rs` (modified: 2 new handler implementations)
- `tests/python_skill_credentials.rs` (new)
