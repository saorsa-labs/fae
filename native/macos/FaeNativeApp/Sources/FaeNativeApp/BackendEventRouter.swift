@preconcurrency import Foundation

/// Fan-out adapter that observes `.faeBackendEvent` (posted by `EmbeddedCoreSender`)
/// and translates known events into the typed notifications the rest of the stack
/// consumes. This bridges the gap between the generic C-ABI event callback and the
/// specific notification names that controllers like `JitPermissionController` expect.
final class BackendEventRouter: Sendable {
    /// Set once in `init`, never mutated — safe across isolation boundaries.
    private nonisolated(unsafe) let observation: NSObjectProtocol

    init() {
        observation = NotificationCenter.default.addObserver(
            forName: .faeBackendEvent, object: nil, queue: .main
        ) { notification in
            BackendEventRouter.route(notification.userInfo as? [String: Any] ?? [:])
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(observation)
    }

    private static func route(_ info: [String: Any]) {
        guard let event = info["event"] as? String else { return }
        let payload = info["payload"] as? [String: Any] ?? [:]

        switch event {
        case "capability.requested":
            let jit = payload["jit"] as? Bool ?? false
            guard jit,
                  let capability = payload["capability"] as? String
            else { return }
            let reason = payload["reason"] as? String ?? ""
            NotificationCenter.default.post(
                name: .faeCapabilityRequested, object: nil,
                userInfo: ["capability": capability, "reason": reason, "jit": true]
            )
        default:
            break  // Other events can be routed here as needed
        }
    }
}
