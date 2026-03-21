# Voice Pipeline Hardening — Roadmap

> Address the weakest areas of Fae's voice pipeline: TTS latency, streaming ASR architecture,
> coordinator complexity, and echo handling. Production-ready quality across all milestones.

## Problem Statement

The voice pipeline is conceptually strong but has four structural weaknesses:
1. TTS is final-only — time-to-first-audio is poor, conversation feels sluggish
2. Streaming STT uses growing-buffer re-transcription — heavy, no true CTC fast-path
3. PipelineCoordinator is ~10K lines with 72+ state vars — every fix risks regressions
4. Echo handling is layered heuristics — fragile on speaker-out without AEC

Recent commits (6419d95, ed79800) addressed: adaptive noise floor, SNR gating, epoch-aware
streaming STT, neural turn detector, speculative LLM prefill. This roadmap builds on that work.

## Success Criteria

- Time-to-first-audio drops by 2-4s on multi-sentence responses
- Parakeet TDT CTC fast-path provides partials within 100ms of speech onset
- CoreML Neural Engine offload — zero GPU contention with LLM/TTS
- PipelineCoordinator reduced from ~10K to <2K lines (orchestration only)
- Echo rejection works reliably on MacBook speakers at moderate volume
- All changes pass existing test suite + new regression tests

---

## Milestone 1: Sentence-Level TTS Pipelining

**Goal**: First audio plays while LLM is still generating subsequent sentences.

**Why first**: Lowest effort, highest UX impact. The streaming TTS path already exists as dead
code behind `preferFinalOnlySpeech = true`. Kokoro is stateless per-call — per-sentence
synthesis won't degrade prosody. AudioPlaybackManager already supports incremental enqueue.

### Phase 1.1: Enable Per-Sentence Streaming TTS

- Remove `preferFinalOnlySpeech = true` hard-coding (PipelineCoordinator line ~5976)
- Activate the existing streaming path (lines ~6059-6075) in `emitStreamingChunk()`
- Ensure `enqueueTTS()` fires per sentence during LLM streaming
- Verify sentence boundary detection in `TextProcessing.findSentenceBoundary()` works for
  real-time streaming (handles abbreviations, decimals, edge cases)
- Handle short responses (<1 sentence) — fall through to immediate TTS

### Phase 1.2: Prosody & Latency Tuning

- Benchmark per-sentence vs. batched synthesis quality (Kokoro's internal style vectors
  are sentence-scoped, so degradation is unlikely but must be verified)
- Tune minimum sentence length before TTS fires (avoid synthesizing 2-word fragments)
- Add clause-level fallback: if LLM generates a long clause without sentence boundary,
  synthesize at clause boundary after timeout (e.g., 3s without sentence end)
- Profile GPU contention: TTS running while LLM is still generating on same MLX device

### Phase 1.3: Testing & Hardening

- Add regression tests: multi-sentence responses, single-sentence, mid-sentence barge-in,
  tool calls interrupting TTS queue, proactive queries
- Measure time-to-first-audio before/after on representative prompts
- Test edge cases: very long sentences (>420 chars), emoji/unicode, code blocks
- Verify orb state transitions match new streaming behavior
- Update eval corpus with TTS latency benchmarks

---

## Milestone 2: Parakeet TDT Dual-Path Streaming ASR — COMPLETE

**Goal**: Second, lighter ASR model providing independent streaming partials alongside
Qwen3-ASR, with vocabulary correction and disagreement tracking.

**Original plan**: CoreML Neural Engine target for zero GPU contention.
**What shipped**: MLX-based Parakeet via vendored mlx-audio-swift. CoreML conversion was
not pursued because the model was already available via MLX and the `generate()` API was
sufficient. CoreML ANE optimization remains a future option if GPU contention is measured.

**Honest limitation**: Current implementation uses periodic whole-buffer decode (same
architectural pattern as Qwen3-ASR streaming, but with a lighter 0.6B model on a different
cadence). True incremental CTC decode (skip already-processed frames) requires exposing
the encoder's internal state — deferred as future optimization.

### Phase 2.1: Parakeet TDT Integration — COMPLETE

- Evaluated speech-swift vs. mlx-audio-swift — chose MLX path (model already available)
- Implemented `ParakeetStreamingEngine` conforming to `StreamingSTTEngine` protocol
- Validated model loads and transcribes via `model.generate()` API
- Added benchmark scaffolding (decode latency, peak memory tracking)

### Phase 2.2: Fast-Path Wiring

- Add `streamingSTTEngine: (any StreamingSTTEngine)?` to PipelineCoordinator
- Wire `feedAudio()` in the capture loop alongside existing VAD
- Route Parakeet partials to: UI display, keyword spotter, barge-in decision
- Keep Qwen3-ASR as the "slow path" — runs on complete segments for final transcript
- Ensure Parakeet resets correctly on segment boundaries

### Phase 2.3: Dual-Path Orchestration — COMPLETE

- Vocabulary correction on streaming partials (correctNameRecognition + DynamicVocabularyCorrector)
- StreamingPartialSource enum tracking fast-path vs slow-path partials
- Disagreement detection: logged when Parakeet and Qwen3-ASR diverge
- Adaptive fallback: nil-safe streamingSTTEngine throughout pipeline

### Phase 2.4: Evaluation & Regression Testing — COMPLETE

- 7 regression tests (dual-path mock, config round-trip, result types)
- Build + test validation (1560 tests, 0 failures)

