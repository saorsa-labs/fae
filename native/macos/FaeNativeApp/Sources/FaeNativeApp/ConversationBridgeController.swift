import Foundation
import WebKit

/// Bridges backend pipeline events to the `ConversationWebView` JavaScript API.
///
/// Observes typed `NotificationCenter` notifications posted by `BackendEventRouter`
/// and calls the corresponding JavaScript functions on the conversation WebView:
///
/// | Notification | JavaScript call |
/// |---|---|
/// | `.faeTranscription` | `window.addMessage('user', text)` (is_final only) |
/// | `.faeAssistantMessage` | `window.addMessage('assistant', text)` |
/// | `.faeAssistantGenerating` | `window.showTypingIndicator(active)` |
/// | `.faeToolExecution` | `window.addMessage('tool', ...)` |
///
/// The `webView` property is set by `ConversationWebView` once its `WKWebView`
/// finishes loading. All JavaScript calls are dispatched on the main queue.
@MainActor
final class ConversationBridgeController: ObservableObject {
    /// Weak reference to the conversation WebView for JS injection.
    /// Set by `ConversationWebView.Coordinator` once the page has loaded.
    weak var webView: WKWebView?

    private var observations: [NSObjectProtocol] = []

    /// Tracks the currently-streaming assistant message ID so we can
    /// append sentence fragments as they arrive rather than adding
    /// a new message bubble for each sentence.
    private var streamingAssistantText: String = ""
    private var isStreamingAssistant: Bool = false

    init() {
        subscribe()
    }

    deinit {
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
        }
    }

    // MARK: - Subscription

    private func subscribe() {
        let center = NotificationCenter.default

        // User transcription (final segments only → show in conversation)
        observations.append(
            center.addObserver(
                forName: .faeTranscription, object: nil, queue: .main
            ) { [weak self] notification in
                guard let userInfo = notification.userInfo,
                      let text = userInfo["text"] as? String,
                      let isFinal = userInfo["is_final"] as? Bool,
                      isFinal, !text.isEmpty
                else { return }
                Task { @MainActor [weak self] in
                    self?.handleUserTranscription(text: text)
                }
            }
        )

        // Assistant sentence (stream partial, commit final)
        observations.append(
            center.addObserver(
                forName: .faeAssistantMessage, object: nil, queue: .main
            ) { [weak self] notification in
                guard let userInfo = notification.userInfo,
                      let text = userInfo["text"] as? String,
                      !text.isEmpty
                else { return }
                let isFinal = userInfo["is_final"] as? Bool ?? false
                Task { @MainActor [weak self] in
                    self?.handleAssistantSentence(text: text, isFinal: isFinal)
                }
            }
        )

        // Generating indicator
        observations.append(
            center.addObserver(
                forName: .faeAssistantGenerating, object: nil, queue: .main
            ) { [weak self] notification in
                let active = notification.userInfo?["active"] as? Bool ?? false
                Task { @MainActor [weak self] in
                    self?.handleGenerating(active: active)
                }
            }
        )

        // Tool execution
        observations.append(
            center.addObserver(
                forName: .faeToolExecution, object: nil, queue: .main
            ) { [weak self] notification in
                guard let userInfo = notification.userInfo else { return }
                Task { @MainActor [weak self] in
                    self?.handleToolExecution(userInfo: userInfo)
                }
            }
        )
    }

    // MARK: - Handlers

    private func handleUserTranscription(text: String) {
        let escaped = escapeForJS(text)
        evaluateJS("window.addMessage && window.addMessage('user', '\(escaped)');")
        // When a new user message arrives, open the conversation panel so it's visible.
        evaluateJS("window.showConversationPanel && window.showConversationPanel();")
    }

    private func handleAssistantSentence(text: String, isFinal: Bool) {
        // Accumulate sentences into a streaming buffer. When the LLM sends
        // a final sentence we flush the complete message.
        streamingAssistantText += (streamingAssistantText.isEmpty ? "" : " ") + text
        isStreamingAssistant = !isFinal

        if isFinal {
            let fullText = streamingAssistantText
            streamingAssistantText = ""
            let escaped = escapeForJS(fullText)
            evaluateJS("window.addMessage && window.addMessage('assistant', '\(escaped)');")
        }
        // Ensure the panel is visible when assistant is responding.
        evaluateJS("window.showConversationPanel && window.showConversationPanel();")
    }

    private func handleGenerating(active: Bool) {
        let jsArg = active ? "true" : "false"
        evaluateJS("window.showTypingIndicator && window.showTypingIndicator(\(jsArg));")
        if active {
            evaluateJS("window.showConversationPanel && window.showConversationPanel();")
        }
    }

    private func handleToolExecution(userInfo: [AnyHashable: Any]) {
        let type_ = userInfo["type"] as? String ?? "executing"
        let name = escapeForJS(userInfo["name"] as? String ?? "")

        switch type_ {
        case "executing":
            evaluateJS("window.addMessage && window.addMessage('tool', '⚙ Using \(name)…');")
        case "result":
            let success = userInfo["success"] as? Bool ?? false
            let icon = success ? "✓" : "✗"
            evaluateJS("window.addMessage && window.addMessage('tool', '\(icon) \(name)');")
        default:
            // "call" — don't display, it's internal
            break
        }
    }

    // MARK: - JS Evaluation

    private func evaluateJS(_ js: String) {
        guard let webView else { return }
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                NSLog("ConversationBridgeController JS error: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    /// Escapes a string for safe embedding inside a single-quoted JS string literal.
    private func escapeForJS(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
