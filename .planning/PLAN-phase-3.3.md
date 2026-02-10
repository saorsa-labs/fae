# Phase 3.3: Server-Side Export

## Overview
Implement scene-to-image export in canvas-renderer and expose via canvas-server REST endpoint.
Wire fae's canvas_export tool to call the server export API.

**Cross-project: modifies both saorsa-canvas and fae**

## Tasks

### Task 1: Add export dependencies to canvas-renderer
**Files:** `saorsa-canvas/canvas-renderer/Cargo.toml`

Add behind a new `export` feature flag:
- `resvg` — SVG to raster rendering
- `usvg` — SVG tree construction
- `tiny-skia` — CPU raster backend (required by resvg)
- `printpdf` — PDF generation

Also need `image` crate (already present behind `images` feature) for PNG/JPEG encoding.
The `export` feature should pull in `images` automatically.

**Acceptance:**
- `cargo check -p canvas-renderer --features export` passes
- No new warnings

### Task 2: Implement SceneExporter — Scene → PNG via SVG intermediate
**Files:** `saorsa-canvas/canvas-renderer/src/export.rs`, `saorsa-canvas/canvas-renderer/src/lib.rs`

Create `export` module (feature-gated behind `export`):
- `ExportConfig { width: u32, height: u32, dpi: f32, background: [u8; 4] }`
- `SceneExporter::new(config: ExportConfig) -> Self`
- `SceneExporter::render_to_png(scene: &Scene) -> RenderResult<Vec<u8>>`

Implementation approach:
1. Build SVG string from Scene elements (text → `<text>`, chart → render plotters to embedded PNG `<image>`, image → `<image>` with base64, shapes → SVG primitives)
2. Parse SVG with `usvg::Tree::from_str()`
3. Render to `tiny_skia::Pixmap`
4. Encode pixmap to PNG bytes via `image` crate

**Acceptance:**
- Can export a scene with Text elements to PNG bytes
- PNG bytes are valid (start with PNG magic bytes)
- Tests pass

### Task 3: Add JPEG, SVG, and WebP output format support
**Files:** `saorsa-canvas/canvas-renderer/src/export.rs`

Extend SceneExporter:
- `render_to_jpeg(scene: &Scene, quality: u8) -> RenderResult<Vec<u8>>`
- `render_to_svg(scene: &Scene) -> RenderResult<String>` (returns raw SVG string, no raster step)
- `render_to_webp(scene: &Scene) -> RenderResult<Vec<u8>>` (if image crate supports, else skip)
- `export(scene: &Scene, format: ExportFormat) -> RenderResult<Vec<u8>>` (dispatcher)

Use `ExportFormat` from canvas-mcp (or define locally and map).

**Acceptance:**
- PNG, JPEG, SVG each produce valid output
- SVG output is valid XML
- JPEG output starts with FFD8 magic bytes

### Task 4: Add PDF export via printpdf
**Files:** `saorsa-canvas/canvas-renderer/src/export.rs`

Add PDF output path:
- `render_to_pdf(scene: &Scene) -> RenderResult<Vec<u8>>`
- Approach: render scene to PNG first, then embed as image in PDF page via printpdf
- Page size matches scene viewport (viewport_width × viewport_height in points)

**Acceptance:**
- PDF bytes start with `%PDF`
- PDF contains embedded image of scene
- Tests pass

### Task 5: Add POST /api/export endpoint to canvas-server
**Files:** `saorsa-canvas/canvas-server/src/routes.rs`, `saorsa-canvas/canvas-server/Cargo.toml`

Add REST endpoint:
- `POST /api/export` with JSON body: `{ session_id, format, width?, height?, dpi?, quality? }`
- Returns binary response with appropriate Content-Type header
- Content-Type: `image/png`, `image/jpeg`, `image/svg+xml`, `application/pdf`
- Error responses as JSON: `{ success: false, error: "..." }`

Add `canvas-renderer` dependency with `export` feature to canvas-server.

Wire into axum router in main.rs.

**Acceptance:**
- Endpoint responds to POST requests
- Returns correct Content-Type for each format
- Returns 404 for non-existent sessions
- Returns 400 for invalid format

### Task 6: Wire fae's canvas_export tool to call server export API
**Files:** `fae/src/canvas/tools/export.rs` (or equivalent)

Update fae's `canvas_export` tool implementation:
- For local sessions: call SceneExporter directly
- For remote sessions: POST to `/api/export` endpoint
- Return base64-encoded data in MCP response
- Handle errors gracefully

**Acceptance:**
- Local export works for PNG/JPEG/SVG
- Remote export makes HTTP POST
- Errors reported via MCP error response

### Task 7: Add export configuration options (size/DPI)
**Files:** `saorsa-canvas/canvas-renderer/src/export.rs`, `saorsa-canvas/canvas-server/src/routes.rs`

Add configurable export parameters:
- Width/height override (default: scene viewport size)
- DPI setting (default: 96.0 for screen, 300.0 for print)
- JPEG quality (default: 85)
- Background color (default: white)
- Scale factor (1x, 2x for retina)

Update ExportConfig to include all parameters.
Update POST /api/export to accept these in request body.

**Acceptance:**
- Export with custom dimensions produces correct size
- DPI affects output resolution
- JPEG quality parameter is respected

### Task 8: Tests — each format, large scenes, error handling
**Files:** `saorsa-canvas/canvas-renderer/tests/export_integration.rs`, `saorsa-canvas/canvas-server/tests/export_integration.rs`

Canvas-renderer tests:
- PNG export of text-only scene
- PNG export of scene with chart + text
- JPEG export with quality settings
- SVG export produces valid XML
- PDF export produces valid header
- Empty scene export
- Large scene (100+ elements) export
- Custom dimensions/DPI

Canvas-server tests:
- POST /api/export returns PNG
- POST /api/export returns JPEG
- POST /api/export with invalid session → 404
- POST /api/export with invalid format → 400

**Acceptance:**
- All tests pass
- Zero clippy warnings across workspace
- `just check` passes (or `cargo` equivalent)
