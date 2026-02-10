# Phase 2.3: Interactive Elements

## Goal
Make the canvas pane interactive: message actions, thinking indicator, tool-call
cards, search/filter, and keyboard navigation. Use a hybrid approach — Dioxus
components for interactivity wrapping the existing HTML content rendering.

## Approach
Replace `dangerous_inner_html` one-shot rendering with per-message Dioxus
components. Each message becomes a Dioxus `rsx!` element with onclick/hover
handlers, while the message *body* still uses `dangerous_inner_html` for
markdown/chart content.

## Tasks

### Task 1: Expose message iteration from CanvasSession
**Files:** `src/canvas/session.rs`, `src/canvas/types.rs`
- Add `CanvasSession::messages_iter()` returning `impl Iterator<Item = &MessageView>`
- Create `MessageView` struct: element_id, role, timestamp_ms, html (rendered body)
- Add `tool_input` and `tool_output` fields to `CanvasMessage` for tool detail cards
- Update `CanvasBridge::on_event()` to capture tool input/output JSON
- Tests: message iteration, tool message with input/output

### Task 2: Thinking indicator
**Files:** `src/bin/gui.rs`
- When `assistant_generating` is true and we're in Canvas view, show animated
  thinking dots at the bottom of the canvas pane (below messages)
- CSS keyframe animation for pulsing dots
- Tests (GUI tests): generating state shows/hides indicator

### Task 3: Tool-call collapsible cards
**Files:** `src/canvas/render.rs`, `src/canvas/types.rs`
- Extend `CanvasMessage` with `tool_input: Option<String>` and `tool_result_text: Option<String>`
- When rendering tool messages, produce `<details><summary>` collapsible HTML
  with syntax-highlighted JSON input and result text
- Update `CanvasBridge` to capture input_json on ToolCall events and result on ToolResult
- Tests: tool card HTML contains `<details>`, JSON is highlighted

### Task 4: Message actions — copy and details
**Files:** `src/bin/gui.rs`
- Replace `dangerous_inner_html: session().to_html()` with per-message Dioxus loop
- Each message: outer `div` with hover → show action bar (copy button)
- Copy button: `onclick` → write message text to clipboard via Dioxus eval
- Details: `onclick` → toggle details panel showing raw JSON / metadata
- CSS for action bar: absolute positioned, fade on hover
- Tests: action bar renders, copy click handler

### Task 5: Message search/filter
**Files:** `src/bin/gui.rs`
- Add search input above canvas pane (only visible in Canvas view)
- Filter messages by case-insensitive substring match on text
- Highlight matching text in rendered messages (wrap matches in `<mark>`)
- Clear search button
- CSS for search input and `<mark>` highlighting
- Tests: search filters messages, clear restores all

### Task 6: Context menu
**Files:** `src/bin/gui.rs`
- Add `oncontextmenu` handler to each message div
- Show floating menu at cursor position with options: Copy, View Source, Fork Here
- Fork Here: set fork point (like activity log fork)
- Dismiss on click outside or Escape
- CSS for floating context menu
- Tests: context menu shows/hides, actions fire

### Task 7: Keyboard navigation and accessibility
**Files:** `src/bin/gui.rs`
- Add `tabindex` and `role` attributes to message elements
- Arrow keys navigate between messages (Tab/Shift+Tab)
- Enter/Space activates focused message (shows action bar)
- Escape closes menus/details
- ARIA labels: `aria-label` on messages with role + timestamp
- `aria-live="polite"` region for new messages (screen reader)
- Tests: keyboard events, ARIA attributes present

### Task 8: Integration and non-message element rendering
**Files:** `src/bin/gui.rs`, `src/canvas/session.rs`
- Render non-message elements (tool-pushed charts/images) in a separate
  Dioxus section below messages
- Ensure `to_html_cached()` works correctly with the new per-message approach
- Add `CanvasSession::tool_elements_html()` for tool-pushed content HTML
- Full integration test: conversation with messages, tool calls, charts, search
- Tests: mixed content renders, cache works with new approach
