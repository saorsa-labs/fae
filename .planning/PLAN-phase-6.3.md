# Phase 6.3 — UX Feedback

**Status:** Planning
**Milestone:** 6 — Dogfood Readiness

---

## Overview

Phase 6.3 adds real-time UX feedback to the conversation view:
- Startup/model progress display so users see loading state
- Partial STT transcription displayed live while speaking
- Incremental assistant response streaming (sentence-by-sentence)
- Audio level visualization hooked to the orb
- Orb right-click context menu for quick actions

All implementation is frontend-only (Swift + JS). The Rust backend already emits all necessary events. No Rust changes required.

---

## Prerequisites

| Prerequisite | Status |
|-------------|--------|
| Phase 6.2 committed (user name) | DONE |
| `aggregate_progress` events emitted from Rust | DONE (BackendEventRouter routes `runtime.progress` to `.faeRuntimeProgress`) |
| `pipeline.audio_level` routed to Swift | DONE (PipelineAuxBridgeController calls `window.setAudioLevel`) |
| `is_final: false` transcription events emitted from Rust | DONE (RuntimeEvent::Transcription has is_final field) |

---

## Tasks

### Task 1 — Progress JS API and CSS skeleton (30 min)

**Goal:** Add `window.showProgress(stage, message, pct)` and `window.hideProgress()` to `conversation.html`.

**Scope:** `conversation.html` JS only

**Subtasks:**
1. Add a `#progress-bar` div inside `#subtitle-area` (above message bubbles), hidden by default
2. Add CSS: thin linear progress bar at top of subtitle area, with smooth width transition
3. Implement `window.showProgress(stage, message, pct)`:
   - Sets `display: block` on the bar
   - Sets `width: {pct}%` on inner fill element
   - Updates a `#progress-label` span with `message`
4. Implement `window.hideProgress()`:
   - Fades out and sets `display: none`
5. Add `window.setProgress(pct)` convenience function
6. Verify CSS does not interfere with `data-window-mode="collapsed"` hide rules

**Dependencies:** None

---

### Task 2 — Wire aggregate_progress to JS (30 min)

**Goal:** `ConversationBridgeController.swift` — handle `aggregate_progress` case and call `window.showProgress`.

**Scope:** `ConversationBridgeController.swift` only

**Subtasks:**
1. Locate the `aggregate_progress` switch case in `handleRuntimeProgress()` — currently `break` (no-op)
2. Extract fields from notification userInfo:
   - `bytes_downloaded: Int64`, `total_bytes: Int64`, `files_complete: Int`, `files_total: Int`, `message: String`
3. Compute `pct = files_total > 0 ? Int(100 * files_complete / files_total) : 0`
4. Call `evaluateJavaScript("window.showProgress && window.showProgress('\(stage)', '\(escapedMsg)', \(pct));")`
5. Handle `runtime.state == "started"` event to call `window.hideProgress()`
6. Add `window.hideProgress()` call when pipeline state transitions to Running

**Dependencies:** Task 1

---

### Task 3 — Partial STT transcription display (30 min)

**Goal:** Show live partial transcriptions as faded subtitle while user is speaking.

**Scope:** `conversation.html` JS, `ConversationBridgeController.swift`

**Subtasks:**
1. In `conversation.html`: Add `window.setSubtitlePartial(text)`:
   - Shows text in `#subtitle-text` with 60% opacity and italic style
   - Does NOT start the 5s auto-hide timer
2. In `conversation.html`: Modify `window.addMessage(role, text)` to clear partial state when `role == "user"` and `is_final` is true (restore normal opacity)
3. In `ConversationBridgeController.swift` `handleUserTranscription()`:
   - Remove the `guard t.isFinal else { return }` early exit
   - If `t.isFinal == false`: call `evaluateJavaScript("window.setSubtitlePartial && window.setSubtitlePartial('\(escaped)');")` 
   - If `t.isFinal == true`: existing `addMessage` call (which clears partial state)
4. Test: partial transcriptions appear briefly as faded text, replaced by normal bubble on completion

**Dependencies:** None (parallel with Task 1)

---

### Task 4 — Incremental assistant streaming display (30 min)

**Goal:** Show each assistant sentence as it arrives rather than waiting for `is_final`.

**Scope:** `conversation.html` JS, `ConversationBridgeController.swift`

**Subtasks:**
1. In `conversation.html`: Add `window.appendStreamingBubble(text)`:
   - Creates or extends an `assistant` bubble that accumulates streamed sentences
   - Bubble is visually distinct (e.g., dimmer color, animated ellipsis suffix) while accumulating
   - Stores reference as `pendingAssistantBubble`
2. In `conversation.html`: Modify `window.addMessage("assistant", text)` to check if `pendingAssistantBubble` exists:
   - If yes: finalize it (remove streaming style) and clear `pendingAssistantBubble`
   - Then display the final message normally
3. In `ConversationBridgeController.swift` `handleAssistantSentence()`:
   - Remove the `guard t.isFinal else { accumulate; return }` pattern
   - If `is_final == false` and text is a sentence: call `window.appendStreamingBubble('\(escaped)')`
   - If `is_final == true`: call existing `window.addMessage` (which finalizes the bubble)
