import Foundation

/// Manages the text-input request and governance overlay lifecycle.
///
/// For text-input requests, `.faeInputRequired` shows the input card and the user
/// submitting or cancelling posts `.faeInputResponse` back to `PipelineCoordinator`.
///
/// For tool-mode upgrade prompts (enrollment, read-only mode), `.faeToolModeUpgradeRequested`
/// shows the tool mode card.
///
/// For governance confirmations, `.faeGovernanceConfirmationRequested` shows a simple
/// confirm/cancel card.
@MainActor
final class InputOverlayController: ObservableObject {

    /// The currently active input request, if any.
    @Published var activeInput: InputRequest?

    /// The currently active tool-mode upgrade request, if any.
    @Published var activeToolModeRequest: ToolModeRequest?

    /// The currently active governance confirmation request, if any.
    @Published var activeGovernanceConfirmation: GovernanceConfirmationRequest?

    struct InputField: Identifiable {
        let id: String
        let label: String
        let placeholder: String
        let isSecure: Bool
        let required: Bool
        let minLength: Int?
        let maxLength: Int?
        let regex: String?
        let allowedValues: [String]?
        let mustBeHttps: Bool
        /// When true, show a multi-line text editor instead of a single-line field.
        var isMultiline: Bool = false
    }

    /// A pending tool-mode upgrade request from the pipeline.
    struct ToolModeRequest: Identifiable {
        let id: String
        /// Why tools are blocked: "toolMode=off", "owner_enrollment_required",
        /// "non-owner", or "tool_not_called".
        let reason: String
    }

    struct GovernanceConfirmationRequest: Identifiable {
        let id: String
        let title: String
        let message: String
        let confirmLabel: String
    }

    /// A pending input request from the LLM.
    struct InputRequest: Identifiable {
        /// Unique request identifier (UUID string).
        let id: String
        /// Card title shown in the header.
        let title: String
        /// Prompt text shown above the field(s).
        let prompt: String
        /// One or more input fields.
        let fields: [InputField]

        var isForm: Bool {
            fields.count > 1 || (fields.first?.id != "text")
        }
    }

    private var observations: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default

