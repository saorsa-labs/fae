# Quality Patterns Review
**Date**: 2026-03-31

## Good Patterns Found
- Atomic commit pattern: all persistent writes deferred to commitAndComplete() — classic transactional enrollment design
- Actor isolation respected throughout (await on speakerProfileStore and wakeWordProfileStore calls)
- Helper extraction: startPulsingProgress() and recordingRing extracted to reduce duplication
- EnrollmentStep: Equatable conformance added to support firstIndex(of:) in stepIndicator
- Guard-before-enroll: `if !conversationalEmbeddings.isEmpty` before bulkEnroll avoids empty profile creation on edge cases
- EchoSuppressor: functionWords Set<String> is a recognized NLP technique (stop-word filtering) applied sensibly

## Anti-Patterns Found
- [MEDIUM] captureSegment(durationSeconds: 20.0) for room noise capture — this method is designed for speech capture (waits for RMS > 0.008 before starting timer, requires ~3s of speech for hasUsableSpeech). For ambient noise, this is semantically wrong. If the room is genuinely quiet, captureSegment will wait indefinitely for speech onset and eventually timeout after 26s returning tail-end samples. The noiseFloorRMS will reflect trailing audio, not baseline ambient noise.
- [LOW] WakeWordAcousticDetectorTests.syntheticWakePhrase() used in test file — this is an implementation detail of a test helper. If the helper is internal, the @testable import will expose it but it's a slightly fragile dependency.

## Grade: B+
