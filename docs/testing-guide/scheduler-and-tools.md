# Fae Scheduler & Tool System Testing Guide

## Overview

This guide covers testing the Fae scheduler and tool system, including scheduler task execution, tool registry filtering, Apple tool integration, and the approval/security system.

---

## 1. Scheduler System (`FaeScheduler.swift`)

### Architecture

- **Type**: Actor-based scheduler using `DispatchSourceTimer` for periodic tasks and `Calendar`-based scheduling for daily tasks
- **Location**: `Scheduler/FaeScheduler.swift`
- **Task Persistence**: `~/Library/Application Support/fae/scheduler.json`
- **State Management**: Built-in task ledger with run history and idempotency tracking

### 19 Built-in Tasks

| Task ID | Name | Schedule | Purpose | Handler |
|---------|------|----------|---------|---------|
| `memory_inbox_ingest` | Memory Inbox Ingest | Every 5 minutes | Import queued files from the inbox pending folder | `runMemoryInboxIngest()` |
| `memory_digest` | Memory Digest | Every 6 hours | Synthesize recent imported/proactive memories into a digest record | `runMemoryDigest()` |
| `memory_reflect` | Memory Reflect | Every 6 hours | Consolidate duplicate memories | `runMemoryReflect()` |
| `memory_reindex` | Memory Reindex | Every 3 hours | Health check + integrity verification | `runMemoryReindex()` |
| `memory_migrate` | Memory Migrate | Every 1 hour | Schema migration checks | `runMemoryMigrate()` |
| `memory_gc` | Memory GC | Daily 03:30 | Retention cleanup (episode expiry) | `runMemoryGC()` |
| `memory_backup` | Memory Backup | Daily 02:00 | Atomic VACUUM INTO backup | `runMemoryBackup()` |
| `check_fae_update` | Check for Updates | Every 6 hours | Sparkle update check | `runCheckUpdate()` |
| `noise_budget_reset` | Noise Budget Reset | Daily 00:00 | Reset proactive interjection counter | `runNoiseBudgetReset()` |
| `stale_relationships` | Stale Relationships | Weekly Sunday 10:00 | Detect relationships needing check-in | `runStaleRelationships()` |
| `morning_briefing` | Morning Briefing | Daily 08:00 | Compile morning briefing (suppressed when enhanced active) | `runMorningBriefing()` |
| `skill_proposals` | Skill Proposals | Daily 11:00 | Detect skill opportunities from interests | `runSkillProposals()` |
| `skill_distill` | Skill Distill | Daily 13:00 | Stage reviewable skill drafts from repeated successful workflows | `runSkillDistill()` |
| `skill_health_check` | Skill Health Check | Every 5 minutes | Python skill health checks | `runSkillHealthCheck()` |
| `vault_backup` | Git Vault Backup | Daily 02:30 | Full snapshot to `~/.fae-vault/` | `runVaultBackup()` |
| `camera_presence_check` | Camera Presence | Every 30s (adaptive) | User presence detection | `runCameraPresenceCheck()` |
| `screen_activity_check` | Screen Activity | Every 19s (adaptive) | Screen activity monitoring | `runScreenActivityCheck()` |
| `overnight_work` | Overnight Research | Hourly 22:00-06:00 | Quiet-hours research on interests | `runOvernightWork()` |
| `embedding_reindex` | Embedding Reindex | Weekly Sunday 03:00 | Re-embed records missing ANN vectors | `runEmbeddingReindex()` |
| `enhanced_morning_briefing` | Enhanced Briefing | Deferred post-camera | Calendar, mail, research, reminders | `runEnhancedMorningBriefing()` |

### Task Handlers

Two handler closures control task execution:

1. **`speakHandler`**: Legacy task output via TTS
   - Called by: `morning_briefing`, `stale_relationships`
   - Type: `(@Sendable (String) async -> Void)`
   - Set by: `FaeCore.start()` after `PipelineCoordinator` is ready

