# Phase A.3: Credential Security

## Objective
Remove plaintext credential storage from config.toml by integrating macOS Keychain for secure storage of API keys, bot tokens, and other sensitive values. Provide encrypted fallback storage for non-macOS platforms.

## Problem
Current configuration stores sensitive credentials in plaintext within `~/.config/fae/config.toml`:
- `LlmConfig.api_key` — LLM provider API keys (OpenAI, Anthropic, etc.)
- `DiscordChannelConfig.bot_token` — Discord bot authentication
- `WhatsAppChannelConfig.access_token` — WhatsApp Business Cloud API
- `WhatsAppChannelConfig.verify_token` — WhatsApp webhook verification
- `ChannelGatewayConfig.bearer_token` — Generic webhook auth

This violates App Store security requirements and exposes credentials to filesystem access. Under macOS App Sandbox, credentials should be stored in Keychain Services (encrypted, access-controlled by OS).

## Strategy

1. **Add keychain crate** — Use `security-framework` (already in deps from Phase A.1) for macOS Keychain access
2. **Create credential manager** — Abstract credential storage with platform-specific backends
3. **Migrate config fields** — Replace plaintext String with credential references
4. **Implement keychain backend** — Store/retrieve credentials via macOS Keychain Services
5. **Implement encrypted fallback** — For non-macOS platforms, use OS-agnostic credential storage
6. **Add migration path** — Detect plaintext credentials in config, offer automatic migration to keychain
7. **Update config loading** — Transparently load credentials from keychain during startup
8. **Secure deletion** — Ensure old plaintext values are cleared after migration

## Success Criteria
- Zero plaintext credentials in config.toml after migration
- Credentials stored in macOS Keychain on macOS (Keychain Access.app visible)
- Credentials stored in encrypted form on other platforms
- Config loading transparently retrieves credentials
- Migration path preserves functionality
- All existing tests pass
- New tests verify credential isolation

## Tasks

### Task 1: Add credential manager types and trait
- **Description**: Define the core types and trait for credential management
- **Files**:
  - `src/credentials/mod.rs` — new module with public API
  - `src/credentials/types.rs` — credential reference types
  - `src/lib.rs` — add `pub mod credentials;`
- **Changes**:
  1. Create `src/credentials/mod.rs` with `CredentialManager` trait
  2. Define `CredentialRef` enum: `Keychain { service, account }`, `Plaintext(String)`, `None`
  3. Define `CredentialManager::store(key, value) -> Result<CredentialRef>`
  4. Define `CredentialManager::retrieve(ref) -> Result<Option<String>>`
  5. Define `CredentialManager::delete(ref) -> Result<()>`
  6. Add error type `CredentialError` with thiserror
  7. Wire module into `src/lib.rs`
- **Verification**: `cargo check` passes
- **Tests**: Unit tests for CredentialRef serialization (serde round-trip)

### Task 2: Implement macOS Keychain backend
- **Description**: Use security-framework to access macOS Keychain Services
- **Files**:
  - `src/credentials/keychain.rs` — macOS Keychain implementation
  - `src/credentials/mod.rs` — add factory function
- **Changes**:
  1. Create `KeychainCredentialManager` struct
  2. Implement `CredentialManager::store()` using `security_framework::passwords::set_generic_password()`
  3. Implement `CredentialManager::retrieve()` using `security_framework::passwords::find_generic_password()`
  4. Implement `CredentialManager::delete()` using `security_framework::passwords::delete_generic_password()`
  5. Service name: `"com.saorsalabs.fae"` for all credentials
  6. Account name: credential-specific (e.g. `"llm.api_key"`, `"discord.bot_token"`)
  7. Add `#[cfg(target_os = "macos")]` guards
  8. Factory function: `create_manager() -> Box<dyn CredentialManager>`
- **Verification**: Compile on macOS, manual test with Keychain Access.app
- **Tests**: Integration test (marked `#[ignore]`) that stores/retrieves/deletes a test credential

### Task 3: Implement encrypted fallback backend
- **Description**: For non-macOS platforms, use encrypted credential storage with keyring crate
- **Files**:
  - `Cargo.toml` — add `keyring` crate
  - `src/credentials/encrypted.rs` — encrypted storage implementation
  - `src/credentials/mod.rs` — update factory for other platforms
- **Changes**:
  1. Add `keyring = "3.5"` to `Cargo.toml` dependencies
  2. Create `EncryptedCredentialManager` struct using `keyring::Entry`
  3. Implement `store()` using `Entry::set_password()`
  4. Implement `retrieve()` using `Entry::get_password()`
  5. Implement `delete()` using `Entry::delete_credential()`
  6. Service name: `"fae-credentials"`
  7. Add `#[cfg(not(target_os = "macos"))]` guards
  8. Update factory to return encrypted backend on non-macOS
- **Verification**: Compile on Linux/Windows (if available), otherwise stub test
- **Tests**: Unit test for backend creation (may require mock or ignore)

### Task 4: Update config types with CredentialRef
- **Description**: Replace sensitive String fields with CredentialRef in config structs
- **Files**:
  - `src/config.rs` — LlmConfig, DiscordChannelConfig, WhatsAppChannelConfig, ChannelGatewayConfig
  - `src/credentials/types.rs` — helper functions for config migration
