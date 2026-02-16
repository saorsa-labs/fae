# Phase 1.2: Conversation Gate

## Goal
Modify `run_conversation_gate()` to use `effective_sleep_phrases()` for multi-phrase sleep detection and disable auto-idle when `idle_timeout_s == 0`. Preserve all wake and barge-in mechanisms.

## Tasks

### Task 1: Replace single stop_phrase with multi-phrase sleep detection
- In `run_conversation_gate()` (src/pipeline/coordinator.rs ~line 2843):
  - Replace `let stop_phrase = config.conversation.stop_phrase.to_lowercase();` with
    `let sleep_phrases: Vec<String> = config.conversation.effective_sleep_phrases().iter().map(|s| s.to_lowercase()).collect();`
  - Replace the single `clean.contains(&stop_phrase)` check (~line 3000) with a loop:
    `sleep_phrases.iter().any(|phrase| clean.contains(phrase))`
- **Files:** `src/pipeline/coordinator.rs`

### Task 2: Make auto-idle conditional on idle_timeout_s > 0
- The `idle_check.tick()` branch already has `if state == GateState::Active && idle_timeout_s > 0` guard (~line 2922)
- This means with `idle_timeout_s == 0` the auto-idle branch is already disabled — verify this is correct
- Update the doc comment on `run_conversation_gate()` to reflect companion mode behavior
- **Files:** `src/pipeline/coordinator.rs`

### Task 3: Full validation
- `cargo fmt --all`
- `cargo clippy --all-features -- -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used`
- `cargo test --all-features`
- Zero errors, zero warnings
- **Files:** all
