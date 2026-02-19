# Security Review
**Date**: 2026-02-19
**Mode**: gsd-task

## Findings

- [OK] All unsafe blocks in ffi.rs have explicit SAFETY comments
- [OK] URL scheme validation prevents javascript: injection
- [OK] Orb palette/feeling/flash validated against allowlists
- [OK] No hardcoded credentials or secrets
- [MEDIUM] src/host/handler.rs:443-455: TOCTOU race in pipeline state check — pipeline_state() acquires/drops lock then re-acquires for write. Concurrent callers could both pass the Stopped check. Low practical risk given single Swift main-thread caller.
- [OK] broadcast channel capacity limits prevent unbounded memory growth
- [OK] Event IDs use UUID v4

## Grade: A-
