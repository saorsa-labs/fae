import AppKit
import AVFoundation
@preconcurrency import Contacts
import EventKit
import Foundation

/// Manages onboarding state and native system permission requests.
///
/// `OnboardingController` bridges the onboarding HTML/JS screens to the macOS
/// permission system. It requests microphone and contacts access on behalf of
/// the user, persists the results, and notifies the web layer to update its UI.
@MainActor
final class OnboardingController: ObservableObject {

    /// Whether the backend onboarding state has been queried.
    /// `ContentView` shows a blank background until this is `true` to avoid
    /// flashing onboarding content for users who already completed it.
    @Published var isStateRestored: Bool = false

    /// Whether onboarding has been completed by the user.
    @Published var isComplete: Bool = false

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

    // MARK: - Permission Requests

    /// Request microphone access and report the result asynchronously.
    func requestMicrophone() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            micGranted = granted
            let state = granted ? "granted" : "denied"
            permissionStates["microphone"] = state
            onPermissionResult?("microphone", state)
        }
    }

    /// Request contacts access and report the result asynchronously.
    /// On grant, also reads the user's own contact card to extract their first name.
    func requestContacts() {
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
    }

    /// Request calendar and reminders access via EventKit and report the result.
    ///
    /// Uses `EKEventStore.requestFullAccessToEvents()` on macOS 14+ and the
    /// legacy `requestAccess(to:completion:)` API on earlier systems. On grant,
    /// updates the "calendar" permission state in the web layer.
    func requestCalendar() {
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
    }

    /// Request mail and notes access.
    ///
    /// Mail and Notes on macOS require Full Disk Access or Automation entitlements
    /// that cannot be requested programmatically at runtime. This method opens
    /// System Settings to the Privacy & Security → Automation panel so the user
    /// can grant access manually. The permission state is set to `"settings"` to
    /// signal to the web layer that the user was redirected to System Settings and
    /// must take action there. The button label updates to "Open Settings".
    func requestMail() {
        // Open System Settings to the Privacy & Security → Automation panel.
        // The user must manually grant access there and re-launch if needed.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
        // Set state to "settings" — the web layer renders the button as "Open Settings"
        // to provide clear feedback that the user was redirected to System Settings.
        permissionStates["mail"] = "settings"
        onPermissionResult?("mail", "settings")
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

        isComplete = true
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

    /// Attempt to read the user's own contact card and extract their name,
    /// email, phone, and family relationships for personalisation.
    private func readMeCard(store: CNContactStore) {
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
