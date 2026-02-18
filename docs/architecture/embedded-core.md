# Embedded Rust Core Architecture

Status: Approved. Definitive integration model for Fae.app.

Companion docs:
- `docs/architecture/native-app-v0.md` — full host architecture spec
- `docs/architecture/native-app-latency-plan.md` — latency SLOs

## Decision

The Fae macOS native app embeds the Rust core as a linked static library (`libfae`).
The app IS the brain — not a thin shell talking to a separate backend.

Other frontends (CLI tools, companion apps, third-party UIs) connect to the running
Fae.app via a Unix domain socket. They use the same JSON command/event protocol but
pay the IPC cost. The primary native app has zero IPC overhead.

## Why Embedded (Not Subprocess)

| Concern | Subprocess (interim) | Embedded (target) |
|---------|---------------------|--------------------|
| Latency | JSON serialization + OS pipes per command | Direct function call (~0ms) |
| Reliability | Pipe breaks, process crashes orphan the UI | Single process, single fate |
| Bundling | Two binaries in .app bundle | One binary |
| State coherence | Two processes with separate memory spaces | Shared address space |
| Crash recovery | UI survives backend crash (but loses state) | Single crash domain (mitigated by zero-panic policy) |
| Sandbox | Backend inherits sandbox via process inheritance | Backend inherits sandbox by being in-process |
| Complexity | Process lifecycle management, pipe buffering | FFI boundary, but no IPC |

The zero-panic Rust policy (`#[deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)]`)
makes the single-crash-domain tradeoff acceptable.

## Topology

### Mode A: Embedded (Fae.app — primary)

```
┌──────────────────────────────────────────────┐
│  Fae.app (single macOS process)              │
│                                              │
│  Swift UI ─── C ABI ───▶ libfae             │
│  (AppKit/SwiftUI)        (Rust static lib)   │
│                                              │
│  libfae contains:                            │
│    - fae-core runtime                        │
│    - pipeline coordinator                    │
│    - memory system                           │
│    - scheduler                               │
│    - tool execution                          │
│    - optional socket listener for Mode B     │
│                                              │
└──────────────────────────────────────────────┘
```

### Mode B: IPC (external frontends)

```
┌──────────────┐        ┌──────────────────────┐
│ CLI tool     │──UDS──▶│                      │
└──────────────┘        │  Fae.app's embedded  │
┌──────────────┐        │  Rust core           │
│ Web UI       │──UDS──▶│  (~/.fae/fae.sock)   │
└──────────────┘        │                      │
┌──────────────┐        │                      │
│ Companion    │──UDS──▶│                      │
└──────────────┘        └──────────────────────┘
```

The socket listener is optional and disabled by default. It can be enabled via
`config.toml` or a host command.

## FFI Surface

The C ABI boundary is intentionally thin — control-plane operations only.

### Planned exports (`src/ffi.rs`)

```rust
/// Initialize the Fae runtime. Returns an opaque handle.
/// config_json: JSON string with runtime configuration.
#[no_mangle]
pub extern "C" fn fae_core_init(config_json: *const c_char) -> *mut FaeRuntime;

/// Start the runtime (spawns tokio runtime, scheduler, pipeline).
#[no_mangle]
pub extern "C" fn fae_core_start(rt: *mut FaeRuntime) -> i32;

/// Send a command envelope (JSON string). Returns response JSON string.
/// Caller must free the returned string with fae_string_free().
#[no_mangle]
pub extern "C" fn fae_core_send_command(
    rt: *mut FaeRuntime,
    command_json: *const c_char,
) -> *mut c_char;

/// Poll for the next pending event. Returns null if no event is available.
/// Caller must free the returned string with fae_string_free().
#[no_mangle]
pub extern "C" fn fae_core_poll_event(rt: *mut FaeRuntime) -> *mut c_char;

/// Register a callback for events (alternative to polling).
/// The callback receives a JSON string for each event.
#[no_mangle]
pub extern "C" fn fae_core_set_event_callback(
    rt: *mut FaeRuntime,
    callback: extern "C" fn(*const c_char, *mut c_void),
    context: *mut c_void,
);

/// Gracefully stop the runtime and release resources.
#[no_mangle]
pub extern "C" fn fae_core_stop(rt: *mut FaeRuntime);

/// Free a string returned by fae_core_send_command or fae_core_poll_event.
#[no_mangle]
pub extern "C" fn fae_string_free(s: *mut c_char);
```

### What crosses the FFI boundary

Control-plane only:

- Command envelopes (JSON strings)
- Response envelopes (JSON strings)
- Event envelopes (JSON strings)
- Runtime lifecycle (init/start/stop)

### What stays in-process (never crosses FFI)

- PCM audio buffers
- STT inference tensors
- LLM generation tokens
- TTS synthesis buffers
- Memory record internals
- Scheduler task execution

## Swift Integration

### Cargo build integration

```toml
# Cargo.toml additions
[lib]
crate-type = ["staticlib", "lib"]
```

The Swift Package Manager build script compiles the Rust static library and links it:

