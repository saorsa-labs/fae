import AppKit
import AVFoundation
@preconcurrency import Contacts
import EventKit
import Foundation

/// Typed onboarding phase, replacing string-based phase identifiers.
enum OnboardingPhase: String, CaseIterable {
    case welcome
    case permissions
    case ready

    /// Next phase in the flow, or `nil` if this is the final phase.
    var next: OnboardingPhase? {
        switch self {
        case .welcome: return .permissions
        case .permissions: return .ready
        case .ready: return nil
        }
    }
}

/// UX W4 — first-launch permission policy.
///
/// The native first-launch flow front-loads ONLY the microphone permission:
/// push-to-talk cannot work without it. Contacts, calendar, and reminders are
/// requested just-in-time on first use of the corresponding Apple tool
/// (`AppleTools.requestPermission` → `JitPermissionController`), so a new user
/// never faces a wall of four permission dialogs before Fae has said a word.
enum FirstLaunchPermissionPolicy {
    /// Permissions the native onboarding flow requests at first launch.
    static let requested: [String] = ["microphone"]

    /// Permissions that must never be requested at first launch — they are
    /// granted just-in-time when the matching Apple tool first runs.
    static let deferredToFirstUse: [String] = ["contacts", "calendar", "reminders"]
}

/// Decision for firing the conversational first-launch onboarding turn.
enum ConversationalOnboardingAction: Equatable {
    /// Already delivered once on this install — never re-fire.
    case skip
    /// Pipeline not ready (models still loading) — record intent and retry
    /// when the runtime reports ready.
    case deferred
    /// Fire now and persist the delivered flag.
    case start
}

/// Pure decision logic for the one-shot conversational onboarding trigger,
/// used by `FaeCore.startConversationalOnboardingIfNeeded()` so the one-shot
/// and deferral semantics are unit-testable without a running core.
enum ConversationalOnboardingPolicy {
    static func action(
        alreadyDelivered: Bool,
        pipelineReady: Bool
    ) -> ConversationalOnboardingAction {
        if alreadyDelivered { return .skip }
        return pipelineReady ? .start : .deferred
    }
}

/// Manages onboarding state and native system permission requests.
///
/// `OnboardingController` drives the native onboarding screens and bridges
/// to the macOS permission system. At first launch it requests microphone
/// access only (see `FirstLaunchPermissionPolicy`); the remaining permission
/// helpers exist for just-in-time and menu-driven requests, persist the
/// results, and update the native UI.
@MainActor
final class OnboardingController: ObservableObject {

    /// Whether the backend onboarding state has been queried.
    /// The retained main-window status host observes this to avoid flashing
    /// setup state for users who already completed onboarding.
    @Published var isStateRestored: Bool = false

    /// Whether onboarding has been completed by the user.
    @Published var isComplete: Bool = false

    /// The onboarding phase to start from when resuming a partially-completed
    /// onboarding flow. Set by `restoreOnboardingState` before the window appears.
    /// Values: "welcome" | "permissions" | "ready"
    @Published var initialPhase: String = "welcome"

    /// Typed initial phase derived from `initialPhase` string.
    var typedInitialPhase: OnboardingPhase {
        OnboardingPhase(rawValue: initialPhase) ?? .welcome
    }

    /// First name extracted from the user's "Me" contacts card, if available.
    @Published var userName: String? = nil

    /// Email extracted from the user's "Me" contacts card.
    @Published var userEmail: String? = nil

    /// Phone number extracted from the user's "Me" contacts card.
    @Published var userPhone: String? = nil

    /// Family relationships from the user's "Me" contacts card.
    /// Each tuple is (relationship label, person name).
    @Published var familyRelationships: [(label: String, name: String)] = []

    /// Current permission states for web layer synchronisation.
    /// Keys: "microphone", "contacts", "calendar", "mail".
    /// Values: "pending" | "granted" | "denied".
    @Published var permissionStates: [String: String] = [
        "microphone": "pending",
        "contacts": "pending",
        "calendar": "pending",
        "mail": "pending"
    ]

    // MARK: - Permission Request Callbacks

    /// Called after a permission result is known (granted or denied).
    /// Arguments: (permission name, state string: "granted" | "denied")
    var onPermissionResult: ((String, String) -> Void)?

    /// Called when the user completes the final onboarding screen.
    var onOnboardingComplete: (() -> Void)?

    // MARK: - Internal

    private var micGranted: Bool = false
    private var contactsGranted: Bool = false

    // MARK: - Current Permission Status

