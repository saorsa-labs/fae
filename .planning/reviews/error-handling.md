# Error Handling Review
**Date**: 2026-03-31
**Mode**: gsd-phase (Phase 1.2)

## Scope
Changed files: SpeakerEnrollmentView.swift, EchoSuppressor.swift

## Findings

- [OK] SpeakerEnrollmentView.recordWakePhrase() — catches errors in do/catch, sets errorMessage
- [OK] SpeakerEnrollmentView.recordConversationalSample() — catches errors with do/catch, sets errorMessage
- [OK] SpeakerEnrollmentView.recordRoomNoise() — catches errors, resets noiseProgress, sets errorMessage
- [OK] SpeakerEnrollmentView.commitAndComplete() — NO do/catch (calls only actor methods that don't throw)
- [OK] No fatalError(), preconditionFailure(), or try! in changed files
- [MEDIUM] recordRoomNoise() uses captureSegment(durationSeconds: 20.0) which waits for speech onset before its timer starts. If no speech is detected, capture hangs silently until maxSamples (26s) is reached. No timeout indicator or user-facing messaging for this scenario.
- [LOW] startPulsingProgress() uses try? Task.sleep — swallowing errors is fine for UI animation.
- [LOW] Wake template generation silently continues if makeTemplate returns nil (advances wakePhraseIndex without adding a template), resulting in fewer templates than wakePhraseCount. User is not informed.
- [OK] commitAndComplete() guards on !conversationalEmbeddings.isEmpty before bulkEnroll

## Grade: B
