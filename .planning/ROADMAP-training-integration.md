# Roadmap: mlx-tune Training Integration

## Context

ImprovementCycleCoordinator has a complete state machine (idle→collecting→training→evaluating→proposing→deploying→idle) but training is a no-op stub. All pieces exist: training-data-bridge exports SFT/DPO data, training-orchestrator scripts run mlx-tune, FaeBenchmark evaluates adapters, MLXLLMEngine.loadAdapter() hot-swaps LoRA weights. They just need wiring.

## Key Interface Issue

SkillManager.execute() sends JSON-RPC to stdin, but training scripts read sys.argv[1]. The coordinator needs to call scripts via UVRuntime.createScriptProcess() with arguments, or fix the scripts to read stdin. We'll add a TrainingBridge actor that calls scripts directly via Process, bypassing SkillManager — the coordinator needs synchronous control over the training lifecycle (poll status, read results) that the skill execution protocol doesn't support.

## Success Criteria

- Overnight cycle exports real training data from fae.db
- mlx-tune SFT/DPO training runs as a detached process
- Coordinator polls until training completes (or times out)
- FaeBenchmark runs with --adapter to produce real EvalDelta
- Adapter is deployed via MLXLLMEngine.loadAdapter() on approval
- Full round-trip test: fake feedback → export → train → eval → deploy

---

## Milestone 1: End-to-End Training Pipeline

### Phase 1.1: TrainingBridge Actor
- Create TrainingBridge actor that calls training scripts via Process
- Handle data export (build_dataset.py), training launch (train.py/train_dpo.py), status polling (check_status.py), evaluation (evaluate.py)
- JSON argument passing via argv (matching existing script interface)
- Tests: mock script execution, argument serialization

### Phase 1.2: Wire Coordinator → TrainingBridge
- Replace training stub in runCycle() with real TrainingBridge calls
- Export data → launch training → poll until complete → read results
- Store adapter path in ImprovementState
- Wire real EvalDelta from FaeBenchmark baseline comparison
- Tests: full cycle with mock bridge, adapter path persistence

### Phase 1.3: FaeBenchmark Integration
- Add baseline capture (run benchmark without adapter, store in ImprovementStore)
- Add adapter evaluation (run benchmark with --adapter, compute deltas)
- EvalDelta from real accuracy differences, not zeros
- Tests: baseline storage, delta computation

### Phase 1.4: End-to-End Verification
- Integration test: seed feedback events → trigger cycle → verify adapter produced
- Verify adapter loads in MLXLLMEngine
- Verify rollback works (swap back to previous adapter)
- Update CLAUDE.md and docs
