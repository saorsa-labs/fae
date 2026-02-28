import Foundation

enum VoiceIdentityDecision: Sendable, Equatable {
    case allow
    case requireStepUp(String)
    case deny(String)
}

enum VoiceIdentityPolicy {
    static func evaluateSensitiveAction(
        config: FaeConfig.SpeakerConfig,
        isOwner: Bool,
        risk: ToolRiskLevel,
        toolName: String
    ) -> VoiceIdentityDecision {
        if config.requireOwnerForTools == false { return .allow }
        if isOwner { return .allow }
        switch risk {
        case .low:
            return .allow
        case .medium:
            return .requireStepUp("Owner verification required for medium-risk tool")
        case .high:
            return .deny("Owner verification required for high-risk tool")
        }
    }
}
