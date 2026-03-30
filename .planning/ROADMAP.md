# Roadmap: Fae Development

## Active: Autonomous Self-Improvement Loop

### Design Documents
- Design doc: `~/.gstack/projects/saorsa-labs-fae/davidirvine-main-design-20260330-181623.md`
- CEO plan: `~/.gstack/projects/saorsa-labs-fae/ceo-plans/2026-03-30-autonomous-self-improvement.md`
- Test plan: `~/.gstack/projects/saorsa-labs-fae/davidirvine-main-eng-review-test-plan-20260330-183512.md`
- Eng review: CLEARED (7 issues resolved, Codex challenge done)
- CEO review: CLEARED (3 expansions accepted, 1 deferred)

### Success Criteria
- Fae automatically trains on accumulated corrections without human intervention
- Eval benchmarks show measurable improvement (or no regression) after each cycle
- External agent review catches at least one issue in first 10 cycles
- Non-technical user notices Fae getting better without knowing why
- Zero security incidents from autonomous self-modification
- 38+ tests passing, full coverage

---

### Milestone 1: Adapter Infrastructure (Prerequisites)

#### Phase 1.1: MLXLLMEngine LoRA Adapter Loading ← YOU ARE HERE
- Verify mlx-swift-lm LoRA adapter API availability
- Add `load(modelID:adapterPath:)` overload to MLXLLMEngine
- Smoke test: train tiny adapter with mlx-tune, load in Swift, verify inference
- Tests: adapter loading, invalid path fallback, adapter hot-swap

#### Phase 1.2: Adapter Deployment Mechanism
- Add `training.personalAdapterPath` to SelfConfigTool adjustable keys
- Add patchConfig case in FaeCore for adapter path changes
- PipelineCoordinator observes adapter path change → reloads MLXLLMEngine
- Tests: config patching, engine reload on adapter change

#### Phase 1.3: FaeBenchmark --adapter Flag
- Add `--adapter <path>` CLI argument to FaeBenchmark
- Run eval suite with base model, then with adapter overlay
- Output comparison JSON with per-metric deltas
- Tests: CLI parsing, comparison output format

### Milestone 2: Improvement Loop Core

#### Phase 2.1: ImprovementStore (improvement.db)
- Create new improvement.db SQLite database (separate from fae.db and scheduler.db)
- Tables: feedback_events, improvement_baselines, improvement_state, capability_gaps, shadow_eval
- CRUD methods for all tables
- Tests: insert/query/update, persistence across restarts

#### Phase 2.2: ImprovementCycleCoordinator
- Deterministic actor with state machine: IDLE → COLLECTING → TRAINING → EVALUATING → PROPOSING → DEPLOYING → IDLE
- Scheduler integration: improvement_cycle task in 02:00-05:00 window
- TrustedActionBroker allowlist: ["activate_skill", "run_skill", "delegate_agent", "self_config"]
- Minimum data threshold: skip if <20 feedback events or <5 corrections
- Tests: all state transitions, error paths, idempotency

#### Phase 2.3: Semi-Automatic Deployment
- Morning proposal with specific + personal messaging
- Earned auto-deploy after 5 user-approved cycles
- Adapter rollback: current_adapter / previous_adapter tracking
- Tests: proposal generation, approval flow, auto-promote

### Milestone 3: Feedback + Verification

#### Phase 3.1: ImplicitFeedbackDetector
- 7 signal types: re-ask, abandonment, follow-through, interruption, praise, topic_change, silence_acceptance
- PipelineCoordinator post-turn integration
- Tests: each signal type with conversation snippets

#### Phase 3.2: External Agent Review Gate
- Fallback chain: Codex → Claude Code → internal self-review
- Gate: PASS/FAIL/CONCERN with 3-deferral maximum
- SecurityEventLogger audit trail
- Tests: fallback chain, deferral counting

#### Phase 3.3: Directive-Based Fast Tuning
- Weekly sub-phase (every 7th nightly cycle)
- Detect feedback patterns → generate directive amendments
- Tests: pattern detection, directive generation, rollback

### Milestone 4: Shadow Eval + Hardening

#### Phase 4.1: Shadow Evaluation
- Overnight-only replay (alternate nights from training)
- Promotion gate: shadow wins >= 60% episodes AND no eval regression
- Tests: episode storage, replay scoring, promotion gate

#### Phase 4.2: CEO Expansions
- Git Vault backup for improvement.db + adapters
- Self-diagnostic integration for improvement health
- Tests: vault backup, diagnostic reports

#### Phase 4.3: Full Test Suite
- 38+ unit tests, integration tests, adapter round-trip test

