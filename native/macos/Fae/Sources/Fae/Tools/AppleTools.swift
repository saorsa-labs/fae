@preconcurrency import Contacts
import EventKit
import Foundation

// MARK: - EventKit Authorization Helper

/// Check EventKit authorization, handling the macOS 14+ API change.
private func isEventKitAuthorized(for entityType: EKEntityType) -> Bool {
    let status = EKEventStore.authorizationStatus(for: entityType)
    if #available(macOS 14.0, *) {
        return status == .fullAccess
    } else {
        return status == .authorized
    }
}

// MARK: - Permission Gate

/// Single-fire flag used to prevent double-resumption of `withCheckedContinuation`.
private final class ResumeOnce {
    var fired = false
}

/// Requests a JIT permission via `NotificationCenter` and awaits the grant/deny response.
///
/// Posts `.faeCapabilityRequested` so `JitPermissionController` triggers the native
/// macOS permission dialog, then listens for `.faeCapabilityGranted` or
/// `.faeCapabilityDenied`. Returns `true` if granted within 30 seconds.
private func requestPermission(capability: String) async -> Bool {
    await withCheckedContinuation { continuation in
        let center = NotificationCenter.default
        var grantedObserver: NSObjectProtocol?
        var deniedObserver: NSObjectProtocol?
        var timerItem: DispatchWorkItem?
        let once = ResumeOnce()

        func cleanup() {
            if let obs = grantedObserver { center.removeObserver(obs) }
            if let obs = deniedObserver { center.removeObserver(obs) }
            timerItem?.cancel()
        }

        func finish(_ result: Bool) {
            guard !once.fired else { return }
            once.fired = true
            cleanup()
            continuation.resume(returning: result)
        }

        grantedObserver = center.addObserver(
            forName: .faeCapabilityGranted, object: nil, queue: .main
        ) { notification in
            guard let cap = notification.userInfo?["capability"] as? String,
                  cap == capability else { return }
            finish(true)
        }

        deniedObserver = center.addObserver(
            forName: .faeCapabilityDenied, object: nil, queue: .main
        ) { notification in
            guard let cap = notification.userInfo?["capability"] as? String,
                  cap == capability else { return }
            finish(false)
        }

        let timeout = DispatchWorkItem { finish(false) }
        timerItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)

        center.post(
            name: .faeCapabilityRequested,
            object: nil,
            userInfo: ["capability": capability]
        )
    }
}

/// Returns `true` if an AppleScript error message indicates a missing Automation permission.
private func isAppleScriptPermissionError(_ message: String) -> Bool {
    message.contains("Automation permission") || message.contains("not allowed") || message.contains("permission")
}

// MARK: - Calendar Tool

/// Fae tool for reading macOS Calendar events via EventKit.
///
/// Supports listing today's events, the next 7 days, a specific date, or searching
/// by keyword across a ±1–3 month window. Event creation is gated behind approval.
/// Requires Full Access calendar permission (System Settings > Privacy > Calendars).
struct CalendarTool: Tool {
    let name = "calendar"
    let description = "Access macOS Calendar events. Actions: list_today, list_week, list_date, create, search."
    let parametersSchema = """
        {"action": "string (required: list_today|list_week|list_date|create|search)", \
        "query": "string (for search)", \
        "date": "string YYYY-MM-DD (for list_date)", \
        "title": "string (for create)", \
        "start_date": "string ISO8601 (for create)", \
        "end_date": "string ISO8601 (for create)"}
        """
    var requiresApproval: Bool { false }
    var riskLevel: ToolRiskLevel { .low }
    let example = #"<tool_call>{"name":"calendar","arguments":{"action":"list_today"}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        let store = EKEventStore()

        if !isEventKitAuthorized(for: .event) {
            guard await requestPermission(capability: "calendar") else {
                return .error("I need calendar access to do that. You can grant it in System Settings > Privacy & Security.")
            }
        }

        guard let action = input["action"] as? String else {
            return .error("Missing required parameter: action")
        }

