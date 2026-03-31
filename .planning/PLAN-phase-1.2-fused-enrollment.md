# Phase 1.2: Fused Enrollment Flow

## Goal
Replace the existing 4-step SpeakerEnrollmentView with a 6-step fused enrollment that captures wake phrases for acoustic template generation, longer conversational samples, and room noise baseline.

## Overview of 6 steps
1. **Name** — text field for display name
2. **Wake phrases** (4x repeats) — user says "Hey Fae" 4 times; generates acoustic templates + stores in WakeWordProfileStore
3. **Conversational** (3x 8s) — three 8-second free-speech samples for speaker embedding (same as current 3-sample flow)
4. **Room noise** (20s) — background noise baseline capture (stored as noise floor metadata)
5. **Photo** — camera capture for visual identity
6. **Complete** — atomic commit of all data; call onComplete

## New State Machine
```
.name → .wakePhrases(phraseIndex: 0..3) → .conversational(sampleIndex: 0..2) → .roomNoise → .photo → .complete
```

## Data to collect
- `displayName: String`
- `wakeEmbeddings: [[Float]]` — 4 wake phrase embeddings (for acoustic templates)
- `conversationalEmbeddings: [[Float]]` — 3 conversational embeddings (for speaker profile)
- `noiseFloorRMS: Float` — room noise baseline
- `capturedPhotoData: Data?` — JPEG photo

## Atomic commit on step 6
On Complete step:
1. Enroll conversational embeddings into SpeakerProfileStore (bulkEnroll)
2. Generate 4 acoustic templates and store via WakeWordProfileStore.recordAcousticTemplate()
3. Save photo if captured
4. Call onComplete(displayName)

## Tasks

### Task 1: Define new EnrollmentStep enum and state variables
- Add new EnrollmentStep cases to SpeakerEnrollmentView
- Add new @State variables: wakeEmbeddings, noiseFloorRMS, wakeRecordingState
- Add WakeWordProfileStore parameter to SpeakerEnrollmentView
- Update body switch to handle new cases
- Files: native/macos/Fae/Sources/Fae/SpeakerEnrollmentView.swift

### Task 2: Implement wake phrase step UI and recording
- Add wakePhraseStep view (step 2 of 6)
- Show "Say 'Hey Fae'" prompt with phrase index indicator (1 of 4, 2 of 4, etc.)
- Record 2-second segments per wake phrase (WakeWordAcousticDetector.maxDurationSeconds)
- Build WakeWordAcousticDetector.Template from each recording
- Accumulate wakeEmbeddings array
- Files: native/macos/Fae/Sources/Fae/SpeakerEnrollmentView.swift

### Task 3: Implement room noise step UI and recording
- Add roomNoiseStep view (step 4 of 6)
- Show "Stay quiet for 20 seconds" prompt with progress ring
- Record 20s of ambient audio and compute RMS as noiseFloorRMS
- Store noiseFloorRMS in @State
- Files: native/macos/Fae/Sources/Fae/SpeakerEnrollmentView.swift

### Task 4: Update complete step for atomic commit
- Refactor completeEnrollment() to perform all writes atomically on step 6:
  - bulkEnroll conversational embeddings → SpeakerProfileStore
  - recordAcousticTemplate x4 → WakeWordProfileStore
  - save photo via onPhotoCapture callback
- Remove intermediate enrollment from recordSample() (was enrolling on 3rd sample)
- Update completeStep view to show "4 wake templates recorded" info
- Files: native/macos/Fae/Sources/Fae/SpeakerEnrollmentView.swift

### Task 5: Update SpeakerEnrollmentView call sites to pass WakeWordProfileStore
- Update ContentView.swift where SpeakerEnrollmentView is instantiated
- Update OnboardingController.swift or other call sites
- Files: native/macos/Fae/Sources/Fae/ContentView.swift, and any other call sites

### Task 6: Tests — completion flow
- Test full enrollment flow: all 6 steps complete → speaker profile enrolled + 4 templates stored
- Test that WakeWordProfileStore has 4 templates after completion
- Test SpeakerProfileStore has embeddings after completion
- Files: native/macos/Fae/Tests/HandoffTests/FusedEnrollmentFlowTests.swift (NEW)

### Task 7: Tests — abandonment + template generation
- Test that abandoning at step 3 (mid-flow) writes nothing to stores
- Test WakeWordAcousticDetector.makeTemplate() produces valid templates from synthetic audio
- Test noiseFloorRMS is > 0 after room noise step
- Files: native/macos/Fae/Tests/HandoffTests/FusedEnrollmentFlowTests.swift (update)

### Task 8: Build validation
- Run `just build` from native/macos/Fae/
- Fix any remaining compile errors
- Run `just test` to confirm all tests pass
