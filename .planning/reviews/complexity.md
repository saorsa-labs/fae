# Complexity Review
**Date**: 2026-02-20
**Mode**: task (GSD)

## Analysis

### ContentView.swift — showOrbContextMenu()

Lines added: ~74
Function creates an NSMenu with 5 items + 2 separators. The function is moderately long but each step is clear:
1. Guard for window/contentView
2. Create menu
3. Add Settings item (system action)
4. Add separator
5. Create Reset handler + item
6. Create Hide handler + item
7. Add separator
8. Add Quit item
9. Retain handlers via associated object
10. Show menu

This is a standard AppKit menu construction pattern. Not overly complex but could be refactored into a helper that builds individual items.

Cyclomatic complexity: ~2 (one branch for guard)

### ConversationBridgeController.swift changes

- `handlePartialTranscription(text:)` — 3 lines, trivial
- Modified `handleAssistantText(text:)` — added else branch (~4 lines)
- Modified `aggregate_progress` case — replaced `break` with 6 lines

All additions are short and focused.

### ConversationWebView.swift

Purely additive: +1 property, +1 case in switch, +1 assignment in two functions. Trivial.

### WindowStateController.swift

Two new 3-line functions. Trivial.

### conversation.html JS additions

Total JS added: ~101 lines across several functions.
- `showProgress()` — 5 lines
- `hideProgress()` — 8 lines (with setTimeout)
- `setProgress()` — 3 lines
- `setSubtitlePartial()` — 7 lines
- Monkey-patch block — 8 lines
- `appendStreamingBubble()` — 6 lines
- `finalizeStreamingBubble()` — 5 lines
- `setAudioLevel()` — 6 lines
- `contextmenu` listener — 4 lines

Each function is small and focused. No deep nesting.

## Findings

- [LOW] `showOrbContextMenu()` in ContentView.swift is moderately long (~60 lines) — consider extracting individual menu item builders if the menu grows larger
- [INFO] All other additions are appropriately small and focused
- [INFO] No functions exceed 50 lines in the new additions (except showOrbContextMenu at ~60)

## Grade: A
