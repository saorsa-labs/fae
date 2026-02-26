# Fae (macOS SwiftUI)

Swift-first native macOS app for Fae. This package is the primary app entrypoint and should be built/tested with SwiftPM.

## Current capabilities

- Native SwiftUI app with native orb/conversation/canvas windows
- Voice pipeline integration, settings/onboarding, approvals, and handoff UI
- Handoff payload publication via `NSUserActivity`
- Native mic permission + discovery and output route picker surfaces

## Build & test

From repository root:

```bash
cd native/macos/Fae
swift build
swift test
```

## Known build blockers

- First-time or clean builds may fail if SwiftPM cannot fetch remote dependencies/submodules (network/DNS required).
- First run may require large model downloads before runtime is ready.

## Notes

- iPhone/Watch session continuation still requires matching companion targets using the same activity type/payload contract.
- Legacy Rust embedding/IPC docs remain in root docs as archival context; SwiftPM app flow is the default for current development.
