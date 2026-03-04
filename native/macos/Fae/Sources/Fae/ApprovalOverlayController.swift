import Foundation

/// Manages the tool-approval overlay lifecycle and text-input request lifecycle.
///
/// When the Rust backend emits `"approval.requested"`, `BackendEventRouter`
/// translates it into `.faeApprovalRequested`. This controller observes that
/// notification and exposes the active request as a published property so the
/// SwiftUI overlay can display Yes/No buttons.
///
/// Approval can be resolved via:
/// 1. **Voice** — the coordinator parses "yes"/"no"/"always" and emits `"approval.resolved"`.
/// 2. **Button** — the user taps No/Yes/Always/Approve All Read-Only/Approve All, which posts `.faeApprovalRespond`.
/// 3. **Timeout** — the coordinator auto-denies after 20s and emits `"approval.resolved"`.
///
/// In all cases, `.faeApprovalResolved` dismisses the overlay.
///
/// For text-input requests, `.faeInputRequired` shows the input card and the user
/// submitting or cancelling posts `.faeInputResponse` back to `PipelineCoordinator`.
@MainActor
final class ApprovalOverlayController: ObservableObject {

    /// The currently active approval request, if any.
    @Published var activeApproval: ApprovalRequest?

    /// The currently active input request, if any.
    @Published var activeInput: InputRequest?

