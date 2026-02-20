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

    /// Native message store for the SwiftUI conversation window.
    /// Set by `FaeNativeApp` during wiring.
    weak var conversationController: ConversationController?

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

        // User transcription (partial + final segments)
        observations.append(
            center.addObserver(
                forName: .faeTranscription, object: nil, queue: .main
            ) { [weak self] notification in
                guard let userInfo = notification.userInfo,
                      let text = userInfo["text"] as? String,
                      !text.isEmpty
                else { return }
                let isFinal = userInfo["is_final"] as? Bool ?? false
                Task { @MainActor [weak self] in
                    if isFinal {
                        self?.handleUserTranscription(text: text)
                    } else {
                        self?.handlePartialTranscription(text: text)
                    }
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

        // Runtime progress (model downloads, loading)
        observations.append(
            center.addObserver(
                forName: .faeRuntimeProgress, object: nil, queue: .main
            ) { [weak self] notification in
                guard let userInfo = notification.userInfo else { return }
                Task { @MainActor [weak self] in
                    self?.handleRuntimeProgress(userInfo: userInfo)
                }
            }
        )

        // Runtime state (started → ready message)
        observations.append(
            center.addObserver(
                forName: .faeRuntimeState, object: nil, queue: .main
            ) { [weak self] notification in
                guard let userInfo = notification.userInfo,
                      let event = userInfo["event"] as? String
                else { return }
                Task { @MainActor [weak self] in
                    self?.handleRuntimeState(event: event, userInfo: userInfo)
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

    private func handlePartialTranscription(text: String) {
        let escaped = escapeForJS(text)
        evaluateJS("window.setSubtitlePartial && window.setSubtitlePartial('\(escaped)');")
    }

    private func handleUserTranscription(text: String) {
        let escaped = escapeForJS(text)
        evaluateJS("window.addMessage && window.addMessage('user', '\(escaped)');")
        // Dual-write: push to native message store.
        conversationController?.appendMessage(role: .user, content: text)
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
            // Finalize streaming bubble and show final message
            evaluateJS("window.finalizeStreamingBubble && window.finalizeStreamingBubble('\(escaped)');")
            // Dual-write: push completed message to native store.
            conversationController?.appendMessage(role: .assistant, content: fullText)
        } else {
            // Stream partial sentence to the orb subtitle
            let escaped = escapeForJS(text)
            evaluateJS("window.appendStreamingBubble && window.appendStreamingBubble('\(escaped)');")
        }
    }

    private func handleGenerating(active: Bool) {
        let jsArg = active ? "true" : "false"
        evaluateJS("window.showTypingIndicator && window.showTypingIndicator(\(jsArg));")
        // Dual-write: update native generating state.
        conversationController?.isGenerating = active
    }

    private func handleToolExecution(userInfo: [AnyHashable: Any]) {
        let type_ = userInfo["type"] as? String ?? "executing"
        let name = escapeForJS(userInfo["name"] as? String ?? "")
        let rawName = userInfo["name"] as? String ?? ""

        switch type_ {
        case "executing":
            evaluateJS("window.addMessage && window.addMessage('tool', '⚙ Using \(name)…');")
            conversationController?.appendMessage(role: .tool, content: "⚙ Using \(rawName)…")
        case "result":
            let success = userInfo["success"] as? Bool ?? false
            let icon = success ? "✓" : "✗"
            evaluateJS("window.addMessage && window.addMessage('tool', '\(icon) \(name)');")
            conversationController?.appendMessage(role: .tool, content: "\(icon) \(rawName)")
        default:
            break
        }
    }

    // MARK: - Runtime Progress

    private func handleRuntimeProgress(userInfo: [AnyHashable: Any]) {
        let stage = userInfo["stage"] as? String ?? ""

        switch stage {
        case "download_started":
            let model = userInfo["model_name"] as? String ?? "models"
            appendStatusMessage("Downloading \(model)...")
        case "aggregate_progress":
            let filesComplete = userInfo["files_complete"] as? Int ?? 0
            let filesTotal = userInfo["files_total"] as? Int ?? 0
            let message = userInfo["message"] as? String ?? "Loading…"
            let pct = filesTotal > 0 ? Int(100.0 * Double(filesComplete) / Double(filesTotal)) : 0
            let escaped = escapeForJS(message)
            evaluateJS("window.showProgress && window.showProgress('download', '\(escaped)', \(pct));")
        case "load_started":
            let model = userInfo["model_name"] as? String ?? "model"
            appendStatusMessage("Loading \(model)...")
        case "load_complete":
            appendStatusMessage("Models loaded.")
        case "error":
            let message = userInfo["message"] as? String ?? "unknown error"
            appendStatusMessage("Model loading failed: \(message)")
        default:
            break
        }
    }

    private func handleRuntimeState(event: String, userInfo: [AnyHashable: Any]) {
        switch event {
        case "runtime.started":
            evaluateJS("window.hideProgress && window.hideProgress();")
            appendStatusMessage("Ready to talk!")
        case "runtime.error":
            let payload = userInfo["payload"] as? [String: Any] ?? [:]
            let message = payload["error"] as? String ?? "unknown error"
            appendStatusMessage("Pipeline error: \(message)")
        default:
            break
        }
    }

    /// Append a system status message to both the WebView and the native message store.
    private func appendStatusMessage(_ text: String) {
        let escaped = escapeForJS(text)
        evaluateJS("window.addMessage && window.addMessage('tool', '\(escaped)');")
        conversationController?.appendMessage(role: .tool, content: text)
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
