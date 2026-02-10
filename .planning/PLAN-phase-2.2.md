# Phase 2.2: Content Renderers

## Goal
Extend `to_html()` to render all ElementKind variants as rich HTML content in the canvas
pane. Add markdown parsing and syntax-highlighted code blocks for assistant responses.

## Current State
- `CanvasSession::to_html()` only renders `ElementKind::Text`, silently ignoring Chart,
  Image, Model3D, Video, OverlayLayer, Group
- canvas-renderer already has chart rendering (plotters → RGBA buffer) and image loading
- No markdown or syntax highlighting deps in fae

## Tasks

### Task 1: Add content rendering dependencies
**Files:** `Cargo.toml`
- Add `pulldown-cmark = "0.13"` (markdown → HTML)
- Add `syntect = { version = "5", default-features = false, features = ["default-fancy"] }`
  (syntax highlighting)
- Add `canvas-renderer = { path = "../saorsa-canvas/canvas-renderer", features = ["charts", "images"] }`
  (chart/image rendering to buffers)
- Add `base64 = "0.22"` (encoding rendered chart buffers as data URIs)
- Verify `just build` passes

### Task 2: Create content renderer module
**Files:** `src/canvas/render.rs`, `src/canvas/mod.rs`
- Create `src/canvas/render.rs` — content rendering functions
- `render_element_html(element: &Element, role_class: &str) -> String`
  — dispatches to variant-specific renderers
- `render_text_html(content: &str, color: &str, role_class: &str) -> String`
  — current text rendering (extracted from to_html)
- Register module in `src/canvas/mod.rs`
- Tests: render_text produces expected HTML

### Task 3: Chart rendering to HTML
**Files:** `src/canvas/render.rs`
- `render_chart_html(chart_type: &str, data: &serde_json::Value, transform: &Transform) -> String`
- Use `canvas_renderer::chart::render_chart_to_buffer()` to get RGBA pixels
- Encode as PNG via `image` crate, then base64 encode → data URI `<img>`
- Fallback: if rendering fails, show `<div class="chart-error">` with chart_type + error
- Tests: render bar chart produces `<img src="data:image/png;base64,...">`, error fallback

### Task 4: Image rendering to HTML
**Files:** `src/canvas/render.rs`
- `render_image_html(src: &str, format: &ImageFormat, transform: &Transform) -> String`
- If `src` starts with `data:` — use as-is in `<img>` tag
- If `src` starts with `http` — use as `<img src="...">` with loading="lazy"
- If `src` is a file path — read and base64 encode
- Add width/height from transform
- Fallback: `<div class="image-error">` if source cannot be resolved
- Tests: data URI passthrough, URL handling, fallback on invalid

### Task 5: Markdown rendering for text content
**Files:** `src/canvas/render.rs`
- `render_markdown_html(content: &str) -> String`
- Use `pulldown_cmark::Parser` → `pulldown_cmark::html::push_html()`
- Detect if text looks like markdown (contains `#`, `**`, `` ` ``, `- `, `> `, etc.)
  or is plain text — `is_markdown(content: &str) -> bool` heuristic
- If markdown: parse and render; if plain text: escape and wrap in `<p>`
- Tests: plain text passes through, markdown headers/bold/lists render as HTML

### Task 6: Syntax-highlighted code blocks
**Files:** `src/canvas/render.rs`
- `highlight_code_block(code: &str, lang: &str) -> String`
- Use `syntect::parsing::SyntaxSet::load_defaults_newlines()`
- Use `syntect::highlighting::ThemeSet::load_defaults()` with "base16-ocean.dark"
- `syntect::html::highlighted_html_for_string()` to produce colored `<pre><code>` blocks
- Integrate with markdown renderer: override code block rendering in pulldown-cmark pipeline
- Fallback: plain `<pre><code>` if lang not found or syntect fails
- Tests: highlight rust code, unknown lang fallback, empty code block

### Task 7: Extend to_html() with all renderers
**Files:** `src/canvas/session.rs`, `src/canvas/render.rs`
- Refactor `CanvasSession::to_html()` to use `render::render_element_html()` for each element
- Handle all ElementKind variants:
  - Text → markdown-aware render (task 5 + 6)
  - Chart → chart render (task 3)
  - Image → image render (task 4)
  - Model3D → placeholder `<div class="model3d-placeholder">` with src/rotation info
  - Video → placeholder `<div class="video-placeholder">` with stream_id
  - OverlayLayer / Group → render children recursively
- Also render elements added via MCP tools (not just messages) — iterate scene.elements()
- Add CSS styles for new content types in gui.rs
- Tests: to_html with mixed element types, chart+text session

### Task 8: Content caching and resize
**Files:** `src/canvas/render.rs`, `src/canvas/session.rs`
- Add `RenderCache` — HashMap<ElementId, String> caching rendered HTML per element
- Invalidate on element modification (track a generation counter)
- `CanvasSession::to_html_cached(&mut self) -> String` — uses cache, re-renders only dirty
- Handle viewport resize: update transforms, invalidate affected cache entries
- Tests: cache hit avoids re-render, cache invalidated on change, resize clears cache
