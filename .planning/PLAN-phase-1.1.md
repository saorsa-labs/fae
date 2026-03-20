# Phase 1.1: Echo suppressor as signal, not gate

## Problem
Barge-in candidates are NEVER created while Fae speaks because:
1. `advancePendingBargeIn()` (line 7216) kills candidates when `echoSuppression=true`
2. `echoSuppressor.isInSuppression` returns `true` the entire time `assistantSpeaking=true` (line 61-62)
3. `AdaptiveInterruptionDecider.process()` (line 37-39) also hard-gates on `echoSuppression`

Result: The decider never runs. Barge-in is architecturally impossible during playback.

## Fix Strategy
- Remove echo suppression as a creation gate for barge-in candidates
- Remove echo suppression as a hard gate in the adaptive decider
- Keep echo suppression as a SIGNAL in InterruptionInput (the decider can use it for weighting)
- Keep echo suppression as a gate for SEGMENT ACCEPTANCE (shouldAccept) — that's for STT, not barge-in
- Reduce echo tail from 2000ms to 800ms
- Reduce holdoff from 500ms to 200ms
- Lower adaptive thresholds

## Tasks

### Task 1: Remove echo suppression gate from advancePendingBargeIn
**File:** `Sources/Fae/Pipeline/PipelineCoordinator.swift` lines 7205-7238
- Remove `echoSuppression` parameter from `advancePendingBargeIn()`
- Remove the `echoSuppression` check at line 7216 and 7218
- Update call site at line 3384-3393 to not pass echoSuppression
- Keep `bargeInSuppressed` and `inDenyCooldown` as hard gates (those are intentional)

### Task 2: Change echo suppression from hard gate to signal in adaptive decider
**File:** `Sources/Fae/Pipeline/AdaptiveInterruptionDecider.swift` lines 35-39
- Remove the hard `echoSuppression` gate (lines 37-39)
- Instead: when `echoSuppression=true`, require STRONGER evidence to interrupt
  - Raise overlap threshold by 100ms
  - Require keyword OR transcript evidence (not just acoustic)
  - This filters noise/echo while allowing deliberate speech through

### Task 3: Do the same for LegacyThresholdInterruptionDecider
**File:** `Sources/Fae/Pipeline/LegacyThresholdInterruptionDecider.swift`
- Remove hard `echoSuppression` gate
- When echoSuppression=true, double the confirmMs threshold (require longer overlap)

### Task 4: Reduce echo tail and holdoff timing
**Files:**
- `Sources/Fae/Pipeline/EchoSuppressor.swift` lines 26-29: reduce echoTailMs 2000→800, shortUtteranceGuardMs 2500→1200
- `Sources/Fae/Core/FaeConfig.swift` line 225: reduce confirmMs 350→200
- `Sources/Fae/Core/FaeConfig.swift` line 226: reduce assistantStartHoldoffMs 500→200

### Task 5: Lower adaptive decider thresholds
**File:** `Sources/Fae/Pipeline/InterruptionTypes.swift` lines 100-115
- minOverlapMs: 300→150
- rmsSustainFloor: 0.06→0.04
- minSustainedChunks: 4→2
- peakRmsRatio: 1.5→1.2

### Task 6: Update tests
**File:** `Tests/HandoffTests/AdaptiveInterruptionDeciderTests.swift`
- Update existing tests for new thresholds
- Add test: barge-in candidate created during echo suppression
- Add test: adaptive decider allows interrupt during echo suppression with strong evidence
- Add test: adaptive decider rejects weak signal during echo suppression
- Add test: keyword interrupt works during echo suppression
- Add test: reduced holdoff timing
- Ensure all 19+ existing tests still pass (adjust thresholds as needed)
