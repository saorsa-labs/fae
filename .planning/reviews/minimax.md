# MiniMax External Review
**Date**: 2026-02-19
**Mode**: gsd-task
**Phase**: 4.2 — Permission Cards with Help

## Analysis

Phase 4.2 delivers a complete permission card system for 4 permission types with TTS help, glassmorphic styling, and animated state transitions. Implementation is solid.

### Critical Issues: None

### Important Issues

1. **Accessibility — reduced-motion animations**: The three new CSS animation classes (`animate-granted`, `animate-denied`, `icon-swap`) need to be suppressed in the `@media (prefers-reduced-motion: reduce)` block. The existing block correctly handles `.screen`, `.orb-wrapper`, and orb animations but misses the permission card animations. This is a WCAG compliance gap.

2. **Mail permission UX flow**: `requestMail()` correctly opens System Settings (the only viable approach for Automation permissions on macOS). However, the state returned to the web layer is "pending", which maps to the same visual as the initial state (button shows "Allow"). The user has no feedback that System Settings was opened. A better UX: update button text to "Open Settings" before opening the URL, then revert after a timeout, or add a state like "redirected" that shows "Configure in Settings" text.

### Minor Issues

3. Window height 640px with 4 cards is borderline — scrolling works but a 680px default would be better default UX.
4. ESLint comments inconsistent on void offsetWidth pattern.

## Grade: B+