2. **`proactiveQueryHandler`**: Full LLM conversation with tool access
   - Called by: Awareness tasks (camera, screen, research, enhanced briefing)
   - Type: `(@Sendable (String, Bool, String, Set<String>, Bool) async -> Void)`
   - Parameters: `(prompt, silent, taskId, allowedTools, consentGranted)`
   - Set by: `FaeCore.refreshAwarenessRuntime()`

### Manual Task Triggering

Via the **`scheduler_trigger`** tool:

```json
{
  "name": "scheduler_trigger",
  "arguments": {
    "task_id": "memory_reflect"
  }
}
```

Implementation in `SchedulerTriggerTool`:
- Finds task by ID
- Calls `FaeScheduler.triggerTask(id:)`
- Executes synchronously within the same pipeline turn
- Returns success/failure + execution details

### Testing Checklist

- [ ] **Task Scheduling**: Verify periodic tasks fire at correct intervals (check `runHistory` via debugger or logs)
- [ ] **Daily Tasks**: Test fixed-time tasks (memory_gc at 03:30, morning_briefing at 08:00)
- [ ] **Inbox Intake**: Drop a supported file into `~/Library/Application Support/fae/memory-inbox/pending/` and verify `memory_inbox_ingest` imports it
- [ ] **Digest Generation**: Trigger `memory_digest` manually and verify it writes a derived digest record linked to source memories
- [ ] **Task Disabling**: Disable a task via `scheduler_update`, verify it doesn't run
- [ ] **Manual Trigger**: Call `scheduler_trigger` with `task_id` parameter, verify execution
- [ ] **Handler Wiring**: Speak handler fires for legacy tasks; proactive handler fires for awareness tasks
- [ ] **Awareness Toggle**: Disable `awareness.enabled` in config, verify awareness tasks don't start
- [ ] **Persistence**: Edit `scheduler.json` manually, restart app, verify changes are loaded
- [ ] **Run Ledger**: Check `taskRunLedger` for idempotency tracking (no duplicate runs)
- [ ] **State Tracking**: Camera presence test checks `lastUserSeenAt`, screen test checks `lastScreenContentHash`

---

## 2. Tool Registry (`ToolRegistry.swift`)

### Tool Inventory

**Total: 34 tools**

Breakdown by category:

| Category | Count | Tools |
|----------|-------|-------|
| Core | 10 | read, write, edit, bash, self_config, channel_setup, window_control, session_search, web_search, fetch_url |
| Skills | 3 | activate_skill, run_skill, manage_skill |
| Delegation | 1 | delegate_agent |
| User Input | 1 | input_request |
| Apple | 5 | calendar, reminders, contacts, mail, notes |
| Scheduler | 5 | scheduler_list, scheduler_create, scheduler_update, scheduler_delete, scheduler_trigger |
| Roleplay | 1 | roleplay |
| Vision | 7 | screenshot, camera, read_screen, click, type_text, scroll, find_element |
| Voice Identity | 1 | voice_identity |
| **Total** | **34** | |

### Tool Modes & Filtering

The registry supports 5 permission modes:

| Mode | Read Tools | Write Tools | Scheduler Mutation | Vision | Bash | Notes |
|------|-----------|-----------|------------------|--------|------|-------|
| `off` | ✗ | ✗ | ✗ | ✗ | ✗ | No tools at all |
| `read_only` | ✓ | ✗ | ✗ | ✗ | ✗ | Safe read-only operations |
| `read_write` | ✓ | ✓ | ✓ | ✓* | ✗ | Read + write + vision (no bash) |
| `full` | ✓ | ✓ | ✓ | ✓ | ✓ | All tools with approval |
| `full_no_approval` | ✓ | ✓ | ✓ | ✓ | ✓ | All tools, skip approval for owner |

*Vision tools require `read_write` or higher.

### Read-Only Tool Set

**15 tools** (always safe):
```
read, window_control, session_search, web_search, fetch_url,
calendar, reminders, contacts, mail, notes,
scheduler_list, roleplay, activate_skill, input_request, find_element, voice_identity
```

### Write Tool Set

