# Phase 1.3: FaeBenchmark --adapter Flag

**Milestone**: Milestone 1 — Adapter Infrastructure
**Phase**: 1.3
**Status**: IN PROGRESS

## Objective

Add `--adapter <path>` CLI argument to FaeBenchmark so it can run the eval suite
with a LoRA adapter overlaid on the base model, then output comparison JSON with
per-metric deltas (base vs adapter).

## Tasks

### Task 1: Add --adapter CLI argument + pass to BenchmarkEngine
- Add `adapterPath: String?` to `CLIArgs`
- Parse `--adapter <path>` in `parseArgs()`
- Add `--adapter` to `printUsage()` help text
- Add `adapterPath: String?` parameter to `BenchmarkEngine.init()`
- In `BenchmarkEngine.load()`, after loading base model, if adapterPath is set call `engine.loadAdapter(from:)`
- Add `adapterPath` to `benchmarkModel()` parameter list, pass through to engine
- In `run()`, pass `args.adapterPath` to `benchmarkModel()`

### Task 2: Add adapterPath to ModelBenchmarkResult + BenchmarkOutput
- Add `adapterPath: String?` field to `ModelBenchmarkResult` (with CodingKey)
- Populate it from the engine/args
- Print adapter info in console output header when set

### Task 3: Comparison mode — run base then adapter, output deltas
- When `--adapter` is passed, run each model TWICE: once base, once with adapter
- Create `ComparisonResult` struct with per-metric deltas
- Add `--compare` output mode that emits comparison JSON
- Output comparison JSON showing: tool_calling accuracy delta, intelligence delta, fae_capability delta, assistant_fit delta, serialization delta, throughput delta

### Task 4: Build verification
- Ensure `just build-benchmark` passes with zero warnings
- Ensure existing benchmark CLI still works without --adapter flag

## Files to modify
- `Sources/FaeBenchmark/main.swift` — CLI args, engine, run(), output
