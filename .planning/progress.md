# Progress Log

## 2026-03-28

### Phase 1.3: Narration + Countdown — COMPLETE (commits e0a01ffc, edd63fa5)
- [x] Task 1: Add pendingNarrationReceiptId to BargeInState
- [x] Task 2: Add toolExecutorNarrateAction + toolExecutorCountdownBeforeIrreversible to ToolExecutorDelegate
- [x] Task 3: Implement toolExecutorNarrateAction in PipelineCoordinator (with speakInterruptible + barge-in undo)
- [x] Task 4: Implement toolExecutorCountdownBeforeIrreversible in PipelineCoordinator (5s poll loop)
- [x] Task 5: Wire narration call in ToolExecutor (step 17, after receipt creation)
- [x] Task 6: Wire countdown gate in ToolExecutor (step 13d, before execution)
- [x] Task 7: Build + tests pass (7/7), zero new warnings

### Phase 1.1: Prerequisites

### Phase 1.4 Complete — 2026-03-28
- [x] Task 1: ReceiptsTimelineView — grouped timeline with undo buttons
- [x] Task 2: ReceiptsWindowController — floating NSPanel for receipt history
- [x] Task 3: ConversationWindowView — receipts icon in header with badge
- [x] Task 4: FaeApp — wire ReceiptsWindowController + notification observer
- [x] Task 5: SettingsToolsTab — capability showcase, no mode picker
- [x] Task 6: Build verification — swift build passes zero errors/warnings
- Commit: 841dd9d6

### Phase 1.5 Starting...

### Phase 1.5: Full Test Suite — COMPLETE (2026-03-28)
- [x] Task 1: MockReceiptStore + MockReceiptCapturingTool added to TestDoubles.swift
- [x] Task 2: TestRuntimeHarness extended with receiptStore + makeBroker() helper
- [x] Task 3-5: EndToEndOwnerSilentModeTests.swift (15 tests) — broker decisions, receipt creation, undo
- [x] Task 6: EndToEndBashReversibilityTests.swift (5 tests + 9 extras = 15 total)
- [x] Task 7: EndToEndNarrationAndBargeInTests.swift (5 tests + 3 extras = 8 total)
- [x] Task 8: EndToEndIrreversibleCountdownTests.swift (3 tests + 5 extras = 8 total)
- [x] Task 9: EndToEndBatchUndoTests.swift (2 tests + 1 extra = 3 total)
- [x] Bonus: Fixed ReceiptStore.record(from:) Int64 cast bug (GRDB returns Int64 not Int for INTEGER)
- [x] Task 10: Full test suite passes — 1683 tests, 5 pre-existing failures (0 unexpected), 0 regressions

### MILESTONE 1: Invisible Permissions — COMPLETE
All phases 1.1 through 1.5 done.
- [x] Phase 1.2: Adapter Deployment Mechanism (commit: 4974fcd4)

### Phase 1.2 Complete - Mon Mar 30 20:21:11 BST 2026
### Phase 1.3 Starting...

### Phase 1.2 Complete - 
- [x] Task 1: Add training.personal_adapter_path to SelfConfigTool adjustableKeys
- [x] Task 2: Add patchConfig cases in FaeCore (hot-swap dispatch)
- [x] Task 3: PipelineCoordinator.applyAdapterChange(path:)
- [x] Task 4: LLMEngine.swapAdapter protocol method (default no-op)
- [x] Task 5: AdapterDeploymentTests.swift (9 tests passing)

### Phase 1.3 Already Implemented (commit 4974fcd4)
- [x] --adapter CLI flag in FaeBenchmark
- [x] AdapterComparisonResult + MetricDelta output structures
- [x] buildComparison() base vs adapter delta computation
- [x] isComparisonMode path in main benchmark loop

### MILESTONE 1: Adapter Infrastructure — COMPLETE
Phases 1.1, 1.2, and 1.3 all done.
- [x] Phase 1.3: FaeBenchmark --adapter Flag (commit: 0afac0fd)

### Milestone 1: Adapter Infrastructure COMPLETE - Mon Mar 30 20:25:25 BST 2026
### Milestone 2: Improvement Loop Core Starting...

### Phase 2.1: ImprovementStore (improvement.db) -- COMPLETE
- [x] ImprovementStore.swift: 5 tables, full CRUD, raw SQL with StatementArguments
- [x] FaeDirectories.improvementDatabase path added
- [x] open(at:) overload for test isolation
- [x] ImprovementStoreTests.swift: 23 tests (all pass)
  - FeedbackEvent CRUD (5 tests)
  - ImprovementBaseline CRUD (3 tests)
  - ImprovementState CRUD (4 tests)
  - CapabilityGap CRUD (2 tests)
  - ShadowEvalEpisode CRUD (4 tests)
  - Error paths + persistence (5 tests)
- Commit: 840abb12

### Phase 2.1 Complete - Sun Mar 30 21:35:00 BST 2026

### Phase 2.2: ImprovementCycleCoordinator -- COMPLETE
- [x] CycleState enum with valid successor enforcement
- [x] ImprovementCycleCoordinator actor (state machine + runCycle)
- [x] Stuck detection (2h timeout → force reset to idle)
- [x] Minimum data thresholds (20 events, 5 corrections)
- [x] Scheduler integration (daily 03:00, lazy store open)
- [x] TrustedActionBroker allowlist for improvement_cycle
- [x] ImprovementCycleCoordinatorTests: 11 tests (all pass)
- Commit: 156e3260

### Phase 2.2 Complete - Sun Mar 30 21:44:00 BST 2026
### Phase 2.3 Starting...
