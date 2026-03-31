# Plan: Phase 1.1 — Push-to-Talk Button

**Milestone:** 1 — Push-to-Talk + Fused Enrollment
**Status:** TODO
**Build:** `just build` from `native/macos/Fae/`
**Test:** `just test` from `native/macos/Fae/`

Rules: no `.unwrap()` or `fatalError()` in production code; zero warnings; doc comments on all public items; TDD where practical; each task ~50 lines.

---

## Task 1.1.1 — AudioRingBuffer value type

**Description.**
Create a fixed-capacity ring buffer that overwrites the oldest samples when full. Pure Swift struct, no Foundation/AVFoundation dependencies.

**Files to create.**
- `native/macos/Fae/Sources/Fae/Audio/AudioRingBuffer.swift`
- `native/macos/Fae/Tests/HandoffTests/AudioRingBufferTests.swift`

**Public surface.**
```swift
/// Fixed-capacity overwrite ring buffer for mono Float32 audio samples.
struct AudioRingBuffer {
    init(capacity: Int)
    mutating func write(_ samples: [Float])
    func read(last count: Int) -> [Float]
    var totalWritten: Int { get }
    var capacity: Int { get }
}
```

**Test expectations.**
- Empty buffer: `read(last: 10)` returns `[]`.
- Partial fill: `write([1,2,3])` then `read(last: 5)` returns `[1,2,3]`.
- Exact fill: write `capacity` samples then `read(last: capacity)` returns them in order.
- Overwrite: write `capacity + 1` samples; `read(last: capacity)` returns the last `capacity` samples in order.
- `read(last: 0)` returns `[]`.
- `totalWritten` reflects cumulative writes.

**Dependencies.** None.

---

## Task 1.1.2 — Wire ring buffer into AudioCaptureManager

**Description.**
Add a 2-second ring buffer (32,000 samples at 16 kHz) to `AudioCaptureManager`. Write every chunk to buffer in `emitChunk(_:)` before mute/gate checks. Expose snapshot method.

**Files to modify.**
- `native/macos/Fae/Sources/Fae/Audio/AudioCaptureManager.swift`

**Files to create.**
- `native/macos/Fae/Tests/HandoffTests/AudioCaptureManagerRingBufferTests.swift`

**Changes.**
- Add `private var ringBuffer = AudioRingBuffer(capacity: 32_000)` property.
- In `emitChunk(_:)`, unconditionally call `ringBuffer.write(chunk.samples)` before mute checks.
- Add public method:
  ```swift
  /// Returns the most recent `seconds` of captured audio (up to 2s).
  func recentAudio(seconds: Double) -> [Float]
  ```

**Test expectations.**
- Before any write, `recentAudio(seconds: 2.0)` returns `[]`.
- After writing known samples, `recentAudio(seconds: 1.0)` returns correct last 16,000 samples.
- Requesting more seconds than available returns all written samples.

**Dependencies.** Task 1.1.1.

---

## Task 1.1.3 — Extend GlobalHotkeyManager for hold-to-talk (Right Option)

**Description.**
Add a `.flagsChanged` monitor to detect Right Option key-down/key-up for hold-to-talk. Expose `startHoldToTalk(onPress:onRelease:)` alongside existing `start(handler:)`.

**Files to modify.**
- `native/macos/Fae/Sources/Fae/Core/GlobalHotkeyManager.swift`

**Files to create.**
- `native/macos/Fae/Tests/HandoffTests/GlobalHotkeyManagerPTTTests.swift`

**New public surface.**
```swift
func startHoldToTalk(onPress: @escaping () -> Void, onRelease: @escaping () -> Void)
func stopHoldToTalk()
static let holdToTalkKeyCode: UInt16 = 61
```

**Implementation notes.**
- Second `private var pttMonitor: Any?` property.
- `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)`, check `event.keyCode == 61`.
- Track `private var pttKeyIsDown: Bool` to avoid duplicate events.

**Test expectations.**
- `stopHoldToTalk()` before `startHoldToTalk` does not crash.
- Calling `startHoldToTalk` twice replaces callbacks without leaking monitors.
- `holdToTalkKeyCode` is `61`.

**Dependencies.** None (parallel with 1.1.1).

---

## Task 1.1.4 — Wire PTT into FaeCore / PipelineCoordinator

**Description.**
Connect `GlobalHotkeyManager.startHoldToTalk` callbacks to `PipelineCoordinator.setMicMuted` in FaeCore. Add notification names for PTT events.

**Files to modify.**
- `native/macos/Fae/Sources/Fae/Core/FaeCore.swift`
- `native/macos/Fae/Sources/Fae/ConversationController.swift` (add notification names)

