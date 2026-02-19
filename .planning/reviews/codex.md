# Codex External Review
**Date**: 2026-02-19
**Status**: CODEX_UNAVAILABLE — manual fallback

## Findings

- [MEDIUM] src/host/handler.rs: request_runtime_start() emits "runtime.started" BEFORE the async pipeline task has loaded models. State transitions to Running and emits "started" while coordinator.run() is still pending in background. Callers may believe pipeline is ready when model loading hasn't completed.
- [LOW] pipeline_started_at records request_runtime_start() return time, not when pipeline is actually running. uptime_secs includes model loading time.
- [OK] Event bridge correctly handles RecvError::Lagged — no crash on event overflow.
- [OK] No deadlock risk — Mutex locks are short-held, never re-entrant.

## Grade: B
