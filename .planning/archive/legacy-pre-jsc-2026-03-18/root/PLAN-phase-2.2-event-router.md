# Phase 2.2: Conversation Display Wiring (Swift)

Wire backend events to the ConversationWebView JS API so messages, transcriptions,
typing indicators, and tool execution status appear in the conversation panel.

## Architecture

```
BackendEventRouter
  .faeTranscription → ConversationBridgeController → WKWebView.evaluateJavaScript
  .faeAssistantMessage → window.addMessage('assistant', text)
  .faeAssistantGenerating → window.showTypingIndicator(true/false)
  .faeToolExecution → window.addMessage('tool', ...)
```

## Tasks

1. Create ConversationBridgeController.swift (new)
2. Wire webView reference from ConversationWebView.Coordinator
3. Subscribe to faeTranscription → push user message
4. Subscribe to faeAssistantMessage → push assistant message with streaming
5. Subscribe to faeAssistantGenerating → showTypingIndicator
6. Subscribe to faeToolExecution → push tool status message
7. Wire ConversationBridgeController into FaeNativeApp.swift
8. Build validation

## Files

- New: native/macos/FaeNativeApp/Sources/FaeNativeApp/ConversationBridgeController.swift
- Modify: native/macos/FaeNativeApp/Sources/FaeNativeApp/ConversationWebView.swift
- Modify: native/macos/FaeNativeApp/Sources/FaeNativeApp/FaeNativeApp.swift
