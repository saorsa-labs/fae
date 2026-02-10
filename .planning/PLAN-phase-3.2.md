# Phase 3.2: Protocol Alignment & Persistence

## Overview

This phase fixes protocol mismatches between fae's remote.rs (client) and saorsa-canvas server's sync.rs, then adds filesystem persistence to canvas-server so sessions survive restarts. Both projects are modified. The goal is reliable client-server communication with durable session storage.

**Projects involved:**
- **fae** (`/Users/davidirvine/Desktop/Devel/projects/fae`)
- **saorsa-canvas** (`/Users/davidirvine/Desktop/Devel/projects/saorsa-canvas`)

---

## Task 1: Fix fae SceneSnapshot → SceneDocument

**Files:**
- `fae/src/canvas/remote.rs` (lines 75-83)

**Description:**

Currently fae's `SceneSnapshot` struct at line 78 only has `session_id` and `elements` fields. It's missing viewport metadata and timestamp that canvas-server's `SceneDocument` includes.

Update `SceneSnapshot` to match canvas-server's `SceneDocument` structure:
1. Add `viewport: ViewportDocument` field (import from canvas_core)
2. Add `timestamp: u64` field
3. Update `#[serde(default)]` annotations to match canvas_core schema.rs
4. Rename struct to `SceneDocument` (matching server exactly)
5. Update all references to `SceneSnapshot` → `SceneDocument` in remote.rs
6. Update `handle_server_message` at line 641 to use viewport data when rebuilding scene
7. Import `ViewportDocument` from canvas_core at top of file

**Tests:**

Add test `test_scene_document_deserialization_with_viewport()`:
- Deserialize JSON with viewport fields (width, height, zoom, pan_x, pan_y)
- Assert viewport fields are populated correctly
- Verify backward compat (defaults for missing fields)

**Acceptance:**

- `SceneSnapshot` renamed to `SceneDocument`
- Struct matches canvas-server's `SceneDocument` exactly
- Tests pass for viewport deserialization
- `cargo check` passes in fae

---

## Task 2: Add missing ServerMessage variants to fae

**Files:**
- `fae/src/canvas/remote.rs` (lines 44-73)

**Description:**

Fae's `ServerMessage` enum is missing variants that canvas-server sends:
- `ElementUpdated` (line 312-317 in canvas-server sync.rs)
- `SyncResult` (line 351-361 in canvas-server sync.rs)

Add these variants to fae's `ServerMessage` enum:

```rust
ElementUpdated {
    element: ElementDocument,
    #[serde(default)]
    timestamp: u64,
},
SyncResult {
    synced_count: usize,
    conflict_count: usize,
    timestamp: u64,
    #[serde(default)]
    failed_operations: Vec<serde_json::Value>, // Simplified for client
},
```

Update `handle_server_message` function at line 628 to handle new variants:
- `ElementUpdated`: Update element in local shadow scene (similar to ElementAdded)
- `SyncResult`: Log at trace level for now

**Tests:**

Add tests:
- `test_server_message_deserialize_element_updated()`
- `test_server_message_deserialize_sync_result()`
- `test_handle_element_updated_message()` — verify element is updated in shadow scene

**Acceptance:**

- New variants added to enum
- Deserialization tests pass
- Handler logic updates shadow scene correctly
- `cargo test --lib canvas::remote` passes

---

## Task 3: Add missing ClientMessage variants to fae

**Files:**
- `fae/src/canvas/remote.rs` (lines 22-42)

**Description:**

Fae's `ClientMessage` enum is missing `UpdateElement` variant that canvas-server expects (line 173-182 in canvas-server sync.rs).

Add to fae's `ClientMessage` enum:

```rust
UpdateElement {
    id: String,
    changes: serde_json::Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    message_id: Option<String>,
},
```

This variant is NOT yet used by fae but must exist for protocol completeness. It will be wired in future phases when implementing element updates.

**Tests:**

Add test `test_client_message_serialize_update_element()`:
- Serialize UpdateElement message
- Assert JSON contains correct "type":"update_element"
- Assert id and changes fields present

**Acceptance:**

- `UpdateElement` variant added to enum
- Serialization test passes
- No compilation warnings
- `cargo test --lib canvas::remote` passes

---

## Task 4: Implement filesystem persistence in canvas-core SceneStore

**Files:**
- `saorsa-canvas/canvas-core/src/store.rs` (entire file)
- `saorsa-canvas/canvas-core/Cargo.toml` (dependencies)

