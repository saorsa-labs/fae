import Foundation

enum ToolRiskLevel: String, Sendable {
    case low
    case medium
    case high
}

enum ToolRiskDecision: Sendable {
    case allow
    case requireApproval(reason: String)
}

/// Legacy helper kept for backwards compatibility in tests.
///
/// Production enforcement is centralized in `DefaultTrustedActionBroker`
/// at the `PipelineCoordinator.executeTool` chokepoint.
enum ToolRiskPolicy {
    static func decision(for tool: any Tool) -> ToolRiskDecision {
        if tool.requiresApproval {
            return .requireApproval(reason: "Tool requires approval")
        }

        switch tool.riskLevel {
        case .low:
            return .allow
        case .medium, .high:
            return .requireApproval(reason: "Tool risk level is \(tool.riskLevel.rawValue)")
        }
    }
}
