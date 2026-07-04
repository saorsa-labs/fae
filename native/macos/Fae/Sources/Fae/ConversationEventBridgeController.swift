import AppKit
import Foundation

/// Bridges backend pipeline events to native SwiftUI state controllers.
///
/// Observes typed `NotificationCenter` notifications posted by `BackendEventRouter`
/// and drives ``SubtitleStateController`` for overlay display plus
/// ``ConversationRuntimeController`` for the orb-host transcript mirror.
///
/// This bridge is non-visual: the legacy Swift transcript/composer has been
/// retired, and the Rust orb/pill is the only conversation surface.
@MainActor
final class ConversationEventBridgeController: ObservableObject {

    /// Native subtitle state for the overlay bubbles.
    /// Set by `FaeApp` during wiring.
    weak var subtitleState: SubtitleStateController?

    /// Runtime transcript store mirrored to the Rust orb host.
    /// Set by `FaeApp` during wiring.
    weak var conversationController: ConversationRuntimeController?

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

    /// Closure for sending peer commands to the daemon. Wired by FaeApp (Phase E).
    var peerCommandSender: ((String, [String: Any]) -> Void)?

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
                }
            }
        )

        // Think text — route to conversation controller for crawl display
        observations.append(
            center.addObserver(
                forName: .faeThinkingText, object: nil, queue: .main
            ) { [weak self] notification in
                guard let userInfo = notification.userInfo else { return }
                let text = userInfo["text"] as? String ?? ""
                let isActive = userInfo["is_active"] as? Bool ?? false
                Task { @MainActor [weak self] in
                    self?.handleThinkingText(text: text, isActive: isActive)
                }
            }
        )

        // x0x peer events (Phase E)
        observations.append(
            center.addObserver(
                forName: .faePeerEvent, object: nil, queue: .main
            ) { [weak self] notification in
                guard let userInfo = notification.userInfo else { return }
                Task { @MainActor [weak self] in
                    self?.handlePeerEvent(userInfo: userInfo)
                }
            }
        )
    }

    private var activeConversationRuntimeController: ConversationRuntimeController? {
        conversationController
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
        activeConversationRuntimeController?.appendMessage(role: .user, content: text)
        pendingUserTranscription = nil
    }

    private func handleAssistantSentence(text: String, isFinal: Bool) {
        // Accumulate sentences into a streaming buffer. When the LLM sends
        // a final sentence we flush the complete message.
        streamingAssistantText += (streamingAssistantText.isEmpty ? "" : " ") + text
        isStreamingAssistant = !isFinal

        // First token — dismiss the persistent "Thinking…" bubble.
        subtitleState?.clearToolMessage()

        // Transition from think phase → streaming phase on first response token.
        if activeConversationRuntimeController?.isStreaming == false {
            activeConversationRuntimeController?.startStreamingReply()
        }

        // Update live streaming text for the orb-host transcript mirror.
        activeConversationRuntimeController?.updateStreaming(text: streamingAssistantText)

        if isFinal {
            streamingAssistantText = ""
            // Pass only the last sentence to the subtitle so it shows
            // the final fragment at full opacity rather than the entire accumulated text.
            subtitleState?.finalizeAssistantMessage(text)
            activeConversationRuntimeController?.finalizeStreaming()
        } else {
            subtitleState?.appendStreamingSentence(text)
        }
    }

    private func handleGenerating(active: Bool) {
        if active {
            subtitleState?.showPersistentToolMessage("Thinking…")
            // Flush the buffered user transcription — coordinator confirmed it was accepted.
            if let pending = pendingUserTranscription, !pending.isEmpty {
                activeConversationRuntimeController?.appendMessage(role: .user, content: pending)
                pendingUserTranscription = nil
            }
            // Reset streaming + thinking state for the new turn. isStreaming stays false
            // during the think phase so the crawl can remain visible until the first token.
            streamingAssistantText = ""
            isStreamingAssistant = false
            activeConversationRuntimeController?.beginThinkingTurn()
        } else {
            // Native generating state — the orb-host mirror observes this directly.
            activeConversationRuntimeController?.isGenerating = false
            // Generation stopped — clear the thinking bubble if still showing.
            subtitleState?.clearToolMessage()
            // If there's partial streamed text that never got an isFinal sentence
            // (barge-in interruption), commit it now so it appears in the panel.
            if !streamingAssistantText.isEmpty {
                streamingAssistantText = ""
                isStreamingAssistant = false
                activeConversationRuntimeController?.cancelStreaming()
            } else {
                activeConversationRuntimeController?.finalizeStreaming()
            }
        }
    }

    private func handleThinkingText(text: String, isActive: Bool) {
        let controller = activeConversationRuntimeController
        if isActive {
            if text.isEmpty {
                // Start of a new think block
                controller?.replaceThinkingTrace(with: "")
            } else {
                controller?.appendThinkingTrace(text)
            }
        } else {
            // Think block ended — finalize trace
            controller?.finalizeThinkingTrace()
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
            activeConversationRuntimeController?.appendMessage(role: .tool, content: message)

            // Subtle UI signal for deferred/background tool work: only mark as
            // background when no active assistant generation is in progress.
            if activeConversationRuntimeController?.isGenerating == false {
                activeConversationRuntimeController?.beginBackgroundLookup()
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
            activeConversationRuntimeController?.appendMessage(role: .tool, content: message)

            if activeConversationRuntimeController?.isBackgroundLookupActive == true {
                activeConversationRuntimeController?.endBackgroundLookup()
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

        case "downloading":
            // MLX LLMModelFactory download in progress (HuggingFace Hub).
            let progress = userInfo["progress"] as? Double ?? 0
            let pct = Int(progress * 100)
            subtitleState?.showProgress(
                label: "Downloading language model… \(pct)%",
                percent: pct
            )

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
            }

        case "verify_started":
            subtitleState?.showProgress(label: "Verifying model readiness…", percent: 97)

        case "verify_complete":
            subtitleState?.showProgress(label: "Models loaded — preparing first response…", percent: 98)

        case "ready":
            subtitleState?.showProgress(
                label: "Warming up Fae for the first conversation…",
                percent: 99
            )

        case "error":
            let message = userInfo["message"] as? String ?? "unknown error"
            appendStatusMessage("Something went wrong: \(message)")

        case "conductor.fallback":
            // ADR-014 assumption: the daemon emits a `conductor.fallback` stage when
            // a cloud-lane turn falls back to local (budget exhausted, PII membrane
            // blocked it, or network error). The exact stage name is not yet
            // finalised — update this case when the daemon contract is published.
            let reason = userInfo["reason"] as? String ?? "cloud unavailable"
            NSLog("ConversationEventBridgeController: cloud fallback — %@", reason)
            subtitleState?.showToolMessage("Running locally (cloud request fell back: \(reason))")

        default:
            break
        }
    }

    // MARK: - Friendly Labels

    /// Human-friendly label for model loading progress (non-technical users).
    static func friendlyLoadingLabel(model: String) -> (String, Int) {
        let lower = model.lowercased()
        if lower.contains("parakeet") || lower.contains("stt") || lower.contains("speech") {
            return ("Loading ears to listen…", 10)
        } else if lower.contains("qwen") || lower.contains("saorsa") || lower.contains("llm") || lower.contains("mistral") {
            return ("Loading brain to think — this takes a moment…", 30)
        } else if lower.contains("kokoro") || lower.contains("tts") || lower.contains("voice") {
            return ("Loading voice to speak with…", 85)
        } else {
            return ("Loading \(model)…", 50)
        }
    }

    /// Human-friendly label when a model finishes loading.
    static func friendlyLoadCompleteLabel(model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("parakeet") || lower.contains("stt") || lower.contains("speech") {
            return "Ears ready — Fae can listen ✓"
        } else if lower.contains("qwen") || lower.contains("saorsa") || lower.contains("llm") || lower.contains("mistral") {
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
    static func friendlyDownloadLabel(repoId: String) -> String {
        let lower = repoId.lowercased()
        if lower.contains("parakeet") || lower.contains("stt") || lower.contains("speech") {
            return "Downloading speech recognition…"
        } else if lower.contains("qwen") || lower.contains("saorsa") || lower.contains("llm") || lower.contains("mistral") {
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
            // runtime.started is emitted once startup is actually complete,
            // including the initial LLM warmup. Progress is hidden by the
            // final readiness gate in PipelineAuxBridgeController / FaeApp.
            break
        case "runtime.stopped":
            subtitleState?.hideProgress()
            conversationController?.resetBackgroundLookups()
        case "runtime.error":
            subtitleState?.hideProgress()
            conversationController?.resetBackgroundLookups()
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
    /// message store. The orb transcript should only contain actual
    /// user/assistant/tool interaction messages.
    private func appendStatusMessage(_ text: String) {
        subtitleState?.showToolMessage(text)
    }

    // MARK: - x0x Peer Events (Phase E)

    private func handlePeerEvent(userInfo: [AnyHashable: Any]) {
        let event = userInfo["event"] as? String ?? ""
        let sender = userInfo["sender"] as? String ?? "<unknown>"
        let senderShort = String(sender.prefix(8))
        switch event {
        case "peer.message":
            let text = userInfo["text"] as? String ?? ""
            let attributed = "[\(senderShort)\u{2026} via x0x] \(text)"
            subtitleState?.showToolMessage(attributed)
            activeConversationRuntimeController?.appendMessage(role: .tool, content: attributed)
        case "peer.consent":
            let kind = userInfo["kind"] as? String ?? "unknown"
            let label: String
            switch kind {
            case "consent_receipt":    label = "Connection authorized by \(senderShort)\u{2026}"
            case "consent_revocation": label = "Connection revoked by \(senderShort)\u{2026}"
            default:                   label = "Consent (\(kind)) from \(senderShort)\u{2026}"
            }
            subtitleState?.showToolMessage("x0x: \(label)")
            NSLog("ConversationEventBridgeController: peer consent %@ from %@", kind, senderShort)
        case "peer.handoff_offer":
            let sourceMachine = userInfo["source_machine"] as? String ?? "<unknown>"
            let tailLen = userInfo["tail_len"] as? Int ?? 0
            let pendingTurn = userInfo["pending_turn"] as? String
            showHandoffOfferAlert(
                sender: sender, senderShort: senderShort,
                sourceMachine: sourceMachine, tailLen: tailLen,
                pendingTurn: pendingTurn)
        default:
            NSLog("ConversationEventBridgeController: unhandled peer event: %@", event)
        }
    }

    private func showHandoffOfferAlert(
        sender: String,
        senderShort: String,
        sourceMachine: String,
        tailLen: Int,
        pendingTurn: String?
    ) {
        let alert = NSAlert()
        alert.messageText = "Continue conversation from \(sourceMachine)?"
        let detail = tailLen > 0
            ? "\(senderShort)\u{2026} is offering to hand off a conversation (\(tailLen) previous turn\(tailLen == 1 ? "" : "s"))."
            : "\(senderShort)\u{2026} is offering to hand off a new conversation."
        alert.informativeText = {
            if let pt = pendingTurn, !pt.isEmpty {
                return "\(detail)\n\nPending message: \u{201C}\(pt)\u{201D}"
            }
            return detail
        }()
        alert.addButton(withTitle: "Accept")
        alert.addButton(withTitle: "Decline")
        alert.alertStyle = .informational
        if alert.runModal() == .alertFirstButtonReturn {
            if let pt = pendingTurn, !pt.isEmpty {
                NotificationCenter.default.post(
                    name: .faeConversationInjectText,
                    object: nil,
                    userInfo: ["text": pt, "prefill_only": true])
            }
            activeConversationRuntimeController?.appendMessage(
                role: .tool,
                content: "[Handoff accepted from \(sourceMachine)] Ready to continue.")
            subtitleState?.showToolMessage("Handoff from \(sourceMachine) accepted.")
            NSLog("ConversationEventBridgeController: handoff from %@ accepted", sourceMachine)
        }
    }
}