    /// A pending tool-approval request.
    struct ApprovalRequest: Identifiable {
        /// Unique request identifier (matches backend `request_id`).
        let id: UInt64
        /// Name of the tool requesting approval (e.g. "bash", "write").
        let toolName: String
        /// Human-readable description of the tool action.
        let description: String
    }

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
                forName: .faeApprovalRequested,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    self?.handleRequested(notification.userInfo ?? [:])
                }
            }
        )

        observations.append(
            center.addObserver(
                forName: .faeApprovalResolved,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.activeApproval = nil
                }
            }
        )

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

    // MARK: - Actions

    /// Approve the active request (button tap).
    func approve() {
        guard let request = activeApproval else { return }
        NotificationCenter.default.post(
            name: .faeApprovalRespond,
            object: nil,
            userInfo: [
                "request_id": String(request.id),
                "approved": true,
                "decision": "yes",
            ]
        )
        activeApproval = nil
    }

    /// Deny the active request (button tap).
    func deny() {
        guard let request = activeApproval else { return }
        NotificationCenter.default.post(
            name: .faeApprovalRespond,
            object: nil,
            userInfo: [
                "request_id": String(request.id),
                "approved": false,
                "decision": "no",
            ]
        )
        activeApproval = nil
    }

    /// Approve and remember: auto-approve this tool name forever.
    func approveAlways() {
        guard let request = activeApproval else { return }
        NotificationCenter.default.post(
            name: .faeApprovalRespond,
            object: nil,
            userInfo: [
                "request_id": String(request.id),
                "approved": true,
                "decision": "always",
                "tool_name": request.toolName,
            ]
        )
        activeApproval = nil
    }

    /// Approve all low-risk (read-only) tools permanently.
    func approveAllReadOnly() {
        guard let request = activeApproval else { return }
        NotificationCenter.default.post(
            name: .faeApprovalRespond,
            object: nil,
            userInfo: [
                "request_id": String(request.id),
                "approved": true,
                "decision": "approveAllReadOnly",
            ]
        )
        activeApproval = nil
    }

    /// Approve all tools permanently (autonomous mode).
    func approveAll() {
        guard let request = activeApproval else { return }
        NotificationCenter.default.post(
            name: .faeApprovalRespond,
            object: nil,
            userInfo: [
                "request_id": String(request.id),
                "approved": true,
                "decision": "approveAll",
            ]
        )
        activeApproval = nil
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

    // MARK: - Private

    private func handleInputRequired(_ info: [AnyHashable: Any]) {
        let requestId = info["request_id"] as? String ?? UUID().uuidString
        let mode = (info["mode"] as? String ?? "text").lowercased()
        let title = info["title"] as? String ?? "Fae needs your input"
        let prompt = info["prompt"] as? String ?? "Input required"

        let fields: [InputField]
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
                    mustBeHttps: mustBeHttps
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
                    mustBeHttps: false
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

    private func handleRequested(_ info: [AnyHashable: Any]) {
        // Accept request_id as either UInt64 or Int (JSON numbers may arrive as Int).
        let requestId: UInt64
        if let id = info["request_id"] as? UInt64 {
            requestId = id
        } else if let id = info["request_id"] as? Int {
            requestId = UInt64(id)
        } else {
            return
        }

        let toolName = info["tool_name"] as? String ?? "tool"
        let description = Self.formatDescription(toolName: toolName, inputJson: info["input_json"] as? String)

        activeApproval = ApprovalRequest(
            id: requestId,
            toolName: toolName,
            description: description
        )
    }

    /// Generate a human-readable description for the overlay card.
    ///
    /// Descriptions must fit a 240px-wide card (≤2 lines at 13pt).
    private static func formatDescription(toolName: String, inputJson: String?) -> String {
        let obj: [String: Any]?
        if let json = inputJson,
           let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = parsed
        } else {
            obj = nil
        }

        switch toolName {

        // MARK: Core tools

        case "bash":
            let cmd = obj?["command"] as? String ?? "a command"
            return "Run: \(truncate(cmd, to: 60))"
        case "read":
            let path = obj?["path"] as? String ?? obj?["file_path"] as? String ?? "a file"
            return "Read: \(path)"
        case "write":
            let path = obj?["file_path"] as? String ?? obj?["path"] as? String ?? "a file"
            return "Create: \(path)"
        case "edit":
            let path = obj?["file_path"] as? String ?? obj?["path"] as? String ?? "a file"
            return "Edit: \(path)"
        case "self_config":
            return "Update Fae settings"
        case "channel_setup":
            let action = obj?["action"] as? String ?? "status"
            let channel = obj?["channel"] as? String ?? "channel"
            return "Channel setup (\(action)): \(truncate(channel, to: 30))"

        // MARK: Web tools

        case "web_search":
            let query = obj?["query"] as? String ?? "the web"
            return "Search: \(truncate(query, to: 50))"
        case "fetch_url":
            let url = obj?["url"] as? String ?? "a URL"
            return "Fetch: \(truncate(url, to: 40))"

        // MARK: Apple tools

        case "calendar":
            let action = obj?["action"] as? String
            if action == "create" {
                let title = obj?["title"] as? String ?? "an event"
                return "Add event: \(truncate(title, to: 40))"
            }
            return "Read your calendar"

        case "reminders":
            let action = obj?["action"] as? String
            if action == "create" {
                let title = obj?["title"] as? String ?? "a reminder"
                return "Add reminder: \(truncate(title, to: 40))"
            } else if action == "complete" {
                let title = obj?["title"] as? String ?? "a reminder"
                return "Complete: \(truncate(title, to: 40))"
            }
            return "Read your reminders"

        case "contacts":
            let action = obj?["action"] as? String
            if action == "search" {
                let query = obj?["query"] as? String ?? obj?["name"] as? String ?? "contacts"
                return "Search contacts: \(truncate(query, to: 30))"
            } else if action == "get_phone" || action == "get_email" {
                let name = obj?["name"] as? String ?? "a contact"
                return "Look up: \(truncate(name, to: 40))"
            }
            return "Access contacts"

        case "mail":
            let action = obj?["action"] as? String
            if action == "check_inbox" || action == "read_recent" {
                return "Read recent emails"
            }
            return "Access mail"

        case "notes":
            let action = obj?["action"] as? String
            if action == "search" {
                let query = obj?["query"] as? String ?? "notes"
                return "Search notes: \(truncate(query, to: 40))"
            } else if action == "list_recent" {
                return "Read recent notes"
            }
            return "Access notes"

        // MARK: Scheduler tools

        case "scheduler_list":
            return "List schedules"
        case "scheduler_create":
            let name = obj?["name"] as? String ?? "a task"
            return "Schedule: \(truncate(name, to: 40))"
        case "scheduler_update":
            let name = obj?["name"] as? String ?? "a task"
            return "Update schedule: \(truncate(name, to: 30))"
        case "scheduler_delete":
            let name = obj?["name"] as? String ?? "a task"
            return "Delete schedule: \(truncate(name, to: 30))"
        case "scheduler_trigger":
            let name = obj?["name"] as? String ?? "a task"
            return "Run: \(truncate(name, to: 40))"

        // MARK: Roleplay

        case "roleplay":
            return "Start roleplay session"

        // MARK: Other

        case "desktop", "desktop_automation":
            return "Desktop automation"
        case "python_skill":
            return "Run Python skill"
        default:
            return "Use \(toolName)"
        }
    }

    /// Truncate a string to a maximum length, appending "..." if trimmed.
    private static func truncate(_ text: String, to maxLength: Int) -> String {
        if text.count > maxLength {
            return String(text.prefix(maxLength)) + "..."
        }
        return text
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted by `ApprovalOverlayController` (or keyboard shortcut) to send
    /// a button-based approval response to the backend.
    ///
    /// userInfo keys:
    /// - `request_id` — the approval request identifier
    /// - `approved: Bool` — whether the tool was approved
    static let faeApprovalRespond = Notification.Name("faeApprovalRespond")
}