4. Keep existing sentence accumulation logic for the final `addMessage` call (full accumulated text)

**Dependencies:** None (parallel with Tasks 1-3)

---

### Task 5 — Audio level JS handler (30 min)

**Goal:** Wire `window.setAudioLevel(rms)` to the orb visual system.

**Scope:** `conversation.html` JS only

**Subtasks:**
1. In `conversation.html`: Add `window.setAudioLevel(rms)`:
   - Map `rms` (0.0–1.0 float from Rust) to `urgencyLevel` (0.0–1.0 float used by orb animation)
   - Apply smoothing: `urgencyLevel = urgencyLevel * 0.7 + rms * 0.3` (exponential moving average)
   - Only apply when `currentOrbMode === "listening"` — orb should react during VAD
2. Verify `PipelineAuxBridgeController.swift` already calls `window.setAudioLevel` with `&&` guard — confirm no Swift changes needed
3. Test: while speaking, orb urgency/wobble visually reflects audio level in real time

**Dependencies:** None (parallel with all tasks)

---

### Task 6 — Context menu registration (30 min)

**Goal:** Register `orbContextMenu` WKScriptMessageHandler and add right-click listener in JS.

**Scope:** `ConversationWebView.swift`, `conversation.html` JS

**Subtasks:**
1. In `ConversationWebView.swift` `makeNSView()`:
   - Add `configuration.userContentController.add(coordinator, name: "orbContextMenu")`
2. In `ConversationWebView.swift` `Coordinator.userContentController(_:didReceive:)`:
   - Add `case "orbContextMenu":` handling
   - Call `parent.onOrbContextMenu?()` (add optional callback to `ConversationWebView`)
3. In `conversation.html` JS:
   - Add `document.addEventListener('contextmenu', (e) => { e.preventDefault(); window.webkit.messageHandlers.orbContextMenu.postMessage({}); })`
4. Wire `onOrbContextMenu` in `ContentView.swift` to show a placeholder `NSMenu` with items: "Settings", "Reset Conversation", "Quit"
5. Show the menu at mouse location using `NSMenu.popUpContextMenu(_:with:for:)`

**Dependencies:** None (parallel with Tasks 1-5)

---

### Task 7 — Context menu actions and hide/show (30 min)

**Goal:** Implement menu item actions and window hide/show from context menu.

**Scope:** `WindowStateController.swift`, `ContentView.swift`, menu action handlers

**Subtasks:**
1. In `WindowStateController.swift`: Add `hideWindow()` — calls `window?.orderOut(nil)` and sets `isHidden = true`
2. In `WindowStateController.swift`: Add `showWindow()` — calls `window?.makeKeyAndOrderFront(nil)` and sets `isHidden = false`
3. Add "Hide Fae" item to context menu → calls `windowState.hideWindow()`
4. Add "Show Fae" / "Unhide" as NSStatusItem action (for when window is hidden)
5. Implement "Reset Conversation" menu action: posts `.faeClearConversation` notification → routes to `evaluateJavaScript("window.clearMessages && window.clearMessages();")`
6. Implement "Settings" menu action: posts `.faeOpenSettings` notification → `FaeNativeApp.swift` opens settings window
7. Implement "Quit" menu action: `NSApplication.shared.terminate(nil)`

**Dependencies:** Task 6

---

## Dependency Graph

```
Task 1 (progress CSS/JS)
    └── Task 2 (wire aggregate_progress)

Task 3 (partial STT)       — independent

Task 4 (streaming bubbles) — independent

Task 5 (audio level)       — independent

Task 6 (context menu reg)
    └── Task 7 (menu actions)
```

Tasks 1, 3, 4, 5, 6 can be started in parallel.
Task 2 requires Task 1.
Task 7 requires Task 6.

---

## Files Changed

| File | Tasks |
|------|-------|
| `native/.../Resources/Conversation/conversation.html` | 1, 3, 4, 5, 6 |
| `native/.../ConversationBridgeController.swift` | 2, 3, 4 |
| `native/.../ConversationWebView.swift` | 6 |
| `native/.../WindowStateController.swift` | 7 |
| `native/.../ContentView.swift` | 6, 7 |

No Rust changes required.

---

## Acceptance Criteria

- [ ] Model loading shows progress bar with percentage during startup
- [ ] Progress bar disappears when pipeline reaches Running state
- [ ] Partial STT text appears in faded italic while user is speaking
- [ ] Partial text is replaced by normal bubble when STT is finalized
- [ ] Assistant response sentences appear incrementally (not all at once)
- [ ] Orb wobble/urgency reflects audio level during listening mode
- [ ] Right-click on orb shows context menu
- [ ] Context menu: Settings opens settings window
- [ ] Context menu: Reset Conversation clears bubbles
- [ ] Context menu: Hide Fae hides the window
- [ ] Context menu: Quit exits the app
- [ ] All existing functionality unaffected (modes, palettes, feelings, window sizing)
- [ ] `cargo fmt`, `cargo clippy`, `cargo nextest` all pass (no Rust changes expected)
