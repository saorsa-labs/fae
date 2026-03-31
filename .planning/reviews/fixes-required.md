# Required Fixes — Phase 1.2 Review Iteration 1
**Date**: 2026-03-31

## CRITICAL Fix: FusedEnrollmentFlowTests.swift — profiles() compile error

File: `native/macos/Fae/Tests/HandoffTests/FusedEnrollmentFlowTests.swift`

### Fix 1: testAtomicCommitWritesConversationalEmbeddingsToSpeakerStore (line 78-82)

Replace:
```swift
let profiles = await speakerStore.profiles()
XCTAssertFalse(profiles.isEmpty, "speaker store should have at least one profile after enrollment")
let ownerProfile = profiles.first(where: { $0.role == .owner })
XCTAssertNotNil(ownerProfile, "owner profile should exist after enrollment")
XCTAssertEqual(ownerProfile?.displayName, "Test User", "owner display name should match")
```

With:
```swift
let summaries = await speakerStore.profileSummaries()
XCTAssertFalse(summaries.isEmpty, "speaker store should have at least one profile after enrollment")
let ownerSummary = summaries.first(where: { $0.role == .owner })
XCTAssertNotNil(ownerSummary, "owner profile should exist after enrollment")
XCTAssertEqual(ownerSummary?.displayName, "Test User", "owner display name should match")
```

### Fix 2: testFullEnrollmentAtomicCommit (line 139-140)

Replace:
```swift
let profiles = await speakerStore.profiles()
XCTAssertFalse(profiles.isEmpty, "speaker store should have profiles after full enrollment")
```

With:
```swift
let summaries = await speakerStore.profileSummaries()
XCTAssertFalse(summaries.isEmpty, "speaker store should have profiles after full enrollment")
```

### Fix 3: testAbandonmentBeforeCompleteLeavesStoresEmpty (line 154-155)

Replace:
```swift
let profiles = await speakerStore.profiles()
XCTAssertTrue(profiles.isEmpty, "speaker store should be empty if enrollment was abandoned")
```

With:
```swift
let summaries = await speakerStore.profileSummaries()
XCTAssertTrue(summaries.isEmpty, "speaker store should be empty if enrollment was abandoned")
```

---

## MEDIUM Fix: recordRoomNoise() — add comment about captureSegment speech-onset behavior

File: `native/macos/Fae/Sources/Fae/SpeakerEnrollmentView.swift`

In `recordRoomNoise()`, before the captureSegment call, add:
```swift
// NOTE: captureSegment waits for speech onset before starting its timer.
// In a quiet room this means capture runs for up to noiseDuration + 6s.
// The returned samples represent ambient + any incidental audio — RMS is
// used as a conservative noise floor estimate.
```
