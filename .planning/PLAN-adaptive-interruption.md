# Plan: Adaptive Interruption Handling for Fae

## Goal
Improve Fae's barge-in and turn-taking behavior by adding an **adaptive interruption layer** on top of the existing VAD pipeline.

This plan is explicitly **not** a VAD replacement plan.

Instead:
- keep VAD for low-latency speech onset/offset primitives
- keep echo suppression and owner verification
- replace naive interruption confirmation with a richer interruption decision layer
- add false-interruption recovery
- improve endpointing over time using transcript-aware heuristics

---

## Why this plan

Fae already has a solid foundation:
- `VoiceActivityDetector` (Silero-backed)
- `EchoSuppressor`
- owner-verified barge-in
- keyword interrupt spotting
- streaming STT partials

Current interruption handling is still mainly threshold-driven:
- speech onset from VAD
- RMS threshold
- fixed confirmation duration
- owner verification

This works, but it can still false-trigger on:
- short overlap bursts
- background TV/noise
- speaker bleed / room echo edge cases
- small backchannels like “yeah”, “mm”, “right”

LiveKit’s adaptive interruption handling suggests a better shape:
- keep VAD primitives
- add a higher-level interruption decision system
- separate “someone made sound” from “the user is actually interrupting”

---

## Non-goals

- Do **not** remove or replace `VoiceActivityDetector`
- Do **not** add a mandatory network dependency for interruption detection
- Do **not** block shipping on a new ML model
- Do **not** weaken owner verification or existing echo suppression safeguards

---

## Current Architecture Review

### Existing components

#### `VoiceActivityDetector`
**File:** `native/macos/Fae/Sources/Fae/Pipeline/VoiceActivityDetector.swift`
- Silero VAD-backed utterance segmentation
- speech onset/offset
- pre-roll + silence thresholding
- max segment duration

#### `EchoSuppressor`
**File:** `native/macos/Fae/Sources/Fae/Pipeline/EchoSuppressor.swift`
- echo tail window
- short utterance guard
- post-playback rejection logic
- amplitude cap during recent playback

#### `PipelineCoordinator` barge-in logic
**File:** `native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift`
Key existing pieces:
- `advancePendingBargeIn(...)`
- `handleBargeInWithVerification(...)`
- `shouldAllowBargeInInterrupt(...)`
- dynamic silence threshold selection while assistant is speaking
- playback event coupling (`assistantSpeaking`, `lastAssistantStart`)

#### `StreamingSTTEngine` and `KeywordSpotter`
**Files:**
- `native/macos/Fae/Sources/Fae/ML/StreamingSTTEngine.swift`
- `native/macos/Fae/Sources/Fae/Pipeline/KeywordSpotter.swift`

Provides:
- partial transcript stream
- interrupt phrase detection
- low-latency text evidence that can improve interruption decisions

#### Config
**File:** `native/macos/Fae/Sources/Fae/Core/FaeConfig.swift`
Current interruption tuning:
- `bargeIn.minRms`
- `bargeIn.confirmMs`
- `bargeIn.assistantStartHoldoffMs`
- `bargeIn.bargeInSilenceMs`

---

## Proposed Architecture

Add a new layer between raw overlap detection and actual interruption:

```text
AudioCapture
  → VoiceActivityDetector
  → EchoSuppressor gate
  → Pending overlap candidate
  → AdaptiveInterruptionDecider
      → ignore
      → keep collecting
      → interrupt now
  → owner verification
  → playback / generation interruption
```

### New responsibilities

#### VAD remains responsible for:
- speech/no-speech primitives
- onset timing
- segmentation
- silence timing

#### Adaptive interruption becomes responsible for:
- deciding whether overlap is meaningful
- filtering backchannels / noise / transient bursts
- combining acoustic + transcript + timing evidence
- triggering interruptions earlier or later than fixed-threshold logic

---

## New Components

### 1. `InterruptionTypes.swift`
**New file:** `native/macos/Fae/Sources/Fae/Pipeline/InterruptionTypes.swift`

Define the shared types:

