# Adaptive Interruption Fix Roadmap

## Overview

Fae has a complete adaptive interruption system (types, protocol, deciders, backchannel suppression, false interruption recovery) but it **doesn't work** because 7 cascading conservative gates prevent barge-in from ever firing. The user cannot interrupt Fae at all.

**Problem:** Echo suppressor hard-blocks barge-in candidate creation during playback. Even after playback stops, 2000-3250ms echo tail + 500ms holdoff + 300ms adaptive overlap + speaker verification = 4+ seconds before any interruption is possible.

**Success:** User can reliably interrupt Fae mid-speech within ~300-500ms. Keyword interrupts ("stop", "quiet") fire in <200ms. Backchannels ("yeah", "mm") don't false-trigger. False interruption recovery works naturally.

---

## Milestone 1: Unblock barge-in during playback

The echo suppressor currently prevents ANY barge-in candidate from being created while Fae speaks. This is the absolute blocker — nothing downstream matters until this is fixed.

### Phase 1.1: Echo suppressor as signal, not gate
- Change echo suppressor from hard pre-filter to a signal in InterruptionInput
- Allow PendingBargeIn creation during playback (remove `echoSuppression` from advancePendingBargeIn gates)
- Move echo rejection INTO the adaptive decider as a weighted signal
- Exempt keyword interrupts from echo suppression entirely
- Reduce echo tail from 2000ms to 800ms for owner-verified speech
- Tests proving barge-in candidates are created during playback

### Phase 1.2: Holdoff and timing fixes
- Reduce assistantStartHoldoffMs from 500ms to 200ms
- Exempt keyword interrupts from holdoff entirely
- Fix lastAssistantStart to set once per response, not per TTS chunk
- Add watchdog to force-clear assistantSpeaking if desynced from playback (60s→10s)
- Tests for holdoff timing

---

## Milestone 2: Speaker verification resilience

Speaker verification is fail-closed — short audio, encoder not loaded, or mismatch = DENY + 5s cooldown. This creates a brittle system where the owner gets locked out.

### Phase 2.1: Graceful degradation for verification
- If audio too short (<350ms): allow as candidate, continue collecting, verify when enough audio
- If encoder not loaded: allow interruption (degrade to legacy RMS-only)
- Reduce deny cooldown from 5s to 2s
- Add progressive verification: allow interrupt, verify async, if not owner restore playback
- Fix bargeInSuppressed stuck-true: add periodic reset watchdog
- Tests for degraded verification paths

---

## Milestone 3: Adaptive decider tuning

The adaptive decider thresholds are too conservative for real-world use.

### Phase 3.1: Lower thresholds for responsive interruption
- Reduce minOverlapMs from 300ms to 150ms
- Reduce minSustainedChunks from 4 to 2
- Reduce rmsSustainFloor from 0.06 to 0.04
- Add keyword fast-path that bypasses ALL acoustic thresholds (just needs VAD speech onset)
- Tune transcript-boosted path: 100ms overlap with 1+ words should fire immediately
- Lower peakRmsRatio from 1.5 to 1.2
- Tests for lower thresholds

### Phase 3.2: End-to-end integration validation
- Validate full pipeline: audio → VAD → (echo signal) → adaptive decider → verification → interrupt
- Stress test: interrupt during long TTS, short TTS, multi-sentence TTS
- Validate false interruption recovery still works
- Validate backchannel suppression still works at lower thresholds
- Measure actual interrupt latency end-to-end

---

## Milestone 4: Dynamic endpointing (DEFERRED)
- Transcript-aware silence thresholds
- Shorter delay after complete sentences
- Only pursue after M1-M3 are validated in live testing
