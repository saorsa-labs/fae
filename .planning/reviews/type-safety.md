# Type Safety Review
**Date**: 2026-03-31

## Findings
- [OK] EnrollmentStep now conforms to Equatable — required for stepIndicator firstIndex(of:) and used correctly
- [OK] All @State vars are typed appropriately ([WakeWordAcousticDetector.Template] for wakeTemplates etc.)
- [OK] No force casts (as!) in changed files
- [OK] WakeWordAcousticDetector.Template uses [Float] embedding — consistent with how WakeWordProfileStore stores it
- [OK] noiseFloorRMS typed as Float — consistent with AudioCaptureManager.SegmentSpeechQuality.rms type
- [LOW] captureSegment returns [Float] at targetSampleRate (16kHz), but makeTemplate is called with AudioCaptureManager.targetSampleRate = 16_000. WakeWordAcousticDetector.prepare() resamples internally to legacySampleRate (24kHz) via CoreMLSpeakerEncoder.sharedLogMelSpectrogram. This is correct but the call site (recordWakePhrase) could benefit from a comment explaining the sample rate hand-off.
- [OK] commitAndComplete is non-throwing — appropriate since it only calls actor methods which handle their own errors internally

## Grade: A
