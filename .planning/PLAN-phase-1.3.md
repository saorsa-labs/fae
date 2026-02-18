# Phase 1.3: Wire Capability Bridge

## Goal
Wire `capability.request`, `capability.grant`, and new `capability.deny` host
commands to persist permission grants in `PermissionStore`. Add onboarding state
commands (`onboarding.get_state`, `onboarding.complete`). When a permission is
granted/denied, emit events so Swift UI can update.

## Tasks

### Task 1: Add capability.deny + onboarding commands to contract
Add `CapabilityDeny`, `OnboardingGetState`, `OnboardingComplete` to `CommandName`
enum. Add `as_str()` and `parse()` entries. Add route handlers in channel.rs.

**Files:** `src/host/contract.rs`, `src/host/channel.rs`

### Task 2: Add config-aware handler with shared state
Give `FaeDeviceTransferHandler` an `Arc<Mutex<SpeechConfig>>` and config path.
Add constructor `FaeDeviceTransferHandler::new(config, config_path)`.
Add `deny_capability()`, `query_onboarding_state()`, `complete_onboarding()` to
the `DeviceTransferHandler` trait.

**Files:** `src/host/channel.rs`, `src/host/handler.rs`

### Task 3: Wire grant/deny/onboarding to persist permissions
Implement `grant_capability()`: parse capability string → `PermissionKind`,
call `store.grant()`, save config to disk.
Implement `deny_capability()`: parse → `store.deny()`, save.
Implement `query_onboarding_state()`: return `{onboarded: bool}`.
Implement `complete_onboarding()`: set `onboarded = true`, save.

**Files:** `src/host/handler.rs`

### Task 4: Unit tests for capability persistence
Test: grant via handler persists to config, deny revokes, unknown capability
returns error, onboarding state query, onboarding complete sets flag.
Test channel routing for all new commands.

**Files:** `src/host/handler.rs` (test module), `src/host/channel.rs` (test additions)

### Task 5: Integration test — end-to-end capability bridge
Create config on disk, send capability.grant via channel, verify config file
updated. Send capability.deny, verify revoked. Send onboarding.complete,
verify flag set. Verify events emitted.

**Files:** `tests/capability_bridge_e2e.rs` (new)
