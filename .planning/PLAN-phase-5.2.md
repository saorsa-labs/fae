# Phase 5.2: API Key Unification — Drop saorsa-ai

## Overview
Remove the `saorsa-ai` dependency. Replace it with direct reading of `~/.pi/agent/models.json` for all AI provider configuration. Fae's agent backend uses a new `PiConfigProvider` that reads from Pi's config file — single source of truth.

## Tasks

### Task 1: Create `src/providers/mod.rs` — provider abstraction
**Files:** `src/providers/mod.rs` (new), `src/lib.rs` (edit)

New module replacing saorsa-ai's provider system:
- `Provider` trait matching what saorsa-agent needs (streaming chat completions)
- `ProviderConfig` struct: name, base_url, api_type, api_key, models
- `ApiType` enum: OpenAiCompletions, OpenAiResponses, AnthropicMessages, Google
- Add `pub mod providers;` to lib.rs

### Task 2: Create `src/providers/pi_config.rs` — read ~/.pi/agent/models.json
**Files:** `src/providers/pi_config.rs` (new)

Parse Pi's models.json:
- `PiModelsConfig` struct with `providers: HashMap<String, ProviderEntry>`
- `ProviderEntry`: baseUrl, api, apiKey, headers, models
- `ModelEntry`: id, name, reasoning, input, contextWindow, maxTokens, cost
- `load_pi_config() -> Result<PiModelsConfig>` reads and deserializes
- `find_provider(name: &str) -> Option<ProviderEntry>` lookup
- Handle missing file gracefully (return empty config)

### Task 3: Create `src/providers/streaming.rs` — streaming provider impl
**Files:** `src/providers/streaming.rs` (new)

Implement the streaming provider that saorsa-agent needs:
- `PiConfigStreamingProvider` wraps a `ProviderConfig`
- For `api: "openai-completions"`: HTTP POST to `{baseUrl}/chat/completions`
- For other API types: translate request format accordingly
- Stream SSE responses, yield token events
- This replaces what `saorsa_ai::MistralrsProvider` and `saorsa_ai::StreamingProvider` did

### Task 4: Replace saorsa-ai in agent module
**Files:** `src/agent/mod.rs`, `src/agent/local_provider.rs`

- Remove `use saorsa_ai::*` imports
- Replace `MistralrsProvider` with local `ToolingMistralrsProvider` (already exists)
- Replace `StreamingProvider` trait usage with new `providers::StreamingProvider`
- Agent now gets its provider from Pi config or local mistralrs — no saorsa-ai

### Task 5: Remove saorsa-ai from Cargo.toml
**Files:** `Cargo.toml`

- Remove `saorsa-ai` dependency line
- Add `reqwest` if not already present (for HTTP provider calls)
- Verify all imports compile without saorsa-ai

### Task 6: Add provider selection logic
**Files:** `src/providers/mod.rs`

Logic for choosing which provider to use:
- If local model loaded (mistralrs) → use local provider (default for voice pipeline)
- If Pi config has cloud providers → available as fallback
- Provider selection: `select_provider(config: &LlmConfig) -> Box<dyn StreamingProvider>`
- Config option to specify preferred provider by name

### Task 7: API key management in GUI settings
**Files:** `src/bin/gui.rs`

Settings panel section for AI providers:
- Read and display providers from `~/.pi/agent/models.json`
- Show: provider name, base URL, model count, has API key (masked)
- Link to `~/.pi/agent/models.json` file location
- Note: "Edit models.json to add/change API keys"

### Task 8: Tests
**Files:** `src/providers/*.rs`

- Parse sample models.json with multiple providers
- Find specific provider by name
- Handle missing/empty models.json
- Streaming provider connects to mock endpoint
- Provider selection logic picks correct provider
- saorsa-ai fully removed, cargo build succeeds

**Acceptance:**
- `saorsa-ai` removed from Cargo.toml
- All AI config read from `~/.pi/agent/models.json`
- Agent works with local mistralrs provider (no cloud keys needed)
- Cloud providers available if configured in Pi's models.json
- `cargo clippy` zero warnings
