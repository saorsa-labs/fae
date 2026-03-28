# Complexity Review
**Date**: 2026-03-28
**Mode**: gsd (task)
**Phase**: 1.4 — Settings + UI

## Findings

- [LOW] ReceiptsTimelineView.swift — `humanLabel(for:)` is 75 lines with a 13-case switch. Cyclomatic complexity ~14. This is the most complex function in Phase 1.4 but still readable. Could be refactored into a separate file or extension on `ActionReceiptRecord`.
- [OK] `groupReceipts()` — 30 lines, clear, linear logic with 3 time buckets
- [OK] ReceiptsWindowController — `openOrFocusPanel()` early-return pattern keeps nesting shallow
- [OK] SettingsToolsTab — `body` delegates to `capabilityCard()` helper cleanly
- [OK] ConversationWindowView — receipts icon addition is minimal (10 lines in `panelHeader`)
- [OK] File sizes are reasonable: ReceiptsTimelineView (296L), ReceiptsWindowController (219L), SettingsToolsTab (185L), ConversationWindowView (308L — existing)
- [OK] No deeply nested closures or callback pyramids

## Grade: A-
