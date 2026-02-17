# Fix Linux Desktop Automation Bugs

## Problem
The xdotool backend (introduced in ba9ab36) has two bugs:
1. **P1**: `click_by_label` searches for windows but never clicks — reports false success
2. **P2**: `is_available()` only checks `xdotool`, missing `scrot` and `xdg-open` deps

## Milestone 1: Fix Linux Desktop Automation Bugs

### Phase 1.1: Fix click-by-label (P1)
- Complete the click action after window search
- Parse xdotool geometry output to find window center
- Focus window then click center coordinates
- Add unit tests for the click-by-label path
- ~4 tasks, ~50 lines each

### Phase 1.2: Fix availability check (P2)
- Check all required binaries (xdotool, scrot, xdg-open)
- Add per-action error messages when specific tools are missing
- Add unit tests for availability checking
- ~4 tasks, ~50 lines each

## Success Criteria
- `click_by_label` actually clicks on the found window
- `is_available()` returns false if scrot or xdg-open missing
- All existing tests pass
- New tests cover both fixes
- Zero clippy warnings
