# Phase 1.2: Fix availability check (P2)

## Task 1: Update is_available() to check all required binaries
**Files**: `src/fae_llm/tools/desktop/xdotool.rs` (lines 111-113)
**Description**: Change `is_available()` to check xdotool AND scrot AND xdg-open.
All three are required for full functionality.

## Task 2: Add per-action missing-tool diagnostics and tests
**Files**: `src/fae_llm/tools/desktop/xdotool.rs`
**Description**: In execute(), add early checks for scrot (screenshot) and xdg-open (launch_app)
with descriptive error messages like "scrot is required for screenshots: sudo apt install scrot".
Add tests verifying the availability check logic.
