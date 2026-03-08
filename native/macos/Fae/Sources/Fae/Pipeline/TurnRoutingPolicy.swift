import Foundation

enum TurnLLMRoute: String, Sendable {
    case operatorModel = "operator"
    case conciergeModel = "concierge"
}

struct TurnRoutingPolicy {
    private static let richResponseHints = [
        "summarize", "summarise", "summary", "explain in detail", "explain deeply",
        "brainstorm", "reflect", "reflection", "analyze", "analyse", "compare",
        "rewrite", "redraft", "polish", "improve this", "draft", "write a",
        "plan", "strategy", "synthesize", "synthesise"
    ]

    private static let toolBiasedHints = [
        "search", "web", "news", "today", "calendar", "reminder", "mail", "email",
        "notes", "contact", "contacts", "file", "folder", "read", "open", "fetch",
        "look up", "check", "bash", "terminal", "website", "url"
    ]

    static func decide(
        userText: String,
        dualModelEnabled: Bool,
        conciergeLoaded: Bool,
        allowConciergeDuringVoiceTurns: Bool,
        isToolFollowUp: Bool,
        proactive: Bool,
        allowsAudibleOutput: Bool,
        toolsAvailable: Bool
    ) -> TurnLLMRoute {
        guard dualModelEnabled, conciergeLoaded else { return .operatorModel }
        guard allowConciergeDuringVoiceTurns || !allowsAudibleOutput else { return .operatorModel }
        guard !isToolFollowUp, !proactive else { return .operatorModel }

        let normalized = userText.lowercased()
        if toolsAvailable, toolBiasedHints.contains(where: { normalized.contains($0) }) {
            return .operatorModel
        }

        if richResponseHints.contains(where: { normalized.contains($0) }) {
            return .conciergeModel
        }

        if normalized.count >= 220 {
            return .conciergeModel
        }

        return .operatorModel
    }
}