**16 additional tools** (requires `read_write` or `full`):
```
write, edit, self_config, channel_setup,
scheduler_create, scheduler_update, scheduler_delete, scheduler_trigger,
manage_skill, run_skill,
screenshot, camera, read_screen, click, type_text, scroll
```

### Native Tool Specs for MLX

- `ToolRegistry.nativeToolSpecs(for mode: String) -> [ToolSpec]?`
- Returns `nil` when `mode == "off"` (so caller can distinguish "disabled" from "empty list")
- Returns filtered list of `ToolSpec` objects for mode `read_only`, `read_write`, `full`, or `full_no_approval`
- Used by `MLXLLMEngine` to populate `UserInput.tools` for native Qwen3.5 tool calling

### Testing Checklist

- [ ] **Tool Count**: Verify 34 tools are registered: `ToolRegistry.buildDefault().allTools.count == 34`
- [ ] **Mode Filtering**: Test `isToolAllowed(name, mode)` for each mode:
  - `off`: zero tools
  - `read_only`: 16 tools (no write, no bash)
  - `read_write`: 32 tools (no bash)
  - `full` / `full_no_approval`: 34 tools
- [ ] **Native Specs**: Call `nativeToolSpecs(for:)` with each mode, verify count and content
- [ ] **Schema Generation**: Call `toolSchemas(for:)` with each mode, verify JSON is valid and filtered
- [ ] **Compact Summary**: Call `compactToolSummary(for:)` with each mode, verify output includes tool names and risk levels
- [ ] **Vision in read_write**: Verify vision tools (screenshot, camera, read_screen) appear only in `read_write` and `full`

---

## 3. Apple Tools (`AppleTools.swift`)

### Tools & Features

| Tool | Actions | Requires Approval | Risk Level | Permissions |
|------|---------|-------------------|-----------|------------|
| `calendar` | list_today, list_week, list_date, search, create | No (read), Yes (create) | low | Full Access |
| `reminders` | list, create, complete, delete | No (read), Yes (write) | low | Full Access |
| `contacts` | list, search, lookup | No | low | Full Access |
| `mail` | count_unread, search, send | No (read), Yes (send) | medium | Mail access |
| `notes` | list, search, create, update | No (read), Yes (write) | low | Notes access |

### Permission Handling

**JIT Permission Flow**:
1. Apple tool checks permission via `isEventKitAuthorized()`, `INPreferences.siriAuthorizationStatus()`, or AppleScript error detection
2. If missing, calls `requestPermission(capability:)` → posts `.faeCapabilityRequested` → `JitPermissionController` triggers native dialog
3. Awaits `.faeCapabilityGranted` or `.faeCapabilityDenied` (30s timeout)
4. If granted, retries tool; if denied, returns friendly error

**Permission Status Provider**:
- `PermissionStatusProvider.swift` checks current status for all 5 Apple tools
- **No pre-flight check** — permissions are checked on first use
- Settings > Apple Tools shows per-tool Granted/Not Granted status + Grant buttons

### Calendar Tool Details

**Parameters**:
```json
{
  "action": "list_today|list_week|list_date|create|search",
  "date": "YYYY-MM-DD (for list_date)",
  "query": "string (for search)",
  "title": "string (for create)",
  "start_date": "ISO8601 (for create)",
  "end_date": "ISO8601 (for create)"
}
```

**Example**:
```
Fae, what's on my calendar today?
→ calendar tool with action=list_today
→ returns list of events for today
```

### Mail Tool Details

**AppleScript-based** (Mail.app automation):
- `count_unread`: returns count via AppleScript
- `search`: queries mail via AppleScript predicates
- `send`: composes and sends email via AppleScript

**Permission Detection**: No pre-flight API — permission is detected from AppleScript error response:
```swift
if isAppleScriptPermissionError(error.message) {
    // Request permission
}
```

### Testing Checklist

