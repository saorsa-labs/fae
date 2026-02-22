import Foundation

/// Bridges backend orb-state and pipeline events to `OrbStateController`.
///
/// Observes notifications posted by `BackendEventRouter` and updates the
/// shared `OrbStateController` so the orb WebView reflects the live pipeline state:
///
/// | Notification | Action |
/// |---|---|
/// | `.faeOrbStateChanged` | Update palette / feeling as directed by backend |
/// | `.faePipelineState` | Map pipeline control events → `OrbMode` |
///
/// ## Orb mode from pipeline state
///
/// | Backend event | OrbMode |
/// |---|---|
/// | `pipeline.control` (Listening) | `.listening` |
/// | `pipeline.control` (Thinking) | `.thinking` |
/// | `pipeline.control` (Speaking) | `.speaking` |
/// | `pipeline.control` (Idle/Stop) | `.idle` |
/// | `pipeline.mic_status` active=true | `.listening` |
/// | `pipeline.mic_status` active=false | `.idle` |
/// | `pipeline.generating` active=true | `.thinking` |
/// | `pipeline.audio_level` (rms>threshold) | `.speaking` (handled via .faeAudioLevel) |
///
/// The controller weakly references `OrbStateController` to avoid a retain cycle.
@MainActor
final class OrbStateBridgeController: ObservableObject {
    /// The orb state controller this bridge drives.
    weak var orbState: OrbStateController?

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

        // Orb visual state changes (palette, feeling, urgency, flash)
        observations.append(
            center.addObserver(
                forName: .faeOrbStateChanged, object: nil, queue: .main
            ) { [weak self] notification in
                guard let userInfo = notification.userInfo else { return }
                Task { @MainActor [weak self] in
                    self?.handleOrbStateChanged(userInfo: userInfo)
                }
            }
        )

        // Pipeline lifecycle → orb mode transitions
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

        // Runtime lifecycle → orb mode transitions
        observations.append(
            center.addObserver(
                forName: .faeRuntimeState, object: nil, queue: .main
            ) { [weak self] notification in
                guard let userInfo = notification.userInfo,
                      let event = userInfo["event"] as? String
                else { return }
                Task { @MainActor [weak self] in
                    self?.handleRuntimeState(event: event)
                }
            }
        )

        // Also observe generating directly for .thinking mode
        observations.append(
            center.addObserver(
                forName: .faeAssistantGenerating, object: nil, queue: .main
            ) { [weak self] notification in
                let active = notification.userInfo?["active"] as? Bool ?? false
                Task { @MainActor [weak self] in
                    guard let self, let orbState = self.orbState else { return }
                    if active {
                        orbState.mode = .thinking
                    } else if orbState.mode == .thinking {
                        orbState.mode = .idle
                    }
                }
            }
        )
    }

    // MARK: - Orb State Handler

    private func handleOrbStateChanged(userInfo: [AnyHashable: Any]) {
        guard let orbState else { return }
        let changeType = userInfo["change_type"] as? String ?? ""

        switch changeType {
        case "palette_set":
            if let paletteName = userInfo["palette"] as? String,
               let palette = OrbPalette(rawValue: paletteName)
            {
                orbState.palette = palette
            }

        case "palette_cleared":
            orbState.palette = .modeDefault

        case "feeling_set":
            if let feelingName = userInfo["feeling"] as? String,
               let feeling = OrbFeeling(rawValue: feelingName)
            {
                orbState.feeling = feeling
            }

        case "state_changed":
            // Handler.rs emits orb.state_changed with a `kind` field embedded
            // in the change_type when routed through BackendEventRouter.
            // The payload passed to .faeOrbStateChanged includes the palette/feeling
            // keys directly if present.
            if let feelingName = userInfo["feeling"] as? String,
               let feeling = OrbFeeling(rawValue: feelingName)
            {
                orbState.feeling = feeling
            }
            if let paletteName = userInfo["palette"] as? String,
               let palette = OrbPalette(rawValue: paletteName)
            {
                orbState.palette = palette
            }
            if let modeName = userInfo["mode"] as? String,
               let mode = OrbMode(rawValue: modeName)
            {
                orbState.mode = mode
            }

        default:
            // urgency_set and flash — no persistent OrbStateController change needed;
            // these are transient effects handled by the orb animation layer.
            break
        }
    }

    // MARK: - Runtime State Handler

    private func handleRuntimeState(event: String) {
        guard let orbState else { return }

        switch event {
        case "runtime.starting":
            orbState.mode = .thinking
        case "runtime.started":
            orbState.mode = .idle
        case "runtime.error":
            orbState.mode = .idle
            orbState.feeling = .concern
        case "runtime.stopped":
            orbState.mode = .idle
        default:
            break
        }
    }

    // MARK: - Pipeline State Handler

    private func handlePipelineState(event: String, payload: [String: Any]) {
        guard let orbState else { return }

        switch event {
        case "pipeline.mic_status":
            let active = payload["active"] as? Bool ?? false
            if active {
                // Microphone opened → listening
                if orbState.mode == .idle {
                    orbState.mode = .listening
                }
            } else {
                // Microphone closed → back to idle if we were listening
                if orbState.mode == .listening {
                    orbState.mode = .idle
                }
            }

        case "pipeline.control":
            // Control string is a Rust Debug-formatted enum variant.
            // Common values: "Start", "Stop", "Pause", "Resume"
            let control = payload["control"] as? String ?? ""
            switch control {
            case "Start", "Resume":
                if orbState.mode == .idle {
                    orbState.mode = .listening
                }
            case "Stop", "Pause":
                orbState.mode = .idle
            default:
                break
            }

        case "pipeline.canvas_visibility":
            // Canvas panel visibility doesn't affect orb mode.
            break

        default:
            break
        }
    }
}
