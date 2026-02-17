# Phase 1.5: Integration Testing & Polish

## Overview
Validate all v0.5.0 changes end-to-end, add integration tests, update documentation.

---

## Task 1: Add gate-starts-Active test
Verify the conversation gate starts in Active state and processes transcriptions immediately without needing a wake word.

**Files:** `src/pipeline/coordinator.rs` (tests section)

**Acceptance:**
- Test that gate starts Active (gate_active is true at init)
- Test that transcriptions flow through without wake word
- Test passes with `cargo test`

---

## Task 2: Test sleep/wake cycle
Verify sleep phrase → Idle → GateCommand::Wake → Active cycle works correctly.

**Files:** `src/pipeline/coordinator.rs` (tests section)

**Acceptance:**
- Test sends transcription with sleep phrase, verifies gate goes Idle
- Test sends GateCommand::Wake, verifies gate goes Active again
- Existing sleep/wake tests still pass

---

## Task 3: Test backward compatibility
Verify old config.toml files with `[wakeword]` section still load without errors.

**Files:** `src/config.rs` (tests section)

**Acceptance:**
- Test deserializes TOML with `[wakeword]` section
- Test deserializes TOML without `[wakeword]` section
- Both produce valid SpeechConfig
- Test passes with `cargo test`

---

## Task 4: Update CHANGELOG.md
Document all v0.5.0 changes.

**Files:** `CHANGELOG.md`

**Acceptance:**
- Added section for v0.5.0
- Lists: wake word removal, always-on mode, speed improvements, tool feedback, blank message fixes
- Follows existing changelog format

---

## Task 5: Update documentation
Remove wake word references from system prompt and SOUL.md.

**Files:** `Prompts/system_prompt.md`, `SOUL.md`

**Acceptance:**
- No references to "wake word" in behavioral docs
- Updated to reflect always-on companion model
- Fae described as always-listening
