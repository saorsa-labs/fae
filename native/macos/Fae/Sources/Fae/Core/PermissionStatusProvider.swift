import AVFoundation
@preconcurrency import Contacts
import EventKit
import Foundation

/// Queries current macOS permission states and formats them for LLM context.
enum PermissionStatusProvider {

    struct Snapshot: Sendable {
        let microphone: Bool
        let contacts: Bool
        let calendar: Bool
        let reminders: Bool
    }

    /// Query current authorization status for all relevant permissions.
    static func current() -> Snapshot {
        let mic: Bool = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let contacts: Bool = CNContactStore.authorizationStatus(for: .contacts) == .authorized

        let cal = Self.isEventKitAuthorized(for: .event)
        let rem = Self.isEventKitAuthorized(for: .reminder)

        return Snapshot(
            microphone: mic,
            contacts: contacts,
            calendar: cal,
            reminders: rem
        )
    }

    /// Format a natural-language prompt fragment describing available permissions.
    static func promptFragment() -> String {
        let snap = current()
        var granted: [String] = []
        var denied: [String] = []

        if snap.microphone { granted.append("Microphone") } else { denied.append("Microphone") }
        if snap.contacts { granted.append("Contacts") } else { denied.append("Contacts") }
        if snap.calendar { granted.append("Calendar") } else { denied.append("Calendar") }
        if snap.reminders { granted.append("Reminders") } else { denied.append("Reminders") }

        var lines: [String] = []
        if !granted.isEmpty {
            lines.append("You have access to: \(granted.joined(separator: ", ")).")
        }
        if !denied.isEmpty {
            lines.append("You do not have access to: \(denied.joined(separator: ", ")).")
        }

        return "Permission status:\n" + lines.joined(separator: " ")
    }

    /// Check EventKit authorization, handling the macOS 14+ API change.
    private static func isEventKitAuthorized(for entityType: EKEntityType) -> Bool {
        let status = EKEventStore.authorizationStatus(for: entityType)
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }
}
