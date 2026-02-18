# Code Simplification Review
**Date**: 2026-02-18
**Mode**: gsd (phase 1.2)

## Analysis

Reviewed the git diff for: Package.swift, FaeNativeApp.swift, EmbeddedCoreSender.swift, src/ffi.rs, src/host/channel.rs.

## Findings

- [LOW] src/ffi.rs:79-97 — drain_events() has three separate Mutex::lock() calls that each drop their guard before the next lock. This is correct (avoids lock ordering issues) but could be noted as intentional. A comment would help.
- [LOW] src/ffi.rs:370-375 — fae_core_set_event_callback acquires callback and callback_user_data in separate lock operations. Correct for avoiding deadlock, could be clarified with a comment about the deliberate split.
- [OK] src/host/channel.rs route() — The large match block is inherently a dispatch table. No simplification needed; adding it as a table-driven approach would add indirection without benefit.
- [OK] EmbeddedCoreSender.swift sendCommand() — The JSON serialization guard chain (isValidJSONObject → data → String) is idiomatic Swift. Cannot be simplified.
- [LOW] FaeNativeApp.swift init() — The `let sender = EmbeddedCoreSender(...)` + try/catch + `commandSender = sender` pattern results in `commandSender` being `Optional<EmbeddedCoreSender>`. This is clear but could use a local helper to reduce nesting. Minor.

## Simplification Opportunities

1. src/ffi.rs drain_events() — Add a comment above the lock sequence: `// Locks acquired separately to prevent deadlock if callback calls back into Fae (SAFETY: callback must NOT call fae_core_* functions)`.
2. src/ffi.rs — FaeInitConfig._log_level could have a doc comment: `/// Reserved for Phase 1.3 — parsed but not yet wired to a tracing subscriber.`

Neither warrants a code change. Both are documentation improvements only.

## Grade: A-
