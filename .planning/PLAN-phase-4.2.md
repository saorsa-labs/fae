# Phase 4.2: Documentation & Polish

## Overview
Final phase of the canvas integration project. Update documentation, add canvas
settings to the GUI, write API docs, create integration tests, and polish.

## Tasks

### Task 1: Update fae README.md with canvas integration docs
**Files:** `README.md`

Add a "Canvas Integration" section to fae's README covering:
- What the canvas pane does (visual output for charts, images, rich content)
- How the MCP tools work (canvas_render, canvas_interact, canvas_export)
- Remote canvas-server connectivity (WebSocket URL setting)
- Screenshot or architecture diagram reference

**Acceptance:**
- README mentions canvas features
- Installation section notes canvas dependencies

### Task 2: Update saorsa-canvas README.md with fae integration examples
**Files:** `../saorsa-canvas/README.md`

Add a "Usage with Fae" section to saorsa-canvas's root README showing:
- How fae embeds canvas-core as a dependency
- The MCP tool flow (agent → tool → scene → render)
- Link to fae's repo for the full integration example

**Acceptance:**
- saorsa-canvas README mentions fae as a consumer
- Integration example is accurate

### Task 3: Add canvas configuration section to fae GUI settings
**Files:** `src/bin/gui.rs`, `src/config.rs`

Add a "Canvas" section to the Settings view showing:
- Canvas server URL (text input, currently in FaeConfig)
- Connection status indicator
- Canvas session info (element count, session ID)

**Acceptance:**
- Settings view shows canvas configuration
- URL is editable and saved to config
- Connection status is visible

### Task 4: Add canvas server URL setting to config
**Files:** `src/config.rs`, `src/canvas/remote.rs`

Ensure `FaeConfig` has `canvas_server_url: Option<String>` and it's:
- Loaded from `~/.fae/config.toml`
- Passed to `RemoteCanvasSession` at startup
- Persisted when changed in settings

**Acceptance:**
- Config field exists and is serializable
- Setting is loaded and applied at startup

### Task 5: Write API documentation for canvas public types
**Files:** `src/canvas/*.rs`

Add doc comments to all public types, methods, and modules in src/canvas/:
- `mod.rs` — module-level docs
- `session.rs` — CanvasSession, CanvasBackend trait
- `bridge.rs` — CanvasBridge, event mapping
- `types.rs` — CanvasMessage enum
- `remote.rs` — RemoteCanvasSession, ConnectionStatus
- `registry.rs` — CanvasSessionRegistry
- `tools/*.rs` — MCP tool structs

**Acceptance:**
- `cargo doc --no-deps` produces clean docs with zero warnings
- All public items have doc comments

### Task 6: Create integration test suite
**Files:** `tests/canvas_integration.rs` (new)

End-to-end tests covering:
- Create session → push message → verify scene elements
- Bridge event routing (RuntimeEvent → CanvasMessage → Element)
- Tool execution (canvas_render with chart data)
- Session registry management
- Export tool (local mode returns metadata)

**Acceptance:**
- Integration tests pass
- Cover the main user-facing workflows

### Task 7: Performance profiling notes
**Files:** `src/canvas/mod.rs` (add perf notes in doc comments)

Document performance characteristics:
- Scene serialization overhead (measure with 100+ elements)
- HTML rendering cost per update
- WebSocket sync bandwidth estimate
- Add `#[cfg(test)]` benchmark-style tests for hot paths

**Acceptance:**
- Performance notes documented
- No regressions detected (tests pass under ~100ms)

### Task 8: Final review and cleanup
**Files:** All canvas-related files

- Remove any TODO/FIXME comments
- Ensure consistent error handling patterns
- Verify all imports are used
- Run full `just check` equivalent (fmt, clippy, test, doc)
- Commit and update STATE.json to milestone_complete

**Acceptance:**
- Zero warnings across both projects
- All tests pass
- Clean git status
