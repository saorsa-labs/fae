# Type Safety Review

## CRITICAL (must fix)
none

## HIGH (should fix)
- `document.getElementById("orbWrapper")` returns `HTMLElement | null` in TypeScript-aware environments and `Element | null` at runtime. The code assigns this to `var orbWrapperEl` without a null check and immediately calls `.addEventListener()` on it. In strict TypeScript this would be a compile error. In plain JS (as used here), it is a runtime TypeError if null. This is the single type-safety gap in this change.

## MEDIUM (consider fixing)
- The `animationend` event callback parameter `e` is implicitly typed. In the context of pure JS, this is fine — `e.animationName` is a valid `AnimationEvent` property. No issue in practice.
- CSS property `transform: scale(1) translateY(0)` in the float keyframes — using both `scale()` and `translateY()` in the same transform is correct and will not be overridden by separate GPU compositing paths on modern WebKit.

## LOW (minor)
- `window.matchMedia("(prefers-reduced-motion: reduce)").matches` — `matchMedia` can return null in environments that don't support it (rare in WKWebView on macOS 14+). A falsy guard would improve robustness.

## VERDICT
WARN — The null dereference on `orbWrapperEl` is the primary type-safety concern. Everything else is clean for a vanilla JS file.
