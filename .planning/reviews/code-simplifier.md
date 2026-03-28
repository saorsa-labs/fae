# Code Simplifier Review
**Date**: 2026-03-28
**Mode**: gsd (task)
**Phase**: 1.4 — Settings + UI

## Findings

- [LOW] ReceiptsWindowController.swift:25 — `private var hostingView: NSHostingView<AnyView>?` — this property is set once and never read. It exists to keep the view alive (ARC), but since `NSHostingView` is added as a subview to `contentView`, the panel's view hierarchy retains it. The property can be removed.
- [LOW] ReceiptsWindowController.swift:114-122 — `makeContentView(receiptStore:) -> AnyView` could be simplified. The `AnyView` wrapping is needed for the `NSHostingView<AnyView>` type, but the whole approach could use a concrete `NSHostingView<ReceiptsPanelContentView>` instead. This would eliminate `AnyView`.
- [LOW] ReceiptsTimelineView.swift:273-283 — `shortPath()` implementation is 11 lines. `URL(fileURLWithPath: path).pathComponents` could simplify the path-shortening logic slightly.
- [LOW] SettingsToolsTab.swift:101-110 — "Grant All Apple Permissions" button fires 4 permission requests sequentially. Consider whether this should be async (requests are currently fire-and-forget which is fine for permissions).
- [OK] `refreshAfterDelay` uses `Task.sleep` correctly for a non-critical delay
- [OK] `@ViewBuilder` used appropriately in `capabilityCard` and `permissionRow`
- [OK] `sectionHeader` helper in ReceiptsTimelineView is clean

## Grade: A-
