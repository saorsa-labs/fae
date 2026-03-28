# Fixes Applied — Phase 1.4 Review
**Date**: 2026-03-28
**Based on**: consensus-20260328-140000.md

## Fixes Applied

### F1 — Hardcoded color replaced with FaeDesign.surfaceBase
- `ReceiptsWindowController.swift:135` — `NSColor(red: 0.06, green: 0.063, blue: 0.075, alpha: 0.97)` → `NSColor(FaeDesign.surfaceBase).withAlphaComponent(0.97)`
- `ReceiptsWindowController.swift:171` — `Color(red: 0.06, green: 0.063, blue: 0.075)` → `FaeDesign.surfaceBase`

### F2 — Removed dead `hostingView` property
- `ReceiptsWindowController.swift:25` — Removed `private var hostingView: NSHostingView<AnyView>?`
- Assignment `hostingView = hosting` also removed

### F3 — Eliminated AnyView type erasure
- `makeContentView(receiptStore:)` return type changed from `AnyView` to `some View`
- `NSHostingView(rootView: content)` now infers the concrete wrapped type
- `ReceiptsPanelContentView` is no longer wrapped in `AnyView()`

## Build Verification
`swift build` — **PASSED** (Build complete! 12.01s) — zero new warnings or errors

## Deferred (not fixed, tracked)
- F4 (unit tests for groupReceipts/humanLabel) — deferred per test strategy (UI logic, no HandoffTests pattern)
- F5 (receiptCount badge live wiring) — ConversationWindowView not in active use from source; badge parameter exists for future use when view is instantiated
