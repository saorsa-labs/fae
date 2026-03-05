import Foundation

/// Strongly-typed contract for scheduler heartbeat runs.
///
/// The heartbeat lane is skills-first: Swift hosts scheduling + safety,
/// while skills decide content/teaching behavior and return structured output.
enum HeartbeatContract {
    static let schemaVersion = 1
    static let defaultAckToken = "HEARTBEAT_OK"
    static let defaultAckMaxChars = 300
}

enum CapabilityProgressStage: String, Codable, Sendable, CaseIterable {
    case discovering
    case guidedUse
    case habitForming
    case advancedAutomation
    case powerUser

    var next: CapabilityProgressStage {
        switch self {
        case .discovering: return .guidedUse
        case .guidedUse: return .habitForming
        case .habitForming: return .advancedAutomation
        case .advancedAutomation: return .powerUser
        case .powerUser: return .powerUser
        }
    }
}

struct CapabilityProgressState: Codable, Sendable {
    var stage: CapabilityProgressStage = .discovering
    var taughtCapabilities: [String] = []
    var successfulNudges: Int = 0
    var dismissedNudges: Int = 0
    var lastNudgeAtISO8601: String?
    var lastNudgeTopic: String?
    var lastStageChangeAtISO8601: String?
}

struct HeartbeatAckPolicy: Codable, Sendable {
    var token: String = HeartbeatContract.defaultAckToken
    var ackMaxChars: Int = HeartbeatContract.defaultAckMaxChars
}

struct HeartbeatRunEnvelope: Codable, Sendable {
    var schemaVersion: Int = HeartbeatContract.schemaVersion
    var runID: String
    var timestampISO8601: String
    var deliveryTarget: String
    var quietMode: Bool
    var checklist: [String]
    var recentContext: [String]
    var progress: CapabilityProgressState
    var ack: HeartbeatAckPolicy = HeartbeatAckPolicy()
}

enum HeartbeatDecisionStatus: String, Codable, Sendable {
    case ok
    case nudge
    case alert
    case teach
}

struct HeartbeatCanvasIntent: Codable, Sendable {
    /// Typed intent kind rendered by trusted Swift templates.
    /// Examples: capability_card, mini_tutorial, chart, table, app_preview.
    var kind: String
    /// Renderer-specific payload.
    var payload: [String: String]
}

struct HeartbeatRunDecision: Codable, Sendable {
    var schemaVersion: Int = HeartbeatContract.schemaVersion
    var status: HeartbeatDecisionStatus
    var message: String?
    var nudgeTopic: String?
    var suggestedStage: CapabilityProgressStage?
    var canvasIntent: HeartbeatCanvasIntent?

    static var noOp: HeartbeatRunDecision {
        HeartbeatRunDecision(status: .ok, message: nil, nudgeTopic: nil, suggestedStage: nil, canvasIntent: nil)
    }
}

enum HeartbeatDecisionParser {
    /// Parse structured heartbeat decision payload from model text.
    ///
    /// Preferred format:
    /// `<heartbeat_result>{json}</heartbeat_result>`
    ///
    /// Fallbacks:
    /// - Raw JSON body
    /// - Ack-token based no-op contract (`HEARTBEAT_OK` with short trailing text)
    static func parse(
        text: String,
        ackToken: String = HeartbeatContract.defaultAckToken,
        ackMaxChars: Int = HeartbeatContract.defaultAckMaxChars
    ) -> HeartbeatRunDecision? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .noOp
        }

        if isAckOnly(trimmed, token: ackToken, ackMaxChars: ackMaxChars) {
            return .noOp
        }

        if let tagged = extractTaggedJSON(from: trimmed, tag: "heartbeat_result"),
           let decision = decodeDecision(from: tagged)
        {
            return decision
        }

        if let decision = decodeDecision(from: trimmed) {
            return decision
        }

        return nil
    }

    static func isAckOnly(
        _ text: String,
        token: String = HeartbeatContract.defaultAckToken,
        ackMaxChars: Int = HeartbeatContract.defaultAckMaxChars
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == token {
            return true
        }

        if trimmed.hasPrefix(token) {
            let remainder = String(trimmed.dropFirst(token.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.count <= ackMaxChars
        }

        if trimmed.hasSuffix(token) {
            let remainder = String(trimmed.dropLast(token.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.count <= ackMaxChars
        }

        return false
    }

    private static func extractTaggedJSON(from text: String, tag: String) -> String? {
        let startTag = "<\(tag)>"
        let endTag = "</\(tag)>"
        guard let start = text.range(of: startTag),
              let end = text.range(of: endTag),
              start.upperBound <= end.lowerBound
        else {
            return nil
        }
        return String(text[start.upperBound ..< end.lowerBound])
    }

    private static func decodeDecision(from jsonString: String) -> HeartbeatRunDecision? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HeartbeatRunDecision.self, from: data)
    }
}
