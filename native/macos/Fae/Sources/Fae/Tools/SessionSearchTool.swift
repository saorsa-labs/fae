import Foundation

struct SessionSearchTool: Tool {
    let name = "session_search"
    let description = "Search prior local conversation sessions for what you and the user previously said."
    let parametersSchema = #"{"query": "string (required)", "limit": "integer (optional, default 5, range 1-10)", "days": "integer (optional, default 180, range 1-3650)"}"#
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .low
    let example = #"<tool_call>{"name":"session_search","arguments":{"query":"launch checklist","limit":3}}</tool_call>"#

    private let sessionStore: SessionStore?

    init(sessionStore: SessionStore?) {
        self.sessionStore = sessionStore
    }

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let rawQuery = input["query"] as? String else {
            return .error("Missing required parameter: query")
        }

        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return .error("Query must not be empty")
        }

        guard let sessionStore else {
            return .error("Session search is unavailable because the local session store is not initialized")
        }

        let limit = Self.clampInteger(input["limit"], defaultValue: 5, lower: 1, upper: 10)
        let days = Self.clampInteger(input["days"], defaultValue: 180, lower: 1, upper: 3650)
        let matches = try await sessionStore.searchSessions(query: query, limit: limit, days: days)

        guard !matches.isEmpty else {
            return .success("No matching prior conversation sessions found for \"\(query)\" in the last \(days) day(s).")
        }

        return .success(Self.format(matches: matches, query: query, days: days))
    }

    private static func clampInteger(
        _ value: Any?,
        defaultValue: Int,
        lower: Int,
        upper: Int
    ) -> Int {
        let parsed: Int?
        switch value {
        case let intValue as Int:
            parsed = intValue
        case let numberValue as NSNumber:
            parsed = numberValue.intValue
        case let stringValue as String:
            parsed = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            parsed = nil
        }

        return min(max(parsed ?? defaultValue, lower), upper)
    }

    private static func format(matches: [SessionSearchResult], query: String, days: Int) -> String {
        var lines = [
            "Found \(matches.count) matching conversation session(s) for \"\(query)\" in the last \(days) day(s)."
        ]

        for (index, match) in matches.enumerated() {
            lines.append("")
            lines.append("Session \(index + 1)")
            lines.append("id: \(match.session.id)")
            lines.append("kind: \(match.session.kind.rawValue)")
            lines.append("date: \(formatDate(match.session.lastMessageAt))")
            if let title = match.session.title, !title.isEmpty {
                lines.append("title: \(title)")
            }
            lines.append("messages: \(match.session.messageCount)")
            lines.append("matched_messages: \(match.matchedMessageCount)")
            if let summary = match.summaryText, !summary.isEmpty {
                lines.append("summary: \(summary)")
            }
            if !match.snippets.isEmpty {
                lines.append("snippets:")
                for snippet in match.snippets {
                    lines.append("- \(snippet.role.rawValue) @ \(formatDate(snippet.createdAt)): \(snippet.snippet)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
