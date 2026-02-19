# Quality Patterns Review
**Date**: 2026-02-19
**Mode**: gsd-task
**Phase**: 4.2 — Permission Cards with Help

## Findings

- [OK] PERMISSION_CARDS data-driven map pattern — excellent separation of data from logic, easy to extend with new permission types
- [OK] Consistent MARK: sectioning in Swift files
- [OK] CSS custom properties (--warm-gold-rgb) used consistently for theming
- [OK] CSS follows existing naming conventions (kebab-case classes)
- [OK] `@available` check pattern consistent with iOS/macOS best practices
- [OK] Weak captures and @MainActor hops consistent with existing code patterns
- [IMPORTANT] `requestMail()` sends "pending" state as the result — semantically incorrect since "pending" means "not yet decided" but here it means "user was redirected to Settings". A dedicated state like "system_settings" or keeping "pending" but with distinct UI label would be clearer. Functionally the card still shows "Allow" after tap which is confusing UX.
- [OK] All new HTML elements have consistent structure (permission-icon with id, permission-info, permission-actions)
- [OK] Dark/light mode CSS for new banner follows existing pattern
- [OK] `prefers-reduced-motion` CSS is used for orb animations — but NEW card animations (animate-granted, animate-denied, icon-swap) are NOT included in the reduced motion block. This is an IMPORTANT accessibility gap.

## Grade: B+ (two issues to fix: mail UX state + reduced-motion gap for card animations)