- [ ] **Calendar Permission**: Deny/grant calendar access, verify JIT flow works
- [ ] **Calendar Actions**: Test list_today, list_week, list_date, search, create
- [ ] **Reminders Permission**: Test reminders permission request
- [ ] **Reminders Actions**: Test list, create, complete, delete
- [ ] **Contacts Access**: Test contact search and lookup
- [ ] **Mail Permission**: Test Mail tool without permission (should trigger request)
- [ ] **Mail Send**: Create draft email, verify AppleScript sends it
- [ ] **Notes Permission**: Test Notes tool without permission
- [ ] **Permission Caching**: Grant permission once, verify next call doesn't re-request
- [ ] **30s Timeout**: Ignore JIT permission request, verify timeout after 30s
- [ ] **Permission Status UI**: Settings > Privacy shows per-tool status badges

---

## 4. Scheduler Tools (`SchedulerTools.swift`)

### 5 Scheduler Management Tools

| Tool | Action | Risk | Purpose |
|------|--------|------|---------|
| `scheduler_list` | — | low | List all tasks with schedule and status |
| `scheduler_create` | create | medium | Add a new user-defined task |
| `scheduler_update` | enable/disable, reschedule | medium | Modify task schedule or enabled state |
| `scheduler_delete` | delete | medium | Remove a user-defined task |
| `scheduler_trigger` | execute_now | low | Manually trigger a task immediately |

### scheduler_list Output Example

```json
{
  "tasks": [
    {
      "id": "memory_reflect",
      "name": "Memory Reflect",
      "kind": "builtin",
      "enabled": true,
      "schedule": "every 6 hours",
      "lastRun": "2026-03-05T10:15:00Z"
    },
    {
      "id": "my_custom_task",
      "name": "My Custom Task",
      "kind": "user",
      "enabled": true,
      "schedule": "daily 14:30",
      "lastRun": null
    }
  ]
}
```

### scheduler_create Parameters

```json
{
  "name": "My Daily Task",
  "schedule_type": "daily",
  "hour": "14",
  "minute": "30",
  "action": "run_skill"
}
```

### scheduler_update Parameters

```json
{
  "task_id": "my_custom_task",
  "enabled": false
}
```

Or:

```json
{
  "task_id": "my_custom_task",
  "schedule_type": "weekly",
  "day": "monday",
  "hour": "09",
  "minute": "00"
}
```

### scheduler_trigger Parameters

```json
{
  "task_id": "memory_reflect"
}
```

### Persistence

Tasks are persisted in `~/Library/Application Support/fae/scheduler.json`:

```json
{
  "tasks": [
    {
      "id": "memory_reflect",
      "name": "Memory Reflect",
      "kind": "builtin",
      "enabled": true,
      "scheduleType": "interval",
      "scheduleParams": {"hours": "6"},
      "action": "memory_reflect",
      "nextRun": "2026-03-05T16:30:00Z"
    }
  ]
}
```

### Testing Checklist

- [ ] **List Tasks**: Call `scheduler_list` tool, verify all 17 tasks appear with correct schedules
- [ ] **Create Task**: Create a new user task, verify it appears in list
- [ ] **Persistence**: Create task, restart app, verify task is still there
- [ ] **Enable/Disable**: Disable a built-in task, verify it doesn't run
- [ ] **Reschedule**: Change a task's schedule, verify it runs at new time
- [ ] **Delete Task**: Delete a user task, verify it's gone
- [ ] **Trigger Now**: Call `scheduler_trigger` with task ID, verify it executes immediately
- [ ] **Trigger Feedback**: Verify trigger returns success/failure status
- [ ] **JSON Roundtrip**: Edit scheduler.json manually, verify changes are read correctly
- [ ] **Built-in Immutability**: Verify built-in tasks cannot be deleted (only enabled/disabled)

---

## 5. Security & Approval System

### TrustedActionBroker (v0.8.63+)

**Central policy chokepoint** — all tool calls route through this actor.

Location: `Tools/TrustedActionBroker.swift` (334 lines)

### Decision Flow

