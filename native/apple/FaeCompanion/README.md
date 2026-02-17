# Fae Companion Receivers (iPhone + Watch)

This folder provides receiver templates for Apple Continuity handoff payloads emitted by the macOS Fae native shell.

## Shared contract

Use `native/apple/FaeHandoffKit` as the single source of truth for the activity payload:

- activity type: `com.saorsalabs.fae.session.handoff`
- payload fields: `target`, `command`, `issuedAtEpochMs`

## Templates

- `Templates/Shared/HandoffSessionModel.swift`
- `Templates/iOS/FaeCompanioniOSApp.swift`
- `Templates/watchOS/FaeCompanionWatchApp.swift`

These are drop-in starter files for Xcode iOS/watchOS targets.

## Integration checklist

1. Add `FaeHandoffKit` to your iOS and watchOS targets.
2. Ensure all Apple targets share the same Team ID and iCloud/continuity entitlement setup.
3. Register `.onContinueUserActivity(FaeHandoffContract.activityType)` in each target.
4. Route received payloads into local audio session startup (mic + speaker) and host command bridge.
5. Validate round-trip by issuing commands on macOS:
   - "move to my watch"
   - "move to my phone"
   - "go home"

## Notes

- Handoff transports intent and minimal session metadata; it does not carry full conversation memory.
- Conversation state should remain anchored in Rust backend storage and rehydrated on receiver startup.
