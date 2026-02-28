import AppKit
import AVFoundation
@preconcurrency import Contacts
import EventKit
import Foundation

/// Handles just-in-time (JIT) native permission requests during an active conversation.
///
/// When the Rust backend emits a `capability.requested` event with `jit: true`,
/// `BackendEventRouter` translates it into a `faeCapabilityRequested` notification.
/// This controller observes that notification, triggers the appropriate macOS native
/// permission dialog, and posts the result as `faeCapabilityGranted` or
/// `faeCapabilityDenied` so `HostCommandBridge` can relay it to the backend.
///
/// Supported capabilities (JIT):
/// - `"microphone"` → `AVCaptureDevice.requestAccess(for: .audio)`
/// - `"contacts"` → `CNContactStore.requestAccess(for: .contacts)`
/// - `"calendar"` → `EKEventStore.requestFullAccessToEvents()`
/// - `"reminders"` → `EKEventStore.requestFullAccessToReminders()`
/// - `"mail"` → opens System Settings > Privacy & Security > Automation (polls Mail.app)
/// - `"notes"` → opens System Settings > Privacy & Security > Automation (polls Notes.app)
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
        case "calendar":
            requestCalendar(capability: capability)
        case "reminders":
            requestReminders(capability: capability)
        case "mail":
            requestMail(capability: capability)
        case "notes":
            requestNotes(capability: capability)
        case "desktop_automation":
            requestDesktopAutomation(capability: capability)
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

    // MARK: - Calendar

    private func requestCalendar(capability: String) {
        let store = EKEventStore()
        store.requestFullAccessToEvents { [weak self] granted, _ in
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

    // MARK: - Reminders

    private func requestReminders(capability: String) {
        let store = EKEventStore()
        store.requestFullAccessToReminders { [weak self] granted, _ in
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

    // MARK: - Mail (System Settings fallback with polling)

    private func requestMail(capability: String) {
        // Mail automation has no direct permission API; open Privacy settings
        // so the user can grant access manually, then poll for up to 30 seconds.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
        pollForAutomationPermission(capability: capability, bundleId: "com.apple.mail")
    }

    // MARK: - Notes (System Settings fallback with polling)

    private func requestNotes(capability: String) {
        // Notes automation has no direct permission API; open Privacy settings
        // so the user can grant access manually, then poll for up to 30 seconds.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
        pollForAutomationPermission(capability: capability, bundleId: "com.apple.Notes")
    }

    // MARK: - Desktop Automation (Accessibility)

    private func requestDesktopAutomation(capability: String) {
        // Desktop automation requires Accessibility permission. Open System
        // Settings to the correct pane and poll for the grant.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        pollForAccessibilityPermission(capability: capability)
    }

    // MARK: - Permission Polling Helpers

    /// Polls for an Automation permission grant by attempting a scripting bridge
    /// check on the target app. Checks every 2 seconds for up to 30 seconds.
    private func pollForAutomationPermission(capability: String, bundleId: String) {
        Task {
            let maxAttempts = 15  // 15 * 2s = 30s
            for _ in 0..<maxAttempts {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                // Check if the user has granted Automation permission by testing
                // a lightweight osascript call. If it succeeds, the permission
                // was granted.
                let result = await checkAutomation(bundleId: bundleId)
                if result {
                    postGranted(capability: capability)
                    return
                }
            }
            postDenied(capability: capability)
        }
    }

    /// Runs a trivial AppleScript targeting the app to check Automation permission.
    private func checkAutomation(bundleId: String) async -> Bool {
        let script: String
        switch bundleId {
        case "com.apple.mail":
            script = "tell application \"Mail\" to return name"
        case "com.apple.Notes":
            script = "tell application \"Notes\" to return name"
        default:
            script = "tell application id \"\(bundleId)\" to return name"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Polls for Accessibility permission grant. Checks every 2 seconds for
    /// up to 30 seconds.
    private func pollForAccessibilityPermission(capability: String) {
        Task {
            let maxAttempts = 15  // 15 * 2s = 30s
            for _ in 0..<maxAttempts {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if AXIsProcessTrusted() {
                    postGranted(capability: capability)
                    return
                }
            }
            postDenied(capability: capability)
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
    /// Posted by `BackendEventRouter` when the backend emits a JIT `capability.requested` event.
    /// userInfo keys: `"capability"` (String), `"reason"` (String), `"jit"` (Bool).
    static let faeCapabilityRequested = Notification.Name("faeCapabilityRequested")

    /// Posted by `JitPermissionController` when the user grants a JIT capability.
    /// userInfo keys: `"capability"` (String).
    static let faeCapabilityGranted = Notification.Name("faeCapabilityGranted")

    /// Posted by `JitPermissionController` when the user denies a JIT capability.
    /// userInfo keys: `"capability"` (String).
    static let faeCapabilityDenied = Notification.Name("faeCapabilityDenied")
}
