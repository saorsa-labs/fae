# Kimi K2 External Review
**Date**: 2026-02-19
**Mode**: gsd-task
**Phase**: 4.2 — Permission Cards with Help

## Analysis

### Overall Assessment

Phase 4.2 correctly implements the permission cards as specified. The code is clean and well-structured.

### Issues Found

**Critical: None**

**Important:**
1. Missing `prefers-reduced-motion` support for new card animations. Lines 470-510 in onboarding.html define `cardGrantedPulse`, `cardDeniedShake`, and `iconFadeIn` but the `@media (prefers-reduced-motion: reduce)` block (line 708) does not suppress them. Users with motion sensitivity get full animations without ability to opt out.

2. `requestMail()` UX: After the user taps "Allow" on the Mail card, `System Settings` opens but the button remains labeled "Allow" with no state change. This creates confusion — did the tap register? Should show a visual state like "Open in Settings" text on the button, or transition to a "Setup..." state.

**Minor:**
3. `EKEventStore` local variable lifetime: The EventKit completion block implicitly retains `store`, keeping it alive until the callback fires. This is the documented pattern and is correct, but a comment would help future readers.

4. Window default height (640px) may be tight for 4 cards + privacy banner. Content is scrollable via `overflow-y: auto`, but increasing default height to 680px would improve first impression.

## Grade: B+