```swift
struct InterruptionInput: Sendable {
    let assistantSpeaking: Bool
    let speechStarted: Bool
    let isSpeech: Bool
    let rms: Float
    let chunkSamples: [Float]
    let overlapDurationMs: Int
    let assistantSpeechElapsedMs: Int
    let echoSuppression: Bool
    let bargeInSuppressed: Bool
    let inDenyCooldown: Bool
    let partialTranscript: String?
    let partialWordCount: Int
    let hasInterruptKeyword: Bool
}

enum InterruptionDecision: Sendable, Equatable {
    case ignore(reason: String)
    case candidate
    case interruptNow(reason: String)
}
```

Also define a small state container for ongoing overlap tracking if needed.

---

### 2. `InterruptionDeciding` protocol
**New file or same file as above**

```swift
protocol InterruptionDeciding: Sendable {
    mutating func process(_ input: InterruptionInput) -> InterruptionDecision
    mutating func reset()
}
```

This allows:
- current threshold behavior to be preserved behind a strategy
- adaptive policy to be swapped in without destabilizing the pipeline
- future ML decider without reworking the coordinator again

---

### 3. `LegacyThresholdInterruptionDecider`
**New file:** `native/macos/Fae/Sources/Fae/Pipeline/LegacyThresholdInterruptionDecider.swift`

Purpose:
- preserve current duration/RMS logic
- make refactor safe
- provide a control baseline in tests

Behavior:
- mimic current `confirmMs` + `minRms` behavior as closely as possible
- no product change in the extraction step

---

### 4. `AdaptiveInterruptionDecider`
**New file:** `native/macos/Fae/Sources/Fae/Pipeline/AdaptiveInterruptionDecider.swift`

Purpose:
- replace raw fixed confirmation logic with a richer heuristic model

Inputs used:
- overlap duration
- RMS / energy persistence
- partial transcript presence
- partial transcript word count
- keyword interrupt hit
- holdoff window after playback start
- echo suppressor state
- deny cooldown state

Output:
- `ignore`
- `candidate`
- `interruptNow`

---

## Decision Policy (Phase 1 heuristic version)

### Immediate interrupt conditions
Interrupt immediately when:
- interrupt keyword matched (`stop`, `quiet`, `shut up`, etc.)
- assistant is audibly speaking
- not echo suppressed
- not barge-in suppressed
- outside assistant-start holdoff

This path should still go through owner verification before actually interrupting.

### Strong adaptive interrupt conditions
Interrupt when all are true:
- overlap duration >= 300–450ms
- and (`partialWordCount >= 1` **or** sustained RMS / continuous speech evidence)
- and assistant is audibly speaking
- and not echo suppressed
- and not in deny cooldown
- and outside assistant-start holdoff

### Ignore conditions
Ignore when any of these are true:
- overlap duration < 200ms
- no text evidence and low RMS
- likely echo-tail residue
- overlap starts during barge-in suppression window
- transcript matches a backchannel phrase only

### Backchannel suppression list (initial)
Treat as weak / ignorable unless sustained:
- `mm`
- `mhm`
- `uh-huh`
- `yeah`
- `right`
- `okay`
- `ok`
- `wow`

These should not hard interrupt unless the user continues speaking.

---

## False Interruption Recovery

### Problem
Sometimes Fae may stop herself even though the user only made a tiny acknowledgment or noise.

### Approach
Add a recovery window after interruption:
- if interruption fired
- but no meaningful continued transcript appears within ~1.5–2.0s
- treat it as a false interruption

### Initial recovery behavior
Do **not** resume raw audio playback.
Instead:
- preserve interrupted assistant text buffer if available
- produce a short repair utterance such as:
  - “I thought you were jumping in — I was saying …”

This is safer and easier than resuming partial TTS.

---

## Dynamic Endpointing Improvements

After adaptive interruption is stable, improve endpointing.

### Current state
Fae already adjusts silence thresholds contextually in `PipelineCoordinator.silenceThresholdMs(...)`.

### Next step
Incorporate transcript-aware signals:
- unfinished phrase heuristics
- punctuation / clause completion
- interruption-prone recent history
- conversational follow-up mode

### Desired outcome
- shorter delay after clearly complete utterances
- longer delay after likely incomplete thoughts
- fewer premature turn cuts

This should remain heuristic-first.

---

## Suggested Config Additions

**File:** `native/macos/Fae/Sources/Fae/Core/FaeConfig.swift`

Add a nested adaptive interruption config:

```toml
[adaptiveInterruption]
enabled = true
minOverlapMs = 300
minInterruptWords = 1
ignoreBackchannels = true
falseInterruptionTimeoutMs = 1800
resumeFalseInterruption = true
rmsSustainFloor = 0.08
```

### Notes
- Keep existing `[bargeIn]` settings during migration
- use old settings as fallback defaults where possible
- do not remove `bargeIn` immediately

---

## Implementation Milestones

## Milestone 1: Refactor without behavior change

### Task 1
Add `InterruptionTypes.swift`

### Task 2
Extract current interruption logic into `LegacyThresholdInterruptionDecider`

### Task 3
Have `PipelineCoordinator` call the decider instead of directly using `confirmMs` logic

### Acceptance
- No user-visible behavior change
- Existing interruption tests still pass
- `swift build` + `swift test` pass

---

## Milestone 2: Heuristic adaptive interruption

### Task 1
Implement `AdaptiveInterruptionDecider`

### Task 2
Plumb STT partial transcript / word count / keyword hit into the decider input

### Task 3
Add backchannel suppression rules

### Task 4
Add config-driven thresholds

### Acceptance
- Fewer false barge-ins in manual testing
- Interrupt keywords still fire quickly
- Owner verification still gates real interruption

---

## Milestone 3: False interruption recovery

### Task 1
Track interruption outcome window

### Task 2
Detect false interruption by silence/no meaningful follow-up

### Task 3
Add repair utterance path

### Acceptance
- Fae recovers gracefully from accidental interruption
- No dead-air / stuck playback state

---

## Milestone 4: Dynamic endpointing improvements

### Task 1
Add transcript-aware heuristics to endpoint timing

### Task 2
Tune silence windows by utterance completeness and recent interaction pattern

### Task 3
Validate unfinished-sentence behavior

### Acceptance
- fewer premature end-of-turns
- faster response after clearly complete questions

---

## Milestone 5: Optional ML spike

### Task 1
Benchmark heuristic interruption quality

### Task 2
If needed, prototype a small local interruption classifier

### Task 3
Compare against heuristic baseline

### Acceptance
- only continue if materially better than heuristic approach
- no mandatory network dependency introduced

---

## Test Plan

### Unit tests
**New file:** `native/macos/Fae/Tests/HandoffTests/AdaptiveInterruptionDeciderTests.swift`

Add coverage for:
- ignores brief overlap burst
- ignores echo-tailed short noise
- interrupts on keyword hit
- interrupts on sustained overlap + transcript evidence
- ignores pure backchannel utterance
- respects holdoff window
- respects suppression / deny cooldown
- emits false interruption recovery decision appropriately

### Integration tests
Likely in:
- `native/macos/Fae/Tests/HandoffTests/...`
- possibly `IntegrationTests/` if full playback interaction is needed

Scenarios:
- assistant speaking + user says “stop” → interrupt immediately
- assistant speaking + TV/noise burst → no interrupt
- assistant speaking + user says “actually…” → interrupt
- assistant speaking + short “yeah” → do not hard interrupt
- interrupted generation cancels playback and keeps conversation state sane

### Manual live validation
Required:
- speakers on (worst-case echo path)
- headphones
- owner voice
- non-owner voice
- whisper / normal / loud interruptions
- long TTS reply interrupted mid-sentence
- approval flow and `speakDirect` non-interruptible windows

---

## Risks

### Risk 1: overfitting to one room / microphone setup
**Mitigation:** keep thresholds configurable and test with real speakers/headphones/noisy room

### Risk 2: slower interruption response
**Mitigation:** preserve keyword immediate interrupt path and keep heuristic decisions lightweight

### Risk 3: accidental weakening of owner verification
**Mitigation:** adaptive decider must never bypass `verifyBargeInSpeaker(audio:)`

### Risk 4: recovery logic feels unnatural
**Mitigation:** start with simple repair utterance, not audio resume

---

## Recommendation

### Build now
- strategy extraction
- heuristic adaptive interruption
- false interruption recovery

### Defer until needed
- external LiveKit inference service
- full ML interruption model
- replacing VAD

---

## Bottom Line

Fae should evolve from:
- **plain VAD + fixed interruption thresholds**

to:
- **VAD primitives + adaptive interruption decisions + recovery**

This is the safest and highest-leverage path to better turn-taking without compromising the existing local-first voice architecture.
