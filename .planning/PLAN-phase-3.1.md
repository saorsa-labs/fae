# Phase 3.1: WebSocket Client

## Goal
Connect fae to remote canvas-server instances via WebSocket. Same tool protocol
works locally and remotely. Enable future multi-device scenarios.

## Architecture

```
                    CanvasBackend trait
                   /                   \
         CanvasSession             RemoteCanvasSession
         (local scene)              (WebSocket proxy)
              |                          |
         Arc<Mutex<..>>           Arc<Mutex<..>>
              |                          |
     CanvasSessionRegistry        background task
         (tools access)            ↕ WebSocket ↕
              |                   canvas-server:9473
         CanvasBridge
       (pipeline events)
```

## Tasks

### Task 1: Add dependencies + CanvasBackend trait

**Files:** `Cargo.toml`, `src/canvas/backend.rs`, `src/canvas/mod.rs`

Add `tokio-tungstenite = "0.24"` and `futures-util = "0.3"` dependencies.

Create `CanvasBackend` trait with methods both local and remote backends need:
- `session_id()`, `push_message()`, `add_element()`, `remove_element()`
- `clear()`, `message_count()`, `element_count()`
- `message_views()`, `tool_elements_html()`, `to_html()`, `to_html_cached()`
- `resize_viewport()`, `connection_status()`

Create `ConnectionStatus` enum: Local, Disconnected, Connecting, Connected,
Reconnecting, Failed.

### Task 2: Implement CanvasBackend for CanvasSession

**Files:** `src/canvas/session.rs`

Add `impl CanvasBackend for CanvasSession` that delegates to existing methods.
`connection_status()` always returns `ConnectionStatus::Local`.

### Task 3: Update registry to use dyn CanvasBackend

**Files:** `src/canvas/registry.rs`

Change `HashMap<String, Arc<Mutex<CanvasSession>>>` to
`HashMap<String, Arc<Mutex<dyn CanvasBackend>>>`. Update all method signatures.

### Task 4: Update tools to use CanvasBackend trait

**Files:** `src/canvas/tools/render.rs`, `tools/interact.rs`, `tools/export.rs`

Change `session.scene_mut().add_element(element)` to
`session.add_element(element)` using the trait method.

### Task 5: Update bridge to use CanvasBackend trait

**Files:** `src/canvas/bridge.rs`

Change `session: CanvasSession` to `session: Box<dyn CanvasBackend>`.
Update `session()` and `session_mut()` to return trait references.
Add factory constructor for remote sessions.

### Task 6: Create RemoteCanvasSession (WebSocket client)

**Files:** `src/canvas/remote.rs`

WebSocket client connecting to canvas-server at `/ws/sync`:
- Protocol message types (wire-compatible with canvas-server)
- Background tokio task for WebSocket I/O
- Command channel (sync → async) for operations
- Local scene mirror updated by server broadcasts
- Session negotiation (Subscribe on connect)
- Reconnection with exponential backoff (1s→2s→4s→...→30s cap)

### Task 7: Connection status indicator in GUI

**Files:** `src/bin/gui.rs`, `src/config.rs`

- Add `canvas_server_url: Option<String>` to config
- Show connection status badge next to canvas pane header
- Color-coded: green=connected, yellow=reconnecting, red=disconnected

### Task 8: Tests

- CanvasBackend trait dispatch (local vs mock remote)
- Registry with dyn CanvasBackend
- Updated tool tests with trait
- Updated bridge tests with trait
- Remote protocol message serialization round-trip
- Connection status display logic
