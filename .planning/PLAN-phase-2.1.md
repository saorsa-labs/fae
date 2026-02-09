# Phase 2.1: MCP Tool Integration

## Overview
Wire canvas-mcp's MCP tool definitions into fae's agent backend so the LLM can
push rich content (charts, images, text) to the canvas via `canvas_render`,
report interactions via `canvas_interact`, and export the canvas via
`canvas_export`. Tools operate on a shared `CanvasSession` via a thread-safe
registry.

---

## Task 1: Add canvas-mcp dependency

Add `canvas-mcp = { path = "../saorsa-canvas/canvas-mcp" }` to fae's Cargo.toml
and ensure it compiles.

**Files**: `Cargo.toml`

---

## Task 2: Create CanvasSessionRegistry

Create `src/canvas/registry.rs` — a thread-safe session store so tools can look
up the active session by ID. The GUI creates a session; tools reference it.

**API**:
- `CanvasSessionRegistry::new() -> Self`
- `register(id, session: Arc<Mutex<CanvasSession>>) -> Option<...>`
- `get(id) -> Option<Arc<Mutex<CanvasSession>>>`
- `remove(id) -> Option<Arc<Mutex<CanvasSession>>>`
- `sessions() -> Vec<String>` (list session IDs)

**Files**: `src/canvas/registry.rs`, `src/canvas/mod.rs` (add `pub mod registry`)

---

## Task 3: Implement CanvasRenderTool

Create `src/canvas/tools/render.rs` implementing `saorsa_agent::Tool` for
`canvas_render`. Deserializes `canvas_mcp::tools::RenderParams`, converts
`RenderContent` to `canvas_core::Element`, pushes to session via registry.

**Input JSON schema** matches `RenderParams` (session_id, content, position).
**Returns** JSON string with element_id and success status.

**Files**: `src/canvas/tools/mod.rs`, `src/canvas/tools/render.rs`

---

## Task 4: Implement CanvasInteractTool

Create `src/canvas/tools/interact.rs` implementing `saorsa_agent::Tool` for
`canvas_interact`. Deserializes `canvas_mcp::tools::InteractParams`, processes
interaction (hit-test, selection), returns AI-friendly JSON description.

**Files**: `src/canvas/tools/interact.rs`

---

## Task 5: Implement CanvasExportTool

Create `src/canvas/tools/export.rs` implementing `saorsa_agent::Tool` for
`canvas_export`. Deserializes `canvas_mcp::tools::ExportParams`. For now returns
a placeholder indicating the format requested (actual rendering deferred to
Phase 2.2 content renderers).

**Files**: `src/canvas/tools/export.rs`

---

## Task 6: Register canvas tools in agent

In `src/agent/mod.rs`, when tool_mode is ReadOnly or higher, register the three
canvas tools. They are non-destructive so no approval wrapper needed. Pass the
session registry (Arc) so tools can access canvas sessions.

- Add `canvas_registry: Option<Arc<Mutex<CanvasSessionRegistry>>>` parameter to
  `SaorsaAgentLlm::new()`
- Register tools when registry is Some and tool_mode != Off

**Files**: `src/agent/mod.rs`

---

## Task 7: Wire registry through pipeline to GUI

- In `src/bin/gui.rs`: create `Arc<Mutex<CanvasSessionRegistry>>`, register the
  bridge's session in it, pass to pipeline/agent
- In `src/pipeline/coordinator.rs`: accept and forward registry to agent
- In `src/startup.rs`: accept and forward registry to agent if present

**Files**: `src/bin/gui.rs`, `src/pipeline/coordinator.rs`, `src/startup.rs`

---

## Task 8: Tests

- Registry: create/get/remove sessions, concurrent access
- CanvasRenderTool: execute with valid/invalid JSON, render text/chart/image
- CanvasInteractTool: execute touch/voice/select interactions
- CanvasExportTool: execute with valid params, format serialization
- Integration: tool execution updates session, session HTML reflects change

**Files**: All `src/canvas/tools/*.rs`, `src/canvas/registry.rs`

---

## Dependencies
- `canvas-mcp` path dep (adds serde types and tool signatures)
- `saorsa-agent` (already present — Tool trait, ToolRegistry)
- `canvas-core` (already present — Scene, Element, ElementKind, Transform)
