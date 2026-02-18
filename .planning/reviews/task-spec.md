# Task Specification Review
**Date**: 2026-02-18
**Task**: Phase 1.2 — Swift Integration (EmbeddedCoreSender), all 5 tasks

## Spec Compliance

### Task 1 — Create CLibFae C module for SPM
- [x] Sources/CLibFae/include/fae.h present (copied from Rust FFI header)
- [x] Sources/CLibFae/include/module.modulemap present with correct module declaration
- [x] Sources/CLibFae/shim.c present (SPM C target placeholder)
- [x] All 8 FFI functions declared in fae.h match src/ffi.rs exports

### Task 2 — Update Package.swift
- [x] CLibFae target added
- [x] FaeNativeApp depends on CLibFae
- [x] -L paths to target/aarch64-apple-darwin/release and target/debug present
- [x] All required system frameworks linked: Security, CoreFoundation, SystemConfiguration, Metal, MetalPerformanceShaders, Accelerate, Carbon, AudioToolbox, CoreAudio, IOKit
- [x] c++ and resolv libraries linked

### Task 3 — Create EmbeddedCoreSender.swift
- [x] Implements HostCommandSender protocol
- [x] Calls fae_core_init, fae_core_start, fae_core_send_command, fae_core_stop, fae_core_destroy
- [x] fae_string_free called on responses
- [~] Event callback registration (fae_core_set_event_callback) NOT implemented — spec says "Registers event callback that posts to NotificationCenter". This is NOT done in EmbeddedCoreSender. Events are only polled via response drain in the Rust side, not pushed via callback to Swift.

### Task 4 — Wire into FaeNativeApp.swift
- [x] EmbeddedCoreSender used instead of ProcessCommandSender
- [x] locateHostBinary() removed (no longer needed)
- [x] init() creates and starts sender
- [x] onAppear wires sender to hostBridge

### Task 5 — Build verification
- [x] swift build -c release passes clean
- [x] Rust cargo check/clippy/test all pass

## Spec Gap Finding
- [MEDIUM] Task 3 spec: "Registers event callback that posts to NotificationCenter" — fae_core_set_event_callback is NOT called from EmbeddedCoreSender. The event push path is absent. Events are only visible to the Swift layer if explicitly polled via fae_core_poll_event (also not wired). This was likely deferred to a future phase but the spec explicitly listed it.

## Grade: B+
(All build gates pass; one spec item — event callback registration — not implemented but may be intentionally deferred)
