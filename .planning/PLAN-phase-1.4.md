# Phase 1.4: Integration Testing

## Goal
Add/update tests for multi-phrase sleep detection, disabled auto-idle, gate state transitions with new config. Verify backward compatibility and prompt assembly. Full validation.

## Tasks

### Task 1: Conversation gate integration tests
- Add test: `sleep_phrases_detected_in_gate` — verify multiple sleep phrases trigger sleep transition
- Add test: `auto_idle_disabled_when_timeout_zero` — verify no auto-idle with default config
- Add test: `wake_word_still_works_after_sleep` — verify wake word brings gate back to active
- These are behavioral tests for the conversation gate logic
- **Files:** `src/pipeline/coordinator.rs` (test module)

### Task 2: Prompt assembly verification tests
- Add test: `prompt_includes_companion_presence` — verify assembled prompt contains companion presence section
- Add test: `soul_includes_presence_principles` — verify SOUL contains presence principles
- **Files:** `src/personality.rs` (test module)

### Task 3: Full validation
- `cargo fmt --all`
- `cargo clippy --all-features -- -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used`
- `cargo test --all-features`
- Zero errors, zero warnings
- **Files:** all
