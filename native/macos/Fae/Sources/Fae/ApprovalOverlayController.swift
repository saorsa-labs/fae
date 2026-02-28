import Foundation

/// Manages the tool-approval overlay lifecycle.
///
/// When the Rust backend emits `"approval.requested"`, `BackendEventRouter`
/// translates it into `.faeApprovalRequested`. This controller observes that
/// notification and exposes the active request as a published property so the
/// SwiftUI overlay can display Yes/No buttons.
///
/// Approval can be resolved three ways:
/// 1. **Voice** — the coordinator parses "yes"/"no" and emits `"approval.resolved"`.
/// 2. **Button** — the user taps Yes/No in the overlay, which posts `.faeApprovalRespond`.
/// 3. **Timeout** — the coordinator auto-denies after 58s and emits `"approval.resolved"`.
///
/// In all cases, `.faeApprovalResolved` dismisses the overlay.
@MainActor
final class ApprovalOverlayController: ObservableObject {

    /// The currently active approval request, if any.
    @Published var activeApproval: ApprovalRequest?

    /// A pending tool-approval request.
    struct ApprovalRequest: Identifiable {
        /// Unique request identifier (matches backend `request_id`).
        let id: UInt64
        /// Name of the tool requesting approval (e.g. "bash", "write").
        let toolName: String
        /// Human-readable description of the tool action.
        let description: String
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
            userInfo: ["request_id": String(request.id), "approved": true]
        )
        activeApproval = nil
    }

    /// Deny the active request (button tap).
    func deny() {
        guard let request = activeApproval else { return }
        NotificationCenter.default.post(
            name: .faeApprovalRespond,
            object: nil,
            userInfo: ["request_id": String(request.id), "approved": false]
        )
        activeApproval = nil
    }

    // MARK: - Private

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
