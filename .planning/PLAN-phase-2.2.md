# Phase 2.2: Fast-Path Wiring

## Context

Phase 2.1 created `ParakeetStreamingEngine` as a standalone actor. This phase wires it
into the live audio pipeline so Parakeet partials flow to the UI, keyword spotter, and
barge-in decisions during active speech.

## Tasks

### Task 1: Add streamingSTTEngine property to PipelineCoordinator

- Add `streamingSTTEngine: (any StreamingSTTEngine)?` property
- Add parameter to init with default `nil`
- Wire from FaeCore using `modelManager.parakeetEngine`

### Task 2: Feed audio to Parakeet in capture loop

- In the `streamingAudioSafe` block, feed audio to Parakeet alongside existing Qwen3-ASR
- Route Parakeet partials through `handleStreamingPartialTranscript`
- Use detached Task to avoid blocking the 36ms audio loop

### Task 3: Reset Parakeet on segment boundaries

- Add `streamingSTTEngine?.reset()` at all streaming epoch reset points:
  - Pipeline stop/teardown
  - User cancel
  - cancelAndWait (test harness)
  - Barge-in segment boundary resets

### Task 4: Validate build and tests

- Zero warnings on `swift build`
- All existing tests pass (no behavior changes)