**Description:**

Add `serde_json` filesystem persistence to `SceneStore`. Sessions are saved as JSON files in a configurable directory.

1. Add optional data directory field to `SceneStore`:
   ```rust
   pub struct SceneStore {
       scenes: Arc<RwLock<HashMap<String, Scene>>>,
       data_dir: Option<PathBuf>, // New field
   }
   ```

2. Add constructor with persistence:
   ```rust
   pub fn with_data_dir(data_dir: impl Into<PathBuf>) -> Result<Self, StoreError>
   ```

3. Add persistence methods:
   ```rust
   fn save_scene(&self, session_id: &str) -> Result<(), StoreError>
   fn load_scene(&self, session_id: &str) -> Result<Scene, StoreError>
   pub fn load_all_sessions(&self) -> Result<Vec<String>, StoreError>
   ```

4. Update mutation methods (`add_element`, `remove_element`, `update_element`, `replace`, `clear`) to auto-save when `data_dir` is Some.

5. File format: `{data_dir}/{session_id}.json` containing `SceneDocument`

6. Add new `StoreError` variants: `IoError(io::Error)`, `SerializationError(String)`

7. Add `std::fs` and `std::path::PathBuf` imports

**Tests:**

Add to existing `#[cfg(test)]` module:
- `test_persistence_save_and_load()` — round-trip scene to disk
- `test_persistence_load_nonexistent_session()` — returns error
- `test_persistence_auto_save_on_mutation()` — add element triggers save
- `test_load_all_sessions()` — finds all .json files

Use `tempfile::tempdir()` for test isolation.

**Acceptance:**

- `SceneStore::with_data_dir()` constructor works
- Scenes save as JSON on mutation
- Scenes load from disk on startup
- All existing tests still pass
- New tests pass

---

## Task 5: Add auto-save on scene mutations in canvas-server

**Files:**
- `saorsa-canvas/canvas-server/src/main.rs` (lines 129-144)
- `saorsa-canvas/canvas-server/src/sync.rs` (scene mutation handlers)

**Description:**

Wire canvas-server to use `SceneStore::with_data_dir()` with a configured data directory.

1. In `main.rs` at line 129, determine data directory from env var:
   ```rust
   let data_dir = std::env::var("CANVAS_DATA_DIR")
       .unwrap_or_else(|_| {
           let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
           format!("{}/.saorsa-canvas/sessions", home)
       });
   std::fs::create_dir_all(&data_dir)?;
   let sync_state = SyncState::with_data_dir(&data_dir)?;
   ```

2. Update `SyncState::new()` in sync.rs to accept optional data_dir and pass to SceneStore.

3. Verify auto-save triggers on:
   - AddElement (sync.rs handler)
   - UpdateElement (sync.rs handler)
   - RemoveElement (sync.rs handler)
   - SyncQueue (batch operations)

Auto-save is already implemented in Task 4 — just ensure handlers call the store methods.

**Tests:**

Integration test in `canvas-server/tests/persistence.rs`:
- Start server with temp data dir
- Add element via WebSocket
- Kill server
- Restart server with same data dir
- Verify element is present in session

**Acceptance:**

- Server creates data directory on startup
- Sessions save to `~/.saorsa-canvas/sessions/{session_id}.json` by default
- `CANVAS_DATA_DIR` env var overrides default
- Integration test passes

---

## Task 6: Add session loading on canvas-server startup

**Files:**
- `saorsa-canvas/canvas-server/src/main.rs` (around line 129)

**Description:**

Load all persisted sessions from disk when canvas-server starts, before accepting connections.

1. After creating `SceneStore::with_data_dir()`, call:
   ```rust
   match sync_state.store().load_all_sessions() {
       Ok(session_ids) => {
           for session_id in session_ids {
               if let Err(e) = sync_state.store().load_scene(&session_id) {
                   tracing::warn!("Failed to load session {}: {}", session_id, e);
               } else {
                   tracing::info!("Loaded session: {}", session_id);
               }
           }
       }
       Err(e) => tracing::warn!("Failed to enumerate sessions: {}", e),
   }
   ```

2. Sessions are lazy-loaded into memory from JSON files.

**Tests:**

Add to integration test from Task 5:
- Create multiple sessions before shutdown
- Restart server
- Verify all sessions are loaded
- GET /api/scene/{session_id} returns correct data for each

**Acceptance:**

- Server logs "Loaded session: {id}" for each session on startup
- All sessions available immediately after startup
- No data loss across restarts

---