**Changes.**
- Add `.faePTTPressed` and `.faePTTReleased` notification names.
- Add `private func startPushToTalkMonitor()` in FaeCore.
- `onPress`: post `.faePTTPressed`, call `setMicMuted(false)`.
- `onRelease`: post `.faePTTReleased`, restore previous mute state.
- Track `private var micWasMutedBeforePTT: Bool`.

**Test expectations.**
- `startPushToTalkMonitor()` does not crash without Accessibility permission.

**Dependencies.** Tasks 1.1.2, 1.1.3.

---

## Task 1.1.5 — Wire collapsed-orb click to start listening

**Description.**
When orb clicked in collapsed mode, also post `.faePTTPressed` to unmute mic. This gives collapsed-orb-click the same "start listening" behavior as PTT.

**Files to modify.**
- `native/macos/Fae/Sources/Fae/ContentView.swift` (collapsedView onOrbClicked)
- `native/macos/Fae/Sources/Fae/OrbCrownView.swift` (collapsed branch)

**Files to create.**
- `native/macos/Fae/Tests/HandoffTests/ContentViewOrbClickTests.swift`

**Changes.**
- Add `.faePTTPressed` post alongside existing `.faeConversationEngage` in both files.

**Test expectations.**
- Posting `.faePTTPressed` notification is observable via XCTestExpectation.

**Dependencies.** Task 1.1.4.

---

## Task 1.1.6 — MissedWakeStore actor

**Description.**
Actor that persists raw Float32 audio as `.wav` files to `~/Library/Application Support/fae/wake_training/missed/`. FIFO cap of 500 files. Hand-rolled 44-byte PCM WAV header (no AVFoundation).

**Files to create.**
- `native/macos/Fae/Sources/Fae/Audio/MissedWakeStore.swift`
- `native/macos/Fae/Tests/HandoffTests/MissedWakeStoreTests.swift`

**Public surface.**
```swift
actor MissedWakeStore {
    static let maxFiles: Int = 500
    static let sampleRate: Int = 16_000
    init() throws
    init(storageURL: URL) throws
    @discardableResult func save(samples: [Float]) async -> URL?
    var fileCount: Int { get async }
    var allFiles: [URL] { get async }
}
```

**Test expectations.**
- `save` with 1-second sine wave creates one `.wav` file.
- 501 saves leaves exactly 500 files (oldest deleted).
- `fileCount` returns 0 on empty store.
- Files have valid WAV header (`RIFF`, `WAVE`, `fmt `).
- `save` with empty array returns `nil`.

**Dependencies.** None (parallel with 1.1.1, 1.1.3).

---

## Task 1.1.7 — Missed-wake capture on PTT

**Description.**
When PTT pressed, check if wake-word detector recently failed. If so, snapshot ring buffer to MissedWakeStore.

**Files to modify.**
- `native/macos/Fae/Sources/Fae/Core/FaeCore.swift` (PTT press handler)
- `native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift` (expose failed-wake flag)

**Files to create.**
- `native/macos/Fae/Tests/HandoffTests/MissedWakeCaptureTests.swift`

**New surface on PipelineCoordinator.**
```swift
func markFailedWake()
func consumeFailedWake() -> Bool
```

**Logic in FaeCore PTT handler.**
```swift
let hadFailed = await pipelineCoordinator?.consumeFailedWake() ?? false
if hadFailed {
    let samples = await capture.recentAudio(seconds: 2.0)
    Task.detached(priority: .background) {
        await missedWakeStore?.save(samples: samples)
    }
}
```

**Test expectations.**
- `consumeFailedWake()` returns false when not marked.
- Returns true after `markFailedWake()`, then false on next call.
- Integration: after mark + simulated PTT, `MissedWakeStore.fileCount` increments.

**Dependencies.** Tasks 1.1.2, 1.1.4, 1.1.6.

---

## Task 1.1.8 — Build validation and cleanup

**Description.**
Verify full build and test suite clean. Fix any warnings. Update ROADMAP status.

**Files to modify.**
- Any files with warnings.
- `.planning/ROADMAP.md` (Phase 1.1 status).

**Acceptance criteria.**
- `just build` exits 0, zero warnings.
- `just test` exits 0, all new tests pass.
- No `.unwrap()` or `fatalError()` in production code.
- All new public items have doc comments.

**Dependencies.** Tasks 1.1.1–1.1.7.

---

## Execution Order

| Group | Tasks | Can run in parallel |
|-------|-------|-------------------|
| A | 1.1.1, 1.1.3, 1.1.6 | Yes (no deps) |
| B | 1.1.2 (needs 1.1.1) | After A |
| C | 1.1.4 (needs 1.1.2 + 1.1.3) | After B |
| D | 1.1.5 (needs 1.1.4), 1.1.7 (needs 1.1.2 + 1.1.4 + 1.1.6) | After C |
| E | 1.1.8 | After all |
