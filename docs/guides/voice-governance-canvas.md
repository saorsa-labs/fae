# Voice Governance Canvas (Current Runtime)

Fae now supports a unified, voice-first governance flow for tool authority and permission visibility.

## What users can do by voice

- "show discussions" / "hide discussions"
- "show canvas" / "hide canvas"
- "open settings"
- "show tools and permissions"
- "set tool mode to read only"
- "set tool mode to read write"
- "set tool mode to full"
- "set tool mode to full no approval" (requires explicit yes/no confirmation)

## Canvas snapshot

When users say "show tools and permissions", Fae renders a live canvas snapshot with:

- Current tool mode
- Speaker/owner trust context
- Owner-gate state
- Current macOS permission states (mic, contacts, calendar, reminders, camera, screen recording)
- Allowed tools in current mode
- Blocked tools in current mode

## Canvas quick actions

The canvas includes mode chips:

- Off
- Read Only
- Read/Write
- Full
- Full (No Approval)

Clicking a chip routes through a governed action bridge and applies via `config.patch(tool_mode, ...)`.

## Architecture notes

- Snapshot model: `native/macos/Fae/Sources/Fae/Core/ToolPermissionSnapshot.swift`
- Voice command parser: `.../Core/VoiceCommandParser.swift`
- Voice command execution and confirmations: `.../Pipeline/PipelineCoordinator.swift`
- Canvas action interception: `.../CanvasWindowView.swift`
- Mutation bridge: `.../HostCommandBridge.swift` via `.faeGovernanceActionRequested`

## Design intent

This keeps the system aligned with the project preference:

- prefer natural-language control,
- keep UI interactive and transparent,
- route changes through a single controlled mutation path,
- preserve user authority over high-impact autonomy changes.
