# Complexity Review
**Date**: 2026-02-18
**Mode**: gsd (phase 1.2)

## Statistics

### New/modified files (phase 1.2)
- src/ffi.rs: 438 lines (new)
- src/host/channel.rs: 764 lines (modified, was ~570)

### Complexity analysis

- [OK] src/ffi.rs — 8 extern "C" functions, each follows the same pattern: null check → borrow_runtime → dispatch → return. Low cyclomatic complexity per function. The most complex is fae_core_send_command at ~30 lines.
- [OK] src/host/channel.rs:164 — route() function dispatches ~14 command variants via match. Each arm is a single function call. Appropriate for a command router.
- [LOW] src/host/channel.rs — The HostCommandServer::route() match covers 14 variants across 200 lines. Not a problem — it's a command dispatch table, inherently O(commands) in length.
- [OK] EmbeddedCoreSender.swift — 106 lines total, 3 substantive methods. No deep nesting.
- [OK] FaeNativeApp.swift — 66 lines, clean SwiftUI App body.
- [OK] No function exceeds 80 lines in new phase 1.2 code.

## Grade: A
