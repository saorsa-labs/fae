import AppKit
import FaeHandoffKit
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
struct FaeNativeApp: App {
    @StateObject private var handoff = DeviceHandoffController()
    @StateObject private var orbState = OrbStateController()
    @StateObject private var orbBridge = OrbStateBridgeController()
    @StateObject private var conversation = ConversationController()
    @StateObject private var conversationBridge = ConversationBridgeController()
    @StateObject private var pipelineAux = PipelineAuxBridgeController()
    @StateObject private var hostBridge = HostCommandBridge()
    @StateObject private var dockIcon = DockIconAnimator()
    @StateObject private var windowState = WindowStateController()
    @StateObject private var canvasController = CanvasController()
    @StateObject private var auxiliaryWindows = AuxiliaryWindowManager()
    @StateObject private var onboarding = OnboardingController()
    /// Retained for the app lifetime — observes JIT capability.requested events and
    /// triggers native macOS permission dialogs mid-conversation.
    @StateObject private var jitPermissions = JitPermissionController()

    /// Retained observer token for `.faeDeviceTransfer` notifications.
    /// Stored to prevent duplicate observer registration if `onAppear` fires more than once.
    @State private var deviceTransferObserver: NSObjectProtocol?

    /// Glassmorphic onboarding window shown on first launch. The main
    /// ``WindowGroup`` is hidden until onboarding completes.
    @StateObject private var onboardingWindow = OnboardingWindowController()

    /// Help window controller for displaying HTML help pages.
    private let helpWindow = HelpWindowController()

    /// Retained reference to the embedded Rust core sender.
    private let commandSender: EmbeddedCoreSender?

    /// Routes generic `.faeBackendEvent` notifications to typed notifications
    /// (e.g. `.faeCapabilityRequested`) so controllers receive events from the
    /// embedded C-ABI path, not just the defunct subprocess path.
    private static let backendEventRouter = BackendEventRouter()

    init() {
        // Force the router to be initialized (retained for app lifetime).
        _ = Self.backendEventRouter

        // Render an initial orb icon immediately so the dock never shows
        // the generic app icon. DockIconAnimator takes over in .onAppear.
        NSApplication.shared.applicationIconImage = Self.renderStaticOrb()

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
                .environmentObject(conversationBridge)
                .environmentObject(pipelineAux)
                .environmentObject(windowState)
                .environmentObject(onboarding)
                .environmentObject(auxiliaryWindows)
                .preferredColorScheme(.dark)
                .onAppear {
                    dockIcon.start()
                    // Wire the orb bridge to the shared OrbStateController so it
                    // can update mode/palette/feeling from pipeline events.
                    orbBridge.orbState = orbState
                    // Wire conversation bridge to the native message store.
                    conversationBridge.conversationController = conversation
                    // Wire pipeline aux to the canvas controller and auxiliary window manager.
                    pipelineAux.canvasController = canvasController
                    pipelineAux.auxiliaryWindows = auxiliaryWindows
                    // Wire auxiliary window manager to its dependencies.
                    auxiliaryWindows.windowState = windowState
                    auxiliaryWindows.conversationController = conversation
                    auxiliaryWindows.canvasController = canvasController
                    auxiliaryWindows.observeWindowState()
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
                    // pipelineAux.webView is set via ContentView's onWebViewReady callback.
                    if let sender = commandSender {
                        hostBridge.sender = sender
                        restoreOnboardingState(sender: sender)
                    } else {
                        // No backend — unblock the UI immediately so the user
                        // isn't stuck on a permanent black screen.
                        onboarding.isStateRestored = true
                    }
                }
                .onChange(of: onboarding.isStateRestored) {
                    guard onboarding.isStateRestored else { return }
                    if onboarding.isComplete {
                        // Already onboarded — start pipeline immediately.
                        startPipelineIfReady()
                        return
                    }
                    // First launch — show glassmorphic onboarding, hide main window.
                    showOnboardingWindow()
                }
                .onChange(of: onboarding.isComplete) {
                    guard onboarding.isComplete, onboardingWindow.isVisible else { return }
                    // Onboarding just finished — close onboarding, show main window.
                    onboardingWindow.close()
                    showMainWindow()
                    startPipelineIfReady()
                }
                .onContinueUserActivity("com.saorsalabs.fae.session.handoff") { activity in
                    handleIncomingHandoff(activity)
                }
        }
        .defaultSize(width: 340, height: 500)

