# Phase 1.1: Enable Per-Sentence Streaming TTS

## Context

The sentence-level streaming TTS infrastructure is **already built** but disabled. Key facts:
- `preferFinalOnlySpeech = true` (line ~5976) gates the entire streaming path
- Sentence buffer + boundary detection + clause fallback already exist (lines ~6014-6284)
- `emitStreamingChunk()` already calls `enqueueTTS()` in the streaming path (line ~6074)
- `enqueueTTS()` chains onto `pendingTTSTask` for ordered synthesis (line ~7564)
- `AudioPlaybackManager.enqueue()` already supports incremental buffers (line ~75)
- Kokoro TTS is stateless per-call — per-sentence synthesis won't degrade prosody
- Streaming thresholds already tuned: `minSentenceChunkChars=28`, `minClauseChunkChars=55`

The primary work is: flip the flag, handle edge cases, test thoroughly.

## Files

- `Sources/Fae/Pipeline/PipelineCoordinator.swift` — Main changes
- `Sources/Fae/Pipeline/TextProcessing.swift` — Sentence boundary detection (verify only)
- `Sources/Fae/ML/KokoroMLXTTSEngine.swift` — Verify per-sentence synthesis (no changes expected)
- `Sources/Fae/Audio/AudioPlaybackManager.swift` — Verify incremental enqueue (no changes expected)
- `Tests/FaeTests/` — New and modified tests

---

## Task 1: Make preferFinalOnlySpeech configurable

**What**: Replace the hardcoded `let preferFinalOnlySpeech = true` with a computed value
that defaults to `false` (streaming enabled). Add a config escape hatch
`tts.preferFinalOnly` for fallback to batched mode if needed.

**Files**: `PipelineCoordinator.swift` (~5976), `Core/FaeConfig.swift`

**Details**:
- Change `let preferFinalOnlySpeech = true` to read from config, defaulting to `false`
- Add `tts.preferFinalOnly: Bool` to FaeConfig with default `false`
- Keep the variable local to `generateWithTools()` — no state promotion needed
- Add debug logging when streaming mode is active

**Tests**: Verify config value is respected; verify default is `false`

---

## Task 2: Verify sentence boundary detection for real-time streaming

**What**: Write targeted tests for `TextProcessing.findSentenceBoundary()` and
`findClauseBoundary()` covering streaming edge cases that don't exist in
batched mode.

**Files**: `Tests/FaeTests/TextProcessingTests.swift`, `Pipeline/TextProcessing.swift`

**Details**:
- Test incremental accumulation: "Hello." arrives as "Hel" + "lo."
- Test abbreviation guards: "Dr. Smith said hello." should not split at "Dr."
- Test decimal guards: "It costs $3.14 per unit." should not split at "3."
- Test multi-sentence: "First sentence. Second sentence." splits correctly
- Test clause boundary fallback: long text without sentence end splits at comma
- Test empty/whitespace-only input
- Test unicode: emoji mid-sentence, CJK punctuation
- Fix any bugs found

---

## Task 3: Handle short/single-sentence responses

**What**: When the LLM produces a short response (<1 sentence) that ends before a
sentence boundary is detected in the streaming buffer, ensure TTS still fires
promptly at turn completion.

**Files**: `PipelineCoordinator.swift` (~6590-6650)

**Details**:
- The end-of-turn path (line ~6590) already handles remaining `sentenceBuffer` contents
- With `preferFinalOnlySpeech = false`, `deferredSentenceQueue` will be empty for
  sentences that already went through streaming TTS
- But the final buffer remainder still needs to be spoken — verify this path works
  when some sentences were already streamed and only the tail remains
- Handle edge case: response is a single short sentence (e.g., "Yes.") — it should
  go through `emitStreamingChunk()` immediately, not wait for more tokens
- Handle edge case: response has no sentence terminator (e.g., "Sure, I can help")
  — the `sentenceBuffer` remainder at turn end must be spoken
- Add debug logging showing which path (streaming vs. final) each chunk took

**Tests**: Single-sentence response, no-terminator response, mixed streamed+final

---

## Task 4: Prevent double-synthesis of streamed sentences

**What**: Ensure sentences that were already synthesized via the streaming path are NOT
re-synthesized at turn completion in the batched fallback.

**Files**: `PipelineCoordinator.swift` (~6597-6633)

**Details**:
- When `preferFinalOnlySpeech = false`, the streaming path calls `enqueueTTS()`
  per sentence during generation. At turn end, `deferredSentenceQueue` should be
  empty (nothing was deferred).
- But `sentenceBuffer` may still have a remainder (partial sentence). The turn-end
  path must ONLY synthesize that remainder, not re-join and re-synthesize everything.
- Current code at line ~6597: `var sentences = deferredSentenceQueue` — when streaming
  is active, this should be empty. Verify this is the case.
- Add a guard: if `deferredSentenceQueue` is empty and `sentenceBuffer` remainder is
  empty, skip TTS entirely at turn end (all audio already enqueued via streaming)
- Track `streamedSentenceCount` to log how many sentences went through streaming vs final

**Tests**: Multi-sentence response with streaming — verify no double-synthesis

---

## Task 5: Wire orb state to streaming TTS

**What**: Ensure the orb transitions to `.speaking` state when the first streaming TTS
chunk starts playing, not when the LLM finishes generating.

**Files**: `PipelineCoordinator.swift`, `OrbStateBridgeController.swift` (verify only)

**Details**:
- `markAssistantSpeechStarted()` is already called inside `enqueueTTS()` (line ~7572)
- With streaming mode, this fires on the first sentence, so the orb should transition
  to speaking state earlier than before
- Verify: orb shows `.thinking` while LLM generates, transitions to `.speaking` when
  first TTS enqueues, stays `.speaking` through remaining sentences
- Verify: the thinking tone (if active) stops when first TTS audio starts
- No code changes expected — just verification and possible debug logging

**Tests**: Orb state transition timing verification

---

## Task 6: Handle barge-in during sentence-queued playback

**What**: Verify barge-in works correctly when multiple sentences are queued and playing
sequentially. Barge-in should cancel remaining queued TTS, not just current sentence.

**Files**: `PipelineCoordinator.swift` (barge-in section ~7761-8130)

**Details**:
- Barge-in already cancels `pendingTTSTask` and calls `playback.stop()` in multiple paths
- With streaming TTS, there may be 2-3 sentences queued in `pendingTTSTask` chain
- Verify: barge-in during sentence 1 cancels sentences 2 and 3
- Verify: barge-in during sentence 2 doesn't replay sentence 1
- Verify: false interruption recovery can resume from the interrupted point
- Check `lastAssistantTextBuffer` accumulation — it should contain all streamed text
  up to the interruption point for recovery purposes
- The generation takeover (Path C) should also cancel queued TTS

**Tests**: Barge-in mid-multi-sentence response; false interruption recovery

---

## Task 7: Build + test validation

**What**: Full build validation and integration test pass.

**Files**: All modified files

**Details**:
- `just build` — zero warnings
- `just test` — all tests pass
- Manually verify (or note for live test): multi-sentence response plays first sentence
  while LLM is still generating
- Verify: tool calls mid-response correctly handle the sentence queue
  (tool responses may inject new text between streamed sentences)
- Verify: proactive queries (which have different `generationContext`) work with streaming
- Log time-to-first-audio in debug console for comparison

**Tests**: Full test suite pass, integration test for streaming TTS path
