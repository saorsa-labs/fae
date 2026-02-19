import Foundation

// MARK: - Conversation Snapshot

/// A single conversation turn for handoff serialisation.
struct SnapshotEntry: Codable {
    let role: String
    let content: String
}

/// Serialisable snapshot of conversation state carried via NSUserActivity handoff.
///
/// Only "user" and "assistant" roles are included — system prompts, tool results,
/// and memory recall hits are excluded to keep the payload small and to avoid
/// leaking internal data over the Handoff channel.
struct ConversationSnapshot: Codable {
    let entries: [SnapshotEntry]
    let orbMode: String
    let orbFeeling: String
    let timestamp: Date
}

// MARK: - Device Target

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

    /// Inject a closure that produces the current conversation snapshot on demand.
    /// The app layer wires this from ConversationController / OrbStateController
    /// without creating a tight coupling between the types.
    ///
    /// The closure is responsible for filtering entries to only "user" and
    /// "assistant" roles before returning the snapshot.
    var snapshotProvider: (() -> ConversationSnapshot)?

    private var activeActivity: NSUserActivity?

    /// Reused encoder — allocated once to avoid per-call overhead.
    private let snapshotEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

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

        var info: [String: Any] = [
            "target": target.rawValue,
            "command": sourceCommand ?? "move to \(target.rawValue)",
            "issuedAtEpochMs": Int(Date().timeIntervalSince1970 * 1000),
        ]

        // Serialise conversation snapshot when a provider is available.
        // Encoding failures are silently ignored — the activity degrades
        // gracefully to target/command only.
        if let provider = snapshotProvider,
           let data = try? snapshotEncoder.encode(provider()),
           let jsonString = String(data: data, encoding: .utf8) {
            info["conversationSnapshot"] = jsonString
        }

        activity.userInfo = info

        activeActivity?.invalidate()
        activity.becomeCurrent()
        activeActivity = activity
    }
}
