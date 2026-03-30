# Phase 3.1: ImplicitFeedbackDetector

## Status: In Progress

## Context
Milestone 3 adds the feedback and verification layers. This phase creates the
ImplicitFeedbackDetector that analyzes conversation patterns to detect implicit
user satisfaction/dissatisfaction signals without requiring explicit feedback.

## Signal Types
1. **re_ask** — User repeats or rephrases the same question
2. **abandonment** — User changes topic without getting an answer
3. **follow_through** — User acts on Fae's suggestion (positive signal)
4. **interruption** — User interrupts/barge-in during response
5. **praise** — User expresses gratitude or satisfaction
6. **topic_change** — User changes topic after response (mild negative)
7. **silence_acceptance** — User accepts response without comment (mild positive)

## Tasks

### Task 1: ImplicitFeedbackDetector — signal detection logic
- Create `Sources/Fae/Pipeline/ImplicitFeedbackDetector.swift`
- Static methods for each signal type detection
- `detect(currentTurn:previousTurns:wasInterrupted:) -> [DetectedSignal]`
- DetectedSignal struct: signalType, confidence, evidence
- Each detector uses text similarity, keyword patterns, timing
- Files: `Sources/Fae/Pipeline/ImplicitFeedbackDetector.swift`

### Task 2: Signal-specific detection implementations
- re_ask: cosine similarity between current query and recent queries > 0.7
- abandonment: assistant response followed by unrelated user query (low similarity)
- follow_through: user references doing what was suggested ("I did", "done", "okay I'll")
- interruption: detect from wasInterrupted flag
- praise: keyword patterns ("thanks", "great", "perfect", "that's helpful")
- topic_change: low similarity to previous topic + not a follow-up
- silence_acceptance: assistant response was the last message (detected at next turn)
- Files: `Sources/Fae/Pipeline/ImplicitFeedbackDetector.swift`

### Task 3: ImplicitFeedbackDetectorTests
- Test each signal type with conversation snippets
- Test: re_ask detected when question is rephrased
- Test: abandonment detected when topic changes after unanswered question
- Test: follow_through detected when user confirms action
- Test: interruption detected from flag
- Test: praise detected from gratitude keywords
- Test: topic_change detected from low similarity
- Test: silence_acceptance detected from conversation flow
- Test: no false positives on normal conversation
- Files: `Tests/HandoffTests/ImplicitFeedbackDetectorTests.swift`

### Task 4: Build verification
- swift build passes
- All tests pass
