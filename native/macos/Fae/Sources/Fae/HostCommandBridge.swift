import AppKit
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
                forName: .faeConversationEngage,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.dispatch("conversation.engage", payload: [:])
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
                forName: .faeOnboardingSetUserName,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let name = notification.userInfo?["name"] as? String else { return }
                Task { @MainActor in
                    self?.dispatch("onboarding.set_user_name", payload: ["name": name])
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
                forName: .faeOnboardingSetContactInfo,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                var payload: [String: Any] = [:]
                if let email = notification.userInfo?["email"] as? String {
                    payload["email"] = email
                }
                if let phone = notification.userInfo?["phone"] as? String {
                    payload["phone"] = phone
                }
                Task { @MainActor in
                    self?.dispatch("onboarding.set_contact_info", payload: payload)
                }
            }
        )
        observations.append(
            center.addObserver(
                forName: .faeOnboardingSetFamilyInfo,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let relations = notification.userInfo?["relations"] as? [[String: String]] else {
                    return
                }
                Task { @MainActor in
                    self?.dispatch("onboarding.set_family_info", payload: ["relations": relations])
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
        observations.append(
            center.addObserver(
                forName: .faeApprovalRespond,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let requestId = notification.userInfo?["request_id"],
                      let approved = notification.userInfo?["approved"] as? Bool
                else { return }
                Task { @MainActor in
                    self?.dispatch(
                        "approval.respond",
                        payload: ["request_id": requestId, "approved": approved]
                    )
                }
            }
        )
        observations.append(
            center.addObserver(
                forName: .faeGovernanceActionRequested,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let action = notification.userInfo?["action"] as? String else { return }
                let source = notification.userInfo?["source"] as? String ?? "unknown"

                Task { @MainActor in
                    guard let self else { return }
                    Self.incrementAuditCounter("fae.governance.total")

                    switch action {
                    case "set_tool_mode":
                        guard let value = notification.userInfo?["value"] as? String else {
                            Self.incrementAuditCounter("fae.governance.invalid")
                            return
                        }
                        if value == "full_no_approval",
                           source.contains("canvas"),
                           !self.confirmHighRiskAction(
                               title: "Allow full autonomy without approvals?",
                               message: "Fae will be able to run high-risk tool actions without confirmation prompts."
                           )
                        {
                            Self.incrementAuditCounter("fae.governance.cancelled")
                            return
                        }
                        NSLog("HostCommandBridge: governance action set_tool_mode=%@ source=%@", value, source)
                        self.dispatch(
                            "config.patch",
                            payload: [
                                "key": "tool_mode",
                                "value": value,
                                "source": source,
                            ]
                        )
                        Self.incrementAuditCounter("fae.governance.set_tool_mode")

                    case "set_setting":
                        guard let key = notification.userInfo?["key"] as? String,
                              let rawValue = notification.userInfo?["value"]
                        else {
                            Self.incrementAuditCounter("fae.governance.invalid")
                            return
                        }

                        if self.shouldConfirmSettingMutation(key: key, value: rawValue, source: source),
                           !self.confirmHighRiskAction(
                               title: "Confirm high-impact setting change",
                               message: "Apply \(key) now? This changes Fae’s authority or identity safeguards."
                           )
                        {
                            Self.incrementAuditCounter("fae.governance.cancelled")
                            return
                        }

                        NSLog("HostCommandBridge: governance action set_setting key=%@ source=%@", key, source)
                        self.dispatch(
                            "config.patch",
                            payload: [
                                "key": key,
                                "value": rawValue,
                                "source": source,
                            ]
                        )
                        Self.incrementAuditCounter("fae.governance.set_setting")

                    case "request_permission":
                        let capability = (notification.userInfo?["capability"] as? String)
                            ?? (notification.userInfo?["value"] as? String)
                            ?? ""
                        guard !capability.isEmpty else {
                            Self.incrementAuditCounter("fae.governance.invalid")
                            return
                        }
                        NSLog("HostCommandBridge: governance action request_permission capability=%@ source=%@", capability, source)
                        NotificationCenter.default.post(
                            name: .faeCapabilityRequested,
                            object: nil,
                            userInfo: ["capability": capability, "reason": "governance_\(source)", "jit": true]
                        )
                        Self.incrementAuditCounter("fae.governance.request_permission")

                    case "open_settings":
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                        NSApp.activate(ignoringOtherApps: true)
                        Self.incrementAuditCounter("fae.governance.open_settings")

                    case "start_owner_enrollment":
                        self.dispatch("speaker.start_enrollment", payload: [:])
                        Self.incrementAuditCounter("fae.governance.start_owner_enrollment")

                    default:
                        NSLog("HostCommandBridge: unknown governance action '%@'", action)
                        Self.incrementAuditCounter("fae.governance.unknown")
                    }
                }
            }
        )
        observations.append(
            center.addObserver(
                forName: .faeEmergencyStop,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.dispatch("runtime.stop", payload: [:])
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
        }
    }

    private func shouldConfirmSettingMutation(key: String, value: Any, source: String) -> Bool {
        guard source.contains("canvas") else { return false }
        switch key {
        case "vision.enabled":
            return (value as? Bool) == true
        case "tts.voice_identity_lock":
            return (value as? Bool) == false
        default:
            return false
        }
    }

    private func confirmHighRiskAction(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Confirm")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func incrementAuditCounter(_ key: String) {
        let defaults = UserDefaults.standard
        let current = defaults.integer(forKey: key)
        defaults.set(current + 1, forKey: key)
    }
}
