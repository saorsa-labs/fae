# External Review: GLM-4
**Date**: 2026-03-28
**Mode**: gsd (task)
**Phase**: 1.4 — Settings + UI

## Findings

- [MEDIUM] ReceiptsWindowController.swift:88-92 — `openOrFocusPanel` focuses existing panel without refreshing. A user who closes (via hide) and re-opens should get fresh data. The current flow: `show()` → `refreshReceipts()` (async) → `openOrFocusPanel()`. This sequence means on re-open, `openOrFocusPanel` fires the early return for the existing panel and `makeKeyAndOrderFront` is called, but this is OK because `refreshReceipts` was called before this. Wait — on second read, `refreshReceipts` runs first then `openOrFocusPanel`. This is actually correct. RETRACTING this finding. The sequence is fine.
- [MEDIUM] ReceiptsWindowController.swift:137 — `NSColor(red: 0.06, green: 0.063, blue: 0.075, alpha: 0.97)` — this is `NSColor` for the panel background. `FaeDesign.surfaceBase` is `Color` (SwiftUI), not `NSColor`. An `NSColor(FaeDesign.surfaceBase)` conversion would be cleaner.
- [LOW] SettingsToolsTab.swift:93-96 — The "Trust & Approvals" section description text says "tap Always to build trust over time" but on macOS it's "click" not "tap". Minor copy inconsistency.
- [LOW] ReceiptsTimelineView.swift — Empty state copy "Nothing yet" followed on next line by "Fae will log changes here as she works." — period at end is slightly inconsistent with other UI copy that lacks trailing periods. Minor.
- [OK] Form layout in SettingsToolsTab uses `.formStyle(.grouped)` — correct macOS pattern
- [OK] All design token usage in ReceiptsTimelineView is correct: `FaeDesign.textFaint`, `FaeDesign.textMuted`, `FaeDesign.heatherMistText`, `FaeDesign.glenGreenText`, `FaeDesign.glenGreen`

## Grade: B+