### Parallelization

```
Lane A: Phase 1.1 → 1.2 → 1.3 (adapter infrastructure)
Lane B: Phase 2.1 (ImprovementStore, independent) → 3.1 (ImplicitFeedbackDetector)
Lane C: Phase 2.2 + 2.3 (coordinator, depends on A+B merge)
Phase 3.2, 3.3, 4.x: sequential after C
```

---

## Completed: Apprenticeship Trust — Invisible Permissions (v0.8.178)

# Previous Roadmap: Fae Apprenticeship Trust — Invisible Permissions

> Replace user-facing permission surfaces with narration-first, undo-based safety.
> Owner already gets zero popups (ToolExecutor:448). This milestone adds the missing pieces.

## Design Documents

- Design doc: `~/.gstack/projects/saorsa-labs-fae/davidirvine-main-design-20260328-094601.md`
- Test plan: `~/.gstack/projects/saorsa-labs-fae/davidirvine-main-eng-review-test-plan-20260328.md`
- Eng review: CLEARED (2 critical gaps tracked in TODOS.md)

## Success Criteria

- >95% of owner sessions with zero approval interruptions (already mostly true)
- Non-technical user completes useful task on first use without permission prompts
- Action receipts provide full undo coverage for file operations + Apple app CRUD
- 30 new tests across 5 test files, all passing
- SOUL.md and HEARTBEAT.md contracts updated for narration-first behavior

---

## Milestone 1: Invisible Permissions (Phase 1)

### Phase 1.1: Prerequisites
- Update SOUL.md narration clause (Tools section, add narration-as-transparency)
- Update HEARTBEAT.md with "Invisible Permissions" section
- Add `speakerId: String?` to ActionIntent + ToolExecutorContext
- Wire speakerId from PipelineCoordinator speaker state through to ToolExecutor
- Add `receiptsFile` path to FaeDirectories (Core/FaeEnvironment.swift)

### Phase 1.2: ActionReceipts Engine
- Create `ReceiptStore.swift` (actor, GRDB DatabaseQueue, separate receipts.db)
- Schema: action_receipts table with full column spec
- ActionReversibility enum with per-tool classification (all 37 tools)
- BashReversibilityClassifier (allowlist only: echo>file, cp, mkdir, mv, touch)
- `createReceipt()` — called from ToolExecutor after auto-approve (line 460) and manual approve (line 475)
- `undo(receiptId:)` — restore from pre_state snapshot via ReversibilityEngine
- `batchUndo(since:)` — reverse chronological order
- `pruneExpired()` — GC for expired receipts, max 10,000 retained
- Pre-state blob cap at 50MB (larger files skip blob, receipt still created)
- Wire GC into FaeScheduler (piggyback on memory_gc at line 395)
- Add receipts.db to GitVaultManager backup list
- Pre-state capture for Apple tools: calendar (event JSON), reminders (reminder JSON)

### Phase 1.3: Narration + Countdown
- New `toolExecutorNarrateAction(_ text: String)` in ToolExecutorDelegate protocol
- PipelineCoordinator implements via `speakDirect()`
- Post-action narration after tool execution ("I saved that note to your Desktop")
- No narration for read-only tools
- Tag receipt ID at narration start in barge-in state
- Barge-in during narration offers undo of tagged receipt
- 5-second narrated countdown for irreversible actions (mail, delegate_agent, agent_session)
- Barge-in during countdown cancels the action

### Phase 1.4: Settings + UI
- Transform SettingsToolsTab: hide mode picker, add informational showcase
- "What Fae Can Do" — capability cards with safety explanations
- "What I Changed" surface — action receipts timeline with one-tap undo
- Voice-accessible: "What have you changed today?"
- Group by time: "This conversation", "Today", "This week"

### Phase 1.5: Full Test Suite
- EndToEndOwnerSilentModeTests.swift (15 tests)
- EndToEndBashReversibilityTests.swift (5 tests)
- EndToEndNarrationAndBargeInTests.swift (5 tests)
- EndToEndIrreversibleCountdownTests.swift (3 tests)
- EndToEndBatchUndoTests.swift (2 tests)
- MockReceiptStore + MockReceiptCapturingTool in TestDoubles
- TestRuntimeHarness extended with receiptStore

---

## Parallelization

```
Lane C: Phase 1.1 (prerequisites, independent)  ──┐
Lane B: Phase 1.4 (settings/UI, independent)    ──┤── parallel
                                                   │
Lane A: Phase 1.2 (receipts) → 1.3 (narration)  ──┘── after 1.1

Phase 1.5: tests (after all code ships)
```