        observations.append(
            center.addObserver(
                forName: .faeInputRequired,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    self?.handleInputRequired(notification.userInfo ?? [:])
                }
            }
        )

        // Tool-mode upgrade requested by pipeline.
        observations.append(
            center.addObserver(
                forName: .faeToolModeUpgradeRequested,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    self?.handleToolModeUpgradeRequested(notification.userInfo ?? [:])
                }
            }
        )

        // Dismiss tool-mode popup when mode changes externally.
        observations.append(
            center.addObserver(
                forName: .faeToolModeUpgradeDismiss,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.activeToolModeRequest = nil
                }
            }
        )

        observations.append(
            center.addObserver(
                forName: .faeGovernanceConfirmationRequested,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    self?.handleGovernanceConfirmationRequested(notification.userInfo ?? [:])
                }
            }
        )

        observations.append(
            center.addObserver(
                forName: .faeGovernanceConfirmationRespond,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let requestID = notification.userInfo?["request_id"] as? String ?? ""
                Task { @MainActor in
                    if self?.activeGovernanceConfirmation?.id == requestID {
                        self?.activeGovernanceConfirmation = nil
                    }
                }
            }
        )

        // Dismiss the input card when the pipeline resolves the request (timeout or
        // double-resolution guard). Normal submit/cancel paths dismiss via their actions.
        observations.append(
            center.addObserver(
                forName: .faeInputResponse,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                let requestId = notification.userInfo?["request_id"] as? String ?? ""
                Task { @MainActor in
                    // Only clear if this response belongs to the currently displayed request.
                    if self.activeInput?.id == requestId {
                        self.activeInput = nil
                    }
                }
            }
        )
    }

    deinit {
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
        }
    }

    // MARK: - Input Actions

    /// Submit text input from the user (field return or button tap).
    func submitInput(text: String) {
        guard let request = activeInput else { return }
        NotificationCenter.default.post(
            name: .faeInputResponse,
            object: nil,
            userInfo: ["request_id": request.id, "text": text]
        )
        activeInput = nil
    }

    /// Submit form input values from the user.
    func submitForm(values: [String: String]) {
        guard let request = activeInput else { return }
        NotificationCenter.default.post(
            name: .faeInputResponse,
            object: nil,
            userInfo: ["request_id": request.id, "form_values": values]
        )
        activeInput = nil
    }

    /// Cancel/dismiss the input request (Escape key or Cancel button).
    func cancelInput() {
        guard let request = activeInput else { return }
        NotificationCenter.default.post(
            name: .faeInputResponse,
            object: nil,
            userInfo: ["request_id": request.id, "text": ""]
        )
        activeInput = nil
    }

    // MARK: - Tool Mode Actions

    /// User chose to upgrade tool mode (e.g. "Read-Only" or "Full Access").
    func upgradeToolMode(_ mode: String) {
        NotificationCenter.default.post(
            name: .faeToolModeUpgradeRespond,
            object: nil,
            userInfo: ["action": "set_mode", "mode": mode]
        )
        activeToolModeRequest = nil
    }

    /// User chose to start voice enrollment from the tool-mode popup.
    func requestEnrollment() {
        NotificationCenter.default.post(
            name: .faeToolModeUpgradeRespond,
            object: nil,
            userInfo: ["action": "start_enrollment"]
        )
        activeToolModeRequest = nil
    }

    /// User chose to open settings from the tool-mode popup.
    func openSettingsFromToolMode() {
        NotificationCenter.default.post(
            name: .faeToolModeUpgradeRespond,
            object: nil,
            userInfo: ["action": "open_settings"]
        )
        activeToolModeRequest = nil
    }

    /// Dismiss the tool-mode popup without taking action.
    func dismissToolModeRequest() {
        activeToolModeRequest = nil
    }

    // MARK: - Governance Actions

    func confirmGovernanceRequest() {
        guard let request = activeGovernanceConfirmation else { return }
        NotificationCenter.default.post(
            name: .faeGovernanceConfirmationRespond,
            object: nil,
            userInfo: ["request_id": request.id, "approved": true]
        )
        activeGovernanceConfirmation = nil
    }

    func denyGovernanceRequest() {
        guard let request = activeGovernanceConfirmation else { return }
        NotificationCenter.default.post(
            name: .faeGovernanceConfirmationRespond,
            object: nil,
            userInfo: ["request_id": request.id, "approved": false]
        )
        activeGovernanceConfirmation = nil
    }

    // MARK: - Private

    private func handleInputRequired(_ info: [AnyHashable: Any]) {
        let requestId = info["request_id"] as? String ?? UUID().uuidString
        let mode = (info["mode"] as? String ?? "text").lowercased()
        let title = info["title"] as? String ?? "Fae needs your input"
        let prompt = info["prompt"] as? String ?? "Input required"

        let fields: [InputField]
        let isMultiline = info["is_multiline"] as? Bool ?? false

        if mode == "form", let rawFields = info["fields"] as? [[String: Any]], !rawFields.isEmpty {
            fields = rawFields.compactMap { field in
                guard let id = field["id"] as? String, !id.isEmpty else { return nil }
                let label = field["label"] as? String ?? id
                let placeholder = field["placeholder"] as? String ?? ""
                let isSecure = field["is_secure"] as? Bool ?? false
                let required = field["required"] as? Bool ?? true
                let minLength = field["min_length"] as? Int
                let maxLength = field["max_length"] as? Int
                let regex = field["regex"] as? String
                let allowedValues = field["allowed_values"] as? [String]
                let mustBeHttps = field["must_be_https"] as? Bool ?? false
                let fieldMultiline = field["is_multiline"] as? Bool ?? isMultiline
                return InputField(
                    id: id,
                    label: label,
                    placeholder: placeholder,
                    isSecure: isSecure,
                    required: required,
                    minLength: minLength,
                    maxLength: maxLength,
                    regex: regex,
                    allowedValues: allowedValues,
                    mustBeHttps: mustBeHttps,
                    isMultiline: fieldMultiline
                )
            }
        } else {
            let placeholder = info["placeholder"] as? String ?? ""
            let isSecure = info["is_secure"] as? Bool ?? false
            fields = [
                InputField(
                    id: "text",
                    label: "Value",
                    placeholder: placeholder,
                    isSecure: isSecure,
                    required: true,
                    minLength: nil,
                    maxLength: nil,
                    regex: nil,
                    allowedValues: nil,
                    mustBeHttps: false,
                    isMultiline: isMultiline
                )
            ]
        }

        activeInput = InputRequest(
            id: requestId,
            title: title,
            prompt: prompt,
            fields: fields
        )
    }

    private func handleToolModeUpgradeRequested(_ info: [AnyHashable: Any]) {
        // Don't pile on — one at a time. If a popup is already showing, skip.
        guard activeToolModeRequest == nil else { return }
        let reason = info["reason"] as? String ?? "unknown"
        activeToolModeRequest = ToolModeRequest(
            id: UUID().uuidString,
            reason: reason
        )
    }

    private func handleGovernanceConfirmationRequested(_ info: [AnyHashable: Any]) {
        guard activeGovernanceConfirmation == nil else { return }
        let requestID = info["request_id"] as? String ?? UUID().uuidString
        let title = info["title"] as? String ?? "Confirm change"
        let message = info["message"] as? String ?? "Apply this change now?"
        let confirmLabel = info["confirm_label"] as? String ?? "Confirm"
        activeGovernanceConfirmation = GovernanceConfirmationRequest(
            id: requestID,
            title: title,
            message: message,
            confirmLabel: confirmLabel
        )
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let faeGovernanceConfirmationRequested = Notification.Name("faeGovernanceConfirmationRequested")
    static let faeGovernanceConfirmationRespond = Notification.Name("faeGovernanceConfirmationRespond")
}
