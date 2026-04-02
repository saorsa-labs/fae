# Phase 1.3: FaeBenchmark Integration

## Context

Phase 1.2 wired TrainingBridge into the coordinator with loss-based proxy evaluation.
Phase 1.3 adds real inference-based evaluation via FaeBenchmark, storing baselines
in ImprovementStore and computing real EvalDelta from accuracy differences.

## Approach

FaeBenchmark is a `swift run FaeBenchmark` CLI that outputs JSON with accuracy metrics.
TrainingBridge gets a `runBenchmark()` method that:
1. Shells out to `swift run FaeBenchmark --model auto --tools --output <path>`
2. Parses the JSON output for accuracy metrics
3. Returns a `BenchmarkResult` struct

The coordinator stores baselines before training and computes real EvalDelta after.

## Tasks

### Task 1: Add BenchmarkResult type and runBenchmark() to TrainingBridge

- `BenchmarkResult` struct with accuracy fields matching ImprovementBaseline
- `runBenchmark(adapterPath: String?, outputPath: String)` method
- Parse ModelBenchmarkResult JSON from the --output file
- Handle: FaeBenchmark not built (graceful skip), timeout, parse errors

### Task 2: Add baseline capture/comparison to coordinator

- Before training: capture baseline via `bridge.runBenchmark(adapterPath: nil)`
- Store baseline in ImprovementStore via `insertBaseline()`
- After training: capture adapter result via `bridge.runBenchmark(adapterPath: adapter)`
- Compute real EvalDelta from accuracy differences
- Fall back to loss-based proxy if benchmark fails/unavailable

### Task 3: Tests

- BenchmarkResult parsing from sample JSON
- EvalDelta computation from baseline vs adapter
- Graceful fallback when benchmark unavailable
