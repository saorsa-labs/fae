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
    /// Retained for the app lifetime — observes JIT capability.requested events and
    /// triggers native macOS permission dialogs mid-conversation.
    @StateObject private var jitPermissions = JitPermissionController()

    /// Retained reference to the embedded Rust core sender.
    private let commandSender: EmbeddedCoreSender?

    init() {
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
                .preferredColorScheme(.dark)
                .onAppear {
                    dockIcon.start()
                    if let sender = commandSender {
                        hostBridge.sender = sender
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
}
