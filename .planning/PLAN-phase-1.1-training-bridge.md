# Phase 1.1: TrainingBridge Actor

## Context

ImprovementCycleCoordinator needs to call training scripts (build_dataset.py, train.py, train_dpo.py, check_status.py, evaluate.py) but can't use SkillManager.execute() because:
1. SkillManager sends JSON-RPC to stdin; scripts read sys.argv[1]
2. Coordinator needs synchronous lifecycle control (launch, poll, read results)
3. Training runs as a detached process — coordinator must poll check_status.py

TrainingBridge wraps Process calls to these scripts via uv, passing JSON args as argv[1].

## Files

- `Sources/Fae/Scheduler/TrainingBridge.swift` (NEW)
- `Tests/HandoffTests/TrainingBridgeTests.swift` (NEW)

---

### Task 1: Define TrainingBridge actor with script discovery

Create `Sources/Fae/Scheduler/TrainingBridge.swift`:

- `actor TrainingBridge`
- Inject `uvPath: String` (from UVRuntime) and `scriptDirectory: URL` (training-orchestrator scripts dir)
- `resolveScriptPath(_ name: String) -> URL` — locates script in Resources/Skills/training-orchestrator/scripts/
- `TrainingBridgeError` enum: scriptNotFound, executionFailed(exitCode, stderr), parseError, timeout, uvNotAvailable
- Helper: `runScript(name:params:timeoutSeconds:) async throws -> [String: Any]` — builds Process with `uv run --script <path>`, passes JSON-encoded params dict as argv[1], captures stdout, parses JSON result

### Task 2: Implement data export method

Add to TrainingBridge:

- `exportTrainingData(dbPath: String, outputDir: String, afterTimestamp: String?) async throws -> ExportResult`
- Calls `build_dataset.py` via `runScript`
- `ExportResult` struct: `sftExamples: Int`, `dpoPairs: Int`, `outputFiles: [String: String]`
- Parse the JSON-RPC result envelope from build_dataset.py stdout
- Default dbPath: `FaeDirectories.memoryDatabaseFile.path`
- Default outputDir: `FaeDirectories.trainingDataDirectory.path`

### Task 3: Implement training launch and status polling

Add to TrainingBridge:

- `launchTraining(mode: TrainingMode, preset: String) async throws -> TrainingLaunchResult`
  - `TrainingMode` enum: `.sft`, `.dpo`
  - Calls `train.py` (sft) or `train_dpo.py` (dpo) via `runScript`
  - `TrainingLaunchResult`: `pid: Int`, `adapterPath: String`, `modelId: String`
- `checkTrainingStatus() async throws -> TrainingStatus`
  - Calls `check_status.py` via `runScript`
  - `TrainingStatus` enum: `.running(pid: Int)`, `.completed(adapterPath: String)`, `.failed(reason: String)`
- `pollUntilComplete(intervalSeconds: Int, maxWaitSeconds: Int) async throws -> String`
  - Polls check_status.py every intervalSeconds
  - Returns adapter path on completion
  - Throws timeout error after maxWaitSeconds (default 7200 = 2h)

### Task 4: Implement evaluation method

Add to TrainingBridge:

- `evaluateAdapter(adapterPath: String) async throws -> TrainingEvalResult`
  - Calls `evaluate.py` via `runScript`
  - `TrainingEvalResult`: `score: Double`, `finalLoss: Double`, `recommendation: String` (upgrade/skip)

### Task 5: Add FaeDirectories training paths

Add to FaeDirectories (or wherever paths are centralized):

- `trainingDataDirectory` → `~/Library/Application Support/fae/training/data/`
- `trainingModelsDirectory` → `~/Library/Application Support/fae/models/personal/`
- `trainingRunFile` → `~/Library/Application Support/fae/training/run.json`
- Ensure directories are created on first access

### Task 6: Tests — TrainingBridgeTests

File: `Tests/HandoffTests/TrainingBridgeTests.swift`

- `testResolveScriptPath` — finds train.py in bundle resources
- `testRunScriptParsesJSON` — mock script that echoes JSON, verify parsing
- `testExportResultDecoding` — verify ExportResult from sample JSON
- `testTrainingLaunchResultDecoding` — verify TrainingLaunchResult from sample JSON
- `testTrainingStatusDecoding` — verify running/completed/failed states
- `testEvalResultDecoding` — verify TrainingEvalResult from sample JSON
- `testPollTimeoutThrows` — verify timeout after max wait
