import Foundation

/// Central builder for runtime capability snapshots used by pipeline + settings + canvas.
enum CapabilitySnapshotService {
    static func policyProfile(for toolMode: String) -> String {
        switch toolMode {
        case "assistant":
            return "assistant"
        case "full":
            return "full_access"
        default:
            return "full_access"
        }
    }

    static func buildSnapshot(
        triggerText: String,
        toolMode: String,
        privacyMode: String,
        speakerState: String,
        ownerGateEnabled: Bool,
        ownerProfileExists: Bool,
        permissions: PermissionStatusProvider.Snapshot,
        thinkingEnabled: Bool,
        requireDirectAddress: Bool,
        visionEnabled: Bool,
        voiceIdentityLock: Bool,
        registry: ToolRegistry
    ) -> ToolPermissionSnapshot {
        let allowedTools = registry.toolNames.sorted()

        let deniedTools: [String] = []

        return ToolPermissionSnapshot(
            generatedAt: Date(),
            triggerText: triggerText,
            toolMode: toolMode,
            policyProfile: policyProfile(for: toolMode),
            speakerState: speakerState,
            ownerGateEnabled: ownerGateEnabled,
            ownerProfileExists: ownerProfileExists,
            permissions: permissions,
            thinkingEnabled: thinkingEnabled,
            requireDirectAddress: requireDirectAddress,
            visionEnabled: visionEnabled,
            voiceIdentityLock: voiceIdentityLock,
            allowedTools: allowedTools,
            deniedTools: deniedTools
        )
    }
}
