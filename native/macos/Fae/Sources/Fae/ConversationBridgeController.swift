import AppKit
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
    /// Set by `FaeApp` during wiring.
    weak var subtitleState: SubtitleStateController?

    /// Native message store for the SwiftUI main conversation window.
    /// Set by `FaeApp` during wiring.
    weak var conversationController: ConversationController?

    /// Native message store for the Work with Fae conversation surface.
    /// Set by `FaeApp` during wiring.
    weak var coworkConversationController: ConversationController?

    private var routeConversationEventsToCowork = false
    private var observations: [NSObjectProtocol] = []

    /// Tracks the currently-streaming assistant message ID so we can
    /// append sentence fragments as they arrive rather than adding
    /// a new message bubble for each sentence.
    private var streamingAssistantText: String = ""
    private var isStreamingAssistant: Bool = false

    /// Buffered user transcription pending confirmation that the coordinator
    /// actually accepted it. We hold it here until `AssistantGenerating { active: true }`
    /// fires — which means the coordinator routed the turn to the LLM or a background agent.
    /// Noise-level drops ("Mm.", "Yeah.", etc.) never trigger AssistantGenerating so they
    /// are silently discarded when the next real transcription overwrites the buffer.
    private var pendingUserTranscription: String? = nil

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

        // Model loaded — capture LLM model label for About tab
        observations.append(
            center.addObserver(
                forName: .faeModelLoaded, object: nil, queue: .main
            ) { [weak self] notification in
                guard let userInfo = notification.userInfo,
                      let engine = userInfo["engine"] as? String,
                      engine == "llm",
                      let modelId = userInfo["model_id"] as? String,
                      !modelId.isEmpty
                else { return }
                Task { @MainActor [weak self] in
                    let label = Self.friendlyModelLabel(from: modelId)
                    self?.conversationController?.loadedModelLabel = label
                    self?.coworkConversationController?.loadedModelLabel = label
                }
            }
        )

        observations.append(
            center.addObserver(
                forName: .faeCoworkConversationRoutingChanged, object: nil, queue: .main
            ) { [weak self] notification in
                let active = notification.userInfo?["active"] as? Bool ?? false
                Task { @MainActor [weak self] in
                    self?.routeConversationEventsToCowork = active
                }
            }
        )
    }

    private var activeConversationController: ConversationController? {
        if routeConversationEventsToCowork {
            return coworkConversationController ?? conversationController
        }
        return conversationController
    }

    // MARK: - Handlers

    private func handlePartialTranscription(text: String) {
        subtitleState?.showPartialTranscription(text)
    }

    private func handleUserTranscription(text: String) {
        subtitleState?.showUserMessage(text)
        // Show the user bubble immediately — don't wait for AssistantGenerating.
        // The old approach buffered until generation started, creating a perceptible
        // delay where the user spoke but saw no bubble. Noise drops that slip through
        // the echo suppressor are rare and harmless as conversation history entries.
        activeConversationController?.appendMessage(role: .user, content: text)
        pendingUserTranscription = nil
    }

    private func handleAssistantSentence(text: String, isFinal: Bool) {
        // Accumulate sentences into a streaming buffer. When the LLM sends
        // a final sentence we flush the complete message.
        streamingAssistantText += (streamingAssistantText.isEmpty ? "" : " ") + text
        isStreamingAssistant = !isFinal

        // First token — dismiss the persistent "Thinking…" bubble.
        subtitleState?.clearToolMessage()

        // Update live streaming bubble in conversation window
        activeConversationController?.updateStreaming(text: streamingAssistantText)

        if isFinal {
            streamingAssistantText = ""
            // Pass only the last sentence to the subtitle so it shows
            // the final fragment at full opacity rather than the entire accumulated text.
            subtitleState?.finalizeAssistantMessage(text)
            activeConversationController?.finalizeStreaming()
        } else {
            subtitleState?.appendStreamingSentence(text)
        }
    }

    private func handleGenerating(active: Bool) {
        // Native generating state — the ConversationWindowView observes this directly.
        activeConversationController?.isGenerating = active
        if active {
            subtitleState?.showPersistentToolMessage("Thinking…")
            // Flush the buffered user transcription — coordinator confirmed it was accepted.
            if let pending = pendingUserTranscription, !pending.isEmpty {
                activeConversationController?.appendMessage(role: .user, content: pending)
                pendingUserTranscription = nil
            }
            // Reset streaming buffer and start streaming state
            streamingAssistantText = ""
            isStreamingAssistant = false
            activeConversationController?.startStreaming()
        } else {
            // Generation stopped — clear the thinking bubble if still showing.
            subtitleState?.clearToolMessage()
            // If there's partial streamed text that never got an isFinal sentence
            // (barge-in interruption), commit it now so it appears in the panel.
            if !streamingAssistantText.isEmpty {
                streamingAssistantText = ""
                isStreamingAssistant = false
                activeConversationController?.cancelStreaming()
            } else {
                activeConversationController?.finalizeStreaming()
            }
        }
    }

    private func handleToolExecution(userInfo: [AnyHashable: Any]) {
        let type_ = userInfo["type"] as? String ?? "executing"
        let name = userInfo["name"] as? String ?? "tool"

        switch type_ {
        case "executing":
            playToolCueExecuting()
            let message = "⚙ Working: \(name)…"
            subtitleState?.showPersistentToolMessage(message)
            activeConversationController?.appendMessage(role: .tool, content: message)

            // Subtle UI signal for deferred/background tool work: only mark as
            // background when no active assistant generation is in progress.
            if activeConversationController?.isGenerating == false {
                activeConversationController?.beginBackgroundLookup()
            }

        case "result":
            let success = userInfo["success"] as? Bool ?? false
            if success {
                playToolCueSuccess()
            } else {
                playToolCueFailure()
            }
            let message = success ? "✓ Done: \(name)" : "✗ Failed: \(name)"
            subtitleState?.showToolMessage(message)
            activeConversationController?.appendMessage(role: .tool, content: message)

            if activeConversationController?.isBackgroundLookupActive == true {
                activeConversationController?.endBackgroundLookup()
            }

        default:
            break
        }
    }

    private func playToolCueExecuting() {
        NSSound(named: NSSound.Name("Tink"))?.play()
    }

    private func playToolCueSuccess() {
        NSSound(named: NSSound.Name("Submarine"))?.play()
    }

    private func playToolCueFailure() {
        NSSound(named: NSSound.Name("Basso"))?.play()
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
            // Capture the LLM model label for the About tab.
            if let llmLabel = Self.extractLLMLabel(from: model) {
                conversationController?.loadedModelLabel = llmLabel
                coworkConversationController?.loadedModelLabel = llmLabel
            }

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

    /// Extracts a friendly LLM label from a raw model_name string.
    ///
    /// Input:  `"LLM (unsloth/Qwen3-8B-GGUF / Qwen3-8B-Q4_K_M.gguf)"`
    /// Output: `"Qwen3 8B · Q4_K_M"`
    static func extractLLMLabel(from modelName: String) -> String? {
        guard modelName.hasPrefix("LLM ("), modelName.hasSuffix(")") else { return nil }
        // Strip "LLM (" prefix and ")" suffix
        let inner = String(modelName.dropFirst(5).dropLast())
        // Take the GGUF filename — last component after "/"
        let basename = inner
            .components(separatedBy: "/")
            .last?
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ".gguf", with: "")
            ?? inner
        // "Qwen3-8B-Q4_K_M" → ["Qwen3", "8B", "Q4_K_M"]
        let parts = basename.components(separatedBy: "-")
        if parts.count >= 3 {
            return "\(parts[0]) \(parts[1]) · \(parts[2])"
        }
        return basename
    }

    /// Friendly model label from an MLX model ID.
    ///
    /// Input:  `"mlx-community/Qwen3-4B-4bit"` → `"Qwen3 4B · 4bit"`
    /// Input:  `"mlx-community/Qwen3-8B-4bit"` → `"Qwen3 8B · 4bit"`
    /// Input:  `"some-model"` → `"some-model"`
    static func friendlyModelLabel(from modelId: String) -> String {
        // Take the last path component: "mlx-community/Qwen3-4B-4bit" → "Qwen3-4B-4bit"
        let basename = modelId.split(separator: "/").last.map(String.init) ?? modelId
        let parts = basename.components(separatedBy: "-")
        if parts.count >= 3 {
            return "\(parts[0]) \(parts[1]) · \(parts.dropFirst(2).joined(separator: "-"))"
        }
        return basename
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
            conversationController?.resetBackgroundLookups()
            coworkConversationController?.resetBackgroundLookups()
        case "runtime.error":
            subtitleState?.hideProgress()
            conversationController?.resetBackgroundLookups()
            coworkConversationController?.resetBackgroundLookups()
            let payload = userInfo["payload"] as? [String: Any] ?? [:]
            let message = payload["error"] as? String ?? "unknown error"
            appendStatusMessage("Pipeline error: \(message)")
        default:
            break
        }
    }

    /// Append a system status message to the **subtitle overlay only**.
    ///
    /// Boot/progress/error messages are transient UI feedback — they belong
    /// in the auto-hiding subtitle layer, NOT in the persistent conversation
    /// message store. The conversation panel should only contain actual
    /// user/assistant/tool interaction messages.
    private func appendStatusMessage(_ text: String) {
        subtitleState?.showToolMessage(text)
    }
}
