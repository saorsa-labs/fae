# Phase 6.1: Backend Cleanup — Task Plan

## Overview
Remove all API/Agent backend code and fix test flake. 8 tasks.

## Task 1: Fix fae_dirs env-override test flake
- Add module-level `static ENV_LOCK: std::sync::Mutex<()>` to fae_dirs tests
- Lock in all 4 env-mutating tests: `data_dir_override_via_env`, `config_dir_override_via_env`, `cache_dir_override_via_env`, `ensure_hf_home_sets_env_when_absent`
- Files: `src/fae_dirs.rs`
- Verify: `cargo nextest run -p fae -- fae_dirs` (run 5x, no flakes)

## Task 2: Remove LlmBackend::Api, LlmBackend::Agent, LlmApiType from config
- Delete `Api` and `Agent` variants from `LlmBackend` enum
- Delete entire `LlmApiType` enum
- Remove LlmConfig fields: `api_url`, `api_model`, `api_type`, `api_version`, `api_organization`, `api_key`, `cloud_provider`, `cloud_model`, `external_profile`, `enable_local_fallback`, `network_timeout_ms`
- Remove helper fns: `default_enable_local_fallback()`, `default_network_timeout_ms()`, `effective_provider_name()`, `has_remote_provider_configured()`
- Remove related tests in config.rs tests section
- Files: `src/config.rs`

## Task 3: Remove API/Agent from startup.rs
- Remove `has_agent_remote_brain_config()`
- Simplify `should_preload_local_llm()` to always return true
- Remove Api/Agent match arms in `initialize_models_with_progress()`
- Remove or stub `execute_scheduled_conversation()` (uses API adapters)
- Remove unused imports (AnthropicAdapter, OpenAiAdapter, etc.)
- Files: `src/startup.rs`

## Task 4: Remove API providers from agent/mod.rs and channels/brain.rs
- Remove `build_remote_provider()`, `has_remote_provider_configured()`, `has_explicit_remote_target()`, `MissingProviderConfigAdapter`
- Simplify `build_provider()` to local-only path
- Remove Api/Agent match arms
- Remove related tests
- Simplify `channels/brain.rs` to always use local model
- Files: `src/agent/mod.rs`, `src/channels/brain.rs`

## Task 5: Delete API provider files
- Delete `src/llm/api.rs`
- Delete `src/agent/http_provider.rs`
- Delete `src/external_llm.rs`
- Remove module declarations from `src/llm/mod.rs`, `src/lib.rs`
- Remove `apply_external_profile` calls from `src/startup.rs`, `src/channels/brain.rs`
- Remove `external_apis_dir()` from `src/fae_dirs.rs`
- Files: 3 deleted + 5 module refs updated

## Task 6: Fix intelligence extraction (remove API calls)
- Remove `resolved_api_key` and api-related fields from `ExtractionParams`
- Remove `extraction_llm_call()` HTTP function
- Stub extraction to skip (TODO: wire to embedded LLM in Phase 6.2)
- Update all callers
- Files: `src/intelligence/mod.rs` + callers

## Task 7: Delete API test files and clean inline tests
- Delete: `tests/e2e_openai.rs`, `tests/e2e_anthropic.rs`, `tests/cross_provider.rs`
- Update inline tests in `src/config.rs`, `src/agent/mod.rs`, `src/pipeline/coordinator.rs`
- Remove `api_test_config()` helper and tests using it
- Files: 3 deleted + inline test cleanup

## Task 8: Update Swift settings + final verification
- Change SettingsModelsTab "Local / API" → "Local (Embedded)"
- Run exhaustive grep for any remaining API/Agent references
- Run `just check` (fmt, clippy, test, doc)
- Files: `SettingsModelsTab.swift`
