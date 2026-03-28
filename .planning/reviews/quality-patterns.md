# Quality Patterns Review
**Date**: 2026-03-28
**Mode**: gsd (task)
**Phase**: 1.4 — Settings + UI

## Findings

- [MEDIUM] ReceiptsWindowController.swift:137,173 — Background color `Color(red: 0.06, green: 0.063, blue: 0.075)` used in two places instead of `FaeDesign.surfaceBase`. This deviates from the Scottish design system token pattern used throughout the codebase. Minor numerical discrepancy (0.06 vs 0.059) could cause subtle inconsistency.
- [LOW] ReceiptsWindowController.swift:72 — `NSLog()` used for error logging. The codebase uses `NSLog` elsewhere for diagnostics; not a deviation, but `debugLog()` from `FaeCore` would route through the debug console.
- [LOW] ReceiptsWindowController.swift:89-92 — `openOrFocusPanel` focuses existing panel with `makeKeyAndOrderFront` but does not refresh receipts when re-focusing. If the user opens the panel, closes it (without destroying it), then opens it again, they'll see stale data until they manually refresh.
- [OK] `@ViewBuilder` used correctly throughout Settings tab
- [OK] `LazyVStack` used in ReceiptsTimelineView for performance with many receipts
- [OK] `@State private var isUndoing` in ReceiptRowView — correct per-row state isolation
- [OK] Consistent button style: `.plain` buttonStyle with custom backgrounds matches existing ConversationWindowView patterns
- [OK] Notification-based decoupling pattern (`.faeShowReceiptsPanel`) consistent with existing codebase notifications

## Grade: B+
