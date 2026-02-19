# Error Handling Review

## CRITICAL (must fix)
- `orbWrapperEl` is obtained via `getElementById("orbWrapper")` without a null check. If the DOM query fails (e.g., typo in id, HTML parse error), the immediately following `addEventListener` call will throw `TypeError: Cannot read properties of null`. This crashes the entire script block, breaking all subsequent onboarding functionality.

## HIGH (should fix)
- The `animationend` listener on `orbWrapperEl` does not guard against multiple firings if the element is somehow re-animated. While `forwards` fill mode prevents restart, defensive code would check if "entered" class already exists before adding.
- No error boundary around the `if (reducedMotion) { orbWrapperEl.classList.add("entered"); }` path — if `orbWrapperEl` is null (same risk as above), this also throws.

## MEDIUM (consider fixing)
- `window.matchMedia` call for `reducedMotion` (referenced at line 920, set earlier) could return null on very old WebKit versions. A guard like `window.matchMedia ? window.matchMedia(...).matches : false` would be safer.
- CSS `.orb-wrapper.entered` sets `transform: scale(1)` which overrides the entrance animation final state redundantly — not an error but a minor logical inconsistency.

## LOW (minor)
- The staggered `fadeSlideUp` animations use fixed delays (1.2s, 1.6s, 2.0s, 2.2s). If the orb entrance animation is skipped for any reason, these delays still fire from page-load time, which may feel mismatched. Not fatal but worth noting.

## VERDICT
WARN — One high-risk null dereference on `orbWrapperEl` that should be guarded before shipping. The rest are low-severity.
