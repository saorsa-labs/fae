# Phase 1.1: Dependency & Shared Types

## Overview
Add canvas-core as a path dependency, create fae's canvas abstraction module with
CanvasMessage enum (mapping RuntimeEvent/LogEntry to ElementKind), CanvasSession
wrapping canvas-core Scene, message-to-element conversion, auto-layout positioning,
HTML serialization, and integration tests.

---

## Task 1: Add canvas-core path dependency to Cargo.toml

**Description**: Add `canvas-core` as a path dependency pointing to the sibling
saorsa-canvas workspace. This gives fae access to Scene, Element, ElementKind,
Transform, and all canvas-core types.

**Files to modify**: `Cargo.toml`

**Changes**:
- Add `canvas-core = { path = "../saorsa-canvas/canvas-core" }` under `[dependencies]`
- Run `cargo check` to verify it resolves and compiles

**Acceptance**:
- `cargo check` succeeds with canvas-core accessible
- No new warnings

**Dependencies**: None

---

## Task 2: Create `src/canvas/mod.rs` — canvas abstraction module

**Description**: Create the `src/canvas/` directory and `mod.rs` that declares
submodules. Register `pub mod canvas;` in `src/lib.rs`.

**Files to create**: `src/canvas/mod.rs`
**Files to modify**: `src/lib.rs`

**Changes**:
- Create `src/canvas/mod.rs` with:
  ```rust
  pub mod types;
  pub mod session;
  ```
- Add `pub mod canvas;` to `src/lib.rs` (alphabetical order, after `audio`)

**Acceptance**:
- `cargo check` succeeds
- Module tree accessible as `fae::canvas::{types, session}`

**Dependencies**: Task 1

---

## Task 3: Create `src/canvas/types.rs` — CanvasMessage enum

**Description**: Define `CanvasMessage` enum that maps fae's domain concepts
(user speech, assistant replies, tool calls, system messages) to canvas-core's
`ElementKind` variants. This is the bridge type between fae's pipeline and the
canvas scene graph.

**Files to create**: `src/canvas/types.rs`

**Types to define**:
```rust
/// Roles for message attribution and styling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageRole {
    User,
    Assistant,
    System,
    Tool,
}

/// A pipeline event translated into a canvas-renderable message.
#[derive(Debug, Clone)]
pub struct CanvasMessage {
    pub role: MessageRole,
    pub text: String,
    pub timestamp_ms: u64,
    /// For tool messages: the tool name.
    pub tool_name: Option<String>,
}
```

**Implementation**:
- `CanvasMessage::new(role, text, timestamp_ms)` constructor
- `CanvasMessage::tool(name, text, timestamp_ms)` convenience constructor
- `MessageRole::css_class(&self) -> &'static str` returning "user"/"assistant"/"system"/"tool"

**Tests**: Construction, field access, css_class mapping.

**Dependencies**: Task 2

---

## Task 4: Create `src/canvas/session.rs` — CanvasSession wrapping Scene

**Description**: `CanvasSession` wraps a `canvas_core::Scene` and manages the
message list, auto-layout Y positioning, and viewport tracking.

**Files to create**: `src/canvas/session.rs`

**Types to define**:
```rust
pub struct CanvasSession {
    scene: canvas_core::Scene,
    /// Messages in order (element ID + metadata for later lookup).
    messages: Vec<MessageEntry>,
    /// Next Y position for auto-layout stacking.
    next_y: f32,
    /// Session identifier.
    session_id: String,
}

struct MessageEntry {
    element_id: canvas_core::ElementId,
    role: MessageRole,
    timestamp_ms: u64,
}
```

**Implementation**:
- `CanvasSession::new(session_id: impl Into<String>, width: f32, height: f32) -> Self`
- `CanvasSession::session_id(&self) -> &str`
- `CanvasSession::scene(&self) -> &Scene`
- `CanvasSession::message_count(&self) -> usize`

**Tests**: Construction, defaults, empty state.

**Dependencies**: Tasks 1, 2

---

## Task 5: Implement `CanvasMessage::to_element()` conversion

**Description**: Convert a `CanvasMessage` into a `canvas_core::Element` with
appropriate `ElementKind::Text`, styling based on role, and default transform.

**Files to modify**: `src/canvas/types.rs`

