import Foundation

/// Unified runtime snapshot of tool availability and OS permission state.
///
/// Used by settings diagnostics and capability reporting to present one
/// coherent view of Fae's current authority envelope.
struct ToolPermissionSnapshot: Sendable {
    struct PermissionAction: Sendable {
        let label: String
        let capability: String
    }

    let generatedAt: Date
    let triggerText: String
    let toolMode: String
    let policyProfile: String
    let speakerState: String
    let ownerGateEnabled: Bool
    let ownerProfileExists: Bool
    let permissions: PermissionStatusProvider.Snapshot
    let thinkingEnabled: Bool
    let requireDirectAddress: Bool
    let visionEnabled: Bool
    let voiceIdentityLock: Bool
    let allowedTools: [String]
    let deniedTools: [String]

    var missingPermissionActions: [PermissionAction] {
        var actions: [PermissionAction] = []
        if !permissions.microphone {
            actions.append(.init(label: "Microphone", capability: "microphone"))
        }
        if !permissions.contacts {
            actions.append(.init(label: "Contacts", capability: "contacts"))
        }
        if !permissions.calendar {
            actions.append(.init(label: "Calendar", capability: "calendar"))
        }
        if !permissions.reminders {
            actions.append(.init(label: "Reminders", capability: "reminders"))
        }
        if !permissions.camera {
            actions.append(.init(label: "Camera", capability: "camera"))
        }
        if !permissions.screenRecording {
            actions.append(.init(label: "Screen Recording", capability: "screen_recording"))
        }
        return actions
    }

}