        switch action {
        case "list_today":
            let start = Calendar.current.startOfDay(for: Date())
            guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else {
                return .error("Failed to compute date range.")
            }
            return listEvents(store: store, start: start, end: end)

        case "list_week":
            let start = Calendar.current.startOfDay(for: Date())
            guard let end = Calendar.current.date(byAdding: .day, value: 7, to: start) else {
                return .error("Failed to compute date range.")
            }
            return listEvents(store: store, start: start, end: end)

        case "list_date":
            guard let dateStr = input["date"] as? String else {
                return .error("Missing required parameter: date (YYYY-MM-DD)")
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            guard let date = formatter.date(from: dateStr) else {
                return .error("Invalid date format. Use YYYY-MM-DD.")
            }
            let start = Calendar.current.startOfDay(for: date)
            guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else {
                return .error("Failed to compute date range.")
            }
            return listEvents(store: store, start: start, end: end)

        case "search":
            guard let query = input["query"] as? String, !query.isEmpty else {
                return .error("Missing required parameter: query")
            }
            guard let start = Calendar.current.date(byAdding: .month, value: -1, to: Date()),
                  let end = Calendar.current.date(byAdding: .month, value: 3, to: Date())
            else {
                return .error("Failed to compute date range.")
            }
            return searchEvents(store: store, query: query, start: start, end: end)

        case "create":
            guard let title = input["title"] as? String, !title.isEmpty else {
                return .error("Missing required parameter: title")
            }
            return .error("Creating calendar events requires approval. Please confirm you'd like me to create '\(title)'.")

        default:
            return .error("Unknown action: \(action). Use list_today, list_week, list_date, create, or search.")
        }
    }

    private func listEvents(store: EKEventStore, start: Date, end: Date) -> ToolResult {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }

        if events.isEmpty {
            return .success("No events found for that period.")
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        let lines = events.prefix(20).map { event in
            let time = event.isAllDay ? "All day" : formatter.string(from: event.startDate)
            let title = event.title ?? "(no title)"
            return "- \(time): \(title)"
        }

        let header = events.count > 20 ? "Showing 20 of \(events.count) events:" : "\(events.count) events:"
        return .success(header + "\n" + lines.joined(separator: "\n"))
    }

    private func searchEvents(store: EKEventStore, query: String, start: Date, end: Date) -> ToolResult {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { ($0.title ?? "").localizedCaseInsensitiveContains(query) }
            .sorted { $0.startDate < $1.startDate }

        if events.isEmpty {
            return .success("No events matching '\(query)' found.")
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let lines = events.prefix(10).map { event in
            let time = event.isAllDay ? "All day" : formatter.string(from: event.startDate)
            return "- \(time): \(event.title ?? "(no title)")"
        }

        return .success("Found \(events.count) events matching '\(query)':\n" + lines.joined(separator: "\n"))
    }
}

// MARK: - Reminders Tool

/// Fae tool for reading macOS Reminders via EventKit.
///
/// Supports listing incomplete reminders and searching by keyword. Creating and
/// completing reminders is gated behind approval to prevent accidental modifications.
/// Requires Reminders permission (System Settings > Privacy > Reminders).
struct RemindersTool: Tool {
    let name = "reminders"
    let description = "Access macOS Reminders. Actions: list_incomplete, create, complete, search."
    let parametersSchema = """
        {"action": "string (required: list_incomplete|create|complete|search)", \
        "title": "string (for create)", \
        "query": "string (for search)", \
        "reminder_id": "string (for complete)"}
        """
    var requiresApproval: Bool { false }
    var riskLevel: ToolRiskLevel { .low }
    let example = #"<tool_call>{"name":"reminders","arguments":{"action":"list_incomplete"}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        let store = EKEventStore()

        if !isEventKitAuthorized(for: .reminder) {
            guard await requestPermission(capability: "reminders") else {
                return .error("I need reminders access to do that. You can grant it in System Settings > Privacy & Security.")
            }
        }

        guard let action = input["action"] as? String else {
            return .error("Missing required parameter: action")
        }

        switch action {
        case "list_incomplete":
            return await listIncomplete(store: store)

        case "search":
            guard let query = input["query"] as? String, !query.isEmpty else {
                return .error("Missing required parameter: query")
            }
            return await searchReminders(store: store, query: query)

        case "create":
            guard let title = input["title"] as? String, !title.isEmpty else {
                return .error("Missing required parameter: title")
            }
            return .error("Creating reminders requires approval. Please confirm you'd like me to create '\(title)'.")

        case "complete":
            return .error("Completing reminders requires approval. Please confirm.")

        default:
            return .error("Unknown action: \(action). Use list_incomplete, create, complete, or search.")
        }
    }

