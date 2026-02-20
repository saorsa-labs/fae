# Phase 6.1b: fae_llm Provider Cleanup — Task Plan

## Overview
Remove all non-embedded LLM provider code from fae_llm. User directive: only downloaded embedded models, no Ollama/LM Studio/external API servers.

## Task 1: Delete provider files and contract tests
- Delete `src/fae_llm/providers/openai.rs` (1600+ lines)
- Delete `src/fae_llm/providers/anthropic.rs` (1100+ lines)
- Delete `src/fae_llm/providers/fallback.rs` (230+ lines)
- Delete `src/fae_llm/providers/profile.rs` (450+ lines)
- Delete `src/fae_llm/providers/profile_tests.rs`
- Delete `src/fae_llm/providers/sse.rs` (SSE parser, only used by OpenAI/Anthropic HTTP streaming)
- Delete `src/fae_llm/providers/local_probe.rs` (probes for local OpenAI-compatible servers)
- Delete `src/fae_llm/providers/local_probe_tests.rs`
- Delete `tests/anthropic_contract.rs`
- Delete `tests/openai_contract.rs`
- Update `src/fae_llm/providers/mod.rs`: remove module declarations + re-exports
- Update `src/fae_llm/mod.rs`: remove pub use re-exports for deleted types

## Task 2: Fix compile errors from deletions
- Remove references to deleted types throughout fae_llm
- Clean up fae_llm/config/* (remove OpenAI/Anthropic provider configs)
- Clean fae_llm integration tests that use deleted providers
- Clean observability redaction (remove API key-specific helpers if unused)
- Fix any test files that reference deleted types

## Task 3: Clean credential and diagnostics references
- Remove `"llm.api_key"` doc comment examples from credentials/types.rs, credentials/mod.rs
- Remove `"llm.api_key"` from diagnostics keychain deletion list
- Verify no other references remain

## Task 4: Final verification
- `cargo fmt --all -- --check`
- `cargo clippy --all-features --all-targets -- -D warnings`
- `cargo test --lib`
- Exhaustive grep for deleted type names
