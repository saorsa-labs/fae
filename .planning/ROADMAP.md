# Roadmap: Fae Apprenticeship Trust — Invisible Permissions

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
