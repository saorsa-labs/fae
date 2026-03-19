# Phase 8.1: Core Python Skill Runner

## Overview
Build `PythonSkillRunner` — subprocess manager that spawns Python skills via `uv run`, communicates via JSON-RPC 2.0 over stdin/stdout, handles lifecycle (spawn, handshake, running, health check, shutdown). Daemon + one-shot modes. Integrated into ToolRegistry.

## Tasks

### Task 1: Error Types & Protocol Definitions
**Files**: `src/skills/error.rs` (new), `src/skills/python_protocol.rs` (new)
**Tests**: Unit tests for error serialization, JSON-RPC 2.0 message parsing
**Acceptance**: `PythonSkillError` enum via thiserror. JSON-RPC 2.0 request/response/notification types. Full serde round-trip tests. Zero warnings.

### Task 2: Process Lifecycle State Machine
**Files**: `src/skills/python_runner.rs` (new)
**Tests**: State transition tests, process cleanup on drop
**Acceptance**: `PythonProcessState` enum (Pending/Starting/Running/Failed/Stopped). `PythonSkillProcess` struct with state tracking. Invalid transitions rejected. `kill_on_drop` verified.

### Task 3: JSON-RPC 2.0 Communication Layer
**Files**: `src/skills/python_runner.rs` (expanded)
**Tests**: Request/response round-trip, timeout handling, broken pipe recovery
**Acceptance**: Send request + receive response with timeout. Handle notifications. Output bounded (100KB). Broken pipe detection.

### Task 4: Handshake & Health Check Protocol
**Files**: `src/skills/python_runner.rs` (expanded), `src/skills/python_protocol.rs` (expanded)
**Tests**: Successful handshake, timeout, invalid response
**Acceptance**: Handshake verifies skill name+version. Health check returns status. Timeout transitions to Failed.

### Task 5: Daemon vs One-Shot Mode
**Files**: `src/skills/python_runner.rs` (expanded)
**Tests**: Daemon keeps process alive, one-shot cleans up
**Acceptance**: Daemon spawns once, reuses. Oneshot spawns per request. Restart backoff (1s/2s/4s, max 60s).

### Task 6: Config Types & Directory Paths
**Files**: `src/config.rs` (expanded), `src/fae_dirs.rs` (expanded)
**Tests**: Serde round-trip, defaults, path resolution
**Acceptance**: `PythonSkillsConfig` in SpeechConfig (enabled, timeout, max_concurrent, health_check_interval, restart_backoff). `python_skills_dir()` with env override. Defaults: 30s timeout, 5 max restarts, 60s health interval.

### Task 7: ToolRegistry Integration
**Files**: `src/fae_llm/tools/python_skill.rs` (new), `src/fae_llm/tools/mod.rs` (expanded)
**Tests**: Tool registration, execution, mode gating
**Acceptance**: `PythonSkillTool` implementing Tool trait. Schema: skill_name + request. ToolMode::Full only. Returns ToolResult. Handles process not found vs execution failure.

### Task 8: Host Commands & Module Wiring
**Files**: `src/host/contract.rs` (expanded), `src/host/handler.rs` (expanded), `src/skills/mod.rs` (expanded)
**Tests**: Command dispatch, module exports
**Acceptance**: `skill.python.start`, `skill.python.stop`, `skill.python.list` commands. Skills module re-exports python_runner types. Host handler routes commands.

### Task 9: End-to-End Integration Test
**Files**: `tests/python_skill_runner_e2e.rs` (new)
**Tests**: Full lifecycle: spawn, handshake, request, response, cleanup, timeout
**Acceptance**: Mock skill script (shell-based echo server, no real UV needed). Handshake succeeds. Request/response works. Timeout fires on hanging skill. Process cleanup on drop.

## Task Dependencies
```
Task 1 (Types) → Task 2 (State Machine) → Task 3 (Communication) → Task 4 (Handshake)
                                         → Task 5 (Modes)
Task 6 (Config) can run after Task 1
Task 7 (Tool) needs Task 3 + 5
Task 8 (Host) needs Task 2
Task 9 (E2E) needs all 1-8
```
