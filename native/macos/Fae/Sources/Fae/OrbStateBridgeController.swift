import Foundation

/// Bridges backend orb-state and pipeline **listening/PTT** events to
/// `OrbStateController`.
///
/// **Orb-host-owns-state (2026-06-17):** the orb's `thinking` / `speaking` /
/// `idle` mode is now owned by the **Rust orb host** (`native/rust/fae-ui-shell`),
/// which derives it from the daemon event stream via a grace-hold state machine
/// (`orb_state.rs`). This controller NO LONGER drives those modes from
/// `.faeAssistantGenerating`, `.faeAudioLevel`, `.faeDaemonAudioLevel`, or
/// `.faeDaemonAudioEnded` — those subscriptions were removed to make the orb
/// host the single source of truth for its visible mode (the no-Swift principle).
///
/// What remains here is what Swift still owns:
/// - **Palette / feeling** (`.faeOrbStateChanged`) — visual theming, not mode.
/// - **Listening / PTT** (`.faePipelineState` mic_status + pipeline.control
///   Start/Stop) — push-to-talk capture is still a Swift `NSEvent` (Right ⌥)
///   the orb host can't see; this is the one remaining orb signal Swift emits
///   until capture moves to the daemon (V5 gap). The orb host may also set
///   listening itself for its own long-press gesture.
/// - **Runtime lifecycle** (`runtime.starting`/`error`/`stopped`) — boot/error
///   shading of the orb before the daemon bridge is up.
@MainActor
final class OrbStateBridgeController: ObservableObject {
    /// The orb state controller this bridge drives.
    weak var orbState: OrbStateController?

    /// When rescue mode is active, force silver-mist palette on all transitions.
    var isRescueMode: Bool = false

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

        // Orb visual state changes (palette, feeling, urgency, flash) — NOT mode.
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

        // Pipeline lifecycle → LISTENING / PTT only (mode-driving for
        // thinking/speaking/idle was retired; the orb host owns those).
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

        // Runtime lifecycle → boot/error orb shading (pre-daemon-bridge).
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

        // NOTE: `.faeAssistantGenerating`, `.faeAudioLevel`,
        // `.faeDaemonAudioLevel`, and `.faeDaemonAudioEnded` are deliberately
        // NOT observed here anymore — the Rust orb host derives the orb's
        // thinking/speaking/idle mode from the daemon event stream itself
        // (orb_state.rs grace-hold state machine). Re-adding them would
        // re-introduce the measured thinking↔idle / speaking↔idle flicker and
        // violate the no-Swift-orb-drive principle.
    }

    // MARK: - Orb State Handler (palette / feeling only)

    private func enforcePalette() {
        if isRescueMode {
            orbState?.palette = .silverMist
        }
    }

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
            // Palette/feeling only. We deliberately do NOT act on a `mode` key
            // here — the orb host owns the mode now.
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

        default:
            // urgency_set and flash — no persistent OrbStateController change needed;
            // these are transient effects handled by the orb animation layer.
            break
        }
        enforcePalette()
    }

    // MARK: - Runtime State Handler (boot/error feeling only)

    private func handleRuntimeState(event: String) {
        // Orb-host-owns-state: runtime lifecycle NO LONGER drives orb mode — the
        // orb host owns thinking/speaking/quiescent. We keep only the error
        // feeling (concern) so a runtime failure still shades the orb before
        // the daemon bridge is up. Mode transitions on boot are left to the
        // host once it connects.
        guard let orbState, event == "runtime.error" else { return }
        orbState.feeling = .concern
        enforcePalette()
    }

    // MARK: - Pipeline State Handler (listening / PTT only)

    private func handlePipelineState(event: String, payload: [String: Any]) {
        guard let orbState else { return }

        switch event {
        case "pipeline.mic_status":
            let active = payload["active"] as? Bool ?? false
            if active {
                // Microphone opened → listening (Swift still owns PTT capture).
                if orbState.mode == .idle {
                    orbState.mode = .listening
                }
            } else {
                // Microphone closed → back to idle if we were listening.
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
                if orbState.mode == .listening {
                    orbState.mode = .idle
                }
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
