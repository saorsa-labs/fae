# Phase 1.1: Fix click-by-label (P1)

## Task 1: Implement click-by-label with window geometry
**Files**: `src/fae_llm/tools/desktop/xdotool.rs` (lines 146-161)
**Description**: Replace the current ClickTarget::Label handler that only searches for windows
but never clicks. New implementation: search → get first window ID → get geometry (position + size)
→ calculate center → activate window → click center coordinates.

Parse xdotool getwindowgeometry output:
```
Window 12345
  Position: 100,200 (screen: 0)
  Geometry: 800x600
```
Extract position + size, compute center = (pos_x + w/2, pos_y + h/2).

Add a `parse_window_geometry()` helper function.

## Task 2: Add tests for click-by-label and geometry parsing
**Files**: `src/fae_llm/tools/desktop/xdotool.rs` (tests module)
**Description**: Add unit tests:
- `parse_window_geometry_valid` — parses standard xdotool output
- `parse_window_geometry_missing_fields` — returns error on malformed output
- `parse_window_geometry_multiline_ids` — handles multiple window IDs (first used)
