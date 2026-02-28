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
        toolName: String,
        livenessScore: Float? = nil
    ) -> VoiceIdentityDecision {
        if config.requireOwnerForTools == false { return .allow }
        if isOwner {
            // Step-up auth: even owner must pass liveness check for high-risk tools.
            if risk == .high,
               let score = livenessScore,
               config.livenessThreshold > 0,
               score < config.livenessThreshold
            {
                return .requireStepUp("Voice liveness check failed — please confirm with a clear voice")
            }
            return .allow
        }
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