**Not completed from original plan** (deferred to live testing):
- Eval corpus runs against real audio (Google Speech Commands, MS AEC Challenge)
- Partial latency measurement against <100ms target
- Neural Engine / GPU contention validation via Instruments
- Noisy room, soft speech, overlapping speaker scenarios

---

## Milestone 3: PipelineCoordinator Decomposition

**Goal**: Break the ~10K line monolith into 5-6 focused actors with explicit async channel
interfaces. PipelineCoordinator becomes a thin orchestrator (<2K lines).

**Why**: 72+ state variables interacting through carefully sequenced mutations. Every bug fix
risks regressions. The 47 MARK sections reveal natural actor boundaries.

### Phase 3.1: State Extraction + Type Promotion — COMPLETE

Safe prep work for deeper decomposition. No async boundary changes — plain owned types first.

- Extracted `SpeechInputStage` class: segment queue, streaming epoch, wake detection state
- Extracted `SpeakerGateState` struct: speaker identity + enrollment + streaming gate state
- Promoted `BargeInTypes`: PendingBargeIn, PlaybackBargeInCandidate, GenerationTakeoverCandidate
- Extracted `ToolCallParsing`: ToolCall, ScriptBlock, parsing logic (~190 lines)
- Promoted `PipelineTypes`: 6 nested enums to top-level types
- Result: 10,080 → 9,724 lines (-356), ~35 state vars grouped, 9 types promoted
- All 1560 tests pass, zero warnings

### Phase 3.2: Extract BargeInDecider + TTSStage

- Extract `BargeInDecider` actor: all barge-in paths A/B/C, false interruption recovery,
  keyword-based generation takeover. Lines ~7761-8130 + ~1159-1240.
- Extract `TTSStage` actor: `enqueueTTS`, `synthesizeSentence`, `pendingTTSTask` chain,
  playback events. Lines ~7557-8162.
- Define async channels: BargeInDecider receives speech signals + playback state,
  emits barge-in/cancel decisions. TTSStage receives text, emits playback events.
- All existing tests must pass

### Phase 3.3: Extract LLMStage + ToolExecutionStage

- Extract `LLMStage` actor: `generateWithTools`, tool call parsing, streaming loop,
  sentence buffer, deferred sentence queue. Lines ~4763-7477 + ~8197-8445.
- Extract `ToolExecutionStage` actor: tool dispatch, capability tickets, deferred tool
  tasks, JSC script execution. Lines ~9446-9950 + ~1303-1341.
- Define async channels: LLMStage receives transcription, emits text chunks + tool calls.
  ToolExecutionStage receives tool calls, emits results.
- All existing tests must pass

### Phase 3.4: Integration Testing & Cleanup

- PipelineCoordinator becomes thin orchestrator: lifecycle, actor wiring, event routing
- Verify <2K lines remaining in coordinator
- Full end-to-end test pass: all pipeline tests, voice identity tests, regression tests
- Profile actor message overhead — ensure no latency regression from async channels
- Remove dead code, unused state variables, stale MARK sections
- Update CLAUDE.md file inventory to reflect new actors

---

## Milestone 4: Echo Handling Hardening

**Goal**: Reliable echo rejection on MacBook speakers at moderate volume without AEC.

**Why**: Current 5-layer heuristic stack works for headphones but is fragile on speaker-out.
Room acoustics, output volume, and device-specific behavior cause false echo drops and
missed user speech.

### Phase 4.1: Playback Baseline & Timing Improvements

- Improve playback baseline tracker: track per-frequency-band energy, not just broadband RMS
- Extend echo tail scaling: use actual room decay estimation (short burst → measure decay)
- Add speaker-vs-headphone detection (AVAudioSession route) to adjust thresholds
- Tune `fae_self` speaker embedding rejection — more aggressive during playback

### Phase 4.2: WebRTC AEC3 Evaluation

- Evaluate WebRTC AEC3 integration feasibility:
  - Can we get the playback reference signal from AudioPlaybackManager?
  - Does WebRTC AEC3 have a C/Swift-compatible API?
  - What's the latency overhead?
- If feasible: implement reference-signal capture from playback engine
- If not feasible: document why and enhance heuristic stack instead

### Phase 4.3: Integration & Acoustic Testing

- Run MS AEC Challenge corpus through improved echo handling
- Test matrix: headphones, MacBook speakers, external speakers, varying volumes
- Measure false echo rejection rate and missed echo rate
- Add echo handling regression tests with synthetic echo scenarios
- Document speaker-out limitations and recommended setup

---

## Dependencies & Risks

| Risk | Mitigation |
|------|-----------|
| Kokoro per-sentence prosody degradation | Benchmark first in Phase 1.2; Kokoro style vectors are sentence-scoped |
| Parakeet CoreML model conversion issues | Two Swift ports exist; fall back to MLX if CoreML fails |
| GPU contention during concurrent TTS+LLM | Parakeet on Neural Engine eliminates STT contention; profile TTS+LLM in Phase 1.2 |
| Actor decomposition introduces latency | Profile in Phase 3.4; async channels on Apple Silicon are sub-microsecond |
| WebRTC AEC3 integration infeasible | Phase 4.2 is explicitly an evaluation; heuristic hardening is the fallback |

## Work Already Done (Recent Commits)

- **6419d95**: Streaming ASR (growing-buffer), silent generation buffering, generation takeover
  (Path C), adaptive noise floor, SNR gating, partial stability filter, eval corpus infra
- **ed79800**: Neural turn detector wired into pipeline, speculative LLM prefill

These are foundations that this roadmap builds on — not redundant work.
