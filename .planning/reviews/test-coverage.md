# Test Coverage Review
**Date**: 2026-03-31

## Statistics
- Test files: 130+ across HandoffTests, IntegrationTests, SearchTests, EvalTests
- Test functions: ~1800 total
- Relevant new test file: FusedEnrollmentFlowTests.swift (14 test functions)
- Tests pass (filtered run): WakeWordAcousticDetectorTests (4/4), EchoTextOverlapTests (26/26)

## Findings
- [CRITICAL] FusedEnrollmentFlowTests.swift:154 — COMPILE ERROR: `speakerStore.profiles()` is inaccessible (private var). The test calls `await speakerStore.profiles()` as a function but `profiles` is a private stored property, not a public function. The correct API is `speakerStore.profileSummaries()` which returns [SpeakerProfileSummary].
- [HIGH] Tests at lines 78, 139, 154 attempt to read internal state via `speakerStore.profiles()` which does not compile — these tests cannot run until fixed.
- [OK] WakeWordAcousticDetector.makeTemplate tests (lines 15-55) are well-structured and cover happy path, silence, and too-short audio
- [OK] Atomic commit logic (lines 89-141) tests the correct public API for WakeWordProfileStore
- [OK] Noise floor RMS tests (lines 169-191) are self-contained and don't require hardware
- [OK] Consistency score tests (lines 195-208) match SpeakerProfileStore.consistencyScore API correctly
- [MEDIUM] No test for the scenario where makeTemplate returns nil (e.g. wake phrase too long) — wakePhraseIndex advances but wakeTemplates stays short. The complete step shows fewer templates but enrollment isn't blocked.
- [LOW] FusedEnrollmentFlowTests references WakeWordAcousticDetectorTests.syntheticWakePhrase() — that helper must be accessible (internal/public). Likely fine given @testable import.

## Grade: D (due to compile error blocking test execution)
