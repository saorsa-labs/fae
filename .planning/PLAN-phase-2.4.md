# Phase 2.4: Evaluation & Regression Testing

**Milestone**: Milestone 2 — Parakeet TDT Dual-Path Streaming ASR
**Status**: COMPLETE (structural tests only; acoustic evaluation deferred)

## Tasks

### Task 1: Dual-path mock simulation test
- Parallel feeding to mock fast-path and slow-path engines
- Independent reset verification

### Task 2: StreamingSTTResult equality and defaults tests
- Result type correctness
- Default values

### Task 3: KeywordBiasConfig defaults test
- Config structure validation

### Task 4: FaeConfig.StreamingASRConfig tests
- Defaults, custom values, Codable round-trip

### Task 5: Build + test validation (1560 tests, 0 failures)

## Not completed (deferred to live testing)
- Eval corpus runs (Google Speech Commands, MS AEC Challenge)
- Partial latency validation against <100ms target
- Neural Engine / GPU contention measurement
- Real audio fixture tests

## Files modified
- `Tests/IntegrationTests/ParakeetStreamingEngineTests.swift` — 7 new tests
