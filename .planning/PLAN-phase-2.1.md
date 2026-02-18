# Phase 2.1: Onboarding State Machine (Rust)

Add `OnboardingPhase` enum tracked in config, add `onboarding.advance` host command,
wire `onboarding.get_state` and `onboarding.complete` to the real state machine, and
emit events on phase transitions.

## Architecture

- `src/onboarding.rs` (new): `OnboardingPhase` enum + `OnboardingState` struct
- `src/config.rs`: add `onboarding_phase: OnboardingPhase` field to `SpeechConfig`
- `src/host/contract.rs`: add `OnboardingAdvance` command variant
- `src/host/channel.rs`: add `advance_onboarding_phase()` to `DeviceTransferHandler` trait
  and wire `handle_onboarding_advance()` in the server router
- `tests/host_contract_v0.rs`: add contract roundtrip tests for `onboarding.advance`
- `tests/host_command_channel_v0.rs`: add channel integration tests for all three
  onboarding commands

## Phase transitions

```
Welcome → Permissions → Ready → Complete
```

Calling `onboarding.advance` moves forward one step. Calling `onboarding.complete`
jumps directly to `Complete` and also sets `config.onboarded = true`. The
`onboarding.get_state` returns `{ phase, onboarded }`.

---

## Task 1: Create src/onboarding.rs with OnboardingPhase enum and state helpers

Create the onboarding module with the phase enum and serialization.

**Files:**
- Create: `src/onboarding.rs`

**Content:**
```rust
/// Four-phase onboarding state machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum OnboardingPhase {
    #[default]
    Welcome,
    Permissions,
    Ready,
    Complete,
}

impl OnboardingPhase {
    /// Advance to the next phase, returning None if already Complete.
    pub fn advance(self) -> Option<Self> { ... }
    /// Wire format string.
    pub fn as_str(self) -> &'static str { ... }
    /// Parse from wire format.
    pub fn parse(raw: &str) -> Option<Self> { ... }
}
```

Full doc comments on every public item. Tests inside the module:
- `advance_welcome_yields_permissions`
- `advance_permissions_yields_ready`
- `advance_ready_yields_complete`
- `advance_complete_yields_none`
- `serde_roundtrip_for_all_phases`
- `as_str_and_parse_roundtrip`

**Acceptance criteria:**
- Zero warnings
- All 6 module-level tests pass
- All public items documented

---

## Task 2: Add onboarding_phase field to SpeechConfig in src/config.rs

Wire the `OnboardingPhase` into config so it persists.

**Files:**
- Modify: `src/config.rs`

**Changes:**
- Add `pub onboarding_phase: OnboardingPhase` field to `SpeechConfig` with `#[serde(default)]`
- Field goes after `pub onboarded: bool`

**Acceptance criteria:**
- `cargo check` passes with zero warnings
- Existing config tests still pass
- `onboarding_phase` defaults to `OnboardingPhase::Welcome` via `#[derive(Default)]`

---

## Task 3: Add OnboardingAdvance to contract (TDD - tests first)

Add the `onboarding.advance` command to `CommandName` in contract.rs, and add
roundtrip tests to `tests/host_contract_v0.rs`.

**Files:**
- Modify: `src/host/contract.rs`
- Modify: `tests/host_contract_v0.rs`

**Changes to contract.rs:**
- Add `OnboardingAdvance` variant with `#[serde(rename = "onboarding.advance")]`
- Add `"onboarding.advance"` to `as_str()` match arm
- Add `"onboarding.advance"` to `parse()` match arm

**Tests to add (host_contract_v0.rs):**
```rust
#[test]
fn command_name_onboarding_advance_roundtrip() { ... }
```
And add `onboarding.advance` to `command_name_parse_known_and_unknown`.

**Acceptance criteria:**
- `OnboardingAdvance` parses from "onboarding.advance"
- Serde roundtrip: serializes to "onboarding.advance"
- `as_str()` returns "onboarding.advance"
- Zero warnings

---

## Task 4: Add advance_onboarding_phase to DeviceTransferHandler and wire channel

Add the trait method and route handler for `onboarding.advance`.

**Files:**
- Modify: `src/host/channel.rs`

**Changes:**
- Add `fn advance_onboarding_phase(&self) -> Result<OnboardingPhase>` to
  `DeviceTransferHandler` trait with a default impl returning `Ok(OnboardingPhase::Welcome)`
- Add `CommandName::OnboardingAdvance => self.handle_onboarding_advance(envelope)` to
  the `route()` match
- Implement `handle_onboarding_advance()`:
  - Calls `self.handler.advance_onboarding_phase()`
  - Emits event `"onboarding.phase_advanced"` with `{ new_phase: <str>, request_id }`
  - Returns response `{ accepted: true, phase: <str> }`

**Acceptance criteria:**
- `cargo check` passes
- Existing tests still pass
- Zero warnings

---

## Task 5: Add onboarding channel integration tests

Add full integration tests for `onboarding.get_state`, `onboarding.complete`, and
`onboarding.advance` to `tests/host_command_channel_v0.rs`.

**Files:**
- Modify: `tests/host_command_channel_v0.rs`

**Tests to add:**
- `onboarding_get_state_returns_state_payload` — default handler returns `{"onboarded": false}`
- `onboarding_complete_emits_event_and_returns_accepted` — checks event `onboarding.completed`,
  payload `{"accepted": true, "onboarded": true}`
- `onboarding_advance_returns_accepted_with_phase` — default handler, checks response has
  `{"accepted": true, "phase": <str>}` and event `"onboarding.phase_advanced"`

**Acceptance criteria:**
- All 3 new tests pass
- Zero warnings
- Existing tests unaffected

---

## Task 6: Add onboarding module to lib.rs and final validation

Wire up `pub mod onboarding` in lib.rs and run full validation.

**Files:**
- Modify: `src/lib.rs`

**Changes:**
- Add `pub mod onboarding;` in alphabetical order

**Validation:**
- `cargo check --all-features` — zero errors
- `cargo clippy --all-features --all-targets -- -D warnings` — zero warnings
- `cargo nextest run --all-features` — all tests pass
- `cargo doc --all-features --no-deps` — zero doc warnings

**Acceptance criteria:**
- All tasks integrated cleanly
- Zero warnings in any mode
- All public items in `onboarding` have doc comments