    private func listIncomplete(store: EKEventStore) async -> ToolResult {
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        let reminders = await withCheckedContinuation { (continuation: CheckedContinuation<[EKReminder]?, Never>) in
            store.fetchReminders(matching: predicate) { result in
                continuation.resume(returning: result)
            }
        }

        guard let reminders, !reminders.isEmpty else {
            return .success("No incomplete reminders found.")
        }

        let lines = reminders.prefix(20).map { reminder in
            let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            let dueStr = due.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .none) } ?? ""
            let title = reminder.title ?? "(no title)"
            return dueStr.isEmpty ? "- \(title)" : "- \(title) (due: \(dueStr))"
        }

        return .success("\(reminders.count) incomplete reminders:\n" + lines.joined(separator: "\n"))
    }

    private func searchReminders(store: EKEventStore, query: String) async -> ToolResult {
        let predicate = store.predicateForReminders(in: nil)
        let reminders = await withCheckedContinuation { (continuation: CheckedContinuation<[EKReminder]?, Never>) in
            store.fetchReminders(matching: predicate) { result in
                continuation.resume(returning: result)
            }
        }

        guard let reminders else {
            return .success("No reminders found.")
        }

        let matches = reminders.filter { ($0.title ?? "").localizedCaseInsensitiveContains(query) }
        if matches.isEmpty {
            return .success("No reminders matching '\(query)' found.")
        }

        let lines = matches.prefix(10).map { reminder in
            let status = reminder.isCompleted ? "done" : "pending"
            return "- [\(status)] \(reminder.title ?? "(no title)")"
        }

        return .success("Found \(matches.count) reminders matching '\(query)':\n" + lines.joined(separator: "\n"))
    }
}

// MARK: - Contacts Tool

/// Fae tool for searching macOS Contacts via CNContactStore.
///
/// Supports full-name search, phone number lookup, and email lookup.
/// Returns up to 10 matching contacts per query.
/// Requires Contacts permission (System Settings > Privacy > Contacts).
struct ContactsTool: Tool {
    let name = "contacts"
    let description = "Search macOS Contacts. Actions: search, get_phone, get_email."
    let parametersSchema = """
        {"action": "string (required: search|get_phone|get_email)", \
        "query": "string (required)"}
        """
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .low
    let example = #"<tool_call>{"name":"contacts","arguments":{"action":"search","query":"Sarah"}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        if CNContactStore.authorizationStatus(for: .contacts) != .authorized {
            guard await requestPermission(capability: "contacts") else {
                return .error("I need contacts access to do that. You can grant it in System Settings > Privacy & Security.")
            }
        }

        guard let action = input["action"] as? String else {
            return .error("Missing required parameter: action")
        }
        guard let query = input["query"] as? String, !query.isEmpty else {
            return .error("Missing required parameter: query")
        }

        let store = CNContactStore()
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]

        let predicate = CNContact.predicateForContacts(matchingName: query)

        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)

            if contacts.isEmpty {
                return .success("No contacts found matching '\(query)'.")
            }

            switch action {
            case "search":
                let lines = contacts.prefix(10).map { contact in
                    let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                    let email = contact.emailAddresses.first.map { $0.value as String } ?? ""
                    let phone = contact.phoneNumbers.first?.value.stringValue ?? ""
                    var parts = [name]
                    if !email.isEmpty { parts.append(email) }
                    if !phone.isEmpty { parts.append(phone) }
                    return "- " + parts.joined(separator: " | ")
                }
                return .success("Found \(contacts.count) contacts:\n" + lines.joined(separator: "\n"))

            case "get_phone":
                let results = contacts.compactMap { contact -> String? in
                    guard let phone = contact.phoneNumbers.first?.value.stringValue else { return nil }
                    let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                    return "\(name): \(phone)"
                }
                if results.isEmpty {
                    return .success("No phone numbers found for '\(query)'.")
                }
                return .success(results.joined(separator: "\n"))

            case "get_email":
                let results = contacts.compactMap { contact -> String? in
                    guard let email = contact.emailAddresses.first else { return nil }
                    let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                    return "\(name): \(email.value as String)"
                }
                if results.isEmpty {
                    return .success("No email addresses found for '\(query)'.")
                }
                return .success(results.joined(separator: "\n"))

            default:
                return .error("Unknown action: \(action). Use search, get_phone, or get_email.")
            }
        } catch {
            return .error("Contacts search failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Mail Tool

/// Fae tool for reading macOS Mail via AppleScript.
///
/// Returns the most recent messages from the inbox (subject, sender, date).
/// Capped at 20 messages. Read-only — sending mail is not supported.
/// Requires Automation permission for Mail (System Settings > Privacy > Automation).
struct MailTool: Tool {
    let name = "mail"
    let description = "Interact with macOS Mail. Actions: check_inbox, read_recent."
    let parametersSchema = """
        {"action": "string (required: check_inbox|read_recent)", \
        "count": "int (optional, default 5)"}
        """
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .low
    let example = #"<tool_call>{"name":"mail","arguments":{"action":"check_inbox","count":5}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let action = input["action"] as? String else {
            return .error("Missing required parameter: action")
        }

        switch action {
        case "check_inbox", "read_recent":
            let count = input["count"] as? Int ?? 5
            let firstAttempt = runMailScript(count: min(count, 20))
            if firstAttempt.isError, isAppleScriptPermissionError(firstAttempt.output) {
                guard await requestPermission(capability: "mail") else {
                    return .error("I need Mail access to do that. You can grant it in System Settings > Privacy & Security.")
                }
                return runMailScript(count: min(count, 20))
            }
            return firstAttempt

        default:
            return .error("Unknown action: \(action). Use check_inbox or read_recent.")
        }
    }

    private func runMailScript(count: Int) -> ToolResult {
        let script = """
            tell application "Mail"
                set msgs to messages 1 through \(count) of inbox
                set output to ""
                repeat with m in msgs
                    set subj to subject of m
                    set sndr to sender of m
                    set d to date received of m
                    set output to output & "- " & (d as string) & " | " & sndr & " | " & subj & linefeed
                end repeat
                return output
            end tell
            """

        guard let appleScript = NSAppleScript(source: script) else {
            return .error("Failed to create AppleScript.")
        }

        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)

        if let error = errorInfo {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            if message.contains("not allowed") || message.contains("permission") {
                return .error("Mail access requires Automation permission. Please grant it in System Settings > Privacy & Security > Automation.")
            }
            return .error("Mail error: \(message)")
        }

        let output = result.stringValue ?? "No messages found."
        return .success(output.isEmpty ? "No messages found." : output)
    }
}