**Implementation**:
```rust
impl CanvasMessage {
    pub fn to_element(&self) -> canvas_core::Element {
        let color = match self.role {
            MessageRole::User => "#3B82F6",      // blue
            MessageRole::Assistant => "#10B981",  // green
            MessageRole::System => "#6B7280",     // gray
            MessageRole::Tool => "#F59E0B",       // amber
        };
        let content = match self.role {
            MessageRole::Tool => format!("[{}] {}", self.tool_name.as_deref().unwrap_or("tool"), self.text),
            _ => self.text.clone(),
        };
        canvas_core::Element::new(canvas_core::ElementKind::Text {
            content,
            font_size: 14.0,
            color: color.to_string(),
        })
    }
}
```

**Tests**: Each role produces correct ElementKind::Text with right color and content format.

**Dependencies**: Tasks 1, 3

---

## Task 6: Implement `CanvasSession::push_message()` — add message with auto-layout

**Description**: Add a message to the session's scene with automatic vertical
stacking. Each message gets positioned below the previous one with padding.

**Files to modify**: `src/canvas/session.rs`

**Implementation**:
```rust
const MESSAGE_HEIGHT: f32 = 40.0;
const MESSAGE_PADDING: f32 = 8.0;
const MESSAGE_MARGIN_X: f32 = 16.0;

impl CanvasSession {
    pub fn push_message(&mut self, message: &CanvasMessage) -> canvas_core::ElementId {
        let mut element = message.to_element();
        let width = self.scene.viewport_width - (MESSAGE_MARGIN_X * 2.0);
        element = element.with_transform(canvas_core::Transform {
            x: MESSAGE_MARGIN_X,
            y: self.next_y,
            width,
            height: MESSAGE_HEIGHT,
            rotation: 0.0,
            z_index: self.messages.len() as i32,
        });
        let id = self.scene.add_element(element);
        self.messages.push(MessageEntry {
            element_id: id,
            role: message.role,
            timestamp_ms: message.timestamp_ms,
        });
        self.next_y += MESSAGE_HEIGHT + MESSAGE_PADDING;
        id
    }
}
```

**Tests**: Push single message (verify position), push multiple (verify stacking),
verify element exists in scene after push.

**Dependencies**: Tasks 4, 5

---

## Task 7: Implement `CanvasSession::to_html()` — serialize scene to HTML

**Description**: Serialize the scene's messages as styled HTML for embedding in
a Dioxus webview. Each message becomes a `<div>` with role-based CSS classes.

**Files to modify**: `src/canvas/session.rs`

**Implementation**:
```rust
impl CanvasSession {
    pub fn to_html(&self) -> String {
        let mut html = String::from("<div class=\"canvas-messages\">\n");
        for entry in &self.messages {
            if let Some(el) = self.scene.get_element(entry.element_id) {
                if let canvas_core::ElementKind::Text { content, color, .. } = &el.kind {
                    let role_class = entry.role.css_class();
                    html.push_str(&format!(
                        "  <div class=\"message {}\" style=\"color: {};\">{}</div>\n",
                        role_class,
                        html_escape(color),
                        html_escape(content),
                    ));
                }
            }
        }
        html.push_str("</div>");
        html
    }
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
     .replace('<', "&lt;")
     .replace('>', "&gt;")
     .replace('"', "&quot;")
}
```

**Tests**: Empty session produces wrapper div only, single message produces correct
HTML with role class, HTML special characters are escaped.

**Dependencies**: Task 6

---

## Task 8: Integration tests — round-trip, session management, auto-layout

**Description**: Comprehensive tests covering the full canvas abstraction layer.

**Files to create**: `tests/canvas_integration.rs` (or inline in session.rs/types.rs)

**Test cases**:
1. Round-trip: Create CanvasMessage → to_element() → verify ElementKind::Text fields
2. Session push: Push 5 messages, verify scene has 5 elements
3. Auto-layout: Push 3 messages, verify Y positions are stacked correctly
4. HTML output: Push user + assistant messages, verify HTML contains both divs with correct classes
5. Session ID: Verify session_id() returns what was passed to new()
6. Empty session: to_html() on empty session returns valid wrapper div
7. Tool message: CanvasMessage::tool() formats "[tool_name] text"
8. All roles: Each MessageRole produces correct css_class string

**Verification**: `just test` passes all new tests, `just lint` zero warnings.

**Dependencies**: All previous tasks
