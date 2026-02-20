# Task Specification Review
**Date**: 2026-02-20
**Mode**: task (GSD)
**Phase**: 6.3 — UX Feedback
**Task**: All tasks 1-7 (final task = 7, all completed)

## Phase 6.3 Goals vs Implementation

### Task 1 — Progress JS API and CSS skeleton
**Goal:** Add `window.showProgress(stage, message, pct)` and `window.hideProgress()` to conversation.html

- [x] `#progressBar` div added with proper HTML structure
- [x] CSS for `.progress-bar`, `.progress-bar-track`, `.progress-bar-fill`, `.progress-bar-label` added
- [x] `window.showProgress(stage, message, pct)` implemented with clamping
- [x] `window.hideProgress()` implemented with fade-out and reset
- [x] `window.setProgress(pct)` convenience function added
- [x] `body[data-window-mode="collapsed"] .progress-bar { display: none !important }` added to CSS
- **Result: COMPLETE**

### Task 2 — Wire aggregate_progress to JS
**Goal:** ConversationBridgeController handles `aggregate_progress` and calls `window.showProgress`

- [x] `aggregate_progress` case now extracts `files_complete`, `files_total`, `message`
- [x] Computes `pct = filesTotal > 0 ? (100 * filesComplete / filesTotal) : 0`
- [x] Calls `window.showProgress('download', escaped, pct)`
- [x] `runtime.started` event calls `window.hideProgress()`
- **Result: COMPLETE**

### Task 3 — Partial STT transcription display
**Goal:** Live partial transcription as faded subtitle

- [x] `window.setSubtitlePartial(text)` added to conversation.html
- [x] Sets opacity 0.5, italic style, clears Fae subtitle
- [x] Does NOT start auto-hide timer (`clearTimeout(subUserTimer)`)
- [x] `window.addMessage` patched to clear partial styling on final
- [x] `ConversationBridgeController` removes `isFinal` guard, dispatches to `handlePartialTranscription` or `handleUserTranscription`
- **Result: COMPLETE**

### Task 4 — Incremental assistant streaming display
**Goal:** Show each assistant sentence as it arrives

- [x] `window.appendStreamingBubble(text)` added — accumulates and shows in subtitle
- [x] `window.finalizeStreamingBubble(fullText)` added — finalizes bubble
- [x] `ConversationBridgeController.handleAssistantText()` calls `appendStreamingBubble` for partial, `finalizeStreamingBubble` for final
- **Result: COMPLETE**

### Task 5 — Audio level visualization
**Goal:** Hook audio level to orb animation

- [x] `window.setAudioLevel(rms)` added to conversation.html
- [x] Exponential moving average smoothing applied
- [x] Only drives urgency during listening mode
- **Note:** Task 5 completion is in this diff under conversation.html

### Task 6 — Orb right-click context menu
**Goal:** Right-click on orb shows native NSMenu

- [x] `contextmenu` event listener added to `#scene` in conversation.html
- [x] `postToSwift('orbContextMenu', ...)` called
- [x] `ConversationWebView.swift` registers `orbContextMenu` message handler
- [x] `ConversationWebView.swift` wires `onOrbContextMenu` callback
- [x] `ContentView.swift` implements `showOrbContextMenu()` with Settings, Reset, Hide, Quit items
- [x] `MenuActionHandler` helper class for closure-based NSMenuItem targets
- **Result: COMPLETE**

### Task 7 — WindowStateController.hideWindow/showWindow
**Goal:** Add hide/show window methods for use by context menu

- [x] `hideWindow()` added with `cancelInactivityTimer()` + `window?.orderOut(nil)`
- [x] `showWindow()` added with `window?.makeKeyAndOrderFront(nil)` + `startInactivityTimer()`
- **Result: COMPLETE**

## Scope Compliance

All changes are confined to Swift + HTML/JS frontend as specified. No Rust changes were made (as required by phase spec — "No Rust changes required").

## Findings

- [INFO] All 7 tasks appear to be fully implemented per spec
- [INFO] No scope creep identified — changes are within stated boundaries
- [LOW] Task 5 (audio level) implementation in conversation.html is correct but `urgencyLevel` variable is set but its consumption by the orb animation engine wasn't in scope to verify in this diff alone

## Grade: A
