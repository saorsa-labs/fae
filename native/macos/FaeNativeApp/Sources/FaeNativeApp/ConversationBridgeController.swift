import Foundation

/// Bridges backend pipeline events to native SwiftUI state controllers.
///
/// Observes typed `NotificationCenter` notifications posted by `BackendEventRouter`
/// and drives ``SubtitleStateController`` for overlay display and
/// ``ConversationController`` for the native message store.
///
/// This replaces the previous implementation that injected JavaScript into a
/// `WKWebView`. All state is now driven through `@Published` properties with
/// full type safety.
@MainActor
final class ConversationBridgeController: ObservableObject {

    /// Native subtitle state for the overlay bubbles.
    /// Set by `FaeNativeApp` during wiring.
    weak var subtitleState: SubtitleStateController?

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
        subtitleState?.showPartialTranscription(text)
    }

    private func handleUserTranscription(text: String) {
        subtitleState?.showUserMessage(text)
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
            subtitleState?.finalizeAssistantMessage(fullText)
            conversationController?.appendMessage(role: .assistant, content: fullText)
        } else {
            subtitleState?.appendStreamingSentence(text)
        }
    }

    private func handleGenerating(active: Bool) {
        // Native generating state — the ConversationWindowView observes this directly.
        conversationController?.isGenerating = active
    }

    private func handleToolExecution(userInfo: [AnyHashable: Any]) {
        let type_ = userInfo["type"] as? String ?? "executing"
        let name = userInfo["name"] as? String ?? ""

        switch type_ {
        case "executing":
            let message = "⚙ Using \(name)…"
            subtitleState?.showToolMessage(message)
            conversationController?.appendMessage(role: .tool, content: message)
        case "result":
            let success = userInfo["success"] as? Bool ?? false
            let icon = success ? "✓" : "✗"
            let message = "\(icon) \(name)"
            subtitleState?.showToolMessage(message)
            conversationController?.appendMessage(role: .tool, content: message)
        default:
            break
        }
    }

    // MARK: - Runtime Progress

    private func handleRuntimeProgress(userInfo: [AnyHashable: Any]) {
        let stage = userInfo["stage"] as? String ?? ""

        switch stage {
        case "download_plan_ready":
            let totalBytes = userInfo["total_bytes"] as? Int ?? 0
            let needsDownload = userInfo["needs_download"] as? Bool ?? false
            if needsDownload {
                let sizeMB = totalBytes / (1024 * 1024)
                appendStatusMessage("Preparing to download Fae's components (\(sizeMB) MB)…")
            }

        case "download_started":
            let repoId = userInfo["repo_id"] as? String ?? ""
            appendStatusMessage(Self.friendlyDownloadLabel(repoId: repoId))

        case "download_progress":
            let bytesDownloaded = userInfo["bytes_downloaded"] as? Int ?? 0
            let totalBytes = userInfo["total_bytes"] as? Int ?? 0
            if totalBytes > 0 {
                let pct = Int(100.0 * Double(bytesDownloaded) / Double(totalBytes))
                let repoId = userInfo["repo_id"] as? String ?? ""
                let label = Self.friendlyDownloadLabel(repoId: repoId)
                subtitleState?.showProgress(label: label, percent: pct)
            }

        case "aggregate_progress":
            let bytesDownloaded = userInfo["bytes_downloaded"] as? Int ?? 0
            let totalBytes = userInfo["total_bytes"] as? Int ?? 0
            let filesComplete = userInfo["files_complete"] as? Int ?? 0
            let filesTotal = userInfo["files_total"] as? Int ?? 0
            let pct: Int
            if totalBytes > 0 {
                pct = Int(100.0 * Double(bytesDownloaded) / Double(totalBytes))
            } else if filesTotal > 0 {
                pct = Int(100.0 * Double(filesComplete) / Double(filesTotal))
            } else {
                pct = 0
            }
            let sizeMB = bytesDownloaded / (1024 * 1024)
            let totalMB = totalBytes / (1024 * 1024)
            let message = "Downloading Fae's components… \(sizeMB)/\(totalMB) MB"
            subtitleState?.showProgress(label: message, percent: pct)

        case "download_complete", "cached":
            break

        case "load_started":
            let model = userInfo["model_name"] as? String ?? "model"
            let (label, pct) = Self.friendlyLoadingLabel(model: model)
            subtitleState?.showProgress(label: label, percent: pct)
            appendStatusMessage(label)

        case "load_complete":
            let model = userInfo["model_name"] as? String ?? "model"
            let label = Self.friendlyLoadCompleteLabel(model: model)
            subtitleState?.showProgress(label: label, percent: 95)
            appendStatusMessage(label)

        case "error":
            let message = userInfo["message"] as? String ?? "unknown error"
            appendStatusMessage("Something went wrong: \(message)")

        default:
            break
        }
    }

    // MARK: - Friendly Labels

    /// Human-friendly label for model loading progress (non-technical users).
    private static func friendlyLoadingLabel(model: String) -> (String, Int) {
        let lower = model.lowercased()
        if lower.contains("parakeet") || lower.contains("stt") || lower.contains("speech") {
            return ("Loading ears to listen…", 10)
        } else if lower.contains("qwen") || lower.contains("llm") || lower.contains("mistral") {
            return ("Loading brain to think — this takes a moment…", 30)
        } else if lower.contains("kokoro") || lower.contains("tts") || lower.contains("voice") {
            return ("Loading voice to speak with…", 85)
        } else {
            return ("Loading \(model)…", 50)
        }
    }

    /// Human-friendly label when a model finishes loading.
    private static func friendlyLoadCompleteLabel(model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("parakeet") || lower.contains("stt") || lower.contains("speech") {
            return "Ears ready — Fae can listen ✓"
        } else if lower.contains("qwen") || lower.contains("llm") || lower.contains("mistral") {
            return "Brain ready — Fae can think ✓"
        } else if lower.contains("kokoro") || lower.contains("tts") || lower.contains("voice") {
            return "Voice ready — Fae can speak ✓"
        } else {
            return "Loaded \(model) ✓"
        }
    }

    /// Human-friendly label for download progress.
    private static func friendlyDownloadLabel(repoId: String) -> String {
        let lower = repoId.lowercased()
        if lower.contains("parakeet") || lower.contains("stt") || lower.contains("speech") {
            return "Downloading speech recognition…"
        } else if lower.contains("qwen") || lower.contains("llm") || lower.contains("mistral") {
            return "Downloading Fae's brain…"
        } else if lower.contains("kokoro") || lower.contains("tts") || lower.contains("voice") {
            return "Downloading Fae's voice…"
        } else {
            let shortName = repoId.split(separator: "/").last.map(String.init) ?? repoId
            return "Downloading \(shortName)…"
        }
    }

    private func handleRuntimeState(event: String, userInfo: [AnyHashable: Any]) {
        switch event {
        case "runtime.starting":
            // Show an initial indeterminate-style progress bar immediately so
            // the user sees loading feedback before the first progress event.
            subtitleState?.showProgress(label: "Fae is waking up…", percent: 2)
        case "runtime.started":
            // NOTE: runtime.started fires immediately after spawning the async
            // pipeline task — models are NOT loaded yet. Do NOT hide progress
            // here. Progress is hidden when all models finish loading
            // (see load_complete handling above, and PipelineAuxBridgeController).
            break
        case "runtime.stopped":
            subtitleState?.hideProgress()
        case "runtime.error":
            subtitleState?.hideProgress()
            let payload = userInfo["payload"] as? [String: Any] ?? [:]
            let message = payload["error"] as? String ?? "unknown error"
            appendStatusMessage("Pipeline error: \(message)")
        default:
            break
        }
    }

    /// Append a system status message to both the subtitle overlay and the native message store.
    private func appendStatusMessage(_ text: String) {
        subtitleState?.showToolMessage(text)
        conversationController?.appendMessage(role: .tool, content: text)
    }
}
