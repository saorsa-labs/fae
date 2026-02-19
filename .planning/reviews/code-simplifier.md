# Code Simplifier Review

## Simplification Opportunities

### High Value
1. **Null guard reduces complexity**: The `orbWrapperEl` block should be wrapped in a null guard. This actually SIMPLIFIES error surface — a guard makes the code's intention explicit and eliminates the undefined behavior path.

2. **Redundant `.entered` properties**: `.orb-wrapper.entered` defines `transform: scale(1); opacity: 1;` but these are already held by `animation-fill-mode: forwards` from `orbEntrance`. Remove them and rely solely on the `animation` property swap:
```css
.orb-wrapper.entered {
  animation: orbFloat 4s ease-in-out infinite;
}
```
This reduces confusion about which mechanism is "winning."

### Medium Value
3. **CSS custom properties for stagger delays**: 4 magic delay values (1.2s, 1.6s, 2.0s, 2.2s) could be expressed as CSS variables relative to a base:
```css
:root { --entrance-base: 1.2s; }
/* Then use calc(var(--entrance-base) + 0.4s) etc. */
```
This allows easy re-timing by changing one value.

4. **Consolidate the JS block**: The null check, event listener, and reducedMotion check are 3 separate concerns on `orbWrapperEl`. Group them:
```javascript
var orbWrapperEl = document.getElementById("orbWrapper");
if (orbWrapperEl) {
  if (reducedMotion) {
    orbWrapperEl.classList.add("entered");
  } else {
    orbWrapperEl.addEventListener("animationend", function(e) {
      if (e.animationName === "orbEntrance") {
        orbWrapperEl.classList.add("entered");
      }
    });
  }
}
```

### Low Value
5. The `@keyframes orbEntrance` and `@keyframes orbFloat` could be co-located with their usage in `.orb-wrapper` and `.orb-wrapper.entered` for better co-location. Not worth moving for a single change.

## VERDICT
PASS — The code is already reasonably clean. Two simplifications are worthwhile: remove redundant `.entered` properties, and consolidate the JS block with null guard.
