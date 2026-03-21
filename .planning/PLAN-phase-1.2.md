# Phase 1.2: Prosody & Latency Tuning

## Context

Phase 1.1 enabled per-sentence streaming TTS by flipping `preferFinalOnlySpeech` to `false`.
The streaming path is now active: LLM tokens → sentence buffer → `emitStreamingChunk()` →
`enqueueTTS()` per sentence. But the tuning thresholds were set speculatively and need
real-world validation.

Current thresholds (PipelineCoordinator ~6013-6017):
- `minSentenceChunkChars = 28` — minimum chars before flushing a sentence to TTS
- `minSentenceFlushIntervalSec = 0.24` — minimum time between sentence flushes
- `minClauseChunkChars = 55` — minimum chars for clause-level fallback
- `minClauseFlushIntervalSec = 0.55` — minimum time between clause flushes
- `maxCharsBeforeClauseFlush = 280` — trigger clause search after this many chars

Key concern: Kokoro TTS runs on MLX GPU, same device as LLM generation. Concurrent
TTS synthesis while LLM is generating tokens may cause contention. Need to measure.

## Files

- `Sources/Fae/Pipeline/PipelineCoordinator.swift` — Streaming thresholds, clause fallback
- `Sources/Fae/ML/KokoroMLXTTSEngine.swift` — TTS synthesis timing (read-only for profiling)
- `Sources/Fae/Core/FaeConfig.swift` — May add configurable thresholds

---

## Task 1: Add time-to-first-audio instrumentation

**What**: Add timing instrumentation to measure time from LLM generation start to first
TTS audio enqueue. This is the key metric for streaming TTS.

**Files**: `PipelineCoordinator.swift`

**Details**:
- At LLM generation start (around line ~5965 `llmStartedAt`), the timer already exists
- In `enqueueTTS()`, add a one-shot measurement: time from `llmStartedAt` to first
  `enqueueTTS()` call. Log as: `"TTS: time-to-first-audio=%.2fs (sentence chars=%d)"`
- Track this via a `firstTtsEnqueuedAt: Date?` local variable in `generateWithTools()`
- Also measure: total LLM generation time, total TTS time, overlap (how much TTS ran
  while LLM was still generating)
- Log a summary at turn end: `"TTS streaming summary: TTFA=%.2fs, LLM=%.2fs, TTS=%.2fs,
  overlap=%.2fs, sentences=%d"`
- Use `debugLog` with `.pipeline` category

**Tests**: Build passes, no logic changes

---

## Task 2: Add clause-level timeout fallback

**What**: When LLM generates a very long sentence without a boundary (e.g., a list or
explanation), add a time-based fallback that synthesizes at the next clause boundary
after a configurable timeout.

**Files**: `PipelineCoordinator.swift` (~6270-6284)

**Details**:
- Current clause fallback only triggers after `maxCharsBeforeClauseFlush = 280` chars
- Add a time-based trigger: if no sentence has been flushed for >3s, check for clause
  boundary regardless of char count (but still require `minClauseChunkChars`)
- This handles the case where LLM generates slowly on a long sentence — user hears
  nothing for many seconds even though 50+ chars of a clause are buffered
- Implementation: check `lastStreamingFlushAt` in the token loop. If elapsed > 3s and
  `sentenceBuffer.count >= minClauseChunkChars`, attempt clause flush.
- The 3s timeout should be a constant: `let maxSilenceBeforeClauseFallbackSec: TimeInterval = 3.0`

**Tests**: Verify clause timeout fires after 3s

---

## Task 3: Tune minimum sentence chunk size

**What**: The current `minSentenceChunkChars = 28` may be too small for good prosody or
too large for responsiveness. Tune based on Kokoro's characteristics.

**Files**: `PipelineCoordinator.swift` (~6013)

**Details**:
- Kokoro TTS has a minimum practical input: very short sentences (<10 chars) produce
  awkward prosody because the style vectors have insufficient context
- Very short fragments also mean more synthesis calls = more GPU contention
- Recommended: raise minimum from 28 to 40 chars. This ensures ~8-10 words minimum,
  which is enough for Kokoro to produce natural prosody.
- But: don't raise too high or time-to-first-audio suffers on short responses
- Add a special case: if the LLM's first sentence is short (e.g., "Sure!" or "Yes."),
  flush it immediately regardless of `minSentenceChunkChars`. Only the first sentence
  gets this treatment — subsequent sentences should respect the minimum.
- This gives instant acknowledgment while maintaining prosody for longer content.

**Tests**: Verify first-sentence exception works

---

## Task 4: Handle GPU contention between TTS and LLM

**What**: When streaming TTS is active, Kokoro and the LLM both compete for the MLX GPU.
Add a brief yield between TTS synthesis and LLM generation to reduce contention.

**Files**: `PipelineCoordinator.swift` (in `enqueueTTS` or `synthesizeSentence`)

**Details**:
- `enqueueTTS()` chains onto `pendingTTSTask` — synthesis runs as a Task on the actor.
  Meanwhile, the LLM token loop continues on the same actor (re-entrant at await points).
- Both Kokoro and the LLM use MLX (Metal GPU). Concurrent MLX operations will serialize
  on the Metal command queue but can cause jitter.
- Option A (conservative): Add a `Task.yield()` after `synthesizeSentence()` completes
  in the `pendingTTSTask` chain to give the LLM token loop priority.
- Option B (if contention is severe): Use the InferencePriorityController pattern —
  pause TTS synthesis until LLM yields a token batch, then resume.
- Start with Option A and measure. Only escalate to Option B if LLM token rate drops
  measurably during TTS synthesis.
- Log LLM tokens/sec during TTS synthesis vs. without to detect contention.

**Tests**: Build passes; contention measurement logged for manual verification

---

## Task 5: Build + test validation

**What**: Full build and test validation after tuning changes.

**Files**: All modified files

**Details**:
- `just build` — zero warnings
- `just test` — all tests pass (including new TextProcessing tests from 1.1)
- Review debug log output format for streaming TTS summary
- Verify the tuning constants are reasonable defaults

**Tests**: Full test suite pass
