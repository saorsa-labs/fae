# Phase 5.2: API Key Unification — Drop saorsa-ai Provider Layer

> Replace saorsa-ai's provider configuration with Pi's `~/.pi/agent/models.json`
> as the single source of truth for AI provider config. Keep saorsa-ai as a
> transitive dependency (required by saorsa-agent for trait definitions only).

## Task 1: Remove MistralrsProvider/MistralrsConfig usage from agent

**Files**: `src/agent/mod.rs`, `Cargo.toml`

**Requirements**:
- In `src/agent/mod.rs`, remove the `use saorsa_ai::{MistralrsConfig, MistralrsProvider, StreamingProvider}` import
- Use `ToolingMistralrsProvider` for ALL tool modes (including `AgentToolMode::Off`)
- Import `StreamingProvider` from `saorsa_ai` only for the trait definition
- In Cargo.toml, change `saorsa-ai` to `{ version = "0.4", default-features = false }` — drop the `mistralrs` feature (we already depend on mistralrs directly)
- Verify `just lint && just test` passes

**Acceptance**: No more `MistralrsProvider` or `MistralrsConfig` imports. Only `StreamingProvider` trait needed from saorsa-ai.

---

## Task 2: Create PiProviderConfig — models.json reader for provider selection

**Files**: `src/llm/pi_config.rs`

**Requirements**:
- Extend existing `PiModelsConfig` with helper methods for provider resolution
- Add `PiModelsConfig::find_provider(name: &str) -> Option<&PiProvider>`
- Add `PiModelsConfig::find_model(provider: &str, model_id: &str) -> Option<&PiModel>`
- Add `PiModelsConfig::list_providers() -> Vec<&str>`
- Add `PiModelsConfig::cloud_providers() -> Vec<(&str, &PiProvider)>` (excludes fae-local)
- Tests: provider lookup, cloud filter, missing provider returns None

**Acceptance**: models.json can be queried for provider configs.

---

## Task 3: Create OpenAI-compatible HTTP streaming provider

**Files**: `src/agent/http_provider.rs`, `src/agent/mod.rs`

**Requirements**:
- Create `HttpStreamingProvider` implementing `saorsa_ai::StreamingProvider`
- Takes base_url, api_key, model_id in constructor
- Uses `ureq` (already a dep) for non-streaming, `reqwest-eventsource` or raw SSE for streaming
- Actually: use the existing `ureq` + tokio::spawn + SSE parsing approach
- Converts between saorsa_ai types and OpenAI API format
- Handles SSE streaming (parse `data: {...}` lines, emit StreamEvents)
- Register `pub mod http_provider;` in `src/agent/mod.rs`
- Tests: constructor, request building (mocked HTTP not needed for unit tests)

**Acceptance**: HttpStreamingProvider can talk to any OpenAI-compatible API.

---

## Task 4: Wire provider selection from models.json into agent

**Files**: `src/agent/mod.rs`, `src/config.rs`

**Requirements**:
- Add `cloud_provider: Option<String>` to `LlmConfig` (provider name from models.json)
- Add `cloud_model: Option<String>` to `LlmConfig` (model ID within that provider)
- In `SaorsaAgentLlm::new()`, when `LlmBackend::Api` is selected:
  - Read `~/.pi/agent/models.json`
  - Look up the provider from `cloud_provider` config
  - Create `HttpStreamingProvider` with base_url, api_key, model_id from models.json
- When `LlmBackend::Local` or `LlmBackend::Agent`: use ToolingMistralrsProvider (existing)
- Tests: provider selection logic

**Acceptance**: Agent can use cloud providers configured in models.json.

---

## Task 5: Clean up saorsa-ai imports and minimize dependency

**Files**: `src/agent/mod.rs`, `src/agent/local_provider.rs`, `Cargo.toml`

**Requirements**:
- Audit all `saorsa_ai::` imports across the codebase
- Minimize to only trait definitions needed: `StreamingProvider`, `Provider`, types
- Remove any saorsa-ai-specific configuration usage
- Ensure `saorsa-ai` in Cargo.toml has `default-features = false` (no mistralrs feature)
- Update module doc comments to reflect the new provider architecture
- Run `just check` (full validation)

**Acceptance**: saorsa-ai used ONLY for trait definitions required by saorsa-agent.

---

## Task 6: Add fallback provider chain

**Files**: `src/agent/mod.rs`

**Requirements**:
- Implement provider fallback: local mistralrs → cloud from models.json
- When local model fails to load, check models.json for available cloud providers
- Log which provider is being used
- Add `LlmConfig::effective_provider_name() -> String` for display
- Tests: fallback logic

**Acceptance**: If local model unavailable, agent can fall back to cloud provider.

---

## Task 7: Update API backend (src/llm/api.rs) to use models.json

**Files**: `src/llm/api.rs`

**Requirements**:
- ApiLlm currently takes api_url/api_model/api_key from LlmConfig
- Add option to resolve these from models.json provider name
- When `cloud_provider` is set in config, look up base_url + api_key from models.json
- Keep backward compatibility (direct api_url still works)
- Tests: provider resolution from models.json

**Acceptance**: ApiLlm can read connection details from either config or models.json.

---

## Task 8: Integration tests and documentation

**Files**: `tests/llm_server.rs`, `src/agent/mod.rs`, `src/llm/pi_config.rs`

**Requirements**:
- Add tests for provider selection from models.json
- Add tests for HttpStreamingProvider type construction
- Update doc comments on all modified public items
- Ensure `just check` passes (fmt, lint, build, test, doc)
- Verify no regression in existing tests

**Acceptance**: All tests pass, documentation updated, zero warnings.
