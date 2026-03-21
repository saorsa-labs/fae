# Phase 2.3: Dual-Path Orchestration

**Milestone**: Milestone 2 — Parakeet TDT Dual-Path Streaming ASR
**Status**: COMPLETE

## Tasks

### Task 1: Apply vocabulary correction to streaming partials
- correctNameRecognition + DynamicVocabularyCorrector on Parakeet partials
- Same correction pipeline as Qwen3-ASR partials

### Task 2: Track fast-path vs slow-path partials
- StreamingPartialSource enum distinguishing Parakeet vs Qwen3-ASR partials
- Source tagged in debug logging

### Task 3: Disagreement detection
- Log when Parakeet partial and Qwen3-ASR partial diverge significantly
- Threshold-based comparison for monitoring (not blocking)

### Task 4: Reset fast-path state at streaming reset points
- Clear lastFastPathPartial at all 3 streaming reset points
- Synchronized with Qwen3-ASR epoch resets

### Task 5: Adaptive fallback verification
- streamingSTTEngine is optional (nil-safe) throughout pipeline
- No code changes needed — verified existing nil guards are sufficient

### Task 6: Build + test validation

## Files modified
- `Sources/Fae/Pipeline/PipelineCoordinator.swift`
