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

    override init() {
        super.init()

        // Guard: only initialise Sparkle if SUFeedURL is present and not a placeholder.
        guard let feedURL = Bundle.main.infoDictionary?["SUFeedURL"] as? String,
              !feedURL.isEmpty,
              !feedURL.contains("__"),
              URL(string: feedURL) != nil
        else {
            NSLog("SparkleUpdaterController: SUFeedURL not configured — updates disabled")
            return
        }

        let ctrl = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        controller = ctrl

        // Bind published properties to Sparkle's KVO-observable state.
        ctrl.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)

        ctrl.updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: RunLoop.main)
            .assign(to: &$lastUpdateCheck)

        NSLog("SparkleUpdaterController: started — feed: %@", feedURL)
    }

    // MARK: - Public API

    /// Trigger a user-initiated update check (e.g. Settings > About > Check for Updates).
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
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
    /// Return `nil` to use the Info.plist SUFeedURL as-is.
    /// Override here if you need to append query parameters (e.g. OS version, channel).
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        nil
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