## Task 7: Add session expiry background task

**Files:**
- `saorsa-canvas/canvas-server/src/sync.rs` (new background task)
- `saorsa-canvas/canvas-server/src/main.rs` (spawn task)

**Description:**

Add configurable TTL for sessions. Delete stale sessions (not accessed within TTL) on a periodic timer.

1. Add to `SyncState`:
   ```rust
   pub struct SyncState {
       store: SceneStore,
       // ... existing fields
       last_access: Arc<RwLock<HashMap<String, Instant>>>, // New
   }
   ```

2. Update session access tracking:
   - Record access time on every WebSocket Subscribe
   - Record access time on every HTTP GET /api/scene/{session_id}

3. Add expiry task spawned in main.rs:
   ```rust
   let session_ttl = std::env::var("CANVAS_SESSION_TTL_HOURS")
       .ok()
       .and_then(|v| v.parse().ok())
       .unwrap_or(24); // Default 24 hours
   let cleanup_interval = Duration::from_secs(3600); // Check hourly
   
   tokio::spawn(async move {
       let mut interval = tokio::time::interval(cleanup_interval);
       loop {
           interval.tick().await;
           sync_state.cleanup_expired_sessions(Duration::from_secs(session_ttl * 3600));
       }
   });
   ```

4. Implement `cleanup_expired_sessions()` in sync.rs:
   - Iterate sessions
   - Check last_access time
   - Delete JSON file and remove from memory if expired
   - Log deletion

**Tests:**

Unit test in sync.rs:
- `test_session_expiry()` — mock time, verify expired session removed
- `test_session_expiry_preserves_active()` — active sessions not deleted

**Acceptance:**

- Sessions expire after TTL (default 24h)
- `CANVAS_SESSION_TTL_HOURS` env var configures TTL
- Background task runs every hour
- Expired sessions deleted from disk and memory
- Tests pass

---

## Task 8: Integration tests for protocol and persistence

**Files:**
- `fae/src/canvas/remote.rs` (add tests module)
- `saorsa-canvas/canvas-server/tests/protocol_roundtrip.rs` (new file)
- `saorsa-canvas/canvas-server/tests/persistence_restart.rs` (new file)

**Description:**

Comprehensive integration tests across the entire stack.

**fae tests (remote.rs):**

Add `#[cfg(test)]` module tests:
1. `test_protocol_roundtrip_scene_update()` — mock server sends SceneUpdate with viewport
2. `test_protocol_roundtrip_element_updated()` — mock server sends ElementUpdated
3. `test_protocol_roundtrip_sync_result()` — mock server sends SyncResult

Use test helpers to create mock ServerMessage JSON and deserialize.

**canvas-server integration tests:**

New file `tests/protocol_roundtrip.rs`:
- Start test server
- Connect fae-like WebSocket client
- Subscribe to session
- Add element from client
- Verify server broadcasts ElementAdded
- Update element from client
- Verify server broadcasts ElementUpdated
- Verify SceneUpdate includes viewport

New file `tests/persistence_restart.rs`:
- Start server with temp data dir
- Create session, add elements via WebSocket
- Shutdown server
- Restart server with same data dir
- Verify session persists
- Verify elements intact

New file `tests/session_expiry.rs`:
- Start server with TTL=1 second
- Create session, access it
- Wait 2 seconds
- Trigger cleanup task
- Verify session deleted

**Acceptance:**

- All fae protocol tests pass
- All canvas-server integration tests pass
- `cargo test` passes in both projects
- No warnings or test failures

---

## Summary

**Task dependency order:**
1. Task 1 (SceneDocument in fae) — standalone
2. Task 2 (ServerMessage variants) — depends on Task 1
3. Task 3 (ClientMessage variants) — standalone
4. Task 4 (SceneStore persistence) — standalone
5. Task 5 (canvas-server auto-save) — depends on Task 4
6. Task 6 (session loading) — depends on Task 4, 5
7. Task 7 (session expiry) — depends on Task 4, 5, 6
8. Task 8 (integration tests) — depends on all previous tasks

**Total changes:**
- fae: ~150 lines (protocol alignment)
- canvas-core: ~200 lines (persistence)
- canvas-server: ~150 lines (startup loading, expiry task)
- Tests: ~300 lines across both projects

**Verification:**
- Protocol alignment: fae and canvas-server have matching message types
- Persistence: sessions survive server restarts
- Expiry: stale sessions cleaned up automatically
- Zero warnings, zero test failures in both projects
