# Codex External Review
**Date**: 2026-02-19
**Mode**: gsd-task
**Phase**: 4.2 — Permission Cards with Help

## Analysis

Reviewing Phase 4.2 changes: 4 Swift files + 1 HTML file.

### Swift Review

**OnboardingController.swift:**
- `requestCalendar()` implementation is idiomatic and correct for both macOS 14+ and earlier.
- `requestMail()` approach (open System Settings, set pending) is the right solution for permissions that can't be requested programmatically. However the UX flow leaves the button in "Allow" state post-tap which may cause repeat taps.
- Dead code: `micGranted`/`contactsGranted` private vars written but never read. Pre-existing but worth flagging.

**OnboardingTTSHelper.swift:**
- Clean switch-case extension. Well-worded help texts with consistent tone.

**OnboardingWindowController.swift:**
- Clean extension of the switch statement. No issues.

### HTML/JS Review

- PERMISSION_CARDS map is a well-designed data-driven approach. Correctly handles all 4 permissions uniformly.
- Animation restart via `void el.offsetWidth` is the correct browser pattern for CSS animation restart.
- Missing `prefers-reduced-motion` coverage for the three new animation classes is an accessibility defect.
- The `permission-status` class assignment uses `"permission-status granted"` (full string replace) which is correct.

### Key Issues

1. **IMPORTANT** [accessibility]: `animate-granted`, `animate-denied`, `icon-swap` CSS animation classes not covered in `@media (prefers-reduced-motion: reduce)`.
2. **SHOULD FIX** [UX]: `requestMail()` sets state to "pending" but button still shows "Allow". User gets no visual feedback that action was taken.
3. **MINOR**: Inconsistent `eslint-disable-line` comments on `void offsetWidth` calls.

## Grade: B+
