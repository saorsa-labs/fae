import Foundation

/// Bridges auxiliary pipeline events to native state and exposes pipeline
/// diagnostic state for the settings UI.
///
/// Handles events not covered by `ConversationBridgeController` or
/// `OrbStateBridgeController`:
///
/// | Notification / Event | Action |
/// |---|---|
/// | `.faePipelineState` (`pipeline.canvas_visibility`) | Toggle auxiliary windows |
/// | `.faeAudioLevel` | Update `@Published var audioRMS` (read by `NativeOrbView` via SwiftUI binding) |
/// | `.faePipelineState` (control/model/error events) | Update `@Published var status` |
///
/// `status` is shown in `SettingsView` under a "Pipeline" diagnostics section.
@MainActor
final class PipelineAuxBridgeController: ObservableObject {
    /// Current pipeline status string for display in SettingsView.
    @Published var status: String = "Not started"

    /// Whether the pipeline has fully started (models loaded, ready for conversation).
    /// Drives UI gating — e.g. the input bar is hidden until this becomes `true`.
    @Published var isPipelineReady: Bool = false

    struct VoiceAttentionEvent: Identifiable, Sendable {
        let id = UUID()
        let timestamp: Date
        let stage: String
        let decision: String
        let reason: String
        let transcript: String?
        let speakerRole: String
        let wakeSource: String?
        let wakeScore: Double?
        let semanticState: String?
        let rms: Double?
    }

    struct VoiceAttentionDiagnostics: Sendable {
        var lastStage: String = "idle"
        var lastDecision: String = "No recent voice decision"
        var lastReason: String = "Waiting for voice input"
        var lastTranscript: String = ""
        var lastSpeakerRole: String = "unknown"
        var lastWakeSource: String?
        var lastWakeScore: Double?
        var lastSemanticState: String?
        var lastRMS: Double?
        var lastUpdatedAt: Date?
        var recentEvents: [VoiceAttentionEvent] = []
    }

    struct LocalStackDiagnostics: Sendable {
        var operatorLoaded: Bool = false
        var conciergeLoaded: Bool = false
        var dualModelActive: Bool = false
        var currentRoute: String = "operator"
        var fallbackReason: String = "unknown"
        var operatorRuntime: String = "in_process"
        var conciergeRuntime: String = "in_process"
        var operatorWorkerRestarts: Int = 0
        var conciergeWorkerRestarts: Int = 0
        var operatorWorkerLastError: String?
        var conciergeWorkerLastError: String?
        var lastUpdatedAt: Date?
    }

    /// Last audio RMS level received from the pipeline (0.0–1.0).
    /// Read directly by `NativeOrbView` via SwiftUI property binding.
    @Published var audioRMS: Double = 0.0

    /// Latest voice attention diagnostics for the Settings > Diagnostics screen.
    @Published var voiceAttention: VoiceAttentionDiagnostics = VoiceAttentionDiagnostics()

    /// Current dual-model runtime diagnostics for Settings > Diagnostics.
    @Published var localStack: LocalStackDiagnostics = LocalStackDiagnostics()

    /// Native canvas store for the SwiftUI canvas window.
    /// Set by `FaeApp` during wiring.
    weak var canvasController: CanvasController?

    /// Auxiliary window manager for showing/hiding conversation and canvas panels.
    /// Set by `FaeApp` during wiring.
    weak var auxiliaryWindows: AuxiliaryWindowManager?

    /// Subtitle/progress bar controller — used to hide the progress bar
    /// once all models have finished loading.
    /// Set by `FaeApp` during wiring.
    weak var subtitleState: SubtitleStateController?

    /// Tracks how many `load_complete` progress events we have received.
    /// The pipeline loads 3 models: STT, LLM, TTS. After all 3 complete,
    /// `isPipelineReady` is set to `true`.
    private var loadCompleteCount: Int = 0

    /// Whether the loading canvas (Star Wars crawl + info) has been shown.
    /// Set once on the first loading event to avoid re-showing on restarts.
    private var hasShownLoadingCanvas: Bool = false

