# Phase 1.2: Swift Integration — EmbeddedCoreSender

## Objective

Replace `ProcessCommandSender` (subprocess IPC) with `EmbeddedCoreSender`
that calls the C FFI functions from `libfae.a` directly in-process.

## Quality gates

```bash
swift build --package-path native/macos/FaeNativeApp -c release
# Must produce a clean build with zero warnings.
```

---

## Task 1 — Create CLibFae C module for SPM

Files: Sources/CLibFae/include/fae.h (copy), Sources/CLibFae/include/module.modulemap (NEW), Sources/CLibFae/shim.c (NEW)

Expose the Fae C header to Swift via a SPM-compatible C library target.

## Task 2 — Update Package.swift

Files: Package.swift

Add CLibFae target. Add libfae.a linker settings to FaeNativeApp target.
Needs `-L` path to Rust build output and `-lfae` plus system frameworks.

## Task 3 — Create EmbeddedCoreSender.swift

Files: Sources/FaeNativeApp/EmbeddedCoreSender.swift (NEW)

Implements `HostCommandSender`. Calls `fae_core_init`, `fae_core_start`,
`fae_core_send_command`, `fae_core_stop`, `fae_core_destroy`. Registers
event callback that posts to NotificationCenter.

## Task 4 — Wire into FaeNativeApp.swift

Files: Sources/FaeNativeApp/FaeNativeApp.swift

Replace `ProcessCommandSender` with `EmbeddedCoreSender`. Remove
`locateHostBinary()`. Update init/onAppear/deinit.

## Task 5 — Build verification

Build libfae.a for arm64, then swift build. Verify clean compilation.
