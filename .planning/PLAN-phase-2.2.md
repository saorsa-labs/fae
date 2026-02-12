# Phase 2.2: Compatibility Profile Engine

## Overview
Build a profile flag system that allows a single OpenAI-compatible adapter to work
with z.ai, MiniMax, DeepSeek, and local backends (Ollama, llama.cpp, vLLM). Each
provider has quirks (different field names for max_tokens, reasoning mode, tool
format, etc.) that profiles normalize.

## Key Files
- `src/fae_llm/providers/profile.rs` (NEW) -- profile types and flag system
- `src/fae_llm/providers/openai.rs` -- integrate profile-based normalization
- `src/fae_llm/providers/mod.rs` -- wire in profile module

---

## Task 1: Profile flag types
**~100 lines | src/fae_llm/providers/profile.rs**

Define the compatibility profile type system:
- `CompatibilityProfile` struct with all flag fields
- `MaxTokensField` enum: MaxTokens, MaxCompletionTokens
- `ReasoningMode` enum: None, OpenAiO1Style, DeepSeekThinking
- `ToolCallFormat` enum: Standard, ParallelOnly, NoStreaming
- `StopSequenceField` enum: Stop, StopSequences
- Builder pattern: `CompatibilityProfile::new(name)` with `.with_*()` methods
- `CompatibilityProfile::openai_default()` -- standard OpenAI profile
- All types derive Debug, Clone, Serialize, Deserialize
- Unit tests for construction and defaults

## Task 2: Built-in profiles (z.ai, DeepSeek, MiniMax, local)
**~120 lines | src/fae_llm/providers/profile.rs**

Create built-in profile constructors:
- `CompatibilityProfile::zai()` -- z.ai profile (max_completion_tokens, no reasoning)
- `CompatibilityProfile::deepseek()` -- DeepSeek profile (thinking mode, tool differences)
- `CompatibilityProfile::minimax()` -- MiniMax profile (max_tokens, no streaming tools)
- `CompatibilityProfile::ollama()` -- Ollama local (max_tokens, basic tool support)
- `CompatibilityProfile::llamacpp()` -- llama.cpp server (max_tokens, limited tool support)
- `CompatibilityProfile::vllm()` -- vLLM (max_tokens, OpenAI-compatible tools)
- Tests verifying each profile's flags are correctly set

## Task 3: Profile resolution from config
**~80 lines | src/fae_llm/providers/profile.rs**

Implement profile lookup and resolution:
- `resolve_profile(provider_name: &str) -> CompatibilityProfile`
- Match known providers: "openai", "zai", "z.ai", "deepseek", "minimax", "ollama", "llamacpp", "vllm"
- Unknown providers fall back to OpenAI-default profile
- `ProfileRegistry` struct holding custom profiles (for config-based overrides)
- `ProfileRegistry::register(name, profile)` and `ProfileRegistry::resolve(name)`
- Tests for all known providers and fallback behavior

## Task 4: Profile-based request normalization
**~100 lines | src/fae_llm/providers/openai.rs**

Integrate profile into the request builder:
- `apply_profile_to_request(body: &mut serde_json::Value, profile: &CompatibilityProfile)`
- Rename `max_tokens` to `max_completion_tokens` per profile
- Rename `stop` to `stop_sequences` per profile
- Add/remove reasoning parameters based on ReasoningMode
- Adjust tool call format based on ToolCallFormat
- Handle `supports_system_message: false` (merge into first user message)
- Tests verifying each flag correctly transforms the request JSON

## Task 5: Profile-based response normalization
**~80 lines | src/fae_llm/providers/openai.rs**

Integrate profile into response parsing:
- Handle provider-specific finish reason strings (DeepSeek "thinking_done", etc.)
- Normalize usage field variations (some providers nest differently)
- Handle reasoning/thinking blocks based on ReasoningMode
- Map provider-specific error codes to standard errors
- Tests with mock responses from each provider format

## Task 6: OpenAI-compatible adapter with profile
**~100 lines | src/fae_llm/providers/openai.rs**

Extend the adapter to accept a profile:
- `OpenAiConfig` gets optional `profile: Option<CompatibilityProfile>` field
- `OpenAiConfig::with_profile(profile)` builder method
- `OpenAiConfig::for_provider(name, api_key, model)` convenience constructor
  that auto-resolves the profile
- Request building uses profile normalization
- Response parsing uses profile normalization
- Tests: create adapter for z.ai, DeepSeek, etc. and verify requests

## Task 7: Profile serialization and config integration
**~80 lines | src/fae_llm/providers/profile.rs**

Make profiles configurable in the TOML config:
- Serde support for all profile types (already derived in Task 1)
- `CompatibilityProfile` can be serialized/deserialized to/from TOML
- Add `profile` field to `ProviderConfig` in config/types.rs
- When loading config, resolve profile from provider name if not explicitly set
- Tests: round-trip profile through JSON, verify config integration

## Task 8: Integration tests and documentation
**~80 lines | various**

Full integration tests:
- Build request for each provider (z.ai, DeepSeek, MiniMax, Ollama) and verify JSON
- Verify field names match provider expectations
- Test profile override (custom profile overrides built-in)
- Test unknown provider fallback
- Module documentation with usage examples
- Verify `just check` passes with zero warnings
- Update progress.md

---

## Acceptance Criteria
- [ ] Profile flag system covers all known provider differences
- [ ] Built-in profiles for z.ai, DeepSeek, MiniMax, Ollama, llama.cpp, vLLM
- [ ] Profile resolution from provider name with fallback
- [ ] Request normalization applies profile flags correctly
- [ ] Response normalization handles provider-specific formats
- [ ] Profiles are serializable for config persistence
- [ ] `just check` passes with zero warnings
- [ ] All new code has doc comments
