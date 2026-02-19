import Foundation
import Network
import FaeHandoffKit

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

    var systemImage: String {
        switch self {
        case .mac:
            return "laptopcomputer"
        case .iphone:
            return "iphone"
        case .watch:
            return "applewatch"
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

    /// Whether the network is currently reachable. UI disables transfer buttons
    /// and shows an offline message when `false`.
    @Published private(set) var isNetworkAvailable: Bool = true

    /// Whether device handoff is enabled. Backed by UserDefaults.
    /// When disabled: no NSUserActivity published, no iCloud KV writes,
    /// toolbar button hidden, NWPathMonitor stopped.
    @Published var handoffEnabled: Bool {
        didSet {
            UserDefaults.standard.set(handoffEnabled, forKey: Self.handoffEnabledKey)
            if !handoffEnabled {
                activeActivity?.invalidate()
                activeActivity = nil
                pathMonitor.cancel()
            } else {
                startNetworkMonitor()
            }
        }
    }

    private static let handoffEnabledKey = "fae.handoff.enabled"

    /// Inject a closure that produces the current conversation snapshot on demand.
    /// The app layer wires this from ConversationController / OrbStateController
    /// without creating a tight coupling between the types.
    ///
    /// The closure is responsible for filtering entries to only "user" and
    /// "assistant" roles before returning the snapshot.
    /// Optional reference to the orb controller for triggering flash effects
    /// during handoff transfers. Set by the app layer.
    weak var orbState: OrbStateController?

    var snapshotProvider: (() -> ConversationSnapshot)?

    private var activeActivity: NSUserActivity?

    /// Reused encoder — allocated once to avoid per-call overhead.
    private let snapshotEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// NWPathMonitor for tracking network connectivity.
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.saorsalabs.fae.network-monitor")

    /// Pending handoff that failed due to network — retried once on restore.
    private var pendingRetry: (target: DeviceTarget, command: String?)?

    /// Timer that fires 30 s after a handoff is published; shows a warning if
    /// no completion signal has been received by then.
    private var handoffTimeoutTask: Task<Void, Never>?

    // MARK: - Init / Deinit

    init() {
        // Default to true if the key has never been written.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.handoffEnabledKey) == nil {
            self.handoffEnabled = true
        } else {
            self.handoffEnabled = defaults.bool(forKey: Self.handoffEnabledKey)
        }
        if handoffEnabled {
            startNetworkMonitor()
        }
    }

    deinit {
        pathMonitor.cancel()
        handoffTimeoutTask?.cancel()
        activeActivity?.invalidate()
    }

    // MARK: - Network Monitoring

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let available = path.status == .satisfied
                self.isNetworkAvailable = available

                // Auto-retry pending handoff when network returns.
                if available, let retry = self.pendingRetry {
                    self.pendingRetry = nil
                    self.publishHandoffActivity(target: retry.target, sourceCommand: retry.command)
                    NSLog("DeviceHandoffController: retried pending handoff to %@", retry.target.rawValue)
                }
            }
        }
        pathMonitor.start(queue: monitorQueue)
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

        guard handoffEnabled else {
            lastCommandText = "Handoff is disabled"
            return
        }

        currentTarget = target
        handoffStateText = target.handoffLabel
        lastCommandText = sourceCommand ?? "Move to \(target.label)"

        // Flash the orb to indicate transfer starting.
        orbState?.flash(mode: .thinking, palette: .dawnLight, duration: 1.5)

        if isNetworkAvailable {
            publishHandoffActivity(target: target, sourceCommand: sourceCommand)
        } else {
            // Save snapshot to iCloud KV as fallback when offline.
            if let provider = snapshotProvider {
                HandoffKVStore.save(provider())
            }
            pendingRetry = (target: target, command: sourceCommand)
            handoffStateText = "Offline — saved for later"
            NSLog("DeviceHandoffController: offline, saved snapshot to KV store")
        }
    }

    func goHome(sourceCommand: String? = nil) {
        currentTarget = .mac
        handoffStateText = DeviceTarget.mac.handoffLabel
        lastCommandText = sourceCommand ?? "Go home"

        handoffTimeoutTask?.cancel()
        handoffTimeoutTask = nil
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
        // Entries are capped to maxEntries to stay within NSUserActivity
        // userInfo platform size limits. Encoding failures are logged; the
        // activity degrades gracefully to target/command only.
        if let json = snapshotJSON() {
            info["conversationSnapshot"] = json
        }

        activity.userInfo = info

        // Also persist to iCloud KV store as a fallback in case
        // real-time Handoff does not reach the target device.
        if let provider = snapshotProvider {
            HandoffKVStore.save(provider())
        }

        activeActivity?.invalidate()
        activity.becomeCurrent()
        activeActivity = activity

        // Start a 30-second watchdog. If the handoff is still active when it
        // fires, surface a soft warning that the transfer may not have completed.
        startHandoffTimeout(target: target)
    }

    /// Builds a JSON string for the conversation snapshot, capping entries to
    /// `ConversationSnapshot.maxEntries` and logging any encoding failure.
    private func snapshotJSON() -> String? {
        guard let provider = snapshotProvider else { return nil }
        let raw = provider()
        let cappedEntries = Array(raw.entries.suffix(ConversationSnapshot.maxEntries))
        let trimmed = ConversationSnapshot(
            entries: cappedEntries,
            orbMode: raw.orbMode,
            orbFeeling: raw.orbFeeling,
            timestamp: raw.timestamp
        )
        do {
            let data = try snapshotEncoder.encode(trimmed)
            return String(data: data, encoding: .utf8)
        } catch {
            NSLog("DeviceHandoffController: snapshot encode failed — %@",
                  error.localizedDescription)
            return nil
        }
    }

    // MARK: - Handoff Timeout

    /// Starts a 30-second watchdog. If the handoff is still active after that
    /// interval (i.e. `goHome` was not called), updates `handoffStateText` with
    /// a soft warning so the user knows the transfer may not have completed.
    private func startHandoffTimeout(target: DeviceTarget) {
        handoffTimeoutTask?.cancel()
        handoffTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                return // cancelled — handoff completed normally or user went home
            }
            guard let self, self.currentTarget == target else { return }
            self.handoffStateText = "Transfer may not have completed"
            NSLog("DeviceHandoffController: handoff to %@ timed out after 30s",
                  target.rawValue)
        }
    }
}
