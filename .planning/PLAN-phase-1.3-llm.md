# Phase 1.3: Config Schema & Persistence

## Goal
Implement the fae_llm configuration system with TOML schema, atomic persistence, round-trip editing, secret resolution, and validation.

## Current State
- fae_llm module exists with foundation types (EndpointType, ModelRef, RequestOptions, LlmEvent, FaeLlmError)
- No config system yet
- Need TOML-based config with:
  - Multi-provider support (OpenAI, Anthropic, local, z.ai, MiniMax, DeepSeek)
  - Secret resolution (none, env, literal, command, keychain)
  - Tool definitions and modes (read_only vs full)
  - Atomic write with backup
  - Round-trip safety (preserve comments/unknown fields)

## Technical Decisions
- Config format: TOML with `toml_edit` crate for round-trip safety
- Secret modes: none, env, literal (dev), command (off by default), keychain
- Tool set: read, bash, edit, write (4 tools, stable names)
- Tool modes: read_only, full (2 modes only)
- Atomic writes: temp file → fsync → atomic rename
- Backup: Keep last-known-good config

## Tasks

### Task 1: Define config schema types
Create src/fae_llm/config/types.rs with config schema structs.
- `FaeLlmConfig` root struct with providers, models, tools, defaults, runtime sections
- `ProviderConfig` with endpoint_type, base_url, api_key (SecretRef), models list
- `ModelConfig` with model_id, display_name, tier (fast/balanced/reasoning), max_tokens
- `ToolConfig` with name, enabled flag, tool-specific options
- `DefaultsConfig` with default_provider, default_model, tool_mode (read_only/full)
- `RuntimeConfig` with request_timeout, max_retries, log_level
- `SecretRef` enum: None, Env(String), Literal(String), Command(String), Keychain(String)
- All structs derive Serialize, Deserialize, Debug, Clone
- Add unit tests for each struct (basic construction)
- **Files:** `src/fae_llm/config/types.rs`, `src/fae_llm/config/mod.rs`

### Task 2: Implement SecretRef resolution
Add secret resolution logic to config/types.rs.
- `SecretRef::resolve(&self) -> Result<Option<String>, FaeLlmError>` method
- Env: read from environment variable, return ConfigError::MissingEnvVar if not found
- Literal: return the string directly (warn in docs this is for dev only)
- Command: return ConfigError::CommandNotAllowed by default (feature-gated)
- Keychain: return ConfigError::KeychainNotImplemented for now (placeholder)
- None: return Ok(None)
- Add unit tests for each variant (mock env vars with temp_env crate or similar)
- **Files:** `src/fae_llm/config/types.rs`

### Task 3: Implement atomic config file operations
Create src/fae_llm/config/persist.rs with atomic read/write.
- `read_config(path: &Path) -> Result<FaeLlmConfig, FaeLlmError>`
  - Read TOML file, deserialize via `toml::from_str`
  - Return ConfigError::NotFound, ParseError on failures
- `write_config_atomic(path: &Path, config: &FaeLlmConfig) -> Result<(), FaeLlmError>`
  - Serialize to TOML string via `toml::to_string`
  - Write to temp file (path + ".tmp")
  - Call fsync on temp file
  - Atomic rename temp to target path
  - Return ConfigError::WriteError on failures
- `backup_config(path: &Path) -> Result<(), FaeLlmError>`
  - Copy current config to path + ".backup"
- Add unit tests with tempfile crate (atomic write, backup)
- **Files:** `src/fae_llm/config/persist.rs`

### Task 4: Implement round-trip TOML editing with toml_edit
Create src/fae_llm/config/editor.rs with round-trip editing.
- `ConfigEditor` struct wrapping `toml_edit::Document`
- `ConfigEditor::load(path: &Path) -> Result<Self, FaeLlmError>` - load with toml_edit
- `ConfigEditor::get<T>(&self, key_path: &str) -> Result<T, FaeLlmError>` - read value by dotted path
- `ConfigEditor::set(&mut self, key_path: &str, value: impl Into<toml_edit::Value>) -> Result<(), FaeLlmError>` - update value preserving comments
- `ConfigEditor::save(&self, path: &Path) -> Result<(), FaeLlmError>` - atomic write via persist.rs
- Add dependency: `toml_edit = "0.22"` to Cargo.toml
- Add unit tests for get/set/round-trip (comments preserved)
- **Files:** `src/fae_llm/config/editor.rs`, `Cargo.toml`

