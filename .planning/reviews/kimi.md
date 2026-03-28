# External Review: Kimi K2
**Date**: 2026-03-28
**Mode**: gsd (task)
**Phase**: 1.4 — Settings + UI

## Findings

- [MEDIUM] ReceiptsWindowController.swift — Panel recreation issue: `panel` and `hostingView` are never cleared when `hide()` is called. If `hide()` is followed by `show()`, `openOrFocusPanel` takes the existing-panel branch and calls `makeKeyAndOrderFront` — receipts are refreshed but the hosting view's `receipts` binding may not update because the old `NSHostingView` reference is still in the panel. SwiftUI `@ObservedObject` should handle this, but the indirect path (AnyView wrapping ReceiptsPanelContentView with ObservedObject) makes the binding chain fragile.
- [MEDIUM] ReceiptsWindowController.swift — `performUndo` swallows the `receiptStore == nil` case silently (line 60: `guard let store = receiptStore else { return }`). If the store is nil at undo time (unlikely but possible during shutdown), the user gets no feedback. A logged warning would help diagnose issues.
- [LOW] ReceiptsTimelineView.swift — `ReceiptGroup` is a private struct inside `ReceiptsTimelineView`. Since it's only used by `groupReceipts()`, this is fine, but the name `ReceiptGroup` is generic enough that a collision with a future public type is possible.
- [OK] `@Published private(set)` pattern used correctly for `isVisible` and `receipts`
- [OK] Task and async patterns are sound

## Grade: B
