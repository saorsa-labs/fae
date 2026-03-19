# Phase 6.2: Event Wiring — Task Plan

**Goal:** Fix critical event chain gaps — Rust emits events but Swift doesn't act.

## Task 1: Wire PipelineAuxBridgeController to AuxiliaryWindowManager for canvas show/hide

**Why:** `pipeline.canvas_visibility` arrives from Rust but PipelineAuxBridgeController only writes a Bool. The actual NSPanel show/hide lives in AuxiliaryWindowManager. Nothing connects them.

**Files:**
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/PipelineAuxBridgeController.swift`
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/FaeNativeApp.swift`

**Work:**
1. Add `weak var auxiliaryWindows: AuxiliaryWindowManager?` to PipelineAuxBridgeController
2. In `handlePipelineState`, replace `canvasController?.isVisible = visible` with calls to `auxiliaryWindows?.showCanvas()/hideCanvas()`
3. In `FaeNativeApp.onAppear`, wire `pipelineAux.auxiliaryWindows = auxiliaryWindows`

---

## Task 2: Add pipeline.conversation_visibility event — Rust side

**Why:** No Rust mechanism exists to show/hide the conversation panel. Canvas has an equivalent but conversation does not.

**Files:**
- `src/runtime.rs`
- `src/host/handler.rs`

**Work:**
1. Add `RuntimeEvent::ConversationVisibility { visible: bool }` variant
2. In handler's `map_runtime_event()`, map it to `"pipeline.conversation_visibility"` with `{"visible": bool}` payload
3. Add unit test for the mapping

---

## Task 3: Wire "show conversation" voice command through coordinator → Swift panel

**Why:** No voice command exists for showing/hiding conversation or canvas panels.

**Files:**
- `src/voice_command.rs`
- `src/pipeline/coordinator.rs`
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/PipelineAuxBridgeController.swift`
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/BackendEventRouter.swift`

**Work:**
1. Add `ShowConversation`, `HideConversation`, `ShowCanvas`, `HideCanvas` variants to VoiceCommand
2. Add parse patterns: "show conversation", "open conversation", "show canvas", etc.
3. In coordinator's `handle_voice_command`, emit `RuntimeEvent::ConversationVisibility`/`ConversationCanvasVisibility`
4. In BackendEventRouter, route `"pipeline.conversation_visibility"` to `.faePipelineState`
5. In PipelineAuxBridgeController, handle `"pipeline.conversation_visibility"` → call `auxiliaryWindows?.showConversation()/hideConversation()`

---

## Task 4: Extend JitPermissionController for calendar, reminders, mail

**Why:** JitPermissionController denies all JIT permissions except "microphone" and "contacts". Calendar/reminders/mail are needed for Apple tool integration.

**Files:**
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/JitPermissionController.swift`

**Work:**
1. Add `requestCalendar(capability:)` using EventKit
2. Add `requestReminders(capability:)` using EventKit
3. Add `requestMail(capability:)` — opens System Settings to Privacy/Automation
4. Wire new cases into `handleRequest(capability:)` dispatch

---

## Task 5: Wire OnboardingController.onPermissionResult to HostCommandBridge

**Why:** Onboarding permission grants are never forwarded to the Rust backend. The `onPermissionResult` callback is never set.

**Files:**
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/FaeNativeApp.swift`

**Work:**
1. In `FaeNativeApp.onAppear`, set `onboarding.onPermissionResult` to post `.faeCapabilityGranted`
2. Both onboarding and JIT paths now converge on HostCommandBridge → `capability.grant` → Rust

---

## Task 6: Wire Rust device events to DeviceHandoffController

**Why:** `device.transfer_requested`/`device.home_requested` events reach BackendEventRouter but nothing dispatches them to DeviceHandoffController.

**Files:**
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/BackendEventRouter.swift`
- `native/macos/FaeNativeApp/Sources/FaeNativeApp/FaeNativeApp.swift`

**Work:**
1. Add `.faeDeviceTransfer` notification name
2. In BackendEventRouter, route `device.transfer_requested` and `device.home_requested` to `.faeDeviceTransfer`
3. In FaeNativeApp.onAppear, subscribe to `.faeDeviceTransfer` and dispatch to `handoff.move(to:)`/`handoff.goHome()`
4. Wire `handoff.snapshotProvider` and `handoff.orbState`

---

## Task 7: Wire Rust handler request_move/request_go_home to emit events

**Why:** `request_move()` and `request_go_home()` are stub no-ops. Handler should emit canvas hide on move.

**Files:**
- `src/host/handler.rs`

**Work:**
1. In `request_move()`, emit `pipeline.canvas_visibility: false` to collapse UI during handoff
2. Add unit test for event emission

---

## Dependency Order

```
Task 1 (independent — canvas wiring)
Task 2 → Task 3 (conversation_visibility event must exist before coordinator wires it)
Task 4 (independent — JIT extensions)
Task 5 (independent — onboarding result wiring)
Task 7 → Task 6 (Rust handler events precede Swift observer wiring)
```

Tasks 1, 4, 5 can be done in parallel. Task 2 before 3. Task 7 before 6.

## Exit Criteria

- "Show conversation" opens the conversation NSPanel
- "Show canvas" opens the canvas NSPanel
- `pipeline.canvas_visibility` from Rust opens/closes canvas panel (not just sets Bool)
- JIT permission for calendar/reminders/mail triggers system dialogs
- Permission grants (onboarding or JIT) propagate `capability.grant` to Rust
- "Move to iPhone" calls DeviceHandoffController.move() and publishes NSUserActivity