```
ActionIntent
    ↓
DefaultTrustedActionBroker.evaluate()
    ↓
PolicyProfile + Speaker Identity + Tool Risk
    ↓
BrokerDecision {
  .allow(reason:)
  .allowWithTransform(checkpointBeforeMutation, reason:)
  .confirm(prompt:, reason:)
  .deny(reason:)
}
    ↓
PipelineCoordinator.executeTool()
    ↓
Tool executes OR approval overlay appears
```

### PolicyProfile (3 modes)

User configurable in Settings > Tools > Policy Profile:

| Profile | Low Risk | Medium Risk | High Risk | Rate Limits |
|---------|----------|-------------|-----------|------------|
| `balanced` | allow | confirm | confirm | 10/hour per tool |
| `moreAutonomous` | allow | allow | confirm | 20/hour per tool |
| `moreCautious` | confirm | confirm | confirm | 5/hour per tool |

### CapabilityTicket

Per-turn scoped grants with TTL:
- Issued at start of each conversation turn
- Tools must hold valid ticket to pass broker
- Auto-expire after turn completes
- Prevents tool calls from being cached/replayed

### Scheduler Task Allowlists

**Per-task auto-allow** via `ActionIntent.schedulerTaskId + schedulerConsentGranted`:

| Task | Allowed Tools | Denied Tools |
|------|---------------|-------------|
| `camera_presence_check` | camera | write, edit, bash, manage_skill, self_config |
| `screen_activity_check` | screenshot | write, edit, bash, manage_skill, self_config |
| `overnight_work` | web_search, fetch_url, activate_skill | write, edit, bash, manage_skill, self_config |
| `enhanced_morning_briefing` | calendar, reminders, contacts, mail, notes, activate_skill | write, edit, bash, manage_skill, self_config |

**Key design**: Scheduler tasks bypass normal approval BUT only for whitelisted tools per task.

### Testing Checklist

- [ ] **Default Deny**: Attempt write without approval, verify broker rejects it
- [ ] **Approval Prompt**: Attempt medium-risk tool (run_skill), verify approval overlay appears
- [ ] **Approval Accept**: Approve a tool call, verify execution proceeds
- [ ] **Approval Reject**: Reject a tool call, verify execution doesn't proceed
- [ ] **Rate Limiting**: Call same tool >10x rapidly, verify rate limit kicks in
- [ ] **ProfilePolicy**: Switch between balanced/moreAutonomous/moreCautious, verify behavior changes
- [ ] **CapabilityTicket**: Verify tool can only execute during same turn (not replayed next turn)
- [ ] **Scheduler Bypass**: Trigger awareness task via `scheduler_trigger`, verify allowed tools execute without approval
- [ ] **Scheduler Denied**: Attempt denied tool in scheduler context (bash, write), verify broker denies
- [ ] **Owner Identity**: When speaker is verified as owner + "full_no_approval" mode, verify tools execute without approval
- [ ] **Audit Log**: Check security event logger for all broker decisions (allow/confirm/deny)

---

## 6. Approval UI & Input Flow

### ApprovalOverlayController

Location: `ApprovalOverlayController.swift`

**Lifecycle**:
1. Tool request comes in with approval requirement
2. Actor posts `.faeInputRequired` notification with approval details
3. SwiftUI `ApprovalOverlayView` renders approval card (Yes/No buttons)
4. User clicks Yes/No
5. Controller posts `.faeInputResponse` with decision
6. Pipeline resumes or cancels execution

**Timeout**: 20 seconds (was 58s in v0.8.0, reduced to prevent user frustration)

### Approval Card UI

```
┌─────────────────────────────┐
│ Tool Approval Required       │
├─────────────────────────────┤
│ Tool: bash                   │
│ Risk: high                   │
│ Action: rm -rf ~/.cache      │
│                              │
│ Reason: Irreversible action  │
│         requires approval    │
├─────────────────────────────┤
│     [Cancel]    [Approve]    │
└─────────────────────────────┘
```

### Input Request Tool

**For interactive text/password input**:

```json
{
  "name": "input_request",
  "arguments": {
    "prompt": "Enter your password",
    "is_password": true,
    "timeout_seconds": 120
  }
}
```