    /// When true, voice enrollment is in progress. Startup should continue to
    /// stay on the main conversation surface without auxiliary canvas windows.
    private var enrollmentModeActive: Bool = false

    /// Retained for compatibility with older releases that tracked whether the
    /// startup canvas had already been shown. Startup now goes directly to the
    /// main conversation surface and keeps auxiliary windows closed.
    private static let hasShownStartupCanvasKey = "fae.hasShownStartupCanvas"

    private var observations: [NSObjectProtocol] = []

    init() {
        subscribe()
        localStack = LocalStackDiagnostics(
            operatorLoaded: UserDefaults.standard.bool(forKey: "fae.runtime.operator_loaded"),
            conciergeLoaded: UserDefaults.standard.bool(forKey: "fae.runtime.concierge_loaded"),
            dualModelActive: UserDefaults.standard.bool(forKey: "fae.dual_model_active"),
            currentRoute: UserDefaults.standard.string(forKey: "fae.runtime.current_route") ?? "operator",
            fallbackReason: UserDefaults.standard.string(forKey: "fae.runtime.fallback_reason") ?? "unknown",
            operatorRuntime: UserDefaults.standard.string(forKey: "fae.runtime.operator_runtime") ?? "in_process",
            conciergeRuntime: UserDefaults.standard.string(forKey: "fae.runtime.concierge_runtime") ?? "in_process",
            operatorWorkerRestarts: UserDefaults.standard.integer(forKey: "fae.runtime.operator_worker_restarts"),
            conciergeWorkerRestarts: UserDefaults.standard.integer(forKey: "fae.runtime.concierge_worker_restarts"),
            operatorWorkerLastError: UserDefaults.standard.string(forKey: "fae.runtime.operator_worker_last_error"),
            conciergeWorkerLastError: UserDefaults.standard.string(forKey: "fae.runtime.concierge_worker_last_error"),
            lastUpdatedAt: nil
        )
    }

