# Phase 5.1: Device Handoff

**Milestone**: 5 — Handoff & Production Polish
**Status**: In Progress
**Total Tasks**: 8

## Overview
Enhance the existing DeviceHandoffController to carry full conversation state through
NSUserActivity and iCloud key-value store, add handoff receiving, offline handling,
orb visual feedback, and a settings toggle.

### Existing Code
- `DeviceHandoff.swift`: DeviceTarget enum, DeviceCommandParser, DeviceHandoffController
  with basic NSUserActivity (target + command only, no conversation state)
- `SettingsView.swift`: "Cross-Device Handoff" section with move buttons
- `FaeNativeApp.swift`: `@StateObject private var handoff = DeviceHandoffController()`
- Rust `src/host/handler.rs`: handles `device.move` and `device.go_home` commands

---

## Task 1: Conversation Snapshot in NSUserActivity
**Goal**: Enrich NSUserActivity with serialised conversation state so the receiving
device can resume the conversation.

**Acceptance Criteria**:
- Define `ConversationSnapshot: Codable` struct with fields: `entries: [Entry]`,
  `orbMode: String`, `orbFeeling: String`, `timestamp: Date`
- `Entry` has `role: String` (user/assistant only) and `content: String`
- Exclude memory recall hits, system prompts, and tool results from entries
- `DeviceHandoffController.publishHandoffActivity` serialises snapshot as JSON
  into `userInfo["conversationSnapshot"]`
- Snapshot is built from `ConversationController.messages` (add public accessor if needed)
- Add unit tests for snapshot encoding/decoding and role filtering
- Zero warnings

**Files**:
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/DeviceHandoff.swift` (edit)
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/ConversationController.swift` (edit — expose messages)

---

## Task 2: iCloud Key-Value Store for Session Continuity
**Goal**: Persist the latest conversation snapshot to iCloud KV store so a user
can resume on another device even if Handoff times out.

**Acceptance Criteria**:
- Create `HandoffKVStore` enum with static methods: `save(_:store:)`, `load(store:)`, `clear(store:)`
- Default `store` parameter is `NSUbiquitousKeyValueStore.default` — injectable for testing
- `save()` is a no-op with `NSLog` warning when iCloud is unavailable
- `load()` returns nil when iCloud is unavailable or key is absent
- `clear()` is always safe (no-op when nothing stored)
- Data stored under key `"fae.handoff.snapshot"` as JSON data
- Register for `NSUbiquitousKeyValueStoreDidChangeExternallyNotification` to detect
  incoming changes from other devices
- Unit tests with mock `NSUbiquitousKeyValueStore` verifying save/load/clear and
  graceful degradation
- Zero warnings

**Files**:
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/HandoffKVStore.swift` (new)

---

## Task 3: Handoff UI — Device Picker & Transfer Button
**Goal**: Improve the handoff section in Settings and add an in-conversation
transfer affordance.

**Acceptance Criteria**:
- Refactor SettingsView handoff section: show current target device with icon,
  transfer buttons with confirmation, and last handoff timestamp
- Add a minimal handoff button to the conversation toolbar (visible only when
  handoff is enabled) — a small device icon that opens a popover with target picker
- Handoff button shows transfer-in-progress spinner when activity is being published
- Transfer confirmation shows conversation entry count being transferred
- VoiceOver labels on all interactive elements
- Zero warnings

**Files**:
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/SettingsView.swift` (edit)
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/HandoffToolbarButton.swift` (new)

---

## Task 4: Receive Handoff — Restore Conversation
**Goal**: When the app receives an NSUserActivity from another device, restore
the conversation state.

**Acceptance Criteria**:
- In `FaeNativeApp`, implement `onContinueUserActivity("com.saorsalabs.fae.session.handoff")`
  handler
- Decode `ConversationSnapshot` from activity's `userInfo`
- Push restored entries into `ConversationController` (add `restore(from:)` method)
- Set orb mode/feeling from snapshot
- Show brief "Conversation received from [device]" banner in conversation UI
- Handle malformed/missing snapshot gracefully (log warning, ignore)
- Also check `HandoffKVStore.load()` on launch as fallback
- Unit tests for restore logic with valid and malformed snapshots
- Zero warnings

**Files**:
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/FaeNativeApp.swift` (edit)
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/ConversationController.swift` (edit — add restore)
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/DeviceHandoff.swift` (edit)

