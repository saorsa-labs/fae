# Phase 1.1: Personality Enhancement

## Overview
Deploy the voice-optimized Fae identity profile and add comprehensive tests.

## Tasks

### Task 1: Replace personality profile with voice-optimized version
**Files:** `Personality/fae-identity-profile.md`
**Action:** Replace the current 291-line full identity profile with the 78-line voice-optimized version from `docs/fae-identity-voice-optimized.md`. The voice-optimized version is designed for voice assistant constraints (1-3 sentences, no emojis, no roleplay).

### Task 2: Create full character reference file
**Files:** `Personality/fae-identity-full.md`
**Action:** Copy the full 291-line character bible from `docs/fae-identity-full.md` to `Personality/fae-identity-full.md`. This preserves the complete reference for future prompt tuning and RAG.

### Task 3: Add FAE_IDENTITY_REFERENCE constant to personality.rs
**Files:** `src/personality.rs`
**Action:** Add `pub const FAE_IDENTITY_REFERENCE: &str = include_str!("../Personality/fae-identity-full.md");` with doc comment. This compiles the full reference into the binary for potential future use.

### Task 4: Add personality enhancement tests
**Files:** `src/personality.rs`
**Action:** Add tests to the existing `#[cfg(test)]` module:
- `fae_personality_contains_scottish_identity` — asserts "Scottish nature spirit" and "Highland" present
- `fae_personality_contains_speech_examples` — asserts "Right then" and "What drives you" present
- `fae_personality_has_voice_constraints` — asserts "1-3 short" and voice constraint text present
- `fae_identity_reference_is_nonempty` — asserts FAE_IDENTITY_REFERENCE is non-empty and longer than FAE_PERSONALITY
- `fae_personality_is_voice_optimized` — asserts the profile is under 5000 chars (voice-optimized, not full)

### Task 5: Verify all tests pass
**Action:** Run `just check` (or equivalent) to ensure zero warnings, zero errors, all tests pass.
