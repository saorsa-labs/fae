import AppKit
import FaeHandoffKit
import Sparkle
import SwiftUI

@MainActor
final class OrbStateController: ObservableObject {
    @Published var mode: OrbMode = .idle
    @Published var palette: OrbPalette = .modeDefault
    @Published var feeling: OrbFeeling = .neutral

    /// Tracks an active flash so we can cancel it if another flash starts.
    private var flashTask: Task<Void, Never>?

    /// Temporarily switch the orb to `flashMode` / `flashPalette` for `duration`
    /// seconds, then restore the previous state.
    ///
    /// If `accessibilityReduceMotion` is enabled, the flash is skipped and only
    /// a subtle palette change is applied (no mode change).
    func flash(mode flashMode: OrbMode, palette flashPalette: OrbPalette, duration: TimeInterval = 1.5) {
        // Cancel any existing flash.
        flashTask?.cancel()

        let previousMode = mode
        let previousPalette = palette

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Reduced motion — only change palette briefly, skip mode change.
            palette = flashPalette
            flashTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.palette = previousPalette
            }
        } else {
            mode = flashMode
            palette = flashPalette
            flashTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.mode = previousMode
                self?.palette = previousPalette
            }
        }
    }
}

@main
struct FaeApp: App {
    @StateObject private var handoff = DeviceHandoffController()
    @StateObject private var orbState = OrbStateController()
    @StateObject private var orbAnimation = OrbAnimationState()
    @StateObject private var orbBridge = OrbStateBridgeController()
    @StateObject private var conversation = ConversationController()
    @StateObject private var conversationBridge = ConversationBridgeController()
    @StateObject private var pipelineAux = PipelineAuxBridgeController()
    @StateObject private var subtitles = SubtitleStateController()
    @StateObject private var hostBridge = HostCommandBridge()
    @StateObject private var dockIcon = DockIconAnimator()
    @StateObject private var windowState = WindowStateController()
    @StateObject private var canvasController = CanvasController()
    @StateObject private var auxiliaryWindows = AuxiliaryWindowManager()
    @StateObject private var onboarding = OnboardingController()
    /// Retained for the app lifetime — observes JIT capability.requested events and
    /// triggers native macOS permission dialogs mid-conversation.
    @StateObject private var jitPermissions = JitPermissionController()
    @StateObject private var approvalOverlay = ApprovalOverlayController()
    /// Sparkle 2 auto-update controller (EdDSA-verified, gentle reminders).
    @StateObject private var sparkleUpdater = SparkleUpdaterController()

    /// Multipeer Connectivity relay — advertises on the local network so
    /// companion devices (iPhone, iPad) can discover and connect.
    @StateObject private var relayServer = FaeRelayServer()

    /// Retained observer token for `.faeDeviceTransfer` notifications.
    /// Stored to prevent duplicate observer registration if `onAppear` fires more than once.
    @State private var deviceTransferObserver: NSObjectProtocol?

    /// Help window controller for displaying HTML help pages.
    private let helpWindow = HelpWindowController()

    /// Pure-Swift core replacing the embedded Rust runtime.
    @StateObject private var faeCore = FaeCore()

    /// Routes generic `.faeBackendEvent` notifications to typed notifications
    /// (e.g. `.faeCapabilityRequested`) so controllers receive events from
    /// `FaeEventBus`, preserving the existing notification-based UI wiring.
    private static let backendEventRouter = BackendEventRouter()

    init() {
        // Force the router to be initialized (retained for app lifetime).
        _ = Self.backendEventRouter

        // Ensure the app gets a regular menu bar and dock icon, even when
        // launched as a bare binary from the terminal (debug builds).
        NSApplication.shared.setActivationPolicy(.regular)

        // Override the process name so the menu bar shows "Fae" instead of
        // the SPM executable name. macOS uses processName for
        // the bold application menu title.
        ProcessInfo.processInfo.processName = "Fae"

        // Render an initial orb icon immediately so the dock never shows
        // the generic app icon. DockIconAnimator takes over in .onAppear.
        NSApplication.shared.applicationIconImage = Self.renderStaticOrb()
    }

