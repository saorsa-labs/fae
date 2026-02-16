# Phase 1.1: Config & Sleep Phrases

## Goal
Update `ConversationConfig` to support multiple sleep phrases and disable auto-idle by default. Backward-compatible with existing configs.

## Tasks

### Task 1: Add sleep_phrases field and update defaults
- Add `sleep_phrases: Vec<String>` field to `ConversationConfig`
- Default sleep phrases: "shut up", "stop fae", "go to sleep", "that will do fae", "that'll do fae", "quiet fae", "sleep fae", "goodbye fae", "bye fae"
- Change `idle_timeout_s` default from 20 to 0 (disabled)
- Keep `stop_phrase` field for backward compatibility (serde will still deserialize old configs)
- Add `/// Deprecated` doc comment on `stop_phrase`
- Add `effective_sleep_phrases()` method that merges `sleep_phrases` with legacy `stop_phrase` (if non-empty and not already in the list)
- Update struct-level doc comment to mention companion mode
- **Files:** `src/config.rs`

### Task 2: Add config tests
- Test: `sleep_phrases_default_is_nonempty` — verify default has multiple phrases
- Test: `idle_timeout_default_is_zero` — verify new default
- Test: `effective_sleep_phrases_includes_legacy` — set `stop_phrase` to a custom value, verify `effective_sleep_phrases()` includes it
- Test: `effective_sleep_phrases_no_duplicates` — set `stop_phrase` to one already in `sleep_phrases`, verify no duplicate
- Test: `conversation_config_backward_compat` — deserialize old TOML with only `stop_phrase`, verify it works
- Test: `conversation_config_new_format` — deserialize TOML with `sleep_phrases` list
- **Files:** `src/config.rs`

### Task 3: Full validation
- `cargo fmt --all`
- `cargo clippy --all-features -- -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used`
- `cargo test --all-features`
- Zero errors, zero warnings
- **Files:** all
