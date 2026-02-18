# Phase 3.1: Just-in-Time Permission Request UI

## Goal

When the Rust backend emits a `capability.requested` event (from `capability.request`
with `jit: true`), the Swift layer:
1. Detects the capability and reason
2. Triggers the appropriate native macOS permission dialog
3. Reports the result back to Rust via `capability.grant` or `capability.deny`

## Architecture

```
Rust backend
  → capability.request { capability, reason, jit: true } command received
  → emits capability.requested { capability, reason, jit: true } event to stdout

ProcessCommandSender (Swift)
  → parses stdout NDJSON lines
  → posts NSNotification "faeCapabilityRequested" { capability, reason, jit }

JitPermissionController (Swift) — NEW
  → observes "faeCapabilityRequested" where jit == true
  → requests native macOS permission (AVCaptureDevice / CNContactStore / etc.)
  → posts "faeCapabilityGranted" or "faeCapabilityDenied" with capability name

HostCommandBridge (Swift)
  → observes "faeCapabilityGranted" / "faeCapabilityDenied"
  → dispatches capability.grant / capability.deny host command to backend
```

## Task List

### Task 1: Rust — add `jit` field to capability.request payload

In `src/host/channel.rs`:
- Add `jit: bool` to `CapabilityRequestPayload`
- Update `parse_capability_request` to read optional `jit` bool (default false)
- Update `handle_capability_request` to include `"jit": request.jit` in emitted event

File: `src/host/channel.rs`

### Task 2: Rust — add tests for jit field

In `tests/host_command_channel_v0.rs`, add:
- `capability_request_jit_true_included_in_event`
- `capability_request_jit_defaults_to_false`

File: `tests/host_command_channel_v0.rs`

### Task 3: Swift — ProcessCommandSender posts capability.requested notifications

Update `ProcessCommandSender.swift` to parse stdout NDJSON lines for event envelopes.
When `event == "capability.requested"` and `payload.jit == true`, post:
  `NSNotification.Name("faeCapabilityRequested")` with userInfo:
  `["capability": String, "reason": String, "jit": Bool]`

File: `native/macos/FaeNativeApp/Sources/FaeNativeApp/ProcessCommandSender.swift`

### Task 4: Swift — JitPermissionController

Create `JitPermissionController.swift` — @MainActor ObservableObject class:
- Observes "faeCapabilityRequested" (jit == true only)
- Maps capability name → native permission request:
  - "microphone" → AVCaptureDevice.requestAccess(for: .audio)
  - "contacts" → CNContactStore().requestAccess(for: .contacts)
  - others → deny immediately (unsupported JIT permission)
- Posts "faeCapabilityGranted" or "faeCapabilityDenied" with capability name

File: `native/macos/FaeNativeApp/Sources/FaeNativeApp/JitPermissionController.swift` (NEW)

### Task 5: Swift — HostCommandBridge grant/deny observers

In `HostCommandBridge.swift`, add observers for:
- `.faeCapabilityGranted` → dispatch `capability.grant { capability: String }`
- `.faeCapabilityDenied` → dispatch `capability.deny { capability: String }`

Add Notification.Name extensions for `.faeCapabilityGranted` and `.faeCapabilityDenied`.

File: `native/macos/FaeNativeApp/Sources/FaeNativeApp/HostCommandBridge.swift`

### Task 6: Swift — Wire JitPermissionController in FaeNativeApp.swift

In `FaeNativeApp.swift`, add:
  `@StateObject private var jitPermissions = JitPermissionController()`
Hold it as a retained property to keep the controller alive for the app lifetime.

File: `native/macos/FaeNativeApp/Sources/FaeNativeApp/FaeNativeApp.swift`
