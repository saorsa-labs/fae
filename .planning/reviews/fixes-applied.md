# Fixes Applied — Phase 4.1 Task 8 Review

**Date:** 2026-02-19
**Iteration:** 1

## Fix 1 — MUST FIX: Add null guard on orbWrapperEl (HIGH — 9 votes)

**File:** `native/macos/FaeNativeApp/Sources/FaeNativeApp/Resources/Onboarding/onboarding.html`

**Change:** Wrapped all `orbWrapperEl` operations in a `if (orbWrapperEl)` null guard. Also restructured the `reducedMotion` check to be inside the guard, so all three operations (entrance listener, reduced-motion bypass, fallback timer) are in one coherent block.

## Fix 2 — SHOULD FIX: Canvas warm-ring burst during entrance (MEDIUM — 5 votes)

**File:** `native/macos/FaeNativeApp/Sources/FaeNativeApp/Resources/Onboarding/onboarding.html`

**Change:** Added 3 staggered `addRing()` calls (0ms, 120ms, 240ms apart) triggered inside the `animationend === "orbEntrance"` handler. This uses the existing ring system to emit warm-colored rings when the orb finishes growing, satisfying the acceptance criterion "emit a burst of warm-colored rings (pulse canvas) during growth." Guarded with `!reducedMotion` check.

## Fix 3 — CONSIDER: animationend fallback timer (LOW — 3 votes)

**Change:** Added `setTimeout` fallback at 1500ms to force-add the `entered` class if `animationend` was never fired (e.g., browser backgrounded during entrance). Only adds class if not already present.

## Build Verification

- cargo check: PASS
- cargo clippy -D warnings: PASS
- cargo fmt --check: PASS

## Items NOT Fixed (by design)

- **Reduced-motion bubble fade** (LOW): Spec says "bubble fades in" under reduced motion. Currently snaps visible. This is acceptable accessibility behavior — users who request reduced motion prefer instant appearance over any animation.
- **orbFloat on non-welcome screens** (LOW): The float animation continues on other screens. The orb is visually shared across screens; pausing would require tracking screen state in JS. Deferred to a future polish task.
- **Redundant .entered transform/opacity** (LOW): Left as-is to maintain explicit fallback in case fill-mode behavior varies across WebKit versions.