    /// Human-readable status for the microphone permission.
    var microphoneStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "Granted"
        case .denied, .restricted: return "Denied"
        case .notDetermined: return "Not Asked"
        @unknown default: return "Unknown"
        }
    }

    /// Human-readable status for the contacts permission.
    var contactsStatus: String {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return "Granted"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Asked"
        @unknown default: return "Unknown"
        }
    }

    /// Human-readable status for the calendar permission.
    var calendarStatus: String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess: return "Granted"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Asked"
        case .writeOnly: return "Write Only"
        @unknown default: return "Unknown"
        }
    }

    /// Human-readable status for the reminders permission.
    var remindersStatus: String {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .authorized, .fullAccess: return "Granted"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Asked"
        case .writeOnly: return "Write Only"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Permission Requests

    /// Request microphone access.
    ///
    /// If not yet determined, shows the system permission dialog.
    /// If already granted, records the state silently.
    /// If denied/restricted, does NOT auto-open System Settings (avoids UX surprise).
    func requestMicrophone() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                micGranted = granted
                let state = granted ? "granted" : "denied"
                permissionStates["microphone"] = state
                onPermissionResult?("microphone", state)
            }
        } else {
            let state = status == .authorized ? "granted" : "denied"
            permissionStates["microphone"] = state
            onPermissionResult?("microphone", state)
        }
    }

    /// Request contacts access.
    ///
    /// If not yet determined, shows the system permission dialog.
    /// If already authorized, reads the Me Card silently.
    /// If denied/restricted, records the state without opening System Settings.
    func requestContacts() {
        let authStatus = CNContactStore.authorizationStatus(for: .contacts)
        if authStatus == .notDetermined {
            let store = CNContactStore()
            store.requestAccess(for: .contacts) { [weak self] granted, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.contactsGranted = granted
                    let state = granted ? "granted" : "denied"
                    self.permissionStates["contacts"] = state
                    self.onPermissionResult?("contacts", state)
                    if granted {
                        self.readMeCard(store: store)
                    }
                }
            }
        } else if authStatus == .authorized {
            contactsGranted = true
            permissionStates["contacts"] = "granted"
            onPermissionResult?("contacts", "granted")
            readMeCard(store: CNContactStore())
        } else {
            permissionStates["contacts"] = "denied"
            onPermissionResult?("contacts", "denied")
        }
    }

    /// Request calendar access.
    ///
    /// If not yet determined, shows the system permission dialog.
    /// If already determined, records the current state silently.
    func requestCalendar() {
        let calStatus = EKEventStore.authorizationStatus(for: .event)
        if calStatus == .notDetermined {
            let store = EKEventStore()
            if #available(macOS 14.0, *) {
                store.requestFullAccessToEvents { [weak self] granted, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let state = granted ? "granted" : "denied"
                        self.permissionStates["calendar"] = state
                        self.onPermissionResult?("calendar", state)
                    }
                }
            } else {
                store.requestAccess(to: .event) { [weak self] granted, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let state = granted ? "granted" : "denied"
                        self.permissionStates["calendar"] = state
                        self.onPermissionResult?("calendar", state)
                    }
                }
            }
        } else {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = calStatus == .fullAccess || calStatus == .writeOnly
            } else {
                granted = calStatus == .authorized
            }
            let state = granted ? "granted" : "denied"
            permissionStates["calendar"] = state
            onPermissionResult?("calendar", state)
        }
    }

    /// Request reminders access.
    ///
    /// If not yet determined, shows the system permission dialog.
    /// If already determined, records the current state silently.
    func requestReminders() {
        let remStatus = EKEventStore.authorizationStatus(for: .reminder)
        if remStatus == .notDetermined {
            let store = EKEventStore()
            if #available(macOS 14.0, *) {
                store.requestFullAccessToReminders { [weak self] granted, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let state = granted ? "granted" : "denied"
                        self.permissionStates["reminders"] = state
                        self.onPermissionResult?("reminders", state)
                    }
                }
            } else {
                store.requestAccess(to: .reminder) { [weak self] granted, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let state = granted ? "granted" : "denied"
                        self.permissionStates["reminders"] = state
                        self.onPermissionResult?("reminders", state)
                    }
                }
            }
        } else {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = remStatus == .fullAccess || remStatus == .writeOnly
            } else {
                granted = remStatus == .authorized
            }
            let state = granted ? "granted" : "denied"
            permissionStates["reminders"] = state
            onPermissionResult?("reminders", state)
        }
    }

    /// Open System Settings to the Automation pane for Mail & Notes.
    func requestMail() {
        openPrivacySettings("Automation")
        permissionStates["mail"] = "settings"
        onPermissionResult?("mail", "settings")
    }

    /// Request the first-launch permissions — mic-only (UX W4).
    ///
    /// Driven by `FirstLaunchPermissionPolicy.requested` so the front-load
    /// stays testably minimal. Contacts, calendar, and reminders are
    /// deliberately NOT requested here: the Apple tools request them
    /// just-in-time on first use via `JitPermissionController`.
    func requestFirstLaunchPermissions() {
        for permission in FirstLaunchPermissionPolicy.requested {
            switch permission {
            case "microphone":
                requestMicrophone()
            case "contacts":
                requestContacts()
            case "calendar":
                requestCalendar()
            case "reminders":
                requestReminders()
            default:
                NSLog(
                    "OnboardingController: unknown first-launch permission '%@'",
                    permission
                )
            }
        }
    }

    // MARK: - System Settings

    /// Open System Settings to the Privacy & Security pane for the given category.
    func openPrivacySettings(_ category: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(category)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Complete the onboarding flow and signal the backend.
    ///
    /// If a user name was captured from the Contacts Me Card, it is sent to the
    /// Rust backend BEFORE the completion notification so the name is persisted
    /// before onboarding finalises.
    func complete() {
        // Send user name to backend before completing (if available).
        if let name = userName, !name.isEmpty {
            NotificationCenter.default.post(
                name: .faeOnboardingSetUserName,
                object: nil,
                userInfo: ["name": name]
            )
        }

        // Send contact info (email, phone) to backend if available.
        if userEmail != nil || userPhone != nil {
            var contactInfo: [String: Any] = [:]
            if let email = userEmail { contactInfo["email"] = email }
            if let phone = userPhone { contactInfo["phone"] = phone }
            NotificationCenter.default.post(
                name: .faeOnboardingSetContactInfo,
                object: nil,
                userInfo: contactInfo
            )
        }

        // Send family relationships to backend if any were found.
        if !familyRelationships.isEmpty {
            let relations = familyRelationships.map { ["label": $0.label, "name": $0.name] }
            NotificationCenter.default.post(
                name: .faeOnboardingSetFamilyInfo,
                object: nil,
                userInfo: ["relations": relations]
            )
        }

        onOnboardingComplete?()
        NotificationCenter.default.post(
            name: .faeOnboardingComplete,
            object: nil
        )
    }

    /// Notify backend of an onboarding phase advance (Welcome → Permissions → Ready).
    func advance() {
        NotificationCenter.default.post(
            name: .faeOnboardingAdvance,
            object: nil
        )
    }

    // MARK: - Contacts "Me" Card

    /// Read the Me Card if contacts permission is already granted (for startup use).
    func readMeCardIfAuthorized() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else { return }
        readMeCard(store: CNContactStore())
    }

    /// Attempt to read the user's own contact card and extract their name,
    /// email, phone, and family relationships for personalisation.
    func readMeCard(store: CNContactStore) {
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactRelationsKey as CNKeyDescriptor,
        ]
        do {
            let meContact = try store.unifiedMeContactWithKeys(toFetch: keysToFetch)

            // Extract first name.
            let firstName = meContact.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !firstName.isEmpty {
                userName = firstName
            }

            // Extract first email address.
            if let firstEmail = meContact.emailAddresses.first {
                userEmail = firstEmail.value as String
            }

            // Extract first phone number.
            if let firstPhone = meContact.phoneNumbers.first {
                userPhone = firstPhone.value.stringValue
            }

            // Extract family/contact relationships.
            familyRelationships = meContact.contactRelations.compactMap { relation in
                let label = CNLabeledValue<CNContactRelation>.localizedString(
                    forLabel: relation.label ?? ""
                )
                let name = relation.value.name
                guard !name.isEmpty else { return nil }
                return (label: label, name: name)
            }

            if !familyRelationships.isEmpty {
                NSLog("OnboardingController: found %d contact relationships", familyRelationships.count)
            }
        } catch {
            // Me card unavailable or access failed — not an error, just continue.
            NSLog("OnboardingController: could not read Me card: %@", error.localizedDescription)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when onboarding is fully complete.
    static let faeOnboardingComplete = Notification.Name("faeOnboardingComplete")
    /// Posted when the onboarding phase should advance (Welcome→Permissions→Ready).
    static let faeOnboardingAdvance = Notification.Name("faeOnboardingAdvance")
    /// Posted to send the user's name (from Me Card) to the Rust backend.
    static let faeOnboardingSetUserName = Notification.Name("faeOnboardingSetUserName")
    /// Posted to send contact info (email, phone) to the Rust backend.
    static let faeOnboardingSetContactInfo = Notification.Name("faeOnboardingSetContactInfo")
    /// Posted to send family relationships to the Rust backend.
    static let faeOnboardingSetFamilyInfo = Notification.Name("faeOnboardingSetFamilyInfo")
}
