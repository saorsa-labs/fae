# Fixes Applied — Phase 6.2 Task 7 Review

**Applied:** 2026-02-20T15:47:00Z
**Consensus report:** consensus-20260220-154647.md

## Fix A: Observer token not stored (6/15 votes)

**File:** `native/macos/FaeNativeApp/Sources/FaeNativeApp/FaeNativeApp.swift`

**Change:**
1. Added `@State private var deviceTransferObserver: NSObjectProtocol?` to `FaeNativeApp` struct.
2. Wrapped the `addObserver` call in `if deviceTransferObserver == nil { ... }` guard.
3. Stored the returned token in `deviceTransferObserver`.

This prevents duplicate observer registration if `onAppear` fires more than once.

## Fix B: Duplicate coordinator match arms (6/15 votes)

**File:** `src/pipeline/coordinator.rs`

**Change:**
1. Added `emit_panel_visibility_events(cmd, runtime_tx)` private helper function before `handle_voice_command`.
2. Replaced the two identical 14-line match blocks (normal path + interrupted-generation path) with calls to the helper.

## Build Verification After Fixes

- `cargo check`: PASS
- `cargo clippy -D warnings`: PASS
- `cargo fmt --check`: PASS

## Remaining Items

- Finding C (no coordinator integration test for ConversationVisibility dispatch): Deferred. Coordinator test complexity makes this a future improvement.
- INFO items: voice_command module doc stale — low priority, deferred.
