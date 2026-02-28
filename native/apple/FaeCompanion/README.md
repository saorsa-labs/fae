# Fae Companion Receivers (iPhone + Watch)

This folder provides receiver templates for Apple Continuity handoff payloads emitted by the macOS Fae app.

## Shared contract

Use `native/apple/FaeHandoffKit` as the source of truth for payload schema:

- activity type: `com.saorsalabs.fae.session.handoff`
- payload fields: `target`, `command`, `issuedAtEpochMs`

## Templates

- `Templates/Shared/HandoffSessionModel.swift`
- `Templates/iOS/FaeCompanioniOSApp.swift`
- `Templates/watchOS/FaeCompanionWatchApp.swift`

## Integration checklist

1. Add `FaeHandoffKit` to iOS/watchOS targets.
2. Ensure the same Team ID and continuity entitlements across targets.
3. Register `.onContinueUserActivity(FaeHandoffContract.activityType)`.
4. Route payloads into local companion audio/session startup.
5. Validate round-trip commands from macOS:
   - "move to my watch"
   - "move to my phone"
   - "go home"

## Notes

- Handoff carries intent + minimal session metadata only.
- Durable conversation/memory state remains anchored in macOS app storage (`~/Library/Application Support/fae/`).
