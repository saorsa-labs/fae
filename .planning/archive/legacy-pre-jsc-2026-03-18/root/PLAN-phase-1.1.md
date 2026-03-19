# Phase 1.1: Permission Store + Config Schema

## Objective

Add a `PermissionStore` with `PermissionKind` enum and an `onboarded: bool` flag to
`SpeechConfig`. Permissions persist in config.toml under `[permissions]`. The
`onboarded` flag gates the onboarding flow — existing test users who never onboarded
will be caught because the flag defaults to `false`.

## Quality gates

```bash
cargo fmt --all -- --check
cargo clippy --all-features -- -D warnings
cargo test --all-features
```

---

## Task 1 — Create `src/permissions.rs` with PermissionKind enum and PermissionStore

File: `src/permissions.rs` (NEW)

- `PermissionKind` enum: Microphone, Contacts, Calendar, Reminders, Mail, Files,
  Notifications, Location, Camera, DesktopAutomation
- Derive: Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize
- `Display` and `FromStr` impls for string round-tripping
- `PermissionGrant` struct: `kind: PermissionKind`, `granted: bool`,
  `granted_at: Option<u64>` (epoch seconds)
- `PermissionStore` struct: wraps `Vec<PermissionGrant>` with helper methods:
  - `is_granted(&self, kind: PermissionKind) -> bool`
  - `grant(&mut self, kind: PermissionKind)` — sets granted=true + timestamp
  - `deny(&mut self, kind: PermissionKind)` — sets granted=false
  - `all_granted(&self) -> Vec<PermissionKind>`
- `Default` impl: empty vec (no permissions granted)

## Task 2 — Add permissions + onboarded flag to SpeechConfig

File: `src/config.rs`

- Add `pub permissions: PermissionStore` field to `SpeechConfig`
- Add `pub onboarded: bool` field to `SpeechConfig` (default `false`)
- Both use `#[serde(default)]` for backward compat with existing config.toml files

## Task 3 — Register module in lib.rs

File: `src/lib.rs`

- Add `pub mod permissions;`
- Add `pub use permissions::{PermissionKind, PermissionStore};`

## Task 4 — Add unit tests for PermissionStore

File: `src/permissions.rs` (tests section)

- Test grant/deny/is_granted round-trip
- Test `all_granted()` returns only granted permissions
- Test `Display`/`FromStr` round-trip for all PermissionKind variants
- Test Default is empty (no permissions)
- Test double-grant updates timestamp, doesn't duplicate

## Task 5 — Add integration test for config serialization

File: `tests/permission_config_roundtrip.rs` (NEW)

- Create SpeechConfig with some permissions granted, serialize to TOML, deserialize,
  verify permissions preserved
- Test that config.toml without `[permissions]` section deserializes cleanly
  (backward compat — default empty store)
- Test that `onboarded = false` is the default when field missing
- Test that `onboarded = true` persists and round-trips
