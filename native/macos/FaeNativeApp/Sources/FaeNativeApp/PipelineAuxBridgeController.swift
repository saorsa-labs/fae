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

    /// Last audio RMS level received from the pipeline (0.0–1.0).
    /// Read directly by `NativeOrbView` via SwiftUI property binding.
    @Published var audioRMS: Double = 0.0

    /// Native canvas store for the SwiftUI canvas window.
    /// Set by `FaeNativeApp` during wiring.
    weak var canvasController: CanvasController?

    /// Auxiliary window manager for showing/hiding conversation and canvas panels.
    /// Set by `FaeNativeApp` during wiring.
    weak var auxiliaryWindows: AuxiliaryWindowManager?

    /// Tracks how many `load_complete` progress events we have received.
    /// The pipeline loads 3 models: STT, LLM, TTS. After all 3 complete,
    /// `isPipelineReady` is set to `true`.
    private var loadCompleteCount: Int = 0

    private var observations: [NSObjectProtocol] = []

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
    }

    // MARK: - Runtime Lifecycle

    private func handleRuntimeLifecycle(event: String) {
        switch event {
        case "runtime.started":
            // NOTE: runtime.started fires immediately after spawning the async
            // pipeline task — models may still be loading. We do NOT set
            // isPipelineReady here. It is set via load_complete progress events.
            status = "Starting…"
        case "runtime.stopped", "runtime.error":
            isPipelineReady = false
            loadCompleteCount = 0
        default:
            break
        }
    }

    // MARK: - Runtime Progress

    private func handleRuntimeProgress(userInfo: [AnyHashable: Any]) {
        let stage = userInfo["stage"] as? String ?? ""

        switch stage {
        case "load_started":
            let model = userInfo["model_name"] as? String ?? "model"
            status = "Loading \(model)…"

        case "load_complete":
            loadCompleteCount += 1
            let model = userInfo["model_name"] as? String ?? "model"
            status = "Loaded \(model)"

            // Fae loads 3 models: STT, LLM, TTS. After all 3 complete,
            // the pipeline coordinator starts and we're ready for conversation.
            // Use >= 3 as a safety measure in case extra models are added.
            if loadCompleteCount >= 3 && !isPipelineReady {
                isPipelineReady = true
                status = "Running"
            }

        case "download_started", "download_progress", "download_complete", "cached":
            // Download progress is handled by ConversationBridgeController
            // for the subtitle/progress bar UI. We only track status string.
            if stage == "download_started" {
                status = "Downloading models…"
            }

        case "aggregate":
            let progress = userInfo["progress"] as? Double ?? 0
            status = "Downloading… \(Int(progress * 100))%"

        case "error":
            let message = userInfo["message"] as? String ?? "unknown"
            status = "Error: \(message)"

        default:
            break
        }
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

        case "pipeline.conversation_visibility":
            let visible = payload["visible"] as? Bool ?? false
            if visible {
                auxiliaryWindows?.showConversation()
            } else {
                auxiliaryWindows?.hideConversation()
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

        case "pipeline.permissions_changed":
            let granted = payload["granted"] as? [String] ?? []
            status = "Permissions: \(granted.joined(separator: ", "))"

        case "pipeline.mic_status":
            let active = payload["active"] as? Bool ?? false
            // Also use mic_status as a fallback readiness signal.
            if !isPipelineReady {
                isPipelineReady = true
                status = "Running"
            } else {
                status = "Mic: \(active ? "active" : "inactive")"
            }

        case "pipeline.conversation_snapshot":
            // Snapshot received — don't update status string, it's a data event.
            break

        case "pipeline.briefing_ready":
            let count = payload["item_count"] as? Int ?? 0
            status = "Briefing ready (\(count) items)"

        case "pipeline.skill_proposal":
            let name = payload["skill_name"] as? String ?? "unknown"
            status = "Skill: \(name)"

        case "pipeline.relationship_update":
            let name = payload["name"] as? String ?? "unknown"
            status = "Relationship update: \(name)"

        default:
            break
        }
    }

    private func handleAudioLevel(rms: Double) {
        audioRMS = rms
    }
}
