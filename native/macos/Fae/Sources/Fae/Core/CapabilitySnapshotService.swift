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
        bargeInEnabled: Bool,
        requireDirectAddress: Bool,
        visionEnabled: Bool,
        voiceIdentityLock: Bool,
        approvalSnapshot: ApprovedToolsStore.ApprovalSnapshot,
        registry: ToolRegistry
    ) -> ToolPermissionSnapshot {
        let allowedTools = registry.toolNames
            .filter { registry.isToolAllowed($0, mode: toolMode, privacyMode: privacyMode) }
            .sorted()

        let deniedTools = registry.toolNames
            .filter { !registry.isToolAllowed($0, mode: toolMode, privacyMode: privacyMode) }
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
            approvedTools: approvalSnapshot.approvedTools,
            approveAllReadonly: approvalSnapshot.approveAllReadonly,
            approveAllInCurrentMode: approvalSnapshot.approveAll,
            allowedTools: allowedTools,
            deniedTools: deniedTools
        )
    }
}
