import AppKit
import SwiftUI

@MainActor
final class OrbStateController: ObservableObject {
    @Published var mode: OrbMode = .idle
    @Published var palette: OrbPalette = .modeDefault
    @Published var feeling: OrbFeeling = .neutral
}

@main
struct FaeNativeApp: App {
    @StateObject private var handoff = DeviceHandoffController()
    @StateObject private var orbState = OrbStateController()
    @StateObject private var conversation = ConversationController()
    @StateObject private var hostBridge = HostCommandBridge()
    @StateObject private var dockIcon = DockIconAnimator()
    @StateObject private var windowState = WindowStateController()
    @StateObject private var onboarding = OnboardingController()
    /// Retained for the app lifetime — observes JIT capability.requested events and
    /// triggers native macOS permission dialogs mid-conversation.
    @StateObject private var jitPermissions = JitPermissionController()

    /// Retained reference to the embedded Rust core sender.
    private let commandSender: EmbeddedCoreSender?

    /// Routes generic `.faeBackendEvent` notifications to typed notifications
    /// (e.g. `.faeCapabilityRequested`) so controllers receive events from the
    /// embedded C-ABI path, not just the defunct subprocess path.
    private static let backendEventRouter = BackendEventRouter()

    init() {
        // Force the router to be initialized (retained for app lifetime).
        _ = Self.backendEventRouter

        // Static fallback while the animator spins up
        if let iconURL = Bundle.module.url(
            forResource: "AppIconFace",
            withExtension: "jpg"
        ), let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }

        // Initialize and start the embedded Rust core.
        let sender = EmbeddedCoreSender(configJSON: "{}")
        do {
            try sender.start()
            commandSender = sender
        } catch {
            NSLog("FaeNativeApp: failed to start embedded core: %@", error.localizedDescription)
            commandSender = nil
        }
    }

    var body: some Scene {
        WindowGroup("Fae") {
            ContentView()
                .environmentObject(handoff)
                .environmentObject(orbState)
                .environmentObject(conversation)
                .environmentObject(windowState)
                .environmentObject(onboarding)
                .preferredColorScheme(.dark)
                .onAppear {
                    dockIcon.start()
                    if let sender = commandSender {
                        hostBridge.sender = sender
                        restoreOnboardingState(sender: sender)
                    } else {
                        // No backend — unblock the UI immediately so the user
                        // isn't stuck on a permanent black screen.
                        onboarding.isStateRestored = true
                    }
                }
        }
        .defaultSize(width: 340, height: 500)

        Settings {
            SettingsView()
                .environmentObject(orbState)
                .environmentObject(handoff)
        }
    }

    /// Query the Rust backend for persisted onboarding state so users who
    /// already completed onboarding don't see it again after restart.
    private func restoreOnboardingState(sender: EmbeddedCoreSender) {
        Task {
            defer { onboarding.isStateRestored = true }

            guard let response = await sender.queryCommand(
                name: "onboarding.get_state", payload: [:]
            ) else { return }

            // The response envelope wraps the payload under "payload".
            let payload = response["payload"] as? [String: Any] ?? response
            if payload["onboarded"] as? Bool == true {
                onboarding.isComplete = true
                NSLog("FaeNativeApp: restored onboarding state — already complete")
            }
        }
    }
}
