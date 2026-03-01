import AppKit
import Combine
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

// MARK: - Root View (reactive wrapper for NSHostingController)

/// Wraps ContentView + license overlay so that `@ObservedObject` tracks
/// changes to `faeCore.isLicenseAccepted` and triggers SwiftUI re-renders
/// inside the AppKit-hosted NSWindow.
private struct FaeRootView: View {
    @ObservedObject var faeCore: FaeCore
    var onAcceptLicense: () -> Void

    var body: some View {
        ZStack {
            ContentView()

            if !faeCore.isLicenseAccepted {
                LicenseAcceptanceView(
                    onAccept: onAcceptLicense,
                    onDecline: { NSApplication.shared.terminate(nil) }
                )
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Borderless Key Window

/// Borderless windows return `false` for `canBecomeKey` by default, which
/// prevents text fields from receiving keyboard input. This subclass
/// overrides both properties so the orb window accepts focus normally.
class FaeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Application Delegate

/// Owns all controller state and creates the main window from AppKit.
///
/// SwiftUI's `WindowGroup` scene fails to create visible windows on macOS 26
/// when stale container state exists for the bundle identifier. By creating the
/// window directly from `applicationDidFinishLaunching`, we bypass this issue
/// entirely and still get full SwiftUI reactivity via `NSHostingController`.
@MainActor
class FaeAppDelegate: NSObject, NSApplicationDelegate {
    var mainWindow: NSWindow?

    // All controllers — owned by the delegate for the app's lifetime.
    let rescueMode = RescueMode()
    let personalityEditor = PersonalityEditorController()
    let handoff = DeviceHandoffController()
    let orbState = OrbStateController()
    let orbAnimation = OrbAnimationState()
    let orbBridge = OrbStateBridgeController()
    let conversation = ConversationController()
    let conversationBridge = ConversationBridgeController()
    let pipelineAux = PipelineAuxBridgeController()
    let subtitles = SubtitleStateController()
    let hostBridge = HostCommandBridge()
    let dockIcon = DockIconAnimator()
    let windowState = WindowStateController()
    let canvasController = CanvasController()
    let auxiliaryWindows = AuxiliaryWindowManager()
    let onboarding = OnboardingController()
    let jitPermissions = JitPermissionController()
    let approvalOverlay = ApprovalOverlayController()
    let sparkleUpdater = SparkleUpdaterController()
    let relayServer = FaeRelayServer()
    let aboutWindow = AboutWindowController()
    let hotkeyManager = GlobalHotkeyManager()
    let debugConsole = DebugConsoleController()
    let faeCore = FaeCore()

    var deviceTransferObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    private static let backendEventRouter = BackendEventRouter()

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            _ = Self.backendEventRouter
            NSLog("FaeAppDelegate: applicationDidFinishLaunching")
            NSApplication.shared.setActivationPolicy(.regular)
            ProcessInfo.processInfo.processName = "Fae"
            NSApplication.shared.applicationIconImage = FaeApp.renderStaticOrb()
            setupControllersAndCreateWindow()
        }
    }

    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor [weak self] in
            if !flag {
                self?.mainWindow?.makeKeyAndOrderFront(nil)
                sender.activate(ignoringOtherApps: true)
            }
        }
        return true
    }

    // MARK: - Window Creation

    private func setupControllersAndCreateWindow() {
        NSLog("FaeAppDelegate: setting up controllers and creating main window")

        // Wire controllers.
        dockIcon.start()
        orbBridge.orbState = orbState
        orbAnimation.bind(to: orbState)
        conversationBridge.subtitleState = subtitles
        conversationBridge.conversationController = conversation
        pipelineAux.canvasController = canvasController
        pipelineAux.auxiliaryWindows = auxiliaryWindows
        pipelineAux.subtitleState = subtitles
        windowState.onCollapse = { [weak subtitles] in subtitles?.clearAll() }
        auxiliaryWindows.windowState = windowState
        auxiliaryWindows.conversationController = conversation
        auxiliaryWindows.canvasController = canvasController
        auxiliaryWindows.subtitleState = subtitles
        auxiliaryWindows.observeWindowState()
        auxiliaryWindows.approvalController = approvalOverlay
        auxiliaryWindows.observeApprovalController()
        auxiliaryWindows.debugConsoleController = debugConsole
        faeCore.setDebugConsole(debugConsole)
        onboarding.onPermissionResult = { capability, state in
            guard state == "granted" else { return }
            NotificationCenter.default.post(
                name: .faeCapabilityGranted,
                object: nil,
                userInfo: ["capability": capability]
            )
        }
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
        aboutWindow.conversation = conversation
        aboutWindow.sparkleUpdater = sparkleUpdater
        aboutWindow.faeCore = faeCore
        relayServer.bindOrbState(orbState)
        relayServer.commandSender = faeCore
        relayServer.audioSender = faeCore
        relayServer.start()
        hostBridge.sender = faeCore

        // Direct Combine observation for pipeline readiness.
        // Bypasses the NotificationCenter event chain (FaeEventBus → GCD →
        // BackendEventRouter → PipelineAuxBridgeController) which can have
        // timing issues with Swift concurrency / GCD interleaving.
        faeCore.$pipelineState
            .receive(on: RunLoop.main)
            .sink { [weak pipelineAux, weak subtitles] state in
                guard let pipelineAux else { return }
                if state == .running, !pipelineAux.isPipelineReady {
                    NSLog("FaeAppDelegate: pipelineState → running, setting isPipelineReady")
                    pipelineAux.isPipelineReady = true
                    pipelineAux.status = "Running"
                    subtitles?.hideProgress()
                }
            }
            .store(in: &cancellables)

        // Wire rescue mode reference to FaeCore.
        faeCore.rescueMode = rescueMode

        // Create the main window with the full ContentView.
        let rootView = FaeRootView(
            faeCore: faeCore,
            onAcceptLicense: { [weak self] in
                guard let self else { return }
                faeCore.acceptLicense()
                startPipelineIfReady()
                if !faeCore.isOnboarded {
                    showIntroCanvas()
                    requestPermissionsForFirstLaunch()
                }
            }
        )
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
        .environmentObject(rescueMode)

        let hostingController = NSHostingController(rootView: rootView)

        // Create the window with the correct borderless style from the start.
        // WindowStateController.window.didSet also sets these, but having them
        // upfront prevents a constraint-update loop when NSHostingView reacts
        // to a style-mask change (titled → borderless) mid-layout.
        let window = FaeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 500),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isRestorable = false
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.title = "Fae"

