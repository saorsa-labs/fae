# Scheduler tooling + permission behavior (Swift runtime)

This note documents current scheduler and tool integration in the Swift app.

## Scheduler ownership

Scheduler authority lives in:

- `native/macos/Fae/Sources/Fae/Scheduler/FaeScheduler.swift`

`FaeCore` wires scheduler lifecycle on runtime start/stop and connects:

- persistence store (`SchedulerPersistenceStore`)
- optional speak handler (`PipelineCoordinator.speakDirect`)

## Scheduler tool integration

**Canonical preference:** Prefer skill contracts over hardcoded code paths; prefer asking Fae conversationally for setup/changes over manual config editing.

Preferred user flow: ask Fae conversationally to create/update/disable scheduled tasks. Raw scheduler file details below are implementation-level context, not the recommended user entrypoint.

Scheduler tools write/read `~/Library/Application Support/fae/scheduler.json` and coordinate with runtime via notifications:

- `.faeSchedulerUpdate` → enable/disable task state
- `.faeSchedulerTrigger` → run task immediately

`FaeCore.observeSchedulerUpdates()` consumes both notifications and forwards to `FaeScheduler`.

## Permission layering

Tool execution in pipeline uses layered checks:

1. Voice-identity policy (`VoiceIdentityPolicy`)
2. Tool risk policy (`ToolRiskPolicy`)
3. Approval workflow (`ApprovalManager`) when required

This applies consistently across direct conversation and tool-follow-up turns.

## Apple tool permission request flow

When an Apple tool (CalendarTool, RemindersTool, ContactsTool, MailTool, NotesTool) is invoked but the required macOS permission is missing, it triggers the JIT permission flow rather than returning a dead-end error:

1. Tool calls `requestPermission(capability:)` — a private async helper in `AppleTools.swift`
2. Helper posts `.faeCapabilityRequested` notification (same channel `JitPermissionController` listens to)
3. `JitPermissionController` shows the native macOS permission dialog or opens System Settings
4. Helper awaits `.faeCapabilityGranted` or `.faeCapabilityDenied` (30-second timeout)
5. If granted — tool retries its action and returns the result
6. If denied or timed out — tool returns a friendly error

MailTool and NotesTool use a try→detect→request→retry pattern since mail/notes automation
permissions are only detectable from AppleScript error messages, not via a pre-flight API.

**Capability strings**: `"calendar"`, `"reminders"`, `"contacts"`, `"mail"`, `"notes"`, `"screen_recording"`, `"camera"`, `"desktop_automation"`.

### Vision + Computer Use permissions

Vision tools trigger JIT permission requests via `JitPermissionController`:

- **Screen Recording** (`"screen_recording"`) — `CGPreflightScreenCaptureAccess()` checks current state; `CGRequestScreenCaptureAccess()` triggers system prompt; polls every 2s for up to 30s.
- **Camera** (`"camera"`) — `AVCaptureDevice.requestAccess(for: .video)` — native async permission dialog.
- **Accessibility** (`"desktop_automation"`) — opens System Settings > Privacy & Security > Accessibility; polls `AXIsProcessTrusted()` every 2s. Note: may already be granted via GlobalHotkeyManager (Ctrl+Shift+A).

## Settings > Tools permission UI

`SettingsToolsTab.swift` includes an "Apple Tool Permissions" section showing per-tool
permission state with grant buttons:

- **Calendar** / **Reminders** / **Contacts** — show Granted/Not Granted badge and a Grant
  button that calls the corresponding `OnboardingController.request*()` method
- **Mail & Notes** — shows an "Open Settings" button (routes to System Settings > Privacy &
  Security > Automation) with an explanatory note

Permission state is read from `PermissionStatusProvider` and refreshed 2 seconds after
any grant attempt.

### Settings > Models vision permissions

`SettingsModelsTab.swift` includes a "Vision" section showing:

- **Enable Vision** toggle (`vision.enabled`)
- **Vision Model** picker (Auto / 8-bit / 4-bit)
- Permission badges for **Screen Recording**, **Camera**, and **Accessibility**
