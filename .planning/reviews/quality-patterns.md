# Quality Patterns Review
**Date**: 2026-02-20
**Mode**: task (GSD)

## Good Patterns Found

### Swift
- `MenuActionHandler: NSObject` with `@objc func invoke()` — correct AppKit target-action pattern for closures
- `final class MenuActionHandler` — correctly marked final
- `[weak self]` capture in all notification/Task closures — correct memory management
- `[weak conversation, conversationBridge]` in menu closure — correct capture list
- `[weak windowState]` in menu closure — correct capture list
- Optional chaining throughout (`window?.orderOut`, `window?.makeKeyAndOrderFront`, `webView?.evaluateJavaScript`)
- `guard let` for early-exit on optional unwrapping
- Inactivity timer management: `cancelInactivityTimer()` on hide, `startInactivityTimer()` on show

### JavaScript
- Progress bar bounds clamping `Math.max(0, Math.min(100, ...))`
- Exponential moving average for audio level smoothing (`smoothedAudioLevel * 0.7 + rms * 0.3`)
- `clearTimeout` before setting new timer to prevent duplicate timers
- `e.preventDefault()` on contextmenu to suppress default browser/WKWebView context menu
- Defer progress bar DOM reset until after CSS transition completes (500ms timeout)

## Anti-Patterns Found

- [MEDIUM] **JS Monkey-Patching**: `var _origAddMessage = window.addMessage; window.addMessage = function(role, text) { ... }` — monkey-patching global functions is fragile and an anti-pattern. The original `addMessage` is captured before this patch block runs, which means load order matters. Better approach: use a custom event or a proper state management pattern.
- [LOW] **String-based Selector**: `Selector(("showSettingsWindow:"))` — bypasses Swift type safety. The double parentheses suggest this was intentional to avoid a compiler warning, but it's still a fragile pattern.
- [LOW] **Magic Strings in JS**: Color values like `rgba(180, 168, 196, 0.6)` in progress bar CSS are hardcoded rather than referencing CSS custom properties/variables used elsewhere in the document.

## Grade: A-
