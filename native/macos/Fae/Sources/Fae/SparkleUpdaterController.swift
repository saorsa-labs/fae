import Combine
import Sparkle
import SwiftUI

/// Manages Sparkle 2 auto-update lifecycle with gentle reminder UX.
///
/// Wraps ``SPUStandardUpdaterController`` in a SwiftUI-friendly
/// `ObservableObject`. Features:
/// - Automatic background checks on a 6-hour cadence
/// - Gentle reminders (non-intrusive update notifications)
/// - EdDSA (Ed25519) signature verification
/// - SwiftUI bindings for "Check for Updates" button state
/// - Graceful degradation when SUFeedURL is not yet configured
///
/// ## Setup Requirements
/// 1. Generate an EdDSA keypair:
///    ```
///    ./Sparkle.framework/Versions/B/Resources/generate_keys
///    ```
///    Store the private key in Keychain, paste the public key into
///    Info.plist under `SUPublicEDKey`.
/// 2. Set `SUFeedURL` in Info.plist to the appcast URL.
/// 3. Sign update archives with `generate_appcast` or `sign_update`.
@MainActor
final class SparkleUpdaterController: NSObject, ObservableObject {
    /// Whether the updater is ready to check for updates (UI binding).
    @Published var canCheckForUpdates = false

    /// The last time a background or manual check was performed.
    @Published var lastUpdateCheck: Date?

    /// The underlying Sparkle controller. `nil` when SUFeedURL is not configured.
    private var controller: SPUStandardUpdaterController?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()

        // Resolve feed URL: prefer Info.plist value, fall back to known appcast URL.
        let plistFeedURL = Bundle.main.infoDictionary?["SUFeedURL"] as? String
        let feedURL: String
        if let plist = plistFeedURL, !plist.isEmpty, !plist.contains("__"), URL(string: plist) != nil {
            feedURL = plist
        } else {
            // Info.plist has placeholder or empty string (common in dev builds) — use known URL.
            feedURL = "https://github.com/saorsa-labs/fae/releases/latest/download/appcast.xml"
            NSLog("SparkleUpdaterController: SUFeedURL not configured in Info.plist — using fallback: %@", feedURL)
        }

        // Start with startingUpdater: false so we can capture the error from startUpdater:.
        let ctrl = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        controller = ctrl

        // Bind published properties to Sparkle's KVO-observable state.
        ctrl.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
                NSLog("SparkleUpdaterController: canCheckForUpdates → %@", value ? "true" : "false")
            }
            .store(in: &cancellables)

        ctrl.updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: RunLoop.main)
            .assign(to: &$lastUpdateCheck)

        // Manually start the updater so we can log any startup errors.
        do {
            try ctrl.updater.start()
            NSLog("SparkleUpdaterController: started successfully — feed: %@", feedURL)
        } catch {
            NSLog("SparkleUpdaterController: ⚠️ updater failed to start: %@", error.localizedDescription)
            NSLog("SparkleUpdaterController: bundle=%@ bundleID=%@ version=%@",
                  Bundle.main.bundlePath,
                  Bundle.main.bundleIdentifier ?? "nil",
                  Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "nil")
        }
    }

    // MARK: - Public API

    /// Trigger a user-initiated update check (e.g. Settings > About > Check for Updates).
    ///
    /// Shows UI for both "update available" and "you're up to date" results.
    func checkForUpdates() {
        guard let controller else {
            let alert = NSAlert()
            alert.messageText = "Updates Not Available"
            alert.informativeText = "Update checking is not configured in this build."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        controller.checkForUpdates(nil)
    }

    /// Trigger a silent background update check (e.g. from the scheduler).
    ///
    /// Only shows UI when an update is actually available. Does nothing visible
    /// when already up to date — no "You're up to date!" dialog.
    func checkForUpdatesInBackground() {
        guard let controller else { return }
        controller.updater.checkForUpdatesInBackground()
    }

    /// Whether Sparkle performs automatic periodic checks.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? true }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// The interval between automatic update checks (seconds). Default: 21600 (6h).
    var updateCheckInterval: TimeInterval {
        get { controller?.updater.updateCheckInterval ?? 21_600 }
        set { controller?.updater.updateCheckInterval = newValue }
    }

    /// Whether the updater is currently available (SUFeedURL configured).
    var isConfigured: Bool { controller != nil }
}

// MARK: - SPUUpdaterDelegate

extension SparkleUpdaterController: SPUUpdaterDelegate {
    /// Append a timestamp query parameter to bypass NSURLCache.
    ///
    /// Sparkle's background checks can race with new releases — if a check
    /// completes seconds before a release is published, NSURLCache may return
    /// the stale appcast for subsequent manual checks. A timestamp query
    /// parameter ensures every check uses a unique URL, forcing a fresh fetch.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        let fallback = "https://github.com/saorsa-labs/fae/releases/latest/download/appcast.xml"
        let base: String
        if let plist = Bundle.main.infoDictionary?["SUFeedURL"] as? String,
           !plist.isEmpty, !plist.contains("__") {
            base = plist
        } else {
            base = fallback
        }
        let ts = Int(Date().timeIntervalSince1970)
        return "\(base)?t=\(ts)"
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension SparkleUpdaterController: SPUStandardUserDriverDelegate {
    /// Enable gentle reminders for scheduled background updates.
    ///
    /// When Sparkle finds an update during a background check, it shows a
    /// subtle, non-modal notification rather than an intrusive alert. The user
    /// can dismiss it and be gently reminded later.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Allow Sparkle to show its standard gentle UI for scheduled updates.
    ///
    /// Returning `true` lets Sparkle handle presentation. When `immediateFocus`
    /// is `false` (app in background), the reminder is extra gentle — just a
    /// dock badge or notification, not a modal dialog.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }

    /// Hook for customising update alert presentation.
    ///
    /// We rely on Sparkle's standard update UI, so no custom handling here.
    /// This method fires for both user-initiated and scheduled checks.
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // No custom handling — Sparkle's standard UI is clean and professional.
    }
}
