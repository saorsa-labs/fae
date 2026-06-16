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
    @EnvironmentObject private var pipelineAux: PipelineAuxBridgeController
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
        .onChange(of: pipelineAux.isPipelineReady) {
            if pipelineAux.isPipelineReady && faeCore.shouldShowStartupIntro {
                faeCore.markStartupIntroSeen()
            }
        }
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
    let inputOverlay = InputOverlayController()
    let sparkleUpdater = SparkleUpdaterController()
    let relayServer = FaeRelayServer()
    let aboutWindow = AboutWindowController()
    let memoryImport = MemoryImportWindowController()
    let hotkeyManager = GlobalHotkeyManager()
    let debugConsole = DebugConsoleController()
    let faeCore = FaeCore()
    let receiptsWindow = ReceiptsWindowController()
    let rustUiShell = RustUiShellController()

    // Local runtime server for OpenAI-compatible localhost access.
    var localRuntimeServer: FaeLocalRuntimeServer?

    // Test harness (only active with --test-server or FAE_TEST_SERVER=1)
    var testServer: TestServer?
    var debugFileLogger: DebugFileLogger?

    /// Standalone skill import panel shown when Fae suggests a community skill.
    var skillImportPanel: NSPanel?
    var deviceTransferObserver: NSObjectProtocol?
    var openSettingsObserver: NSObjectProtocol?
    var closeSettingsObserver: NSObjectProtocol?
    var settingsWindow: NSWindow?
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
            guard let self else { return }
            // Orb-first product: when the orb host is running, the orb IS the
            // UI — dock reopen must not resurrect the legacy Swift window.
            if !flag, !self.rustUiShell.isActive {
                self.mainWindow?.makeKeyAndOrderFront(nil)
                sender.activate(ignoringOtherApps: true)
            }
        }
        return true
    }

    nonisolated func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quit must be SYNCHRONOUS. The previous .terminateLater + async-reply
        // design deadlocked whenever terminate() arrived via a main-queue block
        // (orb menu quit): AppKit's nested wait loop sat on the serial main
        // queue's current block, so the reply Task queued behind it could
        // never run — every real quit ended at the 6s failsafe (log evidence
        // 2026-06-11: three quits, failsafe-only breadcrumbs). Best-effort
        // teardown here, then terminate immediately. fae.db is WAL-mode SQLite
        // and the vault is git — both crash-safe; the async "drain" never
        // actually ran in practice, so nothing of value is lost.
        MainActor.assumeIsolated {
            NSLog("FaeAppDelegate: termination begin (synchronous)")
            debugLog(debugConsole, .qa, "Application terminating — stopping pipeline")
            rustUiShell.stop()
            faeCore.cancel()
            faeCore.stop()
        }
        // The daemon must die WITH the app: faeCore.stop()'s async teardown
        // never runs before .terminateNow exits, so kill it synchronously
        // here (recurring orphan bug — fae-daemon survived every quit).
        DaemonProcessRegistry.terminateAll()
        // Belt-and-braces: never hang inside AppKit's own shutdown either.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
            NSLog("FaeAppDelegate: termination failsafe fired — exiting")
            exit(0)
        }
        NSLog("FaeAppDelegate: terminating now")
        return .terminateNow
    }

    // MARK: - Rust UI Shell

    private func configureRustUiShell() {
        rustUiShell.orbState = orbState
        rustUiShell.conversation = conversation
        rustUiShell.faeCore = faeCore
        rustUiShell.onSettings = { [weak self] in
            self?.rustUiShell.refreshWorkspaceSnapshot()
        }
        rustUiShell.onSettingsLegacy = { [weak self] in
            self?.openSettingsWindow(reason: "rust-ui-shell-legacy")
        }
        rustUiShell.onTalkToggle = { [weak self] in
            guard let faeCore = self?.faeCore else { return }
            Task { await faeCore.pttToggle() }
        }
        // Orb long-press: hold starts capture, release sends — mirrors the
        // Right ⌥ hold-to-talk gesture (and the future touch pattern).
        rustUiShell.onTalkStart = { [weak self] in
            guard let faeCore = self?.faeCore else { return }
            Task { await faeCore.pttStart() }
        }
        rustUiShell.onTalkStop = { [weak self] in
            guard let faeCore = self?.faeCore else { return }
            Task { await faeCore.pttStop() }
        }
        rustUiShell.onSendText = { [weak self] text in
            // Composer text follows the typed-input path (trusted owner).
            self?.faeCore.injectText(text)
        }
        rustUiShell.onResetConversation = { [weak self] in
            self?.conversation.clearMessages()
            self?.subtitles.clearAll()
            self?.faeCore.resetConversation()
        }
        rustUiShell.onHideFae = { [weak self] in
            self?.windowState.hideWindow()
        }
        rustUiShell.onQuit = {
            // Defer one runloop turn: terminate() must never run inside the
            // orb-host stdout handler. With .terminateLater AppKit spins a
            // nested event loop awaiting the async reply; entered from within
            // this closure the main thread never unwinds — a hard deadlock
            // that forced users to force-quit (observed via sample 2026-06-11).
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
        rustUiShell.onPermissionMicrophone = { [weak self] in self?.onboarding.requestMicrophone() }
        rustUiShell.onPermissionContacts = { [weak self] in self?.onboarding.requestContacts() }
        rustUiShell.onPermissionCalendars = { [weak self] in self?.onboarding.requestCalendar() }
        rustUiShell.onPermissionReminders = { [weak self] in self?.onboarding.requestReminders() }
        rustUiShell.onPermissionMailNotes = { [weak self] in self?.onboarding.requestMail() }
        rustUiShell.onOpenPrivacySecurity = { [weak self] in self?.onboarding.openPrivacySettings("AllFiles") }
        rustUiShell.onScheduler = { [weak self] in
            // Panel is opened by the orb host; refresh backing data from Swift.
            self?.rustUiShell.refreshWorkspaceSnapshot()
        }
        rustUiShell.onSkills = { [weak self] in
            // Panel is opened by the orb host; refresh backing data from Swift.
            self?.rustUiShell.refreshWorkspaceSnapshot()
        }
        rustUiShell.onEditSoul = { [weak self] in self?.personalityEditor.showSoulEditor() }
        rustUiShell.onEditCustomInstructions = { [weak self] in self?.personalityEditor.showInstructionsEditor() }
        rustUiShell.onAskAboutShortcuts = { [weak self] in
            self?.prefillFaePrompt("What keyboard shortcuts and voice commands do you support?")
        }
        rustUiShell.onAskAboutModels = { [weak self] in
            self?.prefillFaePrompt("What models are you running and how were they selected?")
        }
        rustUiShell.onAskAboutPrivacy = { [weak self] in
            self?.prefillFaePrompt("How do you handle my privacy and data security?")
        }
        rustUiShell.onAskAboutTools = { [weak self] in
            self?.prefillFaePrompt("What tools do you have and how do I configure them?")
        }
        rustUiShell.onMemoryInbox = { [weak self] in self?.memoryImport.show() }
        rustUiShell.onRescueMode = { [weak self] in self?.toggleRescueMode() }
        rustUiShell.onRestartExhausted = { [weak self] in
            // The orb host is the only product UI. After repeated crashes and
            // exhausted automatic restarts, ask the user instead of silently
            // resurrecting a legacy window.
            self?.presentOrbHostFailureAlert()
        }
        rustUiShell.startIfAvailable()
    }

    /// Shown when the orb host has crashed repeatedly and automatic restarts
    /// are exhausted. The orb is the only product UI — offer Retry or Quit.
    private func presentOrbHostFailureAlert() {
        let alert = NSAlert()
        alert.messageText = "Fae's orb stopped working"
        alert.informativeText = "The orb display crashed repeatedly and could not be restarted automatically. You can try again, or quit Fae."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Quit Fae")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            rustUiShell.retryAfterExhaustedRestarts()
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    private func prefillFaePrompt(_ text: String) {
        windowState.showWindow()
        NotificationCenter.default.post(
            name: .faePrefillInput,
            object: nil,
            userInfo: ["text": text]
        )
        NotificationCenter.default.post(name: .faeWillFocusInputField, object: nil)
    }

    // MARK: - Window Creation

    private func setupControllersAndCreateWindow() {
        NSLog("FaeAppDelegate: setting up controllers and creating main window")

        // Wire controllers.
        dockIcon.start()
        orbBridge.orbState = orbState
        conversationBridge.subtitleState = subtitles
        conversationBridge.conversationController = conversation
        pipelineAux.canvasController = canvasController
        pipelineAux.auxiliaryWindows = auxiliaryWindows
        pipelineAux.subtitleState = subtitles
        auxiliaryWindows.windowState = windowState
        auxiliaryWindows.subtitleState = subtitles
        auxiliaryWindows.inputController = inputOverlay
        auxiliaryWindows.observeInputController()
        auxiliaryWindows.debugConsoleController = debugConsole
        faeCore.setDebugConsole(debugConsole)
        debugLog(debugConsole, .qa, "Build marker: tool-mode-popup-v1")
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
        memoryImport.auxiliaryWindows = auxiliaryWindows
        memoryImport.memoryInboxServiceProvider = { [weak faeCore] in
            faeCore?.memoryInboxService
        }
        let localRuntimeServer = FaeLocalRuntimeServer(
            faeCore: faeCore,
            conversation: conversation,
            inputOverlay: inputOverlay
        )
        self.localRuntimeServer = localRuntimeServer
        localRuntimeServer.start()
        relayServer.bindOrbState(orbState)
        relayServer.commandSender = faeCore
        relayServer.audioSender = faeCore
        relayServer.start()
        hostBridge.sender = faeCore
        hostBridge.debugConsole = debugConsole
        hostBridge.faeCore = faeCore
        configureRustUiShell()

        // Direct Combine observation for final startup readiness.
        // This tracks FaeCore's authoritative "running" state, which is only
        // set after model load and LLM warmup complete.
        faeCore.$pipelineState
            .receive(on: RunLoop.main)
            .sink { [weak pipelineAux] state in
                guard let pipelineAux else { return }
                if state == .running, !pipelineAux.isPipelineReady {
                    pipelineAux.markPipelineReady(source: "pipelineState.running")
                }
            }
            .store(in: &cancellables)

        faeCore.$hasOwnerSetUp
            .receive(on: RunLoop.main)
            .sink { [weak onboarding] hasOwnerSetUp in
                onboarding?.isComplete = hasOwnerSetUp
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
                requestPermissionsForFirstLaunchIfNeeded()
            }
        )
        .environmentObject(handoff)
        .environmentObject(orbState)
        .environmentObject(conversation)
        .environmentObject(conversationBridge)
        .environmentObject(pipelineAux)
        .environmentObject(subtitles)
        .environmentObject(windowState)
        .environmentObject(onboarding)
        .environmentObject(auxiliaryWindows)
        .environmentObject(rescueMode)
        .environmentObject(faeCore)
        .environmentObject(canvasController)

        let hostingController = NSHostingController(rootView: rootView)

        // Create the window with the correct borderless style from the start.
        // WindowStateController.window.didSet also sets these, but having them
        // upfront prevents a constraint-update loop when NSHostingView reacts
        // to a style-mask change (titled → borderless) mid-layout.
        let window = FaeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 740),
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

        // Orb-first product: when the Rust orb host is running, the orb IS the
        // UI — the Swift main window stays hidden (reachable via dock reopen,
        // "Ask Fae", and as automatic fallback if the orb host dies).
        if rustUiShell.isActive {
            NSLog("FaeAppDelegate: orb host active — main window stays hidden")
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

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

        // Sparkle update check — user-initiated (LLM tool, menu, settings).
        NotificationCenter.default.addObserver(
            forName: .faeCheckForUpdatesRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sparkleUpdater.checkForUpdates()
            }
        }

        // Sparkle background check — scheduler only, silent when up to date.
        NotificationCenter.default.addObserver(
            forName: .faeCheckForUpdatesBackgroundRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sparkleUpdater.checkForUpdatesInBackground()
            }
        }

        if openSettingsObserver == nil {
            openSettingsObserver = NotificationCenter.default.addObserver(
                forName: .faeOpenSettingsRequested,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                debugLog(self?.debugConsole, .command, "Received faeOpenSettingsRequested notification")
                Task { @MainActor [weak self] in
                    self?.openSettingsWindow(reason: "notification")
                }
            }
        }

        if closeSettingsObserver == nil {
            closeSettingsObserver = NotificationCenter.default.addObserver(
                forName: .faeCloseSettingsRequested,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                debugLog(self?.debugConsole, .command, "Received faeCloseSettingsRequested notification")
                Task { @MainActor [weak self] in
                    self?.closeSettingsWindows(reason: "notification")
                }
            }
        }

        // Skill import suggestion — Fae found a community skill and wants the user to review it.
        // Opens a standalone import window so it works even when Settings isn't open.
        NotificationCenter.default.addObserver(
            forName: .faeSkillImportSuggested,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?["url"] as? String, !url.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.showSkillImportPanel(url: url)
            }
        }

        // Receipts panel — show "What Fae Changed" floating timeline.
        NotificationCenter.default.addObserver(
            forName: .faeShowReceiptsPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.receiptsWindow.show(receiptStore: self?.faeCore.receiptStore)
            }
        }

        // Global hotkey — summon Fae from anywhere (Ctrl+Shift+A).
        hotkeyManager.start { [weak self] in
            guard let self else { return }
            self.windowState.showWindow()
        }

        // Hold-to-talk — press to listen, release to stop. Key is configurable
        // via voice.pttHotkeyKeyCode (default: Right Option).
        registerHoldToTalkHotkey(
            keyCode: faeCore.pttHotkeyKeyCode().flatMap { UInt16(exactly: $0) }
        )
        NotificationCenter.default.addObserver(
            forName: .faePTTHotkeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let keyCode = (note.userInfo?["keyCode"] as? Int).flatMap { UInt16(exactly: $0) }
            Task { @MainActor [weak self] in
                self?.registerHoldToTalkHotkey(keyCode: keyCode)
            }
        }

        // Observe PTT notifications (S18: push-to-talk is THE capture model).
        // The hotkey drives deliberate capture: press buffers audio for a
        // direct audio turn through the daemon, release ends-and-sends.
        NotificationCenter.default.addObserver(
            forName: .faePTTPressed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let faeCore = self.faeCore
            Task { @MainActor in
                await faeCore.pttStart()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .faePTTReleased,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let faeCore = self.faeCore
            Task { @MainActor in
                await faeCore.pttStop()
            }
        }

        // Test harness: start localhost HTTP server for programmatic control.
        let isTestServerMode = CommandLine.arguments.contains("--test-server")
            || ProcessInfo.processInfo.environment["FAE_TEST_SERVER"] == "1"

        if isTestServerMode {
            let logger = DebugFileLogger()
            debugFileLogger = logger
            debugConsole.fileLoggerCallback = { event, seq in
                logger.log(event: event, seq: seq)
            }

            let server = TestServer(
                faeCore: faeCore,
                debugConsole: debugConsole,
                conversation: conversation,
                inputOverlay: inputOverlay,
                auxiliaryWindows: auxiliaryWindows
            )
            testServer = server
            server.start()
            debugLog(debugConsole, .qa, "Test server started on 127.0.0.1:7433")
        }

        if isTestServerMode && !faeCore.isLicenseAccepted {
            faeCore.acceptLicense()
        }

        // Start pipeline if license already accepted.
        if faeCore.isLicenseAccepted {
            startPipelineIfReady()
            requestPermissionsForFirstLaunchIfNeeded()
        }

        // Read Me Card on every startup (if contacts permission already granted).
        Task { [weak self] in
            guard let self else { return }
            self.onboarding.readMeCardIfAuthorized()
            if let name = self.onboarding.userName, !name.isEmpty, name != self.faeCore.userName {
                self.faeCore.userName = name
            }
        }
    }

    // MARK: - Push-to-Talk Hotkey (S18)

    /// (Re)register the hold-to-talk monitor. nil keyCode = default
    /// (Right Option). The press/release handlers only post notifications —
    /// the PTT-vs-legacy behaviour branch lives in the observers.
    private func registerHoldToTalkHotkey(keyCode: UInt16?) {
        hotkeyManager.startHoldToTalk(
            keyCode: keyCode ?? GlobalHotkeyManager.holdToTalkKeyCode,
            onPress: {
                NotificationCenter.default.post(name: .faePTTPressed, object: nil)
            },
            onRelease: {
                NotificationCenter.default.post(name: .faePTTReleased, object: nil)
            }
        )
    }

    // MARK: - Skill Import Panel

    private func showSkillImportPanel(url: String) {
        // Dismiss any existing import panel.
        skillImportPanel?.close()

        let importView = SkillImportView(
            commandSender: hostBridge.sender,
            initialURL: url,
            dismissAction: { [weak self] in
                self?.skillImportPanel?.close()
                self?.skillImportPanel = nil
            }
        )
        let hostingView = NSHostingView(rootView: importView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 560, height: 440)

        let panel = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Import Community Skill"
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        skillImportPanel = panel
    }

    // MARK: - Pipeline Startup

    private func openSettingsWindow(reason: String) {
        NSApp.activate(ignoringOtherApps: true)

        let primarySelector = Selector(("showSettingsWindow:"))
        let fallbackSelector = Selector(("showPreferencesWindow:"))

        let openedPrimary = NSApp.sendAction(primarySelector, to: nil, from: nil)
        debugLog(debugConsole, .governance, "Open settings requested (\(reason)) primary=\(openedPrimary)")

        let openedFallback = !openedPrimary
            ? NSApp.sendAction(fallbackSelector, to: nil, from: nil)
            : false
        if !openedPrimary {
            debugLog(debugConsole, .governance, "Open settings fallback result=\(openedFallback)")
        }

        if openedPrimary || openedFallback {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.ensureSettingsWindowVisible(reason: "post-action")
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            let retry = NSApp.sendAction(primarySelector, to: nil, from: nil)
            debugLog(self.debugConsole, .governance, "Open settings retry result=\(retry)")
            if retry {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.ensureSettingsWindowVisible(reason: "post-retry")
                }
            } else {
                self.presentManagedSettingsWindow(reason: "manual-fallback")
            }
        }
    }

    private func closeSettingsWindows(reason: String) {
        var closedCount = 0

        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.performClose(nil)
            settingsWindow.orderOut(nil)
            closedCount += 1
        }

        for window in NSApp.windows {
            guard window.isVisible else { continue }
            if let settingsWindow, window === settingsWindow { continue }
            let title = window.title.lowercased()
            guard title.contains("settings") || title.contains("preferences") else { continue }
            window.performClose(nil)
            window.orderOut(nil)
            closedCount += 1
        }

        debugLog(debugConsole, .governance, "Close settings requested (\(reason)) closed=\(closedCount) windows=[\(visibleWindowSummary())]")
    }

    private func ensureSettingsWindowVisible(reason: String) {
        guard !hasVisibleSettingsWindow() else {
            debugLog(debugConsole, .governance, "Settings visible (\(reason)) windows=[\(visibleWindowSummary())]")
            return
        }

        debugLog(debugConsole, .governance, "No visible settings window (\(reason)) windows=[\(visibleWindowSummary())] — forcing managed fallback")
        presentManagedSettingsWindow(reason: "visibility-fallback")
    }

    private func hasVisibleSettingsWindow() -> Bool {
        if let settingsWindow, settingsWindow.isVisible, !settingsWindow.isMiniaturized {
            return true
        }

        return NSApp.windows.contains { window in
            guard window.isVisible, !window.isMiniaturized else { return false }
            let title = window.title.lowercased()
            return title.contains("settings") || title.contains("preferences")
        }
    }

    private func visibleWindowSummary() -> String {
        let titles = NSApp.windows
            .filter { $0.isVisible && !$0.isMiniaturized }
            .map { $0.title.isEmpty ? "<untitled>" : $0.title }

        if titles.isEmpty {
            return "none"
        }
        return titles.prefix(6).joined(separator: ", ")
    }

    private func presentManagedSettingsWindow(reason: String) {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            debugLog(debugConsole, .governance, "Open settings managed reuse (\(reason))")
            return
        }

        let rootView = SettingsView(
            commandSender: faeCore,
            personalityEditor: personalityEditor,
            onToggleRescue: { [weak self] in self?.toggleRescueMode() }
        )
        .environmentObject(orbState)
        .environmentObject(handoff)
        .environmentObject(auxiliaryWindows)
        .environmentObject(onboarding)
        .environmentObject(conversation)
        .environmentObject(rescueMode)
        .environmentObject(pipelineAux)
        .environmentObject(faeCore)

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = hostingController

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        debugLog(debugConsole, .governance, "Open settings managed created (\(reason))")
    }

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
        // Startup now stays on the main conversation surface instead of opening
        // a separate canvas window.
        canvasController.clear()
    }

    /// One-time first-launch flow: read-access permissions + learning the
    /// user's name from the Contacts Me Card. Keyed on its own flag — NOT on
    /// owner voice enrollment (S18: enrollment is no longer part of first
    /// launch; identity is the deliberate physical act at the machine).
    func requestPermissionsForFirstLaunchIfNeeded() {
        let flagKey = "fae.firstLaunch.permissionsRequested"
        guard !FaeEnvironment.defaults.bool(forKey: flagKey) else { return }
        FaeEnvironment.defaults.set(true, forKey: flagKey)
        requestPermissionsForFirstLaunch()
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

    init() {}

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
            .environmentObject(appDelegate.pipelineAux)
            .environmentObject(appDelegate.faeCore)
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

                Button(appDelegate.auxiliaryWindows.isDebugConsoleVisible ? "Hide Debug Console" : "Debug Console") {
                    appDelegate.auxiliaryWindows.toggleDebugConsole()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Ask Fae\u{2026}") {
                    appDelegate.windowState.showWindow()
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

                Button("Memory Inbox...") {
                    appDelegate.memoryImport.show()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Divider()

                Button(appDelegate.rescueMode.isActive ? "Exit Rescue Mode" : "Rescue Mode\u{2026}") {
                    appDelegate.toggleRescueMode()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }
    }

    // MARK: - Ask Fae Helper

    /// Bring the main window to front and pre-fill the input bar with a topic question.
    private func askFae(_ question: String) {
        appDelegate.windowState.showWindow()
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
