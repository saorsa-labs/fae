# Native App Architecture v0 (Hybrid C ABI + Local IPC)

Status: Draft v0 for implementation in `fae-native-app-v0`.

## Decision

Fae will use a hybrid host architecture:

- macOS native app uses in-process Rust via C ABI (`libfae`) for low-latency voice path.
- Other frontends use local IPC to a Rust backend host process (`faed`).

This preserves native UI quality per platform while keeping scheduler, memory, tooling, and safety policy in Rust backend code.

## Goals

- Keep hot voice path latency effectively unchanged on macOS.
- Centralize scheduler authority in backend Rust code.
- Preserve memory contracts and existing on-disk compatibility.
- Support multiple frontends without duplicating backend logic.
- Keep command/event contracts explicit, versioned, and testable.

## Non-Goals (v0)

- Remote multi-machine control.
- Distributed scheduler leadership across hosts.
- Streaming PCM audio over IPC.
- Token-by-token UI streaming over IPC by default.

## Topology

### Mode A: In-Process Host (macOS native app)

```
Swift AppKit/SwiftUI
  └─ libfae (C ABI)
      └─ fae-core runtime (pipeline + memory + scheduler + tools)
```

Notes:

- Rust runs in same process as app shell.
- macOS entitlements/sandbox apply naturally to backend code.
- Best mode for microphone/STT/LLM/TTS/playback latency.

### Mode B: IPC Host (`faed`) for other frontends

```
Native/Web frontend
  └─ local IPC client
      └─ faed (Rust host process)
          └─ fae-core runtime
```

Notes:

- Control plane over IPC only.
- Runtime state and scheduler authority remain in one backend process.
- Apple companion targets (iPhone/Watch) should consume `NSUserActivity`
  handoff payloads and reconnect to the same backend authority rather than
  owning independent runtime/scheduler state.

## Core Host Responsibilities

`fae-core` host layer owns:

- pipeline lifecycle (`PipelineCoordinator`)
- runtime event stream (`RuntimeEvent`)
- approval workflow (`ToolApprovalRequest`)
- scheduler lifecycle and task execution
- model startup/preflight/update hooks
- memory orchestration and audit-safe writes

Current implementation touchpoints to refactor into host service:

- `src/bin/gui.rs`
- `src/pipeline/coordinator.rs`
- `src/startup.rs`
- `src/scheduler/runner.rs`
- `src/scheduler/tasks.rs`

## Control Plane vs Data Plane

### Data plane (must remain local/in-process where possible)

- mic capture
- VAD
- STT inference
- LLM generation
- TTS synthesis
- playback

### Control plane (safe for C ABI and IPC)

- start/stop runtime
- inject text
- gate wake/sleep
- tool approval decisions
- scheduler CRUD/trigger
- config get/patch
- event subscriptions

Rule:

- No PCM or high-frequency token deltas across IPC in v0.

## Contract v0

All hosts expose the same logical API shape.

## Envelope

Request:

```json
{
  "v": 1,
  "request_id": "uuid",
  "command": "runtime.start",
  "payload": {}
}
```

Response:

```json
{
  "v": 1,
  "request_id": "uuid",
  "ok": true,
  "payload": {}
}
```

Event:

```json
{
  "v": 1,
  "event_id": "uuid",
  "event": "runtime.assistant_sentence",
  "payload": {}
}
```

## Commands (v0 minimum)

- `host.ping`
- `host.version`
- `runtime.start`
- `runtime.stop`
- `runtime.status`
- `conversation.inject_text`
- `conversation.gate_set`
- `approval.respond`
- `scheduler.list`
- `scheduler.create`
- `scheduler.update`
- `scheduler.delete`
- `scheduler.trigger_now`
- `device.move`
- `device.go_home`
- `orb.palette.set`
- `orb.palette.clear`
- `capability.request`
- `capability.grant`
- `config.get`
- `config.patch`

## Events (v0 minimum)

Derived from `RuntimeEvent` and scheduler task results:

- `runtime.transcription`
- `runtime.assistant_sentence`
- `runtime.assistant_generating`
- `runtime.control`
- `runtime.tool_call`
- `runtime.tool_result`
- `runtime.mic_status`
- `runtime.model_selected`
- `runtime.provider_fallback`
- `scheduler.task_result`
- `scheduler.needs_user_action`
- `scheduler.error`

Event batching/coalescing policy:

- allow coalescing for high-rate signals (for example audio level)
- never coalesce tool approval requests, scheduler action prompts, or state transitions

## Scheduler Authority Model (Critical)

Single backend instance must be scheduler leader.

### Leader lease

Proposed lock file:

- path: `config_dir()/scheduler.leader.lock`
- fields: `instance_id`, `pid`, `started_at`, `heartbeat_at`, `lease_expires_at`

Cadence:

- heartbeat every 5s
- lease TTL 15s
- follower takeover allowed only after TTL expiry

### States

- `follower`: observes, no task execution
- `candidate`: attempting lease acquisition
- `leader`: executes tasks and emits results

### Execution dedupe

Each run writes an idempotency key:

- key: `task_id + scheduled_at + generation`
- persisted before execution
- repeated execution with same key is skipped

This prevents duplicate runs during failover races or process restarts.

v0.1 implementation note:

- run-key dedupe now serializes writers with a lock file and refreshes the ledger from disk per write attempt to prevent stale-cache duplicate execution across scheduler instances.

### Frontend rule

- frontends never start independent schedulers
- frontends interact through scheduler commands only

## macOS Sandbox and Security Model

### In-process C ABI mode

- backend inherits app sandbox and entitlements
- keychain use remains in backend (`credentials/*`)
- security-scoped bookmark operations remain backend-owned (`platform/*`)
- native shells can publish Apple Continuity handoff intents (`NSUserActivity`) for
  commands like `move to my watch`, `move to my phone`, and `go home`
- mic/speaker route controls should use native Apple APIs (CoreAudio/AVFoundation)
  and propagate route target as host control-plane metadata
- orb visual overrides can be orchestrated through host commands
  (`orb.palette.set` / `orb.palette.clear`) while scheduler/runtime authority
  remains in Rust
- sandbox-escape intents should be modeled as explicit capability broker
  commands (`capability.request` / `capability.grant`) rather than implicit
  in-process privilege changes

### IPC mode

- do not assume sandbox-equivalent rights in external clients
- privileged file/tool operations must execute in host process
- approval policy remains enforced in host process, never client-side

## Threading Model v0

- one runtime owner per host instance
- frontend calls are non-blocking command submissions (never long-running on UI thread)
- host fans out events via bounded queues with backpressure policy
- control-path queue saturation is a hard error with telemetry

## Versioning and Compatibility

- `v` in envelope is mandatory
- additive fields only in v1.x
- command/event removal requires v2
- backend advertises supported versions via `host.version`

## Migration Phases

### Phase 0: Contract + Harness

- define command/event schema
- add host trait abstraction in Rust (no behavior change)
- add scheduler leader lease implementation behind feature flag

### Phase 1: macOS In-Process Host

- create `libfae` C ABI shim over host trait
- wire native macOS shell to ABI
- keep Dioxus shell as parity harness

### Phase 2: IPC Host

- introduce `faed` and local transport
- reuse same command/event schema
- frontends consume via IPC client library

### Phase 3: Frontend Rollout

- move non-mac frontends to IPC
- keep scheduler ownership only in backend host

## Acceptance Gates (Architecture)

- exactly one scheduler leader at any time
- no duplicate scheduled execution in failover tests
- memory and audit files remain backward-compatible
- command/event schema validated in integration tests
- macOS in-process mode preserves sandbox/bookmark/keychain behavior

## Open Questions

- exact transport for local IPC is now UDS on Unix; Windows named-pipe benchmark path remains to be implemented
- whether command envelope should include optional auth nonce even for local clients
- whether scheduler lease should be file-lock-only or lease file + lock hybrid
