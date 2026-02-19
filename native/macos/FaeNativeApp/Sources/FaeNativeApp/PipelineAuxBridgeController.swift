import Foundation
import WebKit

/// Bridges auxiliary pipeline events to the conversation WebView and exposes
/// pipeline diagnostic state for the settings UI.
///
/// Handles events not covered by `ConversationBridgeController` or
/// `OrbStateBridgeController`:
///
/// | Notification / Event | Action |
/// |---|---|
/// | `.faePipelineState` (`pipeline.canvas_visibility`) | `window.showCanvasPanel()` / `window.hideCanvasPanel()` |
/// | `.faeAudioLevel` | Inject RMS into orb animation via `window.setAudioLevel(rms)` if available |
/// | `.faePipelineState` (control/model/error events) | Update `@Published var status` |
///
/// `status` is shown in `SettingsView` under a "Pipeline" diagnostics section.
@MainActor
final class PipelineAuxBridgeController: ObservableObject {
    /// Current pipeline status string for display in SettingsView.
    @Published var status: String = "Not started"

    /// Last audio RMS level received from the pipeline (0.0–1.0).
    @Published var audioRMS: Double = 0.0

    /// Weak reference to the conversation WebView for JS injection.
    weak var webView: WKWebView?

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

    // MARK: - Handlers

    private func handlePipelineState(event: String, payload: [String: Any]) {
        switch event {
        case "pipeline.canvas_visibility":
            let visible = payload["visible"] as? Bool ?? false
            if visible {
                evaluateJS("window.showCanvasPanel && window.showCanvasPanel();")
            } else {
                evaluateJS("window.hideCanvasPanel && window.hideCanvasPanel();")
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
            if status.hasPrefix("Model:") || status.hasPrefix("Pipeline:") {
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
        // Inject into WebView if the conversation HTML supports it.
        // The orb animation layer can respond to window.setAudioLevel(rms).
        evaluateJS("window.setAudioLevel && window.setAudioLevel(\(rms));")
    }

    // MARK: - JS Evaluation

    private func evaluateJS(_ js: String) {
        guard let webView else { return }
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                NSLog("PipelineAuxBridgeController JS error: %@", error.localizedDescription)
            }
        }
    }
}
