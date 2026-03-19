# Phase 3.2: Script-Scoped Capability Tickets

## Goal
Bind capability grants to a script run and its allowed tool set.

## Tasks
- Define script-scoped ticket lifetime and expiry.
- Track remaining budget/capability state during execution.
- Prevent tickets from leaking across turns or scripts.
- Add tests for expiry, scope enforcement, and cancellation cleanup.

## Acceptance
- Script runs have bounded, non-reusable capability scope.
- Tickets expire cleanly on completion, failure, or cancellation.

## Validation
```bash
cd native/macos/Fae
swift build
swift test
```