### Task 5: Implement ConfigService with validation
Create src/fae_llm/config/service.rs with ConfigService API.
- `ConfigService` struct with path field and cached config (Arc<RwLock<FaeLlmConfig>>)
- `ConfigService::new(path: PathBuf) -> Self`
- `ConfigService::load(&self) -> Result<FaeLlmConfig, FaeLlmError>` - read, validate, cache
- `ConfigService::reload(&self) -> Result<(), FaeLlmError>` - force reload from disk
- `ConfigService::get(&self) -> FaeLlmConfig` - return cached clone
- `ConfigService::update<F>(&self, f: F) -> Result<(), FaeLlmError> where F: FnOnce(&mut FaeLlmConfig)` - update with function, validate, backup, write
- `validate_config(config: &FaeLlmConfig) -> Result<(), FaeLlmError>` - check required fields, provider references
- Add unit tests for load, update, validation errors
- **Files:** `src/fae_llm/config/service.rs`

### Task 6: Add safe partial update API for app menu
Add methods to ConfigService for common app-menu updates.
- `update_provider(&self, provider_id: &str, updates: ProviderUpdate) -> Result<(), FaeLlmError>`
- `update_model(&self, model_id: &str, updates: ModelUpdate) -> Result<(), FaeLlmError>`
- `set_default_provider(&self, provider_id: &str) -> Result<(), FaeLlmError>`
- `set_default_model(&self, model_id: &str) -> Result<(), FaeLlmError>`
- `set_tool_mode(&self, mode: ToolMode) -> Result<(), FaeLlmError>`
- `ProviderUpdate` and `ModelUpdate` structs with Option<T> fields (partial updates)
- Each method validates before applying (e.g., provider/model exists)
- Add unit tests for each update method
- **Files:** `src/fae_llm/config/service.rs`, `src/fae_llm/config/types.rs`

### Task 7: Add default config generation
Create src/fae_llm/config/defaults.rs with default config factory.
- `default_config() -> FaeLlmConfig` - returns sensible defaults
  - OpenAI provider with gpt-4o model (api_key from env)
  - Anthropic provider with claude-sonnet-4.5 model (api_key from env)
  - Local provider with localhost:8080 endpoint (no api_key)
  - All 4 tools enabled, tool_mode = read_only
  - Reasonable timeouts (30s request, 3 retries)
- `ensure_config_exists(path: &Path) -> Result<(), FaeLlmError>` - create default if missing
- Add comments to generated TOML explaining each section
- Add unit tests for default config structure
- **Files:** `src/fae_llm/config/defaults.rs`

### Task 8: Integration tests and documentation
Add integration tests and module-level documentation.
- Integration test: full config lifecycle (create default, load, update, reload, verify round-trip)
- Integration test: secret resolution (env vars, literal)
- Integration test: validation errors (invalid provider refs, missing required fields)
- Integration test: atomic write recovery (simulate crash, verify backup)
- Add module-level docs to config/mod.rs explaining architecture
- Add examples in docs for common operations
- Add rustdoc examples that compile (doc tests)
- Run `just check` to verify zero warnings
- **Files:** `src/fae_llm/config/mod.rs`, `tests/config_integration.rs`

## Dependencies to Add
- `toml = "0.8"` - TOML serialization
- `toml_edit = "0.22"` - Round-trip TOML editing
- Dev dependencies: `tempfile = "3.10"` for tests

## Success Criteria
- Zero clippy warnings, zero compilation warnings
- All unit and integration tests pass
- Config can be read, updated, and written while preserving comments
- Atomic writes ensure no corruption on crash
- Secret resolution works for env and literal modes
- Safe partial update API prevents invalid states
- Default config generation works for first-run
