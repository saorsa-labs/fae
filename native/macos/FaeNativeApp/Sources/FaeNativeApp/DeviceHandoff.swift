import Foundation

enum DeviceTarget: String, CaseIterable, Identifiable, Codable {
    case mac
    case iphone
    case watch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mac:
            return "Mac"
        case .iphone:
            return "iPhone"
        case .watch:
            return "Watch"
        }
    }

    var handoffLabel: String {
        switch self {
        case .mac:
            return "on this Mac"
        case .iphone:
            return "handoff requested to iPhone"
        case .watch:
            return "handoff requested to Watch"
        }
    }
}

enum DeviceCommand {
    case move(DeviceTarget)
    case goHome
    case unsupported
}

struct DeviceCommandParser {
    static func parse(_ text: String) -> DeviceCommand {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return .unsupported
        }

        if normalized.contains("go home") || normalized.contains("move home") {
            return .goHome
        }

        if normalized.contains("move to my watch")
            || normalized.contains("move to watch")
            || normalized.contains("to watch")
        {
            return .move(.watch)
        }

        if normalized.contains("move to my phone")
            || normalized.contains("move to phone")
            || normalized.contains("move to my iphone")
            || normalized.contains("move to iphone")
            || normalized.contains("to iphone")
            || normalized.contains("to phone")
        {
            return .move(.iphone)
        }

        if normalized.contains("go home") || normalized.contains("back to mac") {
            return .goHome
        }

        return .unsupported
    }
}

@MainActor
final class DeviceHandoffController: ObservableObject {
    @Published private(set) var currentTarget: DeviceTarget = .mac
    @Published private(set) var handoffStateText: String = DeviceTarget.mac.handoffLabel
    @Published private(set) var lastCommandText: String = "Ready"

    private var activeActivity: NSUserActivity?

    deinit {
        activeActivity?.invalidate()
    }

    func execute(commandText: String) -> DeviceCommand {
        let command = DeviceCommandParser.parse(commandText)
        switch command {
        case .move(let target):
            move(to: target, sourceCommand: commandText)
        case .goHome:
            goHome(sourceCommand: commandText)
        case .unsupported:
            lastCommandText = "Unsupported command: \(commandText)"
        }
        return command
    }

    func note(commandText: String) {
        lastCommandText = commandText
    }

    func move(to target: DeviceTarget, sourceCommand: String? = nil) {
        if target == .mac {
            goHome(sourceCommand: sourceCommand)
            return
        }

        currentTarget = target
        handoffStateText = target.handoffLabel
        lastCommandText = sourceCommand ?? "Move to \(target.label)"

        publishHandoffActivity(target: target, sourceCommand: sourceCommand)
    }

    func goHome(sourceCommand: String? = nil) {
        currentTarget = .mac
        handoffStateText = DeviceTarget.mac.handoffLabel
        lastCommandText = sourceCommand ?? "Go home"

        activeActivity?.invalidate()
        activeActivity = nil
    }

    private func publishHandoffActivity(target: DeviceTarget, sourceCommand: String?) {
        let activity = NSUserActivity(activityType: "com.saorsalabs.fae.session.handoff")
        activity.title = "Move Fae session to \(target.label)"
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.requiredUserInfoKeys = ["target", "issuedAtEpochMs"]
        activity.userInfo = [
            "target": target.rawValue,
            "command": sourceCommand ?? "move to \(target.rawValue)",
            "issuedAtEpochMs": Int(Date().timeIntervalSince1970 * 1000),
        ]

        activeActivity?.invalidate()
        activity.becomeCurrent()
        activeActivity = activity
    }
}
