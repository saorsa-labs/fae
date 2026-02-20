# Code Simplification Review
**Date**: 2026-02-20
**Mode**: task (GSD)

## Analysis

### ContentView.swift — showOrbContextMenu()

The function builds an NSMenu imperatively — this is the standard AppKit idiom. However, there's opportunity to extract repeated menu item creation patterns:

```swift
// CURRENT (repeated pattern):
let resetHandler = MenuActionHandler { ... }
let resetItem = NSMenuItem(title: "Reset Conversation", action: #selector(MenuActionHandler.invoke), keyEquivalent: "")
resetItem.target = resetHandler
menu.addItem(resetItem)

let hideHandler = MenuActionHandler { ... }
let hideItem = NSMenuItem(title: "Hide Fae", action: #selector(MenuActionHandler.invoke), keyEquivalent: "h")
hideItem.target = hideHandler
menu.addItem(hideItem)

// SIMPLIFIED — helper extension:
extension NSMenu {
    @discardableResult
    func addClosureItem(title: String, keyEquivalent: String = "", action: @escaping () -> Void) -> MenuActionHandler {
        let handler = MenuActionHandler(action)
        let item = NSMenuItem(title: title, action: #selector(MenuActionHandler.invoke), keyEquivalent: keyEquivalent)
        item.target = handler
        addItem(item)
        return handler
    }
}
```

This would reduce the menu construction to:
```swift
let handlers = [
    menu.addClosureItem(title: "Reset Conversation") { ... },
    menu.addClosureItem(title: "Hide Fae", keyEquivalent: "h") { ... }
]
```

### ConversationBridgeController.swift — aggregate_progress case

```swift
// CURRENT:
let filesComplete = userInfo["files_complete"] as? Int ?? 0
let filesTotal = userInfo["files_total"] as? Int ?? 0
let message = userInfo["message"] as? String ?? "Loading…"
let pct = filesTotal > 0 ? (100 * filesComplete / filesTotal) : 0
let escaped = escapeForJS(message)
evaluateJS("window.showProgress && window.showProgress('download', '\(escaped)', \(pct));")

// Acceptable as-is — 6 lines for a progress update is appropriate.
```

### conversation.html — window.addMessage monkey-patch

```javascript
// CURRENT (fragile):
var _origAddMessage = window.addMessage;
window.addMessage = function(role, text) {
  if (role === 'user') {
    subUser.style.opacity = '';
    subUser.style.fontStyle = '';
  }
  _origAddMessage(role, text);
};

// SIMPLIFIED — inline in original addMessage function instead of patching:
// Move the partial state clear directly into the existing addMessage function
// at its definition site. This eliminates the monkey-patching entirely.
```

### conversation.html — appendStreamingBubble

```javascript
// CURRENT:
pendingAssistantText += (pendingAssistantText ? ' ' : '') + text;

// SIMPLIFIED — equivalent:
if (pendingAssistantText) pendingAssistantText += ' ';
pendingAssistantText += text;

// Or even simpler with array join — but current is acceptable.
```

## Findings

- [MEDIUM] `ContentView.swift` — Repeated NSMenuItem creation pattern (handler + item + target) could be extracted to an `NSMenu` extension or helper. Reduces boilerplate and makes future menu item additions trivial.
- [MEDIUM] `conversation.html` — `window.addMessage` monkey-patching should be refactored: move partial state clear into the original `addMessage` function definition rather than patching it from outside.
- [LOW] `conversation.html` — `pendingAssistantText += (pendingAssistantText ? ' ' : '') + text` — slightly clever; could use array accumulation for clarity
- [LOW] `showOrbContextMenu()` at ~60 lines is approaching the refactor threshold

## Simplification Opportunities

1. **NSMenu helper** — Extract `addClosureItem(title:keyEquivalent:action:)` to eliminate 3-line pattern per menu item
2. **Inline partial state clear** — Remove monkey-patch, integrate into `addMessage` at definition site
3. **CSS custom properties** — Use `var(--accent-color)` for progress bar colors instead of hardcoded rgba values

## Grade: A-
