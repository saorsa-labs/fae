# Code Quality Review
**Date**: 2026-02-20
**Mode**: task (GSD)

## Analysis

### ContentView.swift

**MenuActionHandler class:**
- Clean, well-scoped helper class for NSMenuItem action targets
- Uses `@escaping () -> Void` closure — GOOD
- `@objc func invoke()` bridging pattern — CORRECT for AppKit target-action
- Class is `final` — GOOD (no subclassing needed)
- Missing documentation comment — LOW

**showOrbContextMenu():**
- Clean NSMenu construction
- `objc_setAssociatedObject` for lifetime management is idiomatic AppKit — GOOD
- `window.mouseLocationOutsideOfEventStream` for menu position — GOOD (uses correct API)
- The "Hide Fae" item uses `keyEquivalent: "h"` — NOTE: `Cmd+H` is the system-wide hide shortcut. NSMenuItem key equivalents without explicit `keyEquivalentModifierMask` default to `Cmd`. This may conflict with system hide shortcut if the key mask isn't set to `.init(rawValue: 0)` for no modifier. Worth checking.

### ConversationBridgeController.swift

- Partial transcription handling is clean and well-structured
- `handlePartialTranscription(text:)` is a good single-responsibility function
- `appendStreamingBubble` / `finalizeStreamingBubble` separation is logical
- Progress bar wiring is clean: extract fields, compute pct, call JS
- `let pct = filesTotal > 0 ? (100 * filesComplete / filesTotal) : 0` — GOOD: division-by-zero guard

### ConversationWebView.swift

- Clean extension of existing `onOrbContextMenu` callback pattern — consistent with existing `onOrbClicked`
- `updateNSView` correctly propagates the callback — GOOD
- Handler registration in `contentController.add` is correctly updated — GOOD

### WindowStateController.swift

- `hideWindow()` and `showWindow()` are clean, minimal additions
- `cancelInactivityTimer()` called in `hideWindow()` — GOOD: prevents timer firing on hidden window
- Missing `@MainActor` annotation consideration (though likely called from main thread)

### conversation.html JS

- `window.setSubtitlePartial` correctly avoids starting auto-hide timer
- `pendingAssistantText` accumulation with space joining is simple and correct
- `Math.max(0, Math.min(100, pct || 0))` clamping — GOOD
- `setTimeout` for progress bar reset after fade is correct
- Monkey-patching `window.addMessage` via `_origAddMessage` — FRAGILE pattern, should use event-based approach instead

## Findings

- [MEDIUM] `ContentView.swift:77` — `hideItem` has `keyEquivalent: "h"` which may conflict with system `Cmd+H` hide shortcut. Should use `keyEquivalentModifierMask = []` or empty string for key equivalent.
- [LOW] `conversation.html` — `window.addMessage` monkey-patching is fragile. If load order changes, `_origAddMessage` could be undefined.
- [LOW] `MenuActionHandler` class lacks documentation comment (per zero-tolerance docs standard).
- [LOW] `showOrbContextMenu()` lacks documentation comment.

## Grade: A-
