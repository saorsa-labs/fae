# Quality Patterns Review

## CRITICAL (must fix)
none

## HIGH (should fix)
- **Missing null guard pattern**: The standard DOM querying pattern in this file should include a null check before adding event listeners. Existing code elsewhere in the file (e.g., `orbWrapper` at line 945) already has similar patterns. The new `orbWrapperEl` at line 1307 omits the guard, breaking the consistent defensive pattern.

## MEDIUM (consider fixing)
- **CSS naming consistency**: The new `.entered` class name is a past-tense adjective describing state, which is idiomatic. However, the existing codebase uses `.orb-speaking`, `.screen.active`, `.exit-left` etc. — all noun/verb patterns. `.entered` fits but consider `.orb-wrapper--floating` (BEM) or `.orb-floating` for clarity about what state it represents (not that entrance happened, but that float is active).
- **Animation class swap pattern**: The pattern of adding a class on `animationend` to switch between animations is standard. However, the `forwards` fill mode on `orbEntrance` combined with the `entered` class setting `transform: scale(1); opacity: 1` creates a redundancy. The fill mode already holds the values — the explicit properties in `.entered` only matter if the fill mode fails. Document this intent.

## LOW (minor)
- Stagger delay values could use CSS custom properties for easier theming.
- The `filter: brightness(1.12)` hover value is consistent with the existing brightness/contrast approach used elsewhere in the file.

## VERDICT
WARN — The missing null guard violates the defensive coding pattern established elsewhere in the file. Otherwise, the implementation follows existing conventions well.