- **Changes**:
  1. Change `LlmConfig.api_key: String` to `api_key: CredentialRef`
  2. Change `DiscordChannelConfig.bot_token: String` to `bot_token: CredentialRef`
  3. Change `WhatsAppChannelConfig.access_token: String` to `access_token: CredentialRef`
  4. Change `WhatsAppChannelConfig.verify_token: String` to `verify_token: CredentialRef`
  5. Change `ChannelGatewayConfig.bearer_token: Option<String>` to `bearer_token: Option<CredentialRef>`
  6. Update `Default` impls to use `CredentialRef::None`
  7. Add serde `skip_serializing_if` for `CredentialRef::None` variants
  8. Add backward-compatibility serde aliases for old String fields
- **Verification**: `cargo check` passes (compilation only, runtime broken until next task)
- **Tests**: Config serialization test with CredentialRef variants

### Task 5: Implement credential loading during config initialization
- **Description**: Load actual credential values from keychain/encrypted storage when config is loaded
- **Files**:
  - `src/config.rs` — add `load_credentials()` method
  - `src/credentials/mod.rs` — add runtime context for credential manager
- **Changes**:
  1. Add `SpeechConfig::load_credentials(&self, manager: &dyn CredentialManager) -> Result<LoadedCredentials>`
  2. Create `LoadedCredentials` struct with actual String values
  3. For each CredentialRef field, call `manager.retrieve()` and populate LoadedCredentials
  4. Return error if required credentials are missing
  5. Update main config loading flow to call `load_credentials()` after deserializing
  6. Cache loaded credentials in runtime state (not persisted)
  7. Update LLM runtime, channel adapters to use LoadedCredentials instead of direct field access
- **Verification**: App starts successfully, loads credentials from keychain
- **Tests**: Unit test for `load_credentials()` with mock manager

### Task 6: Add credential migration tool
- **Description**: Detect plaintext credentials in config and automatically migrate to keychain
- **Files**:
  - `src/credentials/migration.rs` — migration logic
  - `src/bin/fae.rs` or `src/bin/gui.rs` — trigger migration on first run
- **Changes**:
  1. Add `detect_plaintext_credentials(config: &SpeechConfig) -> Vec<PlaintextCredential>`
  2. For each String-based credential field, check if it's non-empty
  3. Add `migrate_to_keychain(config: &mut SpeechConfig, manager: &dyn CredentialManager) -> Result<usize>`
  4. For each plaintext credential:
     - Call `manager.store(account, value)` to save to keychain
     - Replace config field with returned `CredentialRef::Keychain { service, account }`
     - Zero out the original plaintext value
  5. Save updated config.toml after migration
  6. Log migration count and credential types migrated
  7. On startup, check for plaintext credentials and auto-migrate if found
- **Verification**: Load config with plaintext tokens, verify they move to keychain and config.toml is updated
- **Tests**: Integration test (marked `#[ignore]`) with temporary config file

### Task 7: Update LLM and channel runtime credential access
- **Description**: Ensure all runtime components use LoadedCredentials instead of direct config field access
- **Files**:
  - `src/llm_agent.rs` — update API client initialization
  - `src/channels/discord.rs` — update Discord bot initialization
  - `src/channels/whatsapp.rs` — update WhatsApp client initialization
  - `src/channels/gateway.rs` — update webhook auth
- **Changes**:
  1. Update LLM agent to accept LoadedCredentials or explicit api_key parameter
  2. Update Discord adapter to accept LoadedCredentials or explicit bot_token
  3. Update WhatsApp adapter to accept LoadedCredentials or explicit access/verify tokens
  4. Update gateway to accept LoadedCredentials or explicit bearer token
  5. Remove direct `config.channels.discord.bot_token` accesses (replace with credential param)
  6. Ensure all credential access goes through LoadedCredentials
  7. Add runtime validation: return error if required credential is missing
- **Verification**: Channel runtime starts successfully with keychain credentials
- **Tests**: Update existing tests to provide mock LoadedCredentials

### Task 8: Add secure deletion and documentation
- **Description**: Ensure plaintext values are securely cleared, add credential management docs
- **Files**:
  - `src/credentials/migration.rs` — secure deletion utilities
  - `CLAUDE.md` — document credential architecture
  - `src/credentials/mod.rs` — API documentation
- **Changes**:
  1. Add `secure_clear(s: &mut String)` utility that overwrites memory before drop
  2. Use `secure_clear()` after migrating plaintext credentials to keychain
  3. Add `CredentialManager::clear_all() -> Result<()>` for testing cleanup
  4. Document credential storage architecture in CLAUDE.md
  5. Add public API documentation on all credential types and functions
  6. Add example: "How to manually set a credential in keychain"
  7. Add example: "How to migrate from plaintext config"
  8. Update config validation to check for credential ref validity
- **Verification**: Full app startup with credentials from keychain, zero plaintext in config
- **Tests**: Test secure_clear() zeros memory, test full migration flow

## Quality Gates
All tasks must pass:
- `cargo fmt --all -- --check`
- `cargo clippy --all-features -- -D warnings`
- `cargo nextest run --all-features`
- All public credential API items documented
- Zero plaintext credentials in config after migration
- Manual test: credentials visible in macOS Keychain Access.app

## Dependencies
- `security-framework` — already in Cargo.toml from Phase A.1
- `keyring` — add for cross-platform encrypted storage
