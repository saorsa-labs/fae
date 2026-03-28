# External Review: Codex
**Date**: 2026-03-28
**Mode**: gsd (task)
**Phase**: 1.4 — Settings + UI

## Findings

- [MEDIUM] ReceiptsWindowController — `hostingView` property stored but never read after assignment. Property could be removed or replaced with a local variable in `openOrFocusPanel`. Dead storage is a code smell.
- [MEDIUM] ReceiptsWindowController — When `show()` is called while the panel is already visible, the panel is focused via `makeKeyAndOrderFront` (correct) but receipts are re-fetched unnecessarily via `refreshReceipts` before focusing. Should check if panel exists first and only refresh if already visible.
- [MEDIUM] `humanLabel(for:)` in ReceiptsTimelineView — The bash case truncates at 48 chars but doesn't sanitize for display (e.g., newlines in command preview could break layout). Should normalize whitespace.
- [LOW] ReceiptsTimelineView — `relativeTime(from:)` manually implements time formatting instead of using `RelativeDateTimeFormatter`. The custom implementation handles days/hours/minutes/seconds correctly but `RelativeDateTimeFormatter` would provide localization support.
- [OK] Architecture is clean and follows existing patterns
- [OK] Async/await used correctly for undo and refresh operations

## Grade: B+
