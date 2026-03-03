import Foundation

/// Central builder for runtime capability snapshots used by pipeline + settings + canvas.
enum CapabilitySnapshotService {
    static func policyProfile(for toolMode: String) -> String {
        switch toolMode {
        case "off", "read_only":
            return "more_cautious"
        case "full_no_approval":
            return "more_autonomous"
        default:
            return "balanced"
        }
    }

    static func buildSnapshot(
        triggerText: String,
        toolMode: String,
        speakerState: String,
        ownerGateEnabled: Bool,
        ownerProfileExists: Bool,
        permissions: PermissionStatusProvider.Snapshot,
        thinkingEnabled: Bool,
        bargeInEnabled: Bool,
        requireDirectAddress: Bool,
        visionEnabled: Bool,
        voiceIdentityLock: Bool,
        registry: ToolRegistry
    ) -> ToolPermissionSnapshot {
        let allowedTools = registry.toolNames
            .filter { registry.isToolAllowed($0, mode: toolMode) }
            .sorted()

        let deniedTools = registry.toolNames
            .filter { !registry.isToolAllowed($0, mode: toolMode) }
            .sorted()

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
            bargeInEnabled: bargeInEnabled,
            requireDirectAddress: requireDirectAddress,
            visionEnabled: visionEnabled,
            voiceIdentityLock: voiceIdentityLock,
            allowedTools: allowedTools,
            deniedTools: deniedTools
        )
    }
}
