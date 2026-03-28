# External Review: MiniMax
**Date**: 2026-03-28
**Mode**: gsd (task)
**Phase**: 1.4 — Settings + UI

## Findings

- [MEDIUM] ReceiptsWindowController.swift — The `receiptsWindow` property is declared as non-lazy in `FaeAppDelegate`. This means `ReceiptsWindowController` is instantiated at app launch even before the pipeline is ready. While lightweight, it adds to launch memory footprint. A lazy var or deferred instantiation would be marginally better.
- [MEDIUM] ReceiptsTimelineView.swift:82-89 — `groupReceipts` time bucketing has a gap: an item from 31 minutes ago falls into "Earlier today" bucket, but an item from yesterday at 11:59 PM would also fall in "Earlier today" (it's >= todayStart). However, the `conversationCutoff` check is >= 30 min ago — items outside 30 min but within today go to "Earlier today". Items from yesterday that are within `weekCutoff` go to "This week". This logic is correct per the spec but note that "Earlier today" can theoretically show items from the current calendar day that are > 30 minutes old, which matches the intent.
- [LOW] ReceiptsWindowController.swift:95-112 — `openOrFocusPanel` creates the hosting view but never sets an accessibility description on the panel. The "What Fae Changed" panel lacks VoiceOver title in the NSPanel.
- [OK] `isMovableByWindowBackground = true` set on panel — good UX for a floating utility panel
- [OK] `hidesOnDeactivate = false` correct — user shouldn't lose the panel when switching apps

## Grade: B+
