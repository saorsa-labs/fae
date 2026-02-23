# ADR-002: Embedded Rust Core Architecture

**Status:** Accepted
**Date:** 2026-02-11
**Scope:** Host architecture (`src/ffi.rs`, `src/host/`, `native/macos/`)

## Context

Fae needs a native macOS app with the lowest possible voice pipeline latency. The Rust core contains all intelligence — voice pipeline, LLM inference, memory, scheduler, tools, and skills. The question was how to integrate this core with the Swift UI shell.

Two integration patterns were considered:

| Concern | Subprocess | Embedded (C ABI) |
|---------|-----------|-------------------|
| Latency | JSON serialization + OS pipes per command | Direct function call (~0ms) |
| Reliability | Pipe breaks, process crashes orphan the UI | Single process, single fate |
| Bundling | Two binaries in .app bundle | One binary |
| State coherence | Two processes with separate memory spaces | Shared address space |
| Sandbox | Backend inherits via process inheritance | Backend inherits by being in-process |
| Complexity | Process lifecycle management, pipe buffering | FFI boundary, but no IPC |

The zero-panic Rust policy (`#[deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)]`) makes the single-crash-domain tradeoff acceptable.

## Decision

Fae uses a **hybrid architecture** with two integration modes:

### Mode A: Embedded (Fae.app — primary)

The macOS native app links `libfae.a` directly via C ABI. The Rust core runs in-process with zero IPC overhead.

```
Swift AppKit/SwiftUI ─── C ABI ──> libfae (Rust static lib)
                                    ├── Pipeline coordinator
                                    ├── Memory system
                                    ├── Scheduler
                                    ├── Tool execution
                                    └── Optional socket listener (Mode B)
```

### Mode B: IPC (external frontends)

Other frontends connect to the running Fae.app via Unix domain socket (`~/.fae/fae.sock`). Same JSON command/event protocol, but paying IPC cost (~3ms RTT).

### FFI surface (`src/ffi.rs`)

The C ABI boundary is intentionally thin — control-plane only:

- `fae_core_init(config_json)` — Initialize runtime, returns opaque handle
- `fae_core_start(rt)` — Spawn tokio runtime, scheduler, pipeline
- `fae_core_send_command(rt, json)` — Send command envelope, get response
- `fae_core_poll_event(rt)` — Poll for next pending event
- `fae_core_set_event_callback(rt, cb, ctx)` — Register event callback
- `fae_core_stop(rt)` — Graceful shutdown
- `fae_string_free(s)` — Free returned strings

What stays in-process (never crosses FFI): PCM audio buffers, STT/LLM/TTS tensors, memory record internals, scheduler task execution.

### Command/event protocol (v1)

JSON envelope format shared by both modes:

```json
// Command
{"v": 1, "request_id": "uuid", "command": "runtime.start", "payload": {}}

// Response
{"v": 1, "request_id": "uuid", "ok": true, "payload": {}}

// Event
{"v": 1, "event_id": "uuid", "event": "runtime.assistant_sentence", "payload": {}}
```

Commands include: `host.ping`, `host.version`, `runtime.start/stop/status`, `conversation.inject_text`, `conversation.gate_set`, `approval.respond`, `scheduler.*`, `config.get/patch`, `orb.palette.*`, `capability.*`.

### Threading model

- **Main thread** (Swift/AppKit): UI rendering, user events, non-blocking FFI calls
- **Tokio runtime** (owned by libfae): Pipeline, scheduler, memory, socket listener, event broadcast
- **Audio threads** (CoreAudio): Mic capture, playback (managed by macOS, not tokio)

### Scheduler authority

Single backend instance is scheduler leader. Leader lease via lock file with 5s heartbeat, 15s TTL. Frontends never start independent schedulers — they interact through scheduler commands only. Run-key dedupe prevents duplicate execution during failover.

## Latency SLOs (v0)

| Metric | Target |
|--------|--------|
| C ABI command dispatch (`runtime.status`) | p95 <= 0.25ms |
| IPC request/response (`host.ping`) | p95 <= 3ms |
| IPC event delivery | p95 <= 5ms |
| Gate command to effective state | p95 <= 20ms |
| Text inject to generation start | p95 <= 40ms |
| Scheduler trigger jitter | p95 <= 150ms |
| Leader failover recovery | <= 20s |
| Duplicate execution for same run key | 0 |

## Consequences

### Positive

- **Zero IPC overhead** for the primary macOS app path
- **Single process** simplifies crash recovery, bundling, and sandboxing
- **Same protocol** for embedded and external clients — consistent behavior
- **Scheduler authority** centralized in Rust, preventing split-brain

### Negative

- **FFI boundary** requires careful memory management (C string lifecycle)
- **Single crash domain** — a Rust panic takes down the UI (mitigated by zero-panic policy)
- **Build complexity** — static library + Swift Package Manager linking with anti-dead-strip anchor (see `docs/guides/linker-anchor.md`)

## Anti-dead-strip anchor

SPM's `-dead_strip` removes Rust subsystems not reachable from FFI exports. `src/linker_anchor.rs` prevents this with `black_box`-guarded references to all major subsystem constructors. See `docs/guides/linker-anchor.md` for maintenance instructions.

## macOS sandbox and security

- Backend inherits app sandbox and entitlements naturally
- Keychain use remains in backend (`credentials/*`)
- Security-scoped bookmarks remain backend-owned (`platform/*`)
- Sandbox-escape intents modeled as explicit capability broker commands

## References

- Ghostty architecture (inspiration for thin-shell + fat-core pattern)
- `src/ffi.rs`, `src/host/contract.rs`, `src/host/channel.rs`
- `native/macos/Fae/Sources/Fae/EmbeddedCoreSender.swift`