Renders input card with:
- Prompt text
- Text field or SecureField
- Cancel/Submit buttons
- Progress indicator for timeout

### Testing Checklist

- [ ] **Approval Card Render**: High-risk tool call triggers approval overlay
- [ ] **Yes Decision**: Click Approve, verify tool executes
- [ ] **No Decision**: Click Cancel, verify tool call is aborted
- [ ] **Timeout**: Don't click anything, verify approval times out after 20s
- [ ] **Input Request**: Call `input_request` tool with text prompt
- [ ] **Password Input**: Call with `is_password=true`, verify SecureField is used
- [ ] **Input Submit**: Type text and click Submit, verify input is returned to tool
- [ ] **Input Cancel**: Close input card without submitting, verify tool receives cancellation
- [ ] **Input Timeout**: 120s timeout for input requests
- [ ] **Multiple Approvals**: Test sequential approval requests (approval from previous tool shouldn't affect next)

---

## 7. Permission Status Provider & JIT Permissions

### PermissionStatusProvider

Location: `Core/PermissionStatusProvider.swift`

**Provides status checks** for all Apple tools and system capabilities:

```swift
var calendarAuthorizationStatus: String
var remindersAuthorizationStatus: String
var contactsAuthorizationStatus: String
var mailAuthorizationStatus: String
var notesAuthorizationStatus: String
var screenRecordingAuthorized: Bool
var cameraAuthorized: Bool
```

Used by:
- Settings > Apple Tools tab (show per-tool permission badges)
- JitPermissionController (trigger permission requests)
- Apple tools themselves (pre-flight checks before execution)

### JitPermissionController

Location: `JitPermissionController.swift`

**Just-in-time permission request flow**:

1. App posts `.faeCapabilityRequested` notification with capability name
2. `JitPermissionController` observes notification
3. Triggers native macOS permission dialog (screen recording) or Settings redirect (mail/notes)
4. User grants/denies permission
5. `JitPermissionController` posts `.faeCapabilityGranted` or `.faeCapabilityDenied`
6. Apple tool awaits notification and retries (or returns error)

### Notification Names

```swift
extension Notification.Name {
    static let faeCapabilityRequested = Notification.Name("fae.capability.requested")
    static let faeCapabilityGranted = Notification.Name("fae.capability.granted")
    static let faeCapabilityDenied = Notification.Name("fae.capability.denied")
}
```

**userInfo format**:
```json
{
  "capability": "calendar|reminders|contacts|mail|notes|screenRecording|camera"
}
```

### Testing Checklist

- [ ] **Calendar Status**: Check `calendarAuthorizationStatus` before and after granting permission
- [ ] **Reminders Status**: Same for reminders
- [ ] **Contacts Status**: Same for contacts
- [ ] **Mail Status**: Same for mail (AppleScript-based, may not have pre-flight check)
- [ ] **Notes Status**: Same for notes
- [ ] **Screen Recording**: Check `screenRecordingAuthorized`, trigger JIT request
- [ ] **Camera**: Check `cameraAuthorized`, trigger JIT request
- [ ] **Permission Denial**: Deny permission, verify tool returns friendly error
- [ ] **Permission Granting**: Grant permission, verify tool retries and succeeds
- [ ] **JIT Timeout**: Don't respond to permission dialog, verify 30s timeout
- [ ] **Settings Integration**: Settings > Apple Tools tab shows current status and Grant buttons

---

## 8. Settings Tabs for Testing

### SettingsToolsTab

Location: `SettingsToolsTab.swift`

**Controls**:
- **Tool Mode Picker**: off / read_only / read_write / full / full_no_approval
- **PolicyProfile Picker**: balanced / moreAutonomous / moreCautious
- **Apple Tool Permissions**: Per-tool Granted/Not Granted badges + Grant buttons

**Testing**:
- [ ] Tool mode picker works
- [ ] Switching modes immediately filters available tools for LLM
- [ ] PolicyProfile changes take effect immediately (no restart needed)
- [ ] Grant buttons trigger JIT permission flow
- [ ] Permission badges update after granting/denying

### SettingsSchedulesTab

Location: `SettingsSchedulesTab.swift`

**Controls**:
- **Task List**: All 17 built-in + any user tasks
- **Enable/Disable Toggles**: Per-task on/off switch
- **Schedule Editor**: Change interval, daily time, weekly day/time
- **Delete Button**: Remove user-defined tasks
- **Run Now Button**: Manually trigger a task

**Testing**:
- [ ] Task list shows all 17 tasks with current schedules
- [ ] Disabling a task prevents it from running
- [ ] Enabling a disabled task resumes its schedule
- [ ] Run Now button immediately executes task
- [ ] Schedule editor updates task JSON file
- [ ] Create button opens new task dialog
- [ ] Delete button removes user tasks (not built-in tasks)

### SettingsAwarenessTab

Location: `SettingsAwarenessTab.swift`

**Controls**:
- **Master Toggle**: awareness.enabled on/off
- **Consent Section**: "Set Up Proactive Awareness" button (triggers onboarding)
- **Feature Toggles**: cameraEnabled, screenEnabled, overnightWorkEnabled, enhancedBriefingEnabled
- **Interval Pickers**: cameraIntervalSeconds, screenIntervalSeconds
- **Resource Toggles**: pauseOnBattery, pauseOnThermalPressure

**Testing**:
- [ ] Master toggle enables/disables all awareness features
- [ ] Consent button disabled until master toggle is on
- [ ] Camera toggle controls camera_presence_check task
- [ ] Screen toggle controls screen_activity_check task
- [ ] Overnight toggle controls overnight_work task
- [ ] Briefing toggle controls enhanced_morning_briefing task
- [ ] Interval sliders adjust task schedules
- [ ] Battery pause stops awareness when unplugged
- [ ] Thermal pressure pause stops awareness under thermal stress
- [ ] Settings persist after app restart

---

## 9. Test Server & Manual Testing

### Running Tests Locally

```bash
cd native/macos/Fae
swift test
```

**Key test targets**:
- `FaeSchedulerTests` — task scheduling, run history
- `ToolRegistryTests` — tool filtering by mode
- `TrustedActionBrokerTests` — policy evaluation
- `MemoryOrchestratorTests` — memory capture/recall

### Manual Testing Workflow

1. **Start Fae**:
   ```bash
   swift build
   source ~/.secrets  # For signing
   just _sign-bundle
   open .build/debug/Fae.app
   ```

2. **Access Debug Console** (Cmd+Shift+L to toggle):
   - Check scheduler task execution logs
   - Monitor tool calls and approvals
   - View broker decisions (allow/confirm/deny)

3. **Test Scheduler**:
   ```
   User: "List all my scheduled tasks"
   → scheduler_list tool fires
   → Returns 17 built-in + any user tasks
   ```

4. **Test Tool Filtering**:
   ```
   Settings > Tools > Tool Mode
   Select "off" mode
   User: "Read my calendar"
   → calendar tool is NOT available to LLM
   → LLM says "I don't have calendar access"
   ```

5. **Test Approval**:
   ```
   Settings > Tools > Policy Profile = "moreCautious"
   User: "Run my voice-tools skill"
   → high-impact medium-risk tool
   → approval overlay appears
   → Click Approve to proceed
   ```

6. **Test Awareness**:
   ```
   Settings > Awareness > Set Up Proactive Awareness
   → Onboarding flow (camera greeting, contact lookup, consent)
   → Camera observations start running
   → Screen monitoring starts
   → Morning briefing triggers after 07:00
   ```

---

## 10. Known Testing Challenges

### Challenge 1: Timing-Dependent Tests

**Problem**: Scheduler tasks run on wall-clock timers. Testing daily/weekly tasks requires mocking `Date()` or using `FakeClock`.

**Solution**: Use `FakeSchedulerClock` protocol to inject time in tests, or manually call task methods directly.

### Challenge 2: Permission Mocking

**Problem**: JIT permission requests require real system dialogs or mocking `Notification` posts.

**Solution**: `JitPermissionController` uses `NotificationCenter`, which can be mocked in tests. Post fake `.faeCapabilityGranted` notifications.

### Challenge 3: Memory Database State

**Problem**: Scheduler tasks access SQLite database. Tests need real or in-memory databases.

**Solution**: Use `MemoryStore(inMemory: true)` in tests.

### Challenge 4: AppleScript-Based Tools

**Problem**: Mail and Notes tools use AppleScript, which requires running on macOS with actual Mail.app/Notes.app.

**Solution**: Mock AppleScript execution or use CI environment with headless browsers.

### Challenge 5: Voice Pipeline Integration

**Problem**: Scheduler speak/proactive handlers require running `PipelineCoordinator`, which depends on ML engines.

**Solution**: Mock handlers or use unit tests that don't require full pipeline startup.

---

## 11. Continuous Integration Testing

### GitHub Actions Workflow

`.github/workflows/test.yml` runs:

```bash
swift test --enable-code-coverage
```

**CI Test Matrix**:
- macOS 12.7+ (x86_64 and arm64)
- Swift 5.9+
- Debug and Release configurations

### Coverage Goals

- ToolRegistry: 100% (tool filtering logic is critical)
- TrustedActionBroker: 100% (policy evaluation is critical)
- FaeScheduler: 85%+ (timing-dependent tests reduce coverage)
- AppleTools: 60%+ (system permissions hard to mock)

---

## 12. Test Case Examples

### Example 1: Tool Mode Filtering

```swift
func testReadOnlyToolsInReadOnlyMode() {
    let registry = ToolRegistry.buildDefault()

    let readOnlyTools = registry.toolSchemas(for: "read_only")
    XCTAssertNotNil(readOnlyTools)
    XCTAssertTrue(readOnlyTools.contains("calendar"))  // Apple read
    XCTAssertTrue(readOnlyTools.contains("web_search"))  // Web read
    XCTAssertFalse(readOnlyTools.contains("bash"))  // Write tool
    XCTAssertFalse(readOnlyTools.contains("write"))  // Write tool
}
```

### Example 2: Scheduler Task Execution

```swift
func testSchedulerTrigger() async {
    let scheduler = FaeScheduler(eventBus: FakeEventBus())

    // Override task handler
    scheduler.setSpeakHandler { _ in }

    // Trigger task manually
    await scheduler.triggerTask(id: "memory_reflect")
    let history = await scheduler.history(taskID: "memory_reflect")
    XCTAssertEqual(history.count, 1)
}
```

### Example 3: Broker Approval Policy

```swift
func testBrokerConfirmsHighRiskTool() async {
    let broker = DefaultTrustedActionBroker(
        knownTools: ["bash"],
        speakerConfig: FaeConfig.SpeakerConfig()
    )

    let intent = ActionIntent(
        source: .voice,
        toolName: "bash",
        riskLevel: .high,
        requiresApproval: true,
        isOwner: false,
        livenessScore: 0.8,
        explicitUserAuthorization: false,
        hasCapabilityTicket: true,
        policyProfile: .balanced,
        argumentSummary: "rm -rf /"
    )

    let decision = await broker.evaluate(intent)

    if case .confirm(let prompt, _) = decision {
        XCTAssertTrue(prompt.message.contains("bash"))
    } else {
        XCTFail("Expected confirm, got \(decision)")
    }
}
```

---

## Summary

The Fae scheduler and tool system is highly testable with:
- ✅ 31 clearly defined tools with risk levels
- ✅ 5 tool modes with deterministic filtering
- ✅ 17 scheduler tasks with clear execution paths
- ✅ Central broker policy that's easy to mock
- ✅ Approval UI that can be tested via notifications
- ✅ Permission system that's agnostic to real system dialogs

**Key focus areas for testing**:
1. Tool filtering logic (100% coverage)
2. Broker policy decisions (100% coverage)
3. Scheduler task execution (85%+ coverage)
4. JIT permission flow (mocked notifications)
5. Settings UI responsiveness (SwiftUI snapshot tests)
