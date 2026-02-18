# Phase 1.3: Route All Host Commands End-to-End

## Objective

Replace `NoopDeviceTransferHandler` with a production handler, add route()
handlers for the 10 unhandled commands, and wire the Swift event callback.

## Current State

- 13 of 23 commands are routed (ping, version, device, orb, capability, conversation)
- 10 commands fall through to "not implemented" catch-all
- FFI uses `NoopDeviceTransferHandler` which does nothing
- Swift `EmbeddedCoreSender` doesn't register an event callback

## Tasks

### Task 1 — Extend DeviceTransferHandler trait and add all route handlers

Files: `src/host/channel.rs`

Add trait methods for the remaining commands (runtime, scheduler, approval, config)
with default stub returns. Add route() handlers for all 10 remaining commands.
Remove the `_ =>` catch-all — every CommandName variant is now explicitly matched.

### Task 2 — Create FaeDeviceTransferHandler

Files: `src/host/handler.rs` (NEW)

Production handler holding channels:
- `mpsc::UnboundedSender<TextInjection>` for conversation.inject_text
- `mpsc::UnboundedSender<GateCommand>` for conversation.gate_set
- Remaining commands (scheduler, config, approval) log + return OK stubs

### Task 3 — Wire FFI to use FaeDeviceTransferHandler

Files: `src/ffi.rs`, `src/host/mod.rs`

Replace `NoopDeviceTransferHandler` with `FaeDeviceTransferHandler`.
Create channels in `fae_core_init`, store receivers for future pipeline wiring.

### Task 4 — Wire event callback in EmbeddedCoreSender

Files: `EmbeddedCoreSender.swift`

Call `fae_core_set_event_callback` after start(). Parse event JSON,
post to NotificationCenter so HostCommandBridge and UI can observe.

### Task 5 — Add tests for all route handlers

Files: `tests/host_command_channel_v0.rs`, `src/host/channel.rs`

Cover all 23 commands in route() tests. Ensure no `_ =>` catch-all exists.

## Quality gates

```bash
cargo clippy --no-default-features --all-targets -- -D warnings
cargo test --no-default-features
swift build --package-path native/macos/FaeNativeApp -c release
```
