# FaeNativeApp (macOS SwiftUI)

Native Swift app shell for Fae with an orb-first visual system and cross-device handoff controls.

## Current capabilities

- Native SwiftUI window + WebKit orb renderer (`Resources/Orb/index.html`)
- Orb modes: `idle`, `listening`, `thinking`, `speaking`
- Orb palette overrides including `moss-stone` and `peat-earth`
- Command parsing for device transfer intents:
  - `move to my watch`
  - `move to my phone`
  - `go home`
- Command parsing for orb control:
  - `set moss stone`
  - `set peat earth`
  - `reset orb palette`
- Handoff payload publication via `NSUserActivity`
- Native mic permission + discovery and output route picker surfaces
- App icon set from the full-face asset (`Resources/App/AppIconFace.jpg`)

## Run

From repository root:

```bash
cd native/macos/FaeNativeApp
swift run
```

## Notes

- This shell publishes handoff intents so iPhone/Watch counterparts can pick up the session.
- Actual cross-device session continuation requires matching app targets on iPhone/Watch using the same activity type and payload contract.
- Rust host IPC/C-ABI integration is the next layer; this app is the native UI foundation.
