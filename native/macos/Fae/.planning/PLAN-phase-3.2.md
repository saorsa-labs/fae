# Phase 3.2: Extract BargeInDecider + TTSStage

## Overview

Extract barge-in decision state and TTS orchestration state from PipelineCoordinator into
owned helper types. Follows Phase 3.1 pattern: plain classes/structs (NOT actors) to avoid
async boundary changes. Forwarding methods preserve API compatibility.

## Approach

**Key constraint**: Same as Phase 3.1 — no async boundary changes. Extract into owned
types called from the coordinator. PipelineCoordinator is an actor, so extracted types
are plain classes/structs owned by it.

**Baseline**: PipelineCoordinator 9,724 lines, 1560 tests passing.

## Tasks

### Task 1: Extract BargeInState into a consolidated struct

**Goal**: Move all barge-in related state variables into a single `BargeInState` struct,
similar to how `SpeakerGateState` consolidated speaker state in Phase 3.1.

**Files to create**:
- `Sources/Fae/Pipeline/BargeInState.swift`

**State to move from PipelineCoordinator**:
- `pendingBargeIn: PendingBargeIn?`
- `bargeInSuppressed: Bool`
- `playbackBargeInCandidate: PlaybackBargeInCandidate?`
- `playbackWakeWordDetected: Bool`
- `playbackInterruptKeywordDetected: Bool`
- `bargeInDenyCooldownUntil: Date?`
- `bargeInDenyCooldownSeconds: TimeInterval` (static constant)
- `generationTakeoverCandidate: GenerationTakeoverCandidate?`
- `falseInterruptionRecovery: FalseInterruptionRecovery`
- `lastAssistantTextBuffer: String`
- `interruptionDecider: any InterruptionDeciding`

**Methods to add**:
- `resetPlaybackBargeInState()` — clears playbackBargeInCandidate + wakeWord + interruptKeyword
- `recordInterruption(outcome:paused:)` — delegates to falseInterruptionRecovery
- `startDenyCooldown()` — sets bargeInDenyCooldownUntil
- `isInDenyCooldown` computed property
- `startSuppression()` / `endSuppression()` for bargeInSuppressed

**Coordinator changes**: Replace direct state access with `bargeInState.xxx`.

**Tests**: Build + all 1560 tests pass.

---

### Task 2: Extract TTSState into a consolidated struct

**Goal**: Move TTS orchestration state into a `TTSState` struct.

**Files to create**:
- `Sources/Fae/Pipeline/TTSState.swift`

**State to move from PipelineCoordinator**:
- `assistantSpeaking: Bool`
- `lastAssistantStart: Date?`
- `pendingTTSTask: Task<Void, Never>?`
- `lastUserTurnEndedAt: Date?`
- `ttfaEmittedForCurrentTurn: Bool`

**Methods to add**:
- `markSpeechStarted()` — sets speaking=true, lastStart=Date()
- `markSpeechEnded()` — sets speaking=false
- `isSpeechStuck(timeout:)` -> Bool — watchdog helper (>60s check)
- `resetForNewTurn()` — clears ttfaEmitted
- `cancelPendingTTS()` — cancels + nils pendingTTSTask

**Coordinator changes**: Replace direct state access with `ttsState.xxx`.
Note: `markAssistantSpeechStarted()` and `markAssistantSpeechEnded()` do more
(echo suppressor, bargeInState reset, VAD reset) — they stay as coordinator methods
but delegate state tracking to `ttsState`.

**Tests**: Build + all 1560 tests pass.

---

### Task 3: Move static barge-in decision functions to BargeInDecisions namespace

**Goal**: Move the 6 static barge-in decision functions from PipelineCoordinator into
a `BargeInDecisions` enum namespace in `BargeInState.swift`. These are already pure
functions (no self access) — perfect for extraction.

**Functions to move**:
- `shouldTrackBargeIn(assistantSpeaking:)`
- `shouldTrackGenerationTakeover(assistantSpeaking:assistantGenerating:)`
- `advancePendingBargeIn(pending:speechStarted:...)`
- `shouldAllowBargeInInterrupt(assistantSpeaking:assistantGenerating:)`
- `shouldStartDeferredFollowUp(originTurnID:currentTurnID:...)`
- `coalescedDeferredProactiveTaskIDs(existing:incomingTaskID:)`

**Coordinator changes**: Forward to `BargeInDecisions.xxx`. Preserve
`PipelineCoordinator.shouldTrackBargeIn(...)` etc. as forwarding static methods
so existing call sites and tests don't break.

**Tests**: Build + all 1560 tests pass.

---

### Task 4: Move verifyBargeInSpeaker and handleBargeInWithVerification logic

**Goal**: Extract the private barge-in verification and execution helpers into
methods on `BargeInState`, passing needed dependencies as parameters instead
of accessing coordinator ivars.

**Functions to refactor**:
- `handleBargeInWithVerification(barge:)` — extract the decision logic (RMS check,
  holdoff check, fae_self echo check) into `BargeInState.shouldAllowBargeIn(barge:holdoffMs:minRms:lastAssistantStart:)`.
  The side effects (setting interrupted, cancelling TTS, pausing playback) stay in coordinator.
- `executePlaybackBargeIn(candidate:)` — similar: extract condition checks, keep side effects.
- `isGenerationInterrupted(_:)` — move to coordinator-level (stays, it uses interrupted/interruptedGenerationID).
- `markGenerationInterrupted()` — stays in coordinator (writes interrupted state).

**Coordinator changes**: Coordinator calls `bargeInState.shouldAllowBargeIn(...)` then
performs side effects locally. Reduces coordinator method complexity.

**Tests**: Build + all 1560 tests pass.

---

### Task 5: Integration verification and line count audit

**Goal**: Verify the extraction reduced coordinator complexity and all tests pass.

**Checks**:
- `swift build` — zero warnings
- `swift test` — 1560 tests, 0 failures
- Line count: PipelineCoordinator should be ~200-400 lines shorter
- State variable count: ~15+ fewer vars in coordinator
- New files have doc comments on all public types/methods
- No force unwraps in new code

**Update**: progress.md with Phase 3.2 evidence.
