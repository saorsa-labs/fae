# Fae Personalization — Roadmap

**Project:** Fae Personalization (Personality + Voice Cloning)
**Created:** 2026-02-10
**Status:** In Progress

---

## Milestone 1: Fae Personalization

> Give Fae a rich Scottish nature spirit personality and a custom voice via fish-speech.rs voice cloning.

### Phase 1.1 — Personality Enhancement
**Goal:** Deploy the voice-optimized identity profile and ensure Fae responds as an ancient Scottish nature spirit.

| Task | Description | Est. Lines |
|------|-------------|-----------|
| 1.1.1 | Replace `Personality/fae-identity-profile.md` with voice-optimized version | ~100 |
| 1.1.2 | Create `Personality/fae-identity-full.md` full character reference | ~291 |
| 1.1.3 | Add `FAE_IDENTITY_REFERENCE` constant to `src/personality.rs` | ~5 |
| 1.1.4 | Add personality unit tests (Scottish identity, speech examples, constraints) | ~40 |

### Phase 1.2 — TTS Abstraction Layer
**Goal:** Extend config and pipeline to support multiple TTS backends.

| Task | Description | Est. Lines |
|------|-------------|-----------|
| 1.2.1 | Add `TtsBackend` enum to `src/config.rs` | ~20 |
| 1.2.2 | Extend `TtsConfig` with `voice_reference` fields | ~30 |
| 1.2.3 | Update `run_tts_stage` in `src/pipeline/coordinator.rs` for backend selection | ~40 |
| 1.2.4 | Update `src/startup.rs` for backend-aware TTS loading | ~15 |
| 1.2.5 | Update `src/tts/mod.rs` to conditionally export fish_speech module | ~10 |
| 1.2.6 | Add `fish-speech` feature flag to `Cargo.toml` | ~10 |

### Phase 1.3 — Fish Speech Integration
**Goal:** Implement the FishSpeechTts module with voice cloning from reference audio.

| Task | Description | Est. Lines |
|------|-------------|-----------|
| 1.3.1 | Research fish-speech.rs API and determine exact dependency | ~0 (research) |
| 1.3.2 | Create `src/tts/fish_speech.rs` with `FishSpeechTts` struct | ~100 |
| 1.3.3 | Implement voice embedding extraction from `fae.wav` | ~50 |
| 1.3.4 | Implement `synthesize()` with cloned voice | ~50 |
| 1.3.5 | Wire model downloading / caching | ~40 |

### Phase 1.4 — Testing & Polish
**Goal:** Comprehensive testing, benchmarks, documentation, acceptance criteria validation.

| Task | Description | Est. Lines |
|------|-------------|-----------|
| 1.4.1 | TTS backend unit tests (Kokoro default, FishSpeech requires ref) | ~40 |
| 1.4.2 | Config serialization tests (TtsBackend round-trip) | ~30 |
| 1.4.3 | Integration tests for personality + TTS pipeline | ~50 |
| 1.4.4 | Performance benchmarks (latency targets) | ~30 |
| 1.4.5 | Update README and config documentation | ~50 |
| 1.4.6 | Acceptance criteria walkthrough | manual |

---

## Success Criteria

- [ ] Ask "Who are you?" → Fae mentions Scottish nature spirit, Highland origins
- [ ] Responses are 1-3 sentences, warm but direct
- [ ] Uses phrases like "Right then", "aye", "folk" naturally
- [ ] Voice output sounds Scottish, matching the reference audio
- [ ] Latency remains under 600ms end-to-end
- [ ] All tests pass: `cargo test --features fish-speech`
- [ ] Zero warnings, zero clippy violations
