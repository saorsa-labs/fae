import AVFoundation
@preconcurrency import Contacts
import Foundation

/// Manages onboarding state and native system permission requests.
///
/// `OnboardingController` bridges the onboarding HTML/JS screens to the macOS
/// permission system. It requests microphone and contacts access on behalf of
/// the user, persists the results, and notifies the web layer to update its UI.
@MainActor
final class OnboardingController: ObservableObject {

    /// Whether onboarding has been completed by the user.
    @Published var isComplete: Bool = false

    /// First name extracted from the user's "Me" contacts card, if available.
    @Published var userName: String? = nil

    /// Current permission states for web layer synchronisation.
    /// Keys: "microphone", "contacts". Values: "pending" | "granted" | "denied".
    @Published var permissionStates: [String: String] = [
        "microphone": "pending",
        "contacts": "pending"
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

    /// Complete the onboarding flow and signal the backend.
    func complete() {
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

    /// Attempt to read the user's own contact card and extract their first name.
    private func readMeCard(store: CNContactStore) {
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor
        ]
        do {
            let meContact = try store.unifiedMeContactWithKeys(toFetch: keysToFetch)
            let firstName = meContact.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !firstName.isEmpty {
                userName = firstName
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
}