---

## Task 5: Offline & Disconnected Handling
**Goal**: Gracefully handle scenarios where handoff fails due to network or
device unavailability.

**Acceptance Criteria**:
- Use `NWPathMonitor` to track network connectivity status
- Add `isNetworkAvailable: Bool` published property to `DeviceHandoffController`
- When offline: disable transfer buttons, show "Offline — handoff unavailable" message
- When handoff activity fails to publish: show inline error, auto-retry once on
  network restore
- Save snapshot to `HandoffKVStore` as fallback when real-time handoff unavailable
- Timeout: if no handoff acknowledgement after 30s, show "Transfer may not have
  completed" warning
- Clean up `NWPathMonitor` on deinit
- Zero warnings

**Files**:
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/DeviceHandoff.swift` (edit)

---

## Task 6: Orb Flash on Handoff Transfer
**Goal**: Visual feedback in the orb when a handoff transfer starts and completes.

**Acceptance Criteria**:
- When transfer starts: orb briefly flashes to `.thinking` mode with `.aurora` palette
  for 1.5s, then returns to previous state
- When transfer completes (activity invalidated or received): orb flashes `.speaking`
  mode with `.warmSunrise` palette for 1s
- On receive (incoming handoff): orb pulses `.listening` mode for 2s to signal
  "conversation arrived"
- Flash is implemented directly on `OrbStateController` via a `flash(mode:palette:duration:)`
  method (no notification hops)
- Respect `accessibilityReduceMotion` — skip flash, use subtle color change instead
- Zero warnings

**Files**:
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/FaeNativeApp.swift` (edit — orb state)
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/DeviceHandoff.swift` (edit — trigger flash)

---

## Task 7: Settings Toggle for Handoff Enable/Disable
**Goal**: Let users enable or disable device handoff from Settings.

**Acceptance Criteria**:
- Add `handoffEnabled: Bool` to `DeviceHandoffController` backed by `UserDefaults`
  (key: `"fae.handoff.enabled"`, default: `true`)
- When disabled: `publishHandoffActivity` is a no-op, iCloud KV store writes are skipped,
  toolbar button is hidden, NWPathMonitor is stopped
- When re-enabled: resume monitoring and publishing
- Add toggle in SettingsView "Cross-Device Handoff" section with description text
- Persist preference across launches via UserDefaults
- Zero warnings

**Files**:
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/DeviceHandoff.swift` (edit)
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/SettingsView.swift` (edit)

---

## Task 8: Integration Test Plan for Handoff Scenarios
**Goal**: Comprehensive test coverage for handoff paths.

**Acceptance Criteria**:
- Unit tests for `ConversationSnapshot` encode/decode roundtrip
- Unit tests for `HandoffKVStore` save/load/clear with mock store
- Unit tests for `DeviceHandoffController` state transitions (move, goHome, offline)
- Unit tests for `ConversationController.restore(from:)` with valid/malformed data
- Unit tests for orb `flash()` method (mode/palette restored after duration)
- Unit tests for handoff-disabled behavior (no activity published, no KV writes)
- Document manual test plan in code comments: Mac-to-iPhone transfer, timeout,
  offline recovery, settings toggle
- All tests pass, zero warnings

**Files**:
- `native/macos/FaeNativeApp/Tests/FaeNativeAppTests/HandoffTests.swift` (new)

---

## Success Metrics
- 8/8 tasks complete
- NSUserActivity carries full conversation state
- iCloud KV store provides fallback persistence
- Orb provides visual transfer feedback
- Handoff can be disabled in Settings
- All unit tests pass
- Zero warnings, zero test failures
