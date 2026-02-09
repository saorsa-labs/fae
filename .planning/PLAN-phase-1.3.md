# Phase 1.3: Dioxus Canvas Pane

## Overview
Wire CanvasBridge into the GUI's runtime event loop and add a "Canvas" view
that renders messages as styled HTML via the scene graph. This completes the
vertical slice: pipeline events → canvas scene graph → HTML → Dioxus webview.

---

## Task 1: Add CanvasBridge signal to GUI state

Add a `use_signal` for the canvas bridge alongside existing signals.

**Files to modify**: `src/bin/gui.rs`

---

## Task 2: Route runtime events through bridge

In the runtime event handler loop, call `bridge.write().on_event(&ev)` for
each event alongside the existing LogEntry handling.

---

## Task 3: Add "Canvas" to MainView enum and drawer

Add a Canvas view option to the drawer navigation.

---

## Task 4: Create canvas pane component rendering bridge HTML

When MainView::Canvas is selected and pipeline is running, render the bridge's
`session().to_html()` output in a styled div with auto-scroll.

---

## Task 5: Add CSS for canvas message bubbles

Style `.canvas-messages`, `.message.user`, `.message.assistant`, etc.
User messages right-aligned, assistant left-aligned, system centered.

---

## Task 6: Wire auto-scroll for canvas pane

Use `use_effect` to scroll canvas div to bottom on message count changes.

---

## Task 7: Verify build with `just build-gui` and `just lint`

---

## Task 8: Tests — the GUI module tests should still pass