    deinit {
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
        }
    }

    // MARK: - Subscription

    private func subscribe() {
        let center = NotificationCenter.default

        // Pipeline state events (canvas visibility, model loading, control)
        observations.append(
            center.addObserver(
                forName: .faePipelineState, object: nil, queue: .main
            ) { [weak self] notification in
                guard let userInfo = notification.userInfo,
                      let event = userInfo["event"] as? String,
                      let payload = userInfo["payload"] as? [String: Any]
                else { return }
                Task { @MainActor [weak self] in
                    self?.handlePipelineState(event: event, payload: payload)
                }
            }
        )

        // Runtime lifecycle events (stop/error → reset isPipelineReady)
        observations.append(
            center.addObserver(
                forName: .faeRuntimeState, object: nil, queue: .main
            ) { [weak self] notification in
                guard let event = notification.userInfo?["event"] as? String else { return }
                Task { @MainActor [weak self] in
                    self?.handleRuntimeLifecycle(event: event)
                }
            }
        )

        // Runtime progress events (model download/load stages)
        // This is the reliable signal for pipeline readiness — we track
        // individual `load_complete` events until all 3 models are loaded.
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

        // Audio level events
        observations.append(
            center.addObserver(
                forName: .faeAudioLevel, object: nil, queue: .main
            ) { [weak self] notification in
                let rms = notification.userInfo?["rms"] as? Double ?? 0.0
                Task { @MainActor [weak self] in
                    self?.handleAudioLevel(rms: rms)
                }
            }
        )

        // Tool execution → canvas activity cards
        observations.append(
            center.addObserver(
                forName: .faeToolExecution, object: nil, queue: .main
            ) { [weak self] notification in
                guard let userInfo = notification.userInfo else { return }
                Task { @MainActor [weak self] in
                    self?.handleToolExecutionForCanvas(userInfo: userInfo)
                }
            }
        )

        // Archive canvas turn when generation stops
        observations.append(
            center.addObserver(
                forName: .faeAssistantGenerating, object: nil, queue: .main
            ) { [weak self] notification in
                let active = notification.userInfo?["active"] as? Bool ?? false
                Task { @MainActor [weak self] in
                    if !active {
                        self?.canvasController?.archiveCurrentTurn()
                    }
                }
            }
        )

        // Thinking text → thought bubble
    }

    // MARK: - Runtime Lifecycle

    private func handleRuntimeLifecycle(event: String) {
        switch event {
        case "runtime.started":
            // In the new Swift pipeline, runtime.started fires AFTER all models
            // are loaded and the pipeline coordinator is running. Use it as a
            // backup readiness signal alongside the Combine observation in
            // FaeAppDelegate and the load_complete count.
            if !isPipelineReady {
                NSLog("PipelineAuxBridgeController: runtime.started → setting isPipelineReady")
                isPipelineReady = true
                status = "Running"
                subtitleState?.hideProgress()
            } else {
                status = "Running"
            }
        case "runtime.stopped", "runtime.error":
            isPipelineReady = false
            loadCompleteCount = 0
            hasShownLoadingCanvas = false
        default:
            break
        }
    }

    // MARK: - Runtime Progress

    private func handleRuntimeProgress(userInfo: [AnyHashable: Any]) {
        let stage = userInfo["stage"] as? String ?? ""
        NSLog("PipelineAuxBridgeController: progress stage='%@' loadCompleteCount=%d isPipelineReady=%d",
              stage, loadCompleteCount, isPipelineReady ? 1 : 0)

        if !hasShownLoadingCanvas {
            hasShownLoadingCanvas = true
            showLoadingCanvas()
        }

        switch stage {
        case "stt":
            status = "Loading speech recognition…"

        case "llm":
            status = "Loading language model…"

        case "tts":
            status = "Loading voice synthesis…"

        case "ready":
            // "ready" is sent by ModelManager after all 3 models complete
            // (success or degraded). Use as another backup readiness signal.
            if !isPipelineReady {
                NSLog("PipelineAuxBridgeController: ready stage → setting isPipelineReady")
                isPipelineReady = true
                status = "Running"
                subtitleState?.hideProgress()
                transitionToReadyCanvas()
            } else {
                status = "Finalizing startup…"
            }

        case "verify_started":
            status = "Verifying model readiness…"

        case "verify_complete":
            status = "Verification complete"

        case "load_started":
            let model = userInfo["model_name"] as? String ?? "model"
            status = "Loading \(model)…"

        case "load_complete":
            loadCompleteCount += 1
            let model = userInfo["model_name"] as? String ?? "model"
            status = "Loaded \(model)"

            // Fae loads 3 models: STT, LLM, TTS. After all 3 complete,
            // show a brief "personality" loading stage, then mark ready.
            if loadCompleteCount >= 3 && !isPipelineReady {
                status = "Loading personality…"
                subtitleState?.showProgress(
                    label: "Loading personality, memories and relationships…",
                    percent: 97
                )
                // Brief pause so users see the final stage, then mark ready.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard let self, !self.isPipelineReady else { return }
                    self.isPipelineReady = true
                    self.status = "Running"
                    self.subtitleState?.hideProgress()
                    self.transitionToReadyCanvas()
                }
            }

        case "download_started", "download_progress", "download_complete", "cached":
            // Download progress is handled by ConversationBridgeController
            // for the subtitle/progress bar UI. We only track status string.
            if stage == "download_started" {
                status = "Downloading models…"
            }

        case "aggregate_progress":
            let bytesDownloaded = userInfo["bytes_downloaded"] as? Int ?? 0
            let totalBytes = userInfo["total_bytes"] as? Int ?? 0
            let pct = totalBytes > 0 ? Int(100 * bytesDownloaded / totalBytes) : 0
            status = "Downloading… \(pct)%"

        case "error":
            let message = userInfo["message"] as? String ?? "unknown"
            status = "Error: \(message)"

        default:
            break
        }
    }

    // MARK: - Loading Canvas

    /// Keep the legacy startup-canvas hook as a no-op that clears any stale
    /// content from prior sessions. Startup no longer auto-opens the canvas.
    private func showLoadingCanvas() {
        canvasController?.clear()
        auxiliaryWindows?.hideCanvas()
    }

    /// Preserve the prior timing behavior, but keep startup on the main surface.
    private func transitionToReadyCanvas(force: Bool = false) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            self?.finishStartupCanvasTransition(force: force)
        }
    }

    /// Finalize the one-time startup canvas flow after the crawl delay.
    ///
    /// When first-launch enrollment is active, the main window already exposes the
    /// owner setup path. In that state the startup canvas should step aside instead
    /// of lingering on the frozen "First Contact" page.
    func finishStartupCanvasTransition(force: Bool = false) {
        UserDefaults.standard.set(true, forKey: Self.hasShownStartupCanvasKey)
        guard hasShownLoadingCanvas || force || enrollmentModeActive else { return }
        canvasController?.clear()
        auxiliaryWindows?.hideCanvas()
    }

    // MARK: - Canvas Activity Cards

    private func handleToolExecutionForCanvas(userInfo: [AnyHashable: Any]) {
        let type = userInfo["type"] as? String ?? ""
        let name = userInfo["name"] as? String ?? "tool"
        let cardId = userInfo["id"] as? String ?? name
        let detail = formatToolInput(userInfo)

        // Canvas activity cards.
        guard let canvas = canvasController else { return }

        switch type {
        case "executing", "call":
            let card = ActivityCard(
                id: cardId,
                kind: .toolCall(name: name),
                status: .running,
                detail: detail
            )
            canvas.addCard(card)

        case "result":
            let success = userInfo["success"] as? Bool ?? true
            let output = userInfo["output_text"] as? String ?? ""
            let truncated = String(output.prefix(200))
            canvas.updateCard(
                id: cardId,
                status: success ? .done : .error,
                detail: truncated
            )

        default:
            break
        }
    }

    private func formatToolInput(_ userInfo: [AnyHashable: Any]) -> String {
        // Try parsing input_json for structured tool call arguments
        if let jsonStr = userInfo["input_json"] as? String,
            let data = jsonStr.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let path = dict["path"] as? String { return path }
            if let query = dict["query"] as? String { return query }
            if let url = dict["url"] as? String { return url }
            if let cmd = dict["command"] as? String { return String(cmd.prefix(100)) }
            if let prompt = dict["prompt"] as? String { return String(prompt.prefix(100)) }
            if let name = dict["name"] as? String { return name }
        }
        return ""
    }

    // MARK: - Pipeline State Handlers

    private func handlePipelineState(event: String, payload: [String: Any]) {
        switch event {
        case "pipeline.canvas_visibility":
            let visible = payload["visible"] as? Bool ?? false
            if visible {
                auxiliaryWindows?.showCanvas()
            } else {
                auxiliaryWindows?.hideCanvas()
            }

        case "pipeline.canvas_content":
            let html = payload["html"] as? String ?? ""
            let append = payload["append"] as? Bool ?? false
            if append {
                canvasController?.appendContent(html)
            } else {
                canvasController?.setContent(html)
            }

        case "pipeline.control":
            let control = payload["control"] as? String ?? "unknown"
            status = "Pipeline: \(control)"

        case "pipeline.model_selected":
            let model = payload["provider_model"] as? String ?? "unknown"
            status = "Model: \(model)"

        case "pipeline.model_selection_prompt":
            status = "Selecting model…"

        case "pipeline.provider_fallback":
            let primary = payload["primary"] as? String ?? "unknown"
            status = "Fallback from \(primary)"

        case "pipeline.degraded_mode":
            let mode = payload["mode"] as? String ?? "unknown"
            status = "Degraded mode: \(mode)"

        case "pipeline.permissions_changed":
            let granted = payload["granted"] as? [String] ?? []
            status = "Permissions: \(granted.joined(separator: ", "))"

        case "pipeline.mic_status":
            let active = payload["active"] as? Bool ?? false
            // Also use mic_status as a fallback readiness signal.
            if !isPipelineReady {
                isPipelineReady = true
                status = "Running"
                subtitleState?.hideProgress()
                transitionToReadyCanvas()
            } else {
                status = "Mic: \(active ? "active" : "inactive")"
            }

        case "pipeline.voice_attention":
            handleVoiceAttention(payload: payload)

        case "pipeline.conversation_snapshot":
            // Snapshot received — don't update status string, it's a data event.
            break

        case "pipeline.enrollment_started":
            enrollmentModeActive = true

        case "pipeline.enrollment_complete":
            enrollmentModeActive = false
            transitionToReadyCanvas(force: true)

        case "pipeline.briefing_ready":
            let count = payload["item_count"] as? Int ?? 0
            status = "Briefing ready (\(count) items)"

        case "pipeline.skill_proposal":
            let name = payload["skill_name"] as? String ?? "unknown"
            status = "Skill: \(name)"

        case "pipeline.relationship_update":
            let name = payload["name"] as? String ?? "unknown"
            status = "Relationship update: \(name)"

        case "pipeline.local_stack_status":
            handleLocalStackStatus(payload: payload)

        default:
            break
        }
    }

    private func handleVoiceAttention(payload: [String: Any]) {
        let event = VoiceAttentionEvent(
            timestamp: Date(),
            stage: payload["stage"] as? String ?? "unknown",
            decision: payload["decision"] as? String ?? "unknown",
            reason: payload["reason"] as? String ?? "unknown",
            transcript: payload["transcript"] as? String,
            speakerRole: payload["speaker_role"] as? String ?? "unknown",
            wakeSource: payload["wake_source"] as? String,
            wakeScore: payload["wake_score"] as? Double,
            semanticState: payload["semantic_state"] as? String,
            rms: payload["rms"] as? Double
        )

        var diagnostics = voiceAttention
        diagnostics.lastStage = event.stage
        diagnostics.lastDecision = event.decision
        diagnostics.lastReason = event.reason
        diagnostics.lastTranscript = event.transcript ?? ""
        diagnostics.lastSpeakerRole = event.speakerRole
        diagnostics.lastWakeSource = event.wakeSource
        diagnostics.lastWakeScore = event.wakeScore
        diagnostics.lastSemanticState = event.semanticState
        diagnostics.lastRMS = event.rms
        diagnostics.lastUpdatedAt = event.timestamp
        diagnostics.recentEvents.insert(event, at: 0)
        diagnostics.recentEvents = Array(diagnostics.recentEvents.prefix(20))
        voiceAttention = diagnostics
    }

    private func handleLocalStackStatus(payload: [String: Any]) {
        localStack = LocalStackDiagnostics(
            operatorLoaded: payload["operator_loaded"] as? Bool ?? false,
            conciergeLoaded: payload["concierge_loaded"] as? Bool ?? false,
            dualModelActive: payload["dual_model_active"] as? Bool ?? false,
            currentRoute: payload["current_route"] as? String ?? "operator",
            fallbackReason: payload["fallback_reason"] as? String ?? "unknown",
            operatorRuntime: payload["operator_runtime"] as? String ?? "in_process",
            conciergeRuntime: payload["concierge_runtime"] as? String ?? "in_process",
            operatorWorkerRestarts: payload["operator_worker_restarts"] as? Int ?? 0,
            conciergeWorkerRestarts: payload["concierge_worker_restarts"] as? Int ?? 0,
            operatorWorkerLastError: payload["operator_worker_last_error"] as? String,
            conciergeWorkerLastError: payload["concierge_worker_last_error"] as? String,
            lastUpdatedAt: Date()
        )
    }

    private func handleAudioLevel(rms: Double) {
        audioRMS = rms
    }

}
