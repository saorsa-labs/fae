# Phase 1.4: Release Workflow + Production Polish

## Objective

Update the release workflow for the embedded-core architecture (no separate
`fae-backend` binary), create a proper checked-in Info.plist with Handoff
and deep link support, and clean up entitlements.

## Tasks

### Task 1 — Create checked-in Info.plist

File: `native/macos/FaeNativeApp/Info.plist` (NEW)

Proper Info.plist with:
- NSUserActivityTypes for Handoff
- CFBundleURLTypes for deep links (fae://)
- All usage descriptions
- VERSION placeholder for CI substitution

### Task 2 — Update release.yml for embedded core

File: `.github/workflows/release.yml`

- Build libfae.a FIRST before swift build
- Remove all fae-backend references
- Use checked-in Info.plist with version substitution
- Single binary in the app bundle

### Task 3 — Update Entitlements.plist

File: `Entitlements.plist`

Update comment about network.server (now for UDS socket listener, not Dioxus).

### Task 4 — Build verification

cargo clippy, tests, swift build.
