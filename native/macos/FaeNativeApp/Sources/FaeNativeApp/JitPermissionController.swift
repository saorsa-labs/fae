import AVFoundation
@preconcurrency import Contacts
import Foundation

/// Handles just-in-time (JIT) native permission requests during an active conversation.
///
/// When the Rust backend emits a `capability.requested` event with `jit: true`,
/// `ProcessCommandSender` posts a `faeCapabilityRequested` notification. This
/// controller observes that notification, triggers the appropriate macOS native
/// permission dialog, and posts the result as `faeCapabilityGranted` or
/// `faeCapabilityDenied` so `HostCommandBridge` can relay it to the backend.
///
/// Supported capabilities (JIT):
/// - `"microphone"` → `AVCaptureDevice.requestAccess(for: .audio)`
/// - `"contacts"` → `CNContactStore.requestAccess(for: .contacts)`
/// - Any other value → deny immediately (unsupported JIT permission)
@MainActor
final class JitPermissionController: ObservableObject {

    private var observations: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observations.append(
            center.addObserver(
                forName: .faeCapabilityRequested,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let capability = notification.userInfo?["capability"] as? String else {
                    return
                }
                Task { @MainActor in
                    self?.handleRequest(capability: capability)
                }
            }
        )
    }

    deinit {
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
        }
    }

    // MARK: - Dispatch

    private func handleRequest(capability: String) {
        switch capability.lowercased().trimmingCharacters(in: .whitespaces) {
        case "microphone":
            requestMicrophone(capability: capability)
        case "contacts":
            requestContacts(capability: capability)
        default:
            NSLog("JitPermissionController: unsupported JIT capability '%@' — denying", capability)
            postDenied(capability: capability)
        }
    }

    // MARK: - Microphone

    private func requestMicrophone(capability: String) {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if granted {
                postGranted(capability: capability)
            } else {
                postDenied(capability: capability)
            }
        }
    }

    // MARK: - Contacts

    private func requestContacts(capability: String) {
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if granted {
                    self.postGranted(capability: capability)
                } else {
                    self.postDenied(capability: capability)
                }
            }
        }
    }

    // MARK: - Result Notifications

    private func postGranted(capability: String) {
        NotificationCenter.default.post(
            name: .faeCapabilityGranted,
            object: nil,
            userInfo: ["capability": capability]
        )
    }

    private func postDenied(capability: String) {
        NotificationCenter.default.post(
            name: .faeCapabilityDenied,
            object: nil,
            userInfo: ["capability": capability]
        )
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted by `ProcessCommandSender` when the backend emits a JIT `capability.requested` event.
    /// userInfo keys: `"capability"` (String), `"reason"` (String), `"jit"` (Bool).
    static let faeCapabilityRequested = Notification.Name("faeCapabilityRequested")

    /// Posted by `JitPermissionController` when the user grants a JIT capability.
    /// userInfo keys: `"capability"` (String).
    static let faeCapabilityGranted = Notification.Name("faeCapabilityGranted")

    /// Posted by `JitPermissionController` when the user denies a JIT capability.
    /// userInfo keys: `"capability"` (String).
    static let faeCapabilityDenied = Notification.Name("faeCapabilityDenied")
}
