# Voice Governance Canvas (Current Runtime)

Fae now supports a unified, voice-first governance flow for tool authority, behavior settings, and permission remediation.

## What users can do by voice

Window/canvas controls:

- "show discussions" / "hide discussions"
- "show canvas" / "hide canvas"
- "open settings"
- "show tools and permissions"

Governance controls:

- "set tool mode to read only/read write/full/full no approval"
- "enable/disable thinking mode"
- "enable/disable barge in"
- "require/don't require direct address"
- "enable/disable vision"
- "lock/unlock your voice"

Permission requests:

- "request camera permission"
- "enable screen recording permission"
- "grant contacts/calendar/reminders/microphone access"

## Governance confirmations

High-impact changes are explicit transactions:

- `tool_mode = full_no_approval` always requires yes/no confirmation in voice flow.
- Risky setting changes (for example enabling vision or unlocking voice identity) are confirmation-gated in governed paths.

## Canvas snapshot

When users say "show tools and permissions", Fae renders a live snapshot with:

- Tool mode + mapped policy profile
- Speaker/owner trust context
- Owner-gate state
- Behavior toggles (thinking, barge-in, direct-address, vision, voice lock)
- Current macOS permission states (mic, contacts, calendar, reminders, camera, screen recording)
- Allowed tools in current mode
- Blocked tools in current mode

## Canvas quick actions

The canvas now includes:

- Tool mode chips
- Behavior setting chips
- Permission grant chips for currently-missing permissions

All click actions route through the governed mutation path (`.faeGovernanceActionRequested` → `HostCommandBridge` → `config.patch` / JIT permission request).

## Blocked-tool remediation cards

If tools are hidden/blocked or a tool-backed request fails to execute tools, Fae pushes a remediation card to canvas with actionable fixes (mode change, owner enrollment, permission grant, open settings).

## Architecture notes

- Snapshot model + rendering: `native/macos/Fae/Sources/Fae/Core/ToolPermissionSnapshot.swift`
- Snapshot builder service: `.../Core/CapabilitySnapshotService.swift`
- Voice command parser: `.../Core/VoiceCommandParser.swift`
- Voice command execution + confirmations: `.../Pipeline/PipelineCoordinator.swift`
- Canvas action interception: `.../CanvasWindowView.swift`
- Mutation bridge: `.../HostCommandBridge.swift`

## Design intent

- natural-language governance first,
- interactive transparent controls in canvas/settings,
- single governed mutation pathway,
- explicit confirmations for high-impact autonomy changes.
