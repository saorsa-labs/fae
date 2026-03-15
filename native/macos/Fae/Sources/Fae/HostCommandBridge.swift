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
    private struct PendingGovernanceConfirmation {
        let id: String
        let action: String
        let userInfo: [String: Any]
    }

    weak var sender: HostCommandSender?
    weak var debugConsole: DebugConsoleController?
    /// Direct reference for spoken acknowledgments (e.g., "tools enabled").
    weak var faeCore: FaeCore?

    private var observations: [NSObjectProtocol] = []
    private var pendingGovernanceConfirmations: [String: PendingGovernanceConfirmation] = [:]

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
                var payload: [String: Any] = ["request_id": requestId, "approved": approved]
                if let decision = notification.userInfo?["decision"] as? String {
                    payload["decision"] = decision
                }
                if let toolName = notification.userInfo?["tool_name"] as? String {
                    payload["tool_name"] = toolName
                }
                NSLog(
                    "HostCommandBridge: approval.respond request_id=%@ approved=%@ decision=%@ tool=%@",
                    String(describing: requestId),
                    String(describing: approved),
                    String(describing: payload["decision"]),
                    String(describing: payload["tool_name"])
                )
                Task { @MainActor in
                    self?.dispatch("approval.respond", payload: payload)
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
                let userInfo = (notification.userInfo ?? [:]).reduce(into: [String: Any]()) { partialResult, entry in
                    guard let key = entry.key as? String else { return }
                    partialResult[key] = entry.value
                }

                Task { @MainActor in
                    guard let self else { return }
                    Self.incrementAuditCounter("fae.governance.total")
                    let source = userInfo["source"] as? String ?? "unknown"
                    debugLog(self.debugConsole, .governance, "Inbound action=\(action) source=\(source)")
                    self.processGovernanceAction(
                        action: action,
                        userInfo: userInfo,
                        allowPopupConfirmation: true
                    )
                }
            }
        )
        observations.append(
            center.addObserver(
                forName: .faeGovernanceConfirmationRespond,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let requestID = notification.userInfo?["request_id"] as? String else { return }
                let approved = notification.userInfo?["approved"] as? Bool ?? false
                Task { @MainActor in
                    self?.handleGovernanceConfirmationResponse(
                        requestID: requestID,
                        approved: approved
                    )
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
        debugLog(debugConsole, .command, "Dispatch \(name) payload=\(summarizePayload(payload))")
        if let sender {
            sender.sendCommand(name: name, payload: payload)
        } else {
            debugLog(debugConsole, .pipeline, "No sender attached for command \(name)")
        }
    }

    private func processGovernanceAction(
        action: String,
        userInfo: [String: Any],
        allowPopupConfirmation: Bool
    ) {
        let source = userInfo["source"] as? String ?? "unknown"

        switch action {
        case "set_tool_mode":
            guard let value = userInfo["value"] as? String else {
                Self.incrementAuditCounter("fae.governance.invalid")
                return
            }
            // No governance confirmation needed — only two safe modes (assistant/full).

            NSLog("HostCommandBridge: governance action set_tool_mode=%@ source=%@", value, source)
            dispatch(
                "config.patch",
                payload: [
                    "key": "tool_mode",
                    "value": value,
                    "source": source,
                ]
            )
            Self.incrementAuditCounter("fae.governance.set_tool_mode")
            faeCore?.speakDirect("Got it. \(Self.toolModeLabel(value)).")

        case "set_setting":
            guard let key = userInfo["key"] as? String,
                  let rawValue = userInfo["value"]
            else {
                Self.incrementAuditCounter("fae.governance.invalid")
                return
            }

            if allowPopupConfirmation,
               shouldConfirmSettingMutation(key: key, value: rawValue, source: source)
            {
                requestGovernanceConfirmation(
                    action: action,
                    userInfo: userInfo,
                    title: "Confirm high-impact setting change",
                    message: "Apply \(key) now? This changes Fae's authority or identity safeguards.",
                    confirmLabel: "Apply Change"
                )
                return
            }

            NSLog("HostCommandBridge: governance action set_setting key=%@ source=%@", key, source)
            dispatch(
                "config.patch",
                payload: [
                    "key": key,
                    "value": rawValue,
                    "source": source,
                ]
            )
            Self.incrementAuditCounter("fae.governance.set_setting")

        case "request_permission":
            let capability = (userInfo["capability"] as? String)
                ?? (userInfo["value"] as? String)
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
            debugLog(debugConsole, .governance, "Posting faeOpenSettingsRequested from governance bridge")
            NotificationCenter.default.post(name: .faeOpenSettingsRequested, object: nil)
            Self.incrementAuditCounter("fae.governance.open_settings")

        case "start_owner_enrollment":
            dispatch("speaker.start_enrollment", payload: [:])
            Self.incrementAuditCounter("fae.governance.start_owner_enrollment")

        default:
            NSLog("HostCommandBridge: unknown governance action '%@'", action)
            Self.incrementAuditCounter("fae.governance.unknown")
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

    private func requestGovernanceConfirmation(
        action: String,
        userInfo: [String: Any],
        title: String,
        message: String,
        confirmLabel: String
    ) {
        let requestID = UUID().uuidString
        pendingGovernanceConfirmations[requestID] = PendingGovernanceConfirmation(
            id: requestID,
            action: action,
            userInfo: userInfo
        )
        NotificationCenter.default.post(
            name: .faeGovernanceConfirmationRequested,
            object: nil,
            userInfo: [
                "request_id": requestID,
                "title": title,
                "message": message,
                "confirm_label": confirmLabel,
            ]
        )
    }

    private func handleGovernanceConfirmationResponse(requestID: String, approved: Bool) {
        guard let pending = pendingGovernanceConfirmations.removeValue(forKey: requestID) else { return }
        if approved {
            processGovernanceAction(
                action: pending.action,
                userInfo: pending.userInfo,
                allowPopupConfirmation: false
            )
            return
        }

        debugLog(debugConsole, .approval, "Governance popup rejected: \(pending.action)")
        Self.incrementAuditCounter("fae.governance.cancelled")
    }

    private func summarizePayload(_ payload: [String: Any]) -> String {
        payload
            .sorted(by: { $0.key < $1.key })
            .map { key, value in "\(key)=\(String(describing: value))" }
            .joined(separator: ",")
    }

    private static func incrementAuditCounter(_ key: String) {
        let defaults = UserDefaults.standard
        let current = defaults.integer(forKey: key)
        defaults.set(current + 1, forKey: key)
    }

    /// Human-friendly label for a tool_mode value.
    private static func toolModeLabel(_ mode: String) -> String {
        switch mode {
        case "assistant":        return "Read only — search and recall only"
        case "full":             return "Everything enabled — Fae will ask before acting"
        default:                 return "Tool mode updated"
        }
    }
}