// MARK: - Notes Tool

/// Fae tool for reading macOS Notes via AppleScript.
///
/// Supports listing recent note titles and searching by keyword within note names.
/// Returns up to 20 recent notes or 10 search matches. Read-only — creating or
/// editing notes is not supported.
/// Requires Automation permission for Notes (System Settings > Privacy > Automation).
struct NotesTool: Tool {
    let name = "notes"
    let description = "Interact with macOS Notes. Actions: search, list_recent."
    let parametersSchema = """
        {"action": "string (required: search|list_recent)", \
        "query": "string (for search)", \
        "count": "int (optional, default 5)"}
        """
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .low
    let example = #"<tool_call>{"name":"notes","arguments":{"action":"search","query":"meeting notes"}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let action = input["action"] as? String else {
            return .error("Missing required parameter: action")
        }

        switch action {
        case "list_recent":
            let count = input["count"] as? Int ?? 5
            let firstAttempt = runNotesListScript(count: min(count, 20))
            if firstAttempt.isError, isAppleScriptPermissionError(firstAttempt.output) {
                guard await requestPermission(capability: "notes") else {
                    return .error("I need Notes access to do that. You can grant it in System Settings > Privacy & Security.")
                }
                return runNotesListScript(count: min(count, 20))
            }
            return firstAttempt

        case "search":
            guard let query = input["query"] as? String, !query.isEmpty else {
                return .error("Missing required parameter: query")
            }
            let sanitized = sanitizeForAppleScript(query)
            let firstAttempt = runNotesSearchScript(query: sanitized)
            if firstAttempt.isError, isAppleScriptPermissionError(firstAttempt.output) {
                guard await requestPermission(capability: "notes") else {
                    return .error("I need Notes access to do that. You can grant it in System Settings > Privacy & Security.")
                }
                return runNotesSearchScript(query: sanitized)
            }
            return firstAttempt

        default:
            return .error("Unknown action: \(action). Use search or list_recent.")
        }
    }

    private func runNotesListScript(count: Int) -> ToolResult {
        let script = """
            tell application "Notes"
                set noteList to notes 1 through \(count) of default account
                set output to ""
                repeat with n in noteList
                    set output to output & "- " & (name of n) & linefeed
                end repeat
                return output
            end tell
            """

        return executeAppleScript(script)
    }

    private func runNotesSearchScript(query: String) -> ToolResult {
        let script = """
            tell application "Notes"
                set matchingNotes to notes of default account whose name contains "\(query)"
                set output to ""
                set maxCount to 10
                set idx to 0
                repeat with n in matchingNotes
                    if idx >= maxCount then exit repeat
                    set output to output & "- " & (name of n) & linefeed
                    set idx to idx + 1
                end repeat
                if output is "" then
                    return "No notes matching the search."
                end if
                return output
            end tell
            """

        return executeAppleScript(script)
    }

    private func executeAppleScript(_ source: String) -> ToolResult {
        guard let appleScript = NSAppleScript(source: source) else {
            return .error("Failed to create AppleScript.")
        }

        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)

        if let error = errorInfo {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            if message.contains("not allowed") || message.contains("permission") {
                return .error("Notes access requires Automation permission. Please grant it in System Settings > Privacy & Security > Automation.")
            }
            return .error("Notes error: \(message)")
        }

        let output = result.stringValue ?? "No results."
        return .success(output.isEmpty ? "No results." : output)
    }

    /// Sanitize user input for safe AppleScript string interpolation.
    private func sanitizeForAppleScript(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .prefix(200)
            .description
    }
}
