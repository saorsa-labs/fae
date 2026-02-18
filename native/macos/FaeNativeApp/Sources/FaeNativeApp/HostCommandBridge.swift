import Foundation

/// Protocol for sending host commands to the Rust backend.
/// Adopt this protocol to provide a concrete transport (e.g. stdin/stdout JSON,
/// Unix socket, XPC) when the backend process is wired up.
protocol HostCommandSender: AnyObject {
    func sendCommand(name: String, payload: [String: Any])
}

/// Observes conversation notifications from the UI layer and forwards them as
/// host commands. When no backend is connected (`sender` is nil), commands are
/// logged so they remain observable in Console.app during development.
@MainActor
final class HostCommandBridge: ObservableObject {
    weak var sender: HostCommandSender?

    private var observations: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observations.append(
            center.addObserver(
                forName: .faeConversationInjectText,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let text = notification.userInfo?["text"] as? String else { return }
                Task { @MainActor in
                    self?.dispatch("conversation.inject_text", payload: ["text": text])
                }
            }
        )
        observations.append(
            center.addObserver(
                forName: .faeConversationGateSet,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let active = notification.userInfo?["active"] as? Bool else { return }
                Task { @MainActor in
                    self?.dispatch("conversation.gate_set", payload: ["active": active])
                }
            }
        )
        observations.append(
            center.addObserver(
                forName: .faeOnboardingAdvance,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.dispatch("onboarding.advance", payload: [:])
                }
            }
        )
        observations.append(
            center.addObserver(
                forName: .faeOnboardingComplete,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.dispatch("onboarding.complete", payload: [:])
                }
            }
        )
        observations.append(
            center.addObserver(
                forName: .faeConversationLinkDetected,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let url = notification.userInfo?["url"] as? String else { return }
                Task { @MainActor in
                    self?.dispatch("conversation.link_detected", payload: ["url": url])
                }
            }
        )
        observations.append(
            center.addObserver(
                forName: .faeCapabilityGranted,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let capability = notification.userInfo?["capability"] as? String else {
                    return
                }
                Task { @MainActor in
                    self?.dispatch("capability.grant", payload: ["capability": capability])
                }
            }
        )
        observations.append(
            center.addObserver(
                forName: .faeCapabilityDenied,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let capability = notification.userInfo?["capability"] as? String else {
                    return
                }
                Task { @MainActor in
                    self?.dispatch("capability.deny", payload: ["capability": capability])
                }
            }
        )
    }

    deinit {
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
        }
    }

    private func dispatch(_ name: String, payload: [String: Any]) {
        if let sender {
            sender.sendCommand(name: name, payload: payload)
        } else {
            NSLog("HostCommandBridge: no backend connected, dropped %@", name)
        }
    }
}
