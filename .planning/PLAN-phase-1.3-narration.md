# Phase 1.3: Narration + Countdown

**Milestone**: 1 — Invisible Permissions
**Phase**: 1.3
**Status**: in_progress

## Objective

Add post-action narration (Fae speaks what she just did) and 5-second countdown
for irreversible actions (mail, delegate_agent, agent_session) with barge-in
cancellation. This makes all tool actions transparent to the user without
requiring approval popups.

## Key Design Decisions

- `toolExecutorNarrateAction(_ text: String)` added to `ToolExecutorDelegate`
- `PipelineCoordinator` implements via a NEW interruptible variant (NOT speakDirect)
  - Post-action narration uses barge-in-ENABLED path so user can interrupt and undo
  - `bargeInState.pendingNarrationReceiptId` set before starting narration
  - On barge-in interrupt: if `pendingNarrationReceiptId` is set, attempt undo
- Read-only tools (notApplicable reversibility) get NO narration
- `toolExecutorCountdownBeforeIrreversible(_ text: String) async -> Bool` returns false if cancelled
  - 5 seconds countdown with barge-in checking
  - `bargeInState.isSuppressed = false` during countdown so user CAN interrupt
  - Returns `false` → ToolExecutor aborts execution of the irreversible action
- Irreversible tools requiring countdown: `mail` (send/reply/forward), `delegate_agent`, `agent_session`

## Files

- `Sources/Fae/Tools/ToolExecutorDelegate.swift` — add 2 new protocol methods
- `Sources/Fae/Tools/ToolExecutor.swift` — call narration after step 16; call countdown before step 14 for irreversible tools
- `Sources/Fae/Pipeline/BargeInState.swift` — add `pendingNarrationReceiptId: String?`
- `Sources/Fae/Pipeline/PipelineCoordinator.swift` — implement 2 new delegate methods

## Tasks

### Task 1: Add `pendingNarrationReceiptId` to BargeInState
- Add `var pendingNarrationReceiptId: String?` to `BargeInState`
- Add it to `clearAll()` reset
- File: `Sources/Fae/Pipeline/BargeInState.swift`

### Task 2: Add `toolExecutorNarrateAction` + `toolExecutorCountdownBeforeIrreversible` to ToolExecutorDelegate protocol
- `func toolExecutorNarrateAction(_ text: String, receiptId: String?) async`
- `func toolExecutorCountdownBeforeIrreversible(_ text: String) async -> Bool`
- File: `Sources/Fae/Tools/ToolExecutorDelegate.swift`

### Task 3: Implement `toolExecutorNarrateAction` in PipelineCoordinator
- New `speakInterruptible(_ text: String)` method (barge-in NOT suppressed)
- `toolExecutorNarrateAction`: set `bargeInState.pendingNarrationReceiptId = receiptId`, then call `speakInterruptible`
- Barge-in handler: if `bargeInState.pendingNarrationReceiptId` is set on interrupt, queue an undo
- File: `Sources/Fae/Pipeline/PipelineCoordinator.swift`

### Task 4: Implement `toolExecutorCountdownBeforeIrreversible` in PipelineCoordinator
- Announce the action: "Sending that email in 5 seconds. Say stop to cancel."
- Loop: check for barge-in interrupt once per second for 5 seconds
- If barge-in detected during loop: speak "Cancelled." and return false
- If no interrupt after 5s: return true
- barge-in check: read `bargeInState.pendingBargeIn != nil`
- File: `Sources/Fae/Pipeline/PipelineCoordinator.swift`

### Task 5: Wire narration call in ToolExecutor (after step 16)
- After step 16 (action receipt), if `!result.isError`:
  - Compute reversibility for current tool
  - Only narrate if reversibility != .notApplicable (skip read-only tools)
  - Build human-readable narration text from tool name + arguments
  - Call `await delegate?.toolExecutorNarrateAction(text, receiptId: receiptId)`
- `receiptId` = value returned from `store.createReceipt(...)` in step 16
- File: `Sources/Fae/Tools/ToolExecutor.swift`

### Task 6: Wire countdown call in ToolExecutor (before step 14)
- Add countdown check between step 13b and step 14
- Irreversible tools needing countdown: mail (non-read actions), delegate_agent, agent_session
- Call `await delegate?.toolExecutorCountdownBeforeIrreversible(description)`
- If returns false: return `.error("Action cancelled by user")`
- File: `Sources/Fae/Tools/ToolExecutor.swift`

### Task 7: Build and verify
- `cd native/macos/Fae && swift build 2>&1 | head -60`
- Fix any compiler errors
- Ensure zero warnings