        Settings {
            SettingsView(commandSender: commandSender)
                .environmentObject(orbState)
                .environmentObject(handoff)
                .environmentObject(pipelineAux)
                .environmentObject(auxiliaryWindows)
                .environmentObject(onboarding)
        }
        .commands {
            CommandGroup(replacing: .help) {
                Button("Getting Started") {
                    helpWindow.showPage("getting-started")
                }
                Button("Keyboard Shortcuts") {
                    helpWindow.showPage("shortcuts")
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
    /// the default (heather-mist) palette stop.
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

        // Use the heather-mist palette stop as the default colour.
        let color = NSColor(hue: 270.0 / 360.0, saturation: 0.15, brightness: 0.77, alpha: 1)

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

    // MARK: - Onboarding Window Lifecycle

    /// Configures and presents the glassmorphic onboarding window, hiding the
    /// main window so the user only sees the focused onboarding experience.
    private func showOnboardingWindow() {
        onboardingWindow.configure(onboarding: onboarding)
        onboardingWindow.show()

        // Hide the main window while onboarding is active.
        if let mainWindow = windowState.window {
            mainWindow.orderOut(nil)
        }
    }

    /// Makes the main conversation window key and visible after onboarding
    /// completes.
    private func showMainWindow() {
        if let mainWindow = windowState.window {
            mainWindow.makeKeyAndOrderFront(nil)
        }
    }

    /// Sends `runtime.start` to the Rust backend so the voice pipeline begins
    /// downloading models and initialising. Called after onboarding is confirmed
    /// complete (either restored from config or just finished).
    private func startPipelineIfReady() {
        guard onboarding.isComplete, let sender = commandSender else { return }
        sender.sendCommand(name: "runtime.start", payload: [:])
        orbState.mode = .thinking // visual feedback during model loading
    }

    // MARK: - Handoff Receiving

    /// Handle an incoming NSUserActivity from another device via Handoff.
    ///
    /// Decodes the `ConversationSnapshot` from `userInfo` and pushes it into
    /// `ConversationController` for display. Malformed or missing snapshots are
    /// logged and ignored.
    private func handleIncomingHandoff(_ activity: NSUserActivity) {
        guard let info = activity.userInfo else {
            NSLog("FaeNativeApp: received handoff with no userInfo")
            return
        }

        let device = (info["target"] as? String) ?? "unknown device"

        guard let jsonString = info["conversationSnapshot"] as? String,
              let data = jsonString.data(using: .utf8) else {
            NSLog("FaeNativeApp: handoff missing conversationSnapshot")
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let snapshot = try? decoder.decode(ConversationSnapshot.self, from: data) else {
            NSLog("FaeNativeApp: failed to decode handoff snapshot")
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

        NSLog("FaeNativeApp: restored handoff from %@ (%d entries)",
              device, snapshot.entries.count)
    }

    /// Check iCloud KV store on launch for a snapshot that may have been
    /// written by another device while this app was not running.
    private func checkKVStoreForHandoff() {
        if let snapshot = HandoffKVStore.load() {
            conversation.restore(from: snapshot, device: "iCloud")
            HandoffKVStore.clear()
            NSLog("FaeNativeApp: restored handoff from iCloud KV store")
        }
    }

    /// Query the Rust backend for persisted onboarding state so users who
    /// already completed onboarding don't see it again after restart.
    ///
    /// A 5-second timeout prevents the UI from hanging on a black screen
    /// indefinitely if the backend is unresponsive.
    private func restoreOnboardingState(sender: EmbeddedCoreSender) {
        Task {
            defer { onboarding.isStateRestored = true }

            let response: [String: Any]? = await withTaskGroup(of: [String: Any]?.self) { group in
                group.addTask {
                    await sender.queryCommand(name: "onboarding.get_state", payload: [:])
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    return nil // timeout sentinel
                }
                // Return whichever finishes first.
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }

            guard let response else { return }

            // The response envelope wraps the payload under "payload".
            let payload = response["payload"] as? [String: Any] ?? response
            if payload["onboarded"] as? Bool == true {
                onboarding.isComplete = true
                NSLog("FaeNativeApp: restored onboarding state — already complete")
            }
        }
    }
}
