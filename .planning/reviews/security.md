# Security Review
**Date**: 2026-02-20
**Mode**: task (GSD)
**Scope**: Swift/HTML/JS changes in Phase 6.3

## Analysis

### Potential Security Concerns

**ContentView.swift - showOrbContextMenu():**
- Uses `Selector(("showSettingsWindow:"))` with a string literal — MEDIUM: using string-based selectors bypasses Swift type safety. If the selector doesn't exist, this menu item will be silently inoperable (NSMenuItem won't validate). Not a security vulnerability but a robustness concern.
- `objc_setAssociatedObject` with `NSArray` for handler retention — ACCEPTABLE: standard AppKit pattern for menu targets

**ConversationBridgeController.swift:**
- JS string interpolation with `escapeForJS()`: partial transcription text is user-derived data injected into JS — MEDIUM: relies entirely on `escapeForJS()` being correct. If `escapeForJS` misses quote/backslash escapes, XSS within WKWebView could occur. (WKWebView is sandboxed, but can still execute arbitrary JS in the web content context)
- `window.appendStreamingBubble('\(escaped)')` — same concern as above
- `window.showProgress('download', '\(escaped)', \(pct))` — `escaped` here is from userInfo `message` field (Rust-controlled). `pct` is integer arithmetic, safe.

**conversation.html JS:**
- `postToSwift('orbContextMenu', { x: e.clientX, y: e.clientY })` — passes mouse coordinates to Swift; coordinates are numbers, not user text — SAFE
- `document.getElementById('scene').addEventListener('contextmenu', ...)` — standard event listener — SAFE
- `e.preventDefault()` on contextmenu — ACCEPTABLE for custom menu
- JS patching of `window.addMessage` — if any external script could override this first, the patch chain breaks — ACCEPTABLE (no external scripts)

## Findings

- [MEDIUM] `ConversationBridgeController.swift` - JS string interpolation of user-derived text (partial transcription, assistant streaming) depends on `escapeForJS()` correctness; recommend audit of that function to ensure it escapes single quotes, backslashes, and newlines
- [LOW] `ContentView.swift` - `Selector(("showSettingsWindow:"))` uses string-based selector; no runtime validation. The menu item will silently fail if the responder chain has no handler. Not a security issue but a reliability concern.
- [INFO] No hardcoded credentials, API keys, or secrets found in the diff
- [INFO] No unsafe Rust code in this diff (Swift/JS only)
- [INFO] No HTTP (non-TLS) endpoints introduced

## Grade: B+
