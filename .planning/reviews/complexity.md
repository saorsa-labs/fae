# Complexity Review
**Date**: 2026-03-31

## Largest Files (LOC)
- PipelineCoordinator.swift: 8,401 lines (existing, unchanged)
- SpeakerEnrollmentView.swift: ~700 lines (grown from ~500 with new steps)

## Findings
- [OK] SpeakerEnrollmentView is a View struct — SwiftUI complexity is acceptable here
- [LOW] recordRoomNoise() has duplicated timer logic inline (tickNanos, ticks calculation) rather than using the existing startPulsingProgress() helper. The noise step has a deterministic duration so a different approach is warranted, but the code is clear.
- [LOW] commitAndComplete() is ~25 lines of sequential async calls — readable and not complex
- [OK] stepIndicator builds step list inline on every body re-render — minor performance point but SwiftUI views are value types, no real issue
- [OK] startPulsingProgress() cleanly extracted as a helper — reduces duplication across 2 recording functions
- [OK] EchoSuppressor changes (functionWords set, threshold bump) are additive, low complexity

## Grade: A-