    var body: some Scene {
        WindowGroup("Fae") {
            ContentView()
                .environmentObject(handoff)
                .environmentObject(orbState)
                .environmentObject(orbAnimation)
                .environmentObject(conversation)
                .environmentObject(conversationBridge)
                .environmentObject(pipelineAux)
                .environmentObject(subtitles)
                .environmentObject(windowState)
                .environmentObject(onboarding)
                .environmentObject(auxiliaryWindows)
                .preferredColorScheme(.dark)
                .onAppear {
                    dockIcon.start()
                    // Wire the orb bridge to the shared OrbStateController so it
                    // can update mode/palette/feeling from pipeline events.
                    orbBridge.orbState = orbState
                    // Bind the animation state engine to the orb state controller
                    // so spring transitions fire automatically on mode/palette/feeling changes.
                    orbAnimation.bind(to: orbState)
                    // Wire conversation bridge to the native subtitle overlay and message store.
                    conversationBridge.subtitleState = subtitles
                    conversationBridge.conversationController = conversation
                    // Wire pipeline aux to the canvas controller, subtitle state, and auxiliary window manager.
                    pipelineAux.canvasController = canvasController
                    pipelineAux.auxiliaryWindows = auxiliaryWindows
                    pipelineAux.subtitleState = subtitles
                    // Clear subtitle bubbles when the orb collapses so stale
                    // bubbles don't reappear when the window re-expands.
                    windowState.onCollapse = { [weak subtitles] in subtitles?.clearAll() }
                    // Wire auxiliary window manager to its dependencies.
                    auxiliaryWindows.windowState = windowState
                    auxiliaryWindows.conversationController = conversation
                    auxiliaryWindows.canvasController = canvasController
                    auxiliaryWindows.subtitleState = subtitles
                    auxiliaryWindows.observeWindowState()
                    auxiliaryWindows.approvalController = approvalOverlay
                    auxiliaryWindows.observeApprovalController()
                    // Wire onboarding permission results to the backend via HostCommandBridge.
                    // Both onboarding and JIT paths converge on .faeCapabilityGranted → Rust.
                    onboarding.onPermissionResult = { capability, state in
                        guard state == "granted" else { return }
                        NotificationCenter.default.post(
                            name: .faeCapabilityGranted,
                            object: nil,
                            userInfo: ["capability": capability]
                        )
                    }
                    // Wire device handoff controller dependencies.
                    handoff.orbState = orbState
                    handoff.snapshotProvider = { [weak conversation, weak orbState] in
                        let entries = (conversation?.messages ?? [])
                            .filter { $0.role == .user || $0.role == .assistant }
                            .map { SnapshotEntry(role: $0.role == .user ? "user" : "assistant", content: $0.content) }
                        return ConversationSnapshot(
                            entries: entries,
                            orbMode: orbState?.mode.rawValue ?? "idle",
                            orbFeeling: orbState?.feeling.rawValue ?? "neutral",
                            timestamp: Date()
                        )
                    }
                    // Subscribe to device transfer events from the Rust backend.
                    // Guard against re-registration if onAppear fires more than once
                    // (e.g. window restoration), storing the token for the app lifetime.
                    if deviceTransferObserver == nil {
                        deviceTransferObserver = NotificationCenter.default.addObserver(
                            forName: .faeDeviceTransfer,
                            object: nil,
                            queue: .main
                        ) { [weak handoff] notification in
                            guard let handoff,
                                  let event = notification.userInfo?["event"] as? String,
                                  let payload = notification.userInfo?["payload"] as? [String: Any]
                            else { return }
                            Task { @MainActor in
                                switch event {
                                case "device.transfer_requested":
                                    let targetStr = payload["target"] as? String ?? "iphone"
                                    let target = DeviceTarget(rawValue: targetStr) ?? .iphone
                                    handoff.move(to: target)
                                case "device.home_requested":
                                    handoff.goHome()
                                default:
                                    break
                                }
                            }
                        }
                    }
                    // Start the Multipeer Connectivity relay so companion
                    // devices can discover this Mac on the local network.
                    relayServer.bindOrbState(orbState)
                    relayServer.commandSender = faeCore
                    relayServer.audioSender = faeCore
                    relayServer.start()

                    hostBridge.sender = faeCore

                    // Always start pipeline on launch (no blocking onboarding).
                    startPipelineIfReady()

                    // First launch: show intro crawl and request contacts.
                    if !faeCore.isOnboarded {
                        showIntroCanvas()
                        requestContactsForFirstLaunch()
                    }
                }
                .onContinueUserActivity("com.saorsalabs.fae.session.handoff") { activity in
                    handleIncomingHandoff(activity)
                }
        }
        .defaultSize(width: 340, height: 500)

        Settings {
            SettingsView(commandSender: faeCore, sparkleUpdater: sparkleUpdater)
                .environmentObject(orbState)
                .environmentObject(handoff)
                .environmentObject(auxiliaryWindows)
                .environmentObject(onboarding)
                .environmentObject(conversation)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Menu("Permissions") {
                    Button("Microphone") {
                        onboarding.requestMicrophone()
                    }
                    Button("Contacts") {
                        onboarding.requestContacts()
                    }
                    Button("Calendar & Reminders") {
                        onboarding.requestCalendar()
                    }
                    Button("Mail & Notes (System Settings)") {
                        onboarding.requestMail()
                    }
                }
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Fae") {
                    let model = conversation.loadedModelLabel
                    var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
                    if !model.isEmpty {
                        options[.credits] = NSAttributedString(
                            string: "Model: \(model)",
                            attributes: [
                                .font: NSFont.systemFont(ofSize: 11),
                                .foregroundColor: NSColor.secondaryLabelColor
                            ]
                        )
                    }
                    NSApp.orderFrontStandardAboutPanel(options: options)
                }
            }
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Toggle Canvas") {
                    auxiliaryWindows.toggleCanvas()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Button("Toggle Discussions") {
                    auxiliaryWindows.toggleConversation()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Getting Started") {
                    helpWindow.showPage("getting-started")
                }
                Button("Keyboard Shortcuts") {
                    helpWindow.showPage("shortcuts")
                }
                Button("Model & Voice Reference") {
                    helpWindow.showPage("models-and-voice")
                }
                Divider()
                Button("Privacy & Security") {
                    helpWindow.showPage("privacy")
                }
                Divider()
                if let websiteURL = URL(string: "https://saorsalabs.com") {
                    Link("Fae Website", destination: websiteURL)
                }
                if let issuesURL = URL(string: "https://github.com/saorsa-labs/fae/issues") {
                    Link("Report an Issue", destination: issuesURL)
                }
            }
        }
    }

    /// Renders a static orb icon matching the DockIconAnimator style at
    /// the default (faeGold) palette stop.
    private static func renderStaticOrb() -> NSImage {
        let size: CGFloat = 256
        let nsSize = NSSize(width: size, height: size)
        let image = NSImage(size: nsSize)
        image.lockFocus()

        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
        let center = CGPoint(x: size / 2, y: size / 2)
        let radius = size / 2

        // Background: near-black rounded rect (matches app bg)
        let bgPath = CGPath(
            roundedRect: rect, cornerWidth: size * 0.22, cornerHeight: size * 0.22, transform: nil
        )
        ctx.setFillColor(CGColor(red: 0.04, green: 0.043, blue: 0.051, alpha: 1))
        ctx.addPath(bgPath)
        ctx.fillPath()

        // Use faeGold as the default colour.
        let color = NSColor(hue: 35.0 / 360.0, saturation: 0.70, brightness: 0.65, alpha: 1)

        // Outer glow
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [color.withAlphaComponent(0.18).cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: radius * 0.95, options: [])
        }

        // Core orb
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [NSColor.white.withAlphaComponent(0.85).cgColor,
                     color.withAlphaComponent(0.9).cgColor,
                     color.withAlphaComponent(0.25).cgColor] as CFArray,
            locations: [0, 0.35, 1]
        ) {
            let lightCenter = CGPoint(x: center.x - radius * 0.15, y: center.y + radius * 0.15)
            ctx.drawRadialGradient(gradient, startCenter: lightCenter, startRadius: 0,
                                   endCenter: center, endRadius: radius * 0.42, options: [])
        }

        // Specular highlight
        let specCenter = CGPoint(x: center.x - radius * 0.12, y: center.y + radius * 0.14)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [NSColor.white.withAlphaComponent(0.7).cgColor,
                     NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawRadialGradient(gradient, startCenter: specCenter, startRadius: 0,
                                   endCenter: specCenter, endRadius: radius * 0.14, options: [])
        }

        image.unlockFocus()
        return image
    }

    // MARK: - Pipeline Startup

    /// Starts the FaeCore voice pipeline immediately on launch.
    private func startPipelineIfReady() {
        try? faeCore.start()
        orbState.mode = .thinking // visual feedback during model loading
    }

    // MARK: - First Launch

    /// Show the Star Wars-style intro crawl in the canvas window.
    private func showIntroCanvas() {
        canvasController.setContent(IntroCrawl.fullHTML)
        auxiliaryWindows.showCanvas()
    }

    /// Request contacts access on first launch to learn the user's name.
    ///
    /// Uses a timeout to prevent hanging if the system dialog is dismissed
    /// without a response. Always completes onboarding regardless of outcome.
    private func requestContactsForFirstLaunch() {
        Task {
            // Small delay so the app window settles and models start loading.
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // Request contacts with a 30-second timeout.
            let learnedName: String? = await withTaskGroup(of: String?.self) { group in
                group.addTask { @MainActor [onboarding] in
                    // Request contacts — triggers macOS system dialog.
                    onboarding.requestContacts()
                    // Wait for Me Card read to complete.
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return onboarding.userName
                }
                group.addTask {
                    // Timeout after 30 seconds.
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    return nil
                }
                // Take whichever finishes first.
                let result = await group.next() ?? nil
                group.cancelAll()
                return result
            }

            // Persist the user's name if learned.
            if let name = learnedName, !name.isEmpty {
                faeCore.userName = name
                NSLog("Fae: learned user name from contacts: %@", name)
            } else {
                NSLog("Fae: contacts access not granted or Me Card not found")
            }

            // Always mark as onboarded regardless of contacts outcome.
            faeCore.completeOnboarding()
            onboarding.isComplete = true
        }
    }

    // MARK: - Handoff Receiving

    /// Handle an incoming NSUserActivity from another device via Handoff.
    ///
    /// Decodes the `ConversationSnapshot` from `userInfo` and pushes it into
    /// `ConversationController` for display. Malformed or missing snapshots are
    /// logged and ignored.
    private func handleIncomingHandoff(_ activity: NSUserActivity) {
        guard let info = activity.userInfo else {
            NSLog("Fae: received handoff with no userInfo")
            return
        }

        let device = (info["target"] as? String) ?? "unknown device"

        guard let jsonString = info["conversationSnapshot"] as? String,
              let data = jsonString.data(using: .utf8) else {
            NSLog("Fae: handoff missing conversationSnapshot")
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let snapshot = try? decoder.decode(ConversationSnapshot.self, from: data) else {
            NSLog("Fae: failed to decode handoff snapshot")
            return
        }

        conversation.restore(from: snapshot, device: device)

        // Restore orb state from snapshot.
        if let mode = OrbMode.allCases.first(where: { $0.rawValue == snapshot.orbMode }) {
            orbState.mode = mode
        }
        if let feeling = OrbFeeling.allCases.first(where: { $0.rawValue == snapshot.orbFeeling }) {
            orbState.feeling = feeling
        }

        // Pulse the orb to signal "conversation arrived".
        orbState.flash(mode: .listening, palette: .rowanBerry, duration: 2.0)

        NSLog("Fae: restored handoff from %@ (%d entries)",
              device, snapshot.entries.count)
    }

    /// Check iCloud KV store on launch for a snapshot that may have been
    /// written by another device while this app was not running.
    private func checkKVStoreForHandoff() {
        if let snapshot = HandoffKVStore.load() {
            conversation.restore(from: snapshot, device: "iCloud")
            HandoffKVStore.clear()
            NSLog("Fae: restored handoff from iCloud KV store")
        }
    }

}