        mainWindow = window

        // Let WindowStateController configure frame and min/max sizes
        // BEFORE the hosting view is attached, so the first layout pass
        // sees the final window geometry.
        windowState.window = window

        window.contentViewController = hostingController
        window.makeKeyAndOrderFront(nil)

        NSApplication.shared.activate(ignoringOtherApps: true)

        NSLog("FaeAppDelegate: main window created — visible=%d", window.isVisible ? 1 : 0)

        // Cancel generation observer — stop button and Cmd+. post this.
        NotificationCenter.default.addObserver(
            forName: .faeCancelGeneration,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.faeCore.cancel()
            }
        }

        // Global hotkey — summon Fae from anywhere (Ctrl+Shift+A).
        hotkeyManager.start { [weak self] in
            guard let self else { return }
            self.windowState.transitionToCompact()
            NSApp.activate(ignoringOtherApps: true)
            self.mainWindow?.makeKeyAndOrderFront(nil)
        }

        // Start pipeline if license already accepted.
        if faeCore.isLicenseAccepted {
            startPipelineIfReady()
            if !faeCore.isOnboarded {
                showIntroCanvas()
                requestPermissionsForFirstLaunch()
            }
        }
    }

    // MARK: - Pipeline Startup

    func startPipelineIfReady() {
        try? faeCore.start()
        orbState.mode = .thinking
    }

    // MARK: - Rescue Mode

    func toggleRescueMode() {
        if rescueMode.isActive {
            rescueMode.deactivate()
            orbBridge.isRescueMode = false
            faeCore.stop()
            try? faeCore.start()
        } else {
            rescueMode.activate()
            orbBridge.isRescueMode = true
            faeCore.stop()
            orbState.palette = .silverMist
            try? faeCore.start()
        }
    }

    // MARK: - First Launch

    func showIntroCanvas() {
        canvasController.setContent(IntroCrawl.fullHTML)
        auxiliaryWindows.showCanvas()
    }

    func requestPermissionsForFirstLaunch() {
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // Request all read-access permissions up front.
            let onboarding = self.onboarding
            let learnedName: String? = await withTaskGroup(of: String?.self) { group in
                group.addTask { @MainActor in
                    onboarding.requestAllReadPermissions()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return onboarding.userName
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    return nil
                }
                let result = await group.next() ?? nil
                group.cancelAll()
                return result
            }

            if let name = learnedName, !name.isEmpty {
                self.faeCore.userName = name
                NSLog("Fae: learned user name from contacts: %@", name)
            } else {
                NSLog("Fae: contacts access not granted or Me Card not found")
            }

            self.faeCore.completeOnboarding()
            self.onboarding.isComplete = true
        }
    }

    // MARK: - Handoff Receiving

    func handleIncomingHandoff(_ activity: NSUserActivity) {
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

        if let mode = OrbMode.allCases.first(where: { $0.rawValue == snapshot.orbMode }) {
            orbState.mode = mode
        }
        if let feeling = OrbFeeling.allCases.first(where: { $0.rawValue == snapshot.orbFeeling }) {
            orbState.feeling = feeling
        }

        orbState.flash(mode: .listening, palette: .rowanBerry, duration: 2.0)

        NSLog("Fae: restored handoff from %@ (%d entries)",
              device, snapshot.entries.count)
    }

    func checkKVStoreForHandoff() {
        if let snapshot = HandoffKVStore.load() {
            conversation.restore(from: snapshot, device: "iCloud")
            HandoffKVStore.clear()
            NSLog("Fae: restored handoff from iCloud KV store")
        }
    }
}

