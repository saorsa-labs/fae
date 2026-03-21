# Phase 1.3: Testing & Hardening

**Milestone**: Milestone 1 — Sentence-Level TTS Pipelining
**Phase**: 1.3 (final phase)
**Status**: COMPLETE

## Objective

Add regression tests and edge-case coverage for the streaming TTS changes from phases 1.1 and 1.2.
All tests must be deterministic (no LLM calls, no audio devices). Focus on the static helpers
and pure-logic paths that are fully testable.

## Tasks

### Task 1: Streaming TTS config regression tests (FaeConfigTests.swift)
- `testTTSPreferFinalOnlyDefaultIsFalse` — streaming mode is on by default
- `testTTSPreferFinalOnlyCanBeEnabled` — batched mode can be configured

### Task 2: batchedTTSSegments edge cases (VoicePipelineRegressionTests.swift)
- `testBatchedTTSSegmentsEmptyString` — returns empty array
- `testBatchedTTSSegmentsShortString` — returns single segment
- `testBatchedTTSSegmentsLongMultiSentence` — splits at sentence boundaries
- `testBatchedTTSSegmentsVeryLongSentence` — >420 chars, no boundary → single segment forced
- `testBatchedTTSSegmentsEmojiAndUnicode` — unicode chars don't break splitting
- `testBatchedTTSSegmentsCodeBlock` — code text handled without crash
- `testBatchedTTSSegmentsPreservesSegmentOrder` — segments are in correct order

### Task 3: Sentence boundary edge cases (TextProcessingTests.swift)
- `testVeryLongSentence` — >420 chars with sentence boundary at end
- `testEmojiMidSentence` — emoji doesn't prevent boundary detection
- `testUnicodePunctuation` — Unicode sentence terminators
- `testCodeBlockNoBoundary` — code block without sentence-ending punctuation
- `testMultipleSentenceFlushSequence` — simulate multi-sentence streaming: flush first sentence,
  keep remainder, accumulate to next sentence boundary

### Task 4: looksLikeNonProse (TextProcessingTests.swift)
- `testLooksLikeNonProseSuppressesToolCallXML`
- `testLooksLikeNonProseSuppressesJSON`
- `testLooksLikeNonProseAllowsNormalProse`
- `testLooksLikeNonProseAllowsShortCode` — < 10 chars passes through

### Task 5: Verify build + all tests pass

## Files to modify
- `Tests/HandoffTests/TextProcessingTests.swift` — add new tests in Tasks 3 + 4
- `Tests/HandoffTests/VoicePipelineRegressionTests.swift` — add Task 2 tests
- `Tests/HandoffTests/FaeConfigTests.swift` — add Task 1 tests