```swift
// Package.swift (conceptual)
.systemLibrary(name: "libfae", pkgConfig: nil, providers: []),
.executableTarget(
    name: "FaeNativeApp",
    dependencies: ["libfae"],
    linkerSettings: [
        .unsafeFlags(["-L", "../../../target/release"]),
        .linkedLibrary("fae"),
    ]
)
```

### Swift sender replacement

`ProcessCommandSender` (subprocess, interim) gets replaced by `EmbeddedCoreSender`:

```swift
/// Sends commands directly to the embedded Rust core via C ABI.
final class EmbeddedCoreSender: HostCommandSender {
    private var runtime: OpaquePointer?

    func start(configJSON: String) throws {
        runtime = configJSON.withCString { fae_core_init($0) }
        guard runtime != nil else { throw FaeError.coreInitFailed }
        let result = fae_core_start(runtime)
        guard result == 0 else { throw FaeError.coreStartFailed(code: result) }
    }

    func sendCommand(name: String, payload: [String: Any]) {
        guard let runtime else { return }
        // Build envelope JSON, call fae_core_send_command
        let envelope = buildEnvelope(name: name, payload: payload)
        envelope.withCString { json in
            let response = fae_core_send_command(runtime, json)
            if let response {
                // Process response
                fae_string_free(response)
            }
        }
    }

    func stop() {
        guard let runtime else { return }
        fae_core_stop(runtime)
        self.runtime = nil
    }
}
```

`HostCommandBridge` stays unchanged — it listens to NotificationCenter and forwards
to whatever `HostCommandSender` is wired up. The bridge doesn't know or care whether
it's talking to a subprocess or an embedded library.

## Migration Path

### Phase 0: Current (interim subprocess) ✅

- `fae-host` binary spawned as subprocess
- stdin/stdout JSON pipes via `ProcessCommandSender`
- Host command protocol fully defined and tested
- Native Swift shell operational with adaptive window system

### Phase 1: Build libfae static library

- Add `crate-type = ["staticlib", "lib"]` to Cargo.toml
- Create `src/ffi.rs` with `extern "C"` exports
- Wrap `HostCommandServer` + tokio runtime behind opaque handle
- Generate C header with `cbindgen`
- Verify static lib compiles for macOS arm64/x86_64

### Phase 2: Swift integration

- Add C header to Swift package
- Create `EmbeddedCoreSender` implementing `HostCommandSender`
- Wire into `FaeNativeApp.swift` (replace `ProcessCommandSender`)
- Verify all existing functionality works identically
- Remove `fae-host` binary from app bundle

### Phase 3: Optional socket listener

- Add tokio task in `libfae` that listens on `~/.fae/fae.sock`
- Reuse `HostCommandServer` with same routing logic
- External clients connect and use JSON protocol
- Gated behind config flag (disabled by default)

### Phase 4: Retire interim code

- Remove `ProcessCommandSender.swift`
- Remove `src/bin/host_bridge.rs` (or repurpose as standalone `faed` daemon)
- Remove subprocess-related logic from `FaeNativeApp.swift`
- `src/host/stdio.rs` becomes the IPC transport for Mode B only

## Threading Model

```
┌─────────────────────────────────────────────────────┐
│  macOS process                                       │
│                                                      │
│  Main thread (Swift/AppKit)                          │
│    └─ UI rendering, user events                      │
│    └─ FFI calls to libfae (non-blocking)             │
│                                                      │
│  Tokio runtime (owned by libfae, background threads) │
│    └─ Pipeline coordinator                           │
│    └─ Scheduler                                      │
│    └─ Memory operations                              │
│    └─ Socket listener (if enabled)                   │
│    └─ Event broadcast                                │
│                                                      │
│  Audio threads (CoreAudio/AVFoundation)              │
│    └─ Mic capture → STT                              │
│    └─ TTS → Playback                                 │
└─────────────────────────────────────────────────────┘
```

Rules:
- FFI calls from Swift MUST be non-blocking (submit command, return immediately)
- Events flow from tokio to Swift via callback or polling (never block tokio)
- Audio threads are managed by macOS, not tokio
- The tokio runtime is created once in `fae_core_init` and destroyed in `fae_core_stop`

## Testing Strategy

### Unit tests

- `src/ffi.rs` functions tested via Rust unit tests (call through C ABI locally)
- Command/response roundtrip through FFI boundary
- Event callback delivery

### Integration tests

- Swift test target that links libfae and exercises full lifecycle
- init → start → send commands → receive events → stop
- Verify no memory leaks (Instruments / LeakSanitizer)

### Latency validation

- Microbenchmarks comparing subprocess path vs FFI path
- Must meet SLOs in `docs/architecture/native-app-latency-plan.md`
- C ABI command dispatch p95 <= 0.25ms

## Open Questions

- Whether to use `cbindgen` (manual C header generation) or UniFFI (auto-generated Swift bindings).
  Current recommendation: `cbindgen` for the small surface area, to avoid the UniFFI dependency.
- Whether the tokio runtime should be single-threaded or multi-threaded inside the app.
  Current recommendation: multi-threaded (default tokio), as the app has CPU headroom.
- Whether to expose async Swift APIs via Swift concurrency bridging (Sendable callbacks)
  or keep the polling model. Current recommendation: callback-based for v1, consider
  Swift async bridging later.