// MARK: - App Entry Point

/// The `FaeApp` struct provides only the Settings scene and menu commands.
/// The main window is created by `FaeAppDelegate` via AppKit, bypassing
/// SwiftUI's broken `WindowGroup` scene on macOS 26.
@main
struct FaeApp: App {
    @NSApplicationDelegateAdaptor(FaeAppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                commandSender: appDelegate.faeCore,
                personalityEditor: appDelegate.personalityEditor,
                onToggleRescue: { [appDelegate] in appDelegate.toggleRescueMode() }
            )
            .environmentObject(appDelegate.orbState)
            .environmentObject(appDelegate.handoff)
            .environmentObject(appDelegate.auxiliaryWindows)
            .environmentObject(appDelegate.onboarding)
            .environmentObject(appDelegate.conversation)
            .environmentObject(appDelegate.rescueMode)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Fae") {
                    appDelegate.aboutWindow.show()
                }

                Divider()

                Button("Check for Updates\u{2026}") {
                    appDelegate.sparkleUpdater.checkForUpdates()
                }
                .disabled(!appDelegate.sparkleUpdater.canCheckForUpdates)
            }
            CommandGroup(after: .appInfo) {
                Menu("Permissions") {
                    Button("Microphone — \(appDelegate.onboarding.microphoneStatus)") {
                        appDelegate.onboarding.requestMicrophone()
                    }
                    Button("Contacts — \(appDelegate.onboarding.contactsStatus)") {
                        appDelegate.onboarding.requestContacts()
                    }
                    Button("Calendars — \(appDelegate.onboarding.calendarStatus)") {
                        appDelegate.onboarding.requestCalendar()
                    }
                    Button("Reminders — \(appDelegate.onboarding.remindersStatus)") {
                        appDelegate.onboarding.requestReminders()
                    }
                    Divider()
                    Button("Mail & Notes (Automation)\u{2026}") {
                        appDelegate.onboarding.requestMail()
                    }
                    Divider()
                    Button("Open Privacy & Security\u{2026}") {
                        appDelegate.onboarding.openPrivacySettings("AllFiles")
                    }
                }
            }
            CommandMenu("Edit") {
                Button("Edit Soul\u{2026}") {
                    appDelegate.personalityEditor.showSoulEditor()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Edit Custom Instructions\u{2026}") {
                    appDelegate.personalityEditor.showInstructionsEditor()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(before: .sidebar) {
                Button("Stop") {
                    NotificationCenter.default.post(name: .faeCancelGeneration, object: nil)
                }
                .keyboardShortcut(".", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Toggle Canvas") {
                    appDelegate.auxiliaryWindows.toggleCanvas()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Button("Toggle Discussions") {
                    appDelegate.auxiliaryWindows.toggleConversation()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button(appDelegate.auxiliaryWindows.isDebugConsoleVisible ? "Hide Debug Console" : "Debug Console") {
                    appDelegate.auxiliaryWindows.toggleDebugConsole()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Ask Fae\u{2026}") {
                    appDelegate.auxiliaryWindows.showConversation()
                    NotificationCenter.default.post(name: .faeWillFocusInputField, object: nil)
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])

                Divider()

                Button("Ask About Shortcuts") {
                    askFae("What keyboard shortcuts and voice commands do you support?")
                }
                Button("Ask About Models") {
                    askFae("What models are you running and how were they selected?")
                }
                Button("Ask About Privacy") {
                    askFae("How do you handle my privacy and data security?")
                }
                Button("Ask About Tools") {
                    askFae("What tools do you have and how do I configure them?")
                }

                Divider()

                Button(appDelegate.rescueMode.isActive ? "Exit Rescue Mode" : "Rescue Mode\u{2026}") {
                    appDelegate.toggleRescueMode()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }
    }

    // MARK: - Ask Fae Helper

    /// Show the conversation panel and pre-fill the input bar with a topic question.
    private func askFae(_ question: String) {
        appDelegate.auxiliaryWindows.showConversation()
        NotificationCenter.default.post(
            name: .faePrefillInput,
            object: nil,
            userInfo: ["text": question]
        )
        NotificationCenter.default.post(name: .faeWillFocusInputField, object: nil)
    }

    // MARK: - Static Orb Rendering

    static func renderStaticOrb() -> NSImage {
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

        let bgPath = CGPath(
            roundedRect: rect, cornerWidth: size * 0.22, cornerHeight: size * 0.22, transform: nil
        )
        ctx.setFillColor(CGColor(red: 0.04, green: 0.043, blue: 0.051, alpha: 1))
        ctx.addPath(bgPath)
        ctx.fillPath()

        let color = NSColor(hue: 35.0 / 360.0, saturation: 0.70, brightness: 0.65, alpha: 1)

        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [color.withAlphaComponent(0.18).cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: radius * 0.95, options: [])
        }

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
}
