import AppKit
import Combine
import SwiftUI

/// NSPanel subclass that allows becoming key window when clicked.
///
/// Used for the canvas panel which contains interactive WKWebView content (governance
/// action buttons). Standard `.nonactivatingPanel` prevents `canBecomeKey`, which means
/// WKWebView link clicks are silently dropped. This subclass re-enables key status
/// so clicks work, while keeping `.nonactivatingPanel` to avoid activating the app.
private final class InteractivePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns and positions auxiliary `NSPanel` windows (canvas, approval, debug console).
///
/// Conversation is now inline in the main window — no separate conversation panel.
/// The canvas panel slides in beside the compact orb window, which shifts sideways
/// to make room. All panels are `.nonactivatingPanel` so they never steal keyboard
/// focus from the orb's input bar.
@MainActor
final class AuxiliaryWindowManager: ObservableObject {

    // MARK: - Published State

    /// When true, auxiliary windows hide when the orb collapses due to inactivity.
    @Published var autoHideOnCollapse: Bool {
        didSet { UserDefaults.standard.set(autoHideOnCollapse, forKey: Self.autoHideKey) }
    }

    @Published private(set) var isCanvasVisible: Bool = false
    @Published private(set) var isApprovalVisible: Bool = false
    @Published private(set) var isDebugConsoleVisible: Bool = false
    @Published private(set) var isThoughtBubbleVisible: Bool = false

    // MARK: - Private State

    private var canvasPanel: NSPanel?
    private var approvalPanel: NSPanel?
    private var debugConsolePanel: NSPanel?
    private var debugConsolePanelDelegate: PanelCloseDelegate?
    private var thoughtBubblePanel: NSPanel?

    // MARK: - Debug Console Controller

    /// Set by FaeAppDelegate during wiring before the debug console is shown.
    var debugConsoleController: DebugConsoleController?

    private static let autoHideKey = "fae.windows.autoHideOnCollapse"

    private let panelGap: CGFloat = 12
    private let canvasSize = NSSize(width: 420, height: 540)

    /// The orb window frame saved *before* the first panel-induced shift.
    /// Restored when all panels close.
    private var orbFrameBeforePanels: NSRect?

    /// Whether an animated show/hide is currently running.
    /// Prevents overlapping animations from fighting each other.
    private var isAnimating: Bool = false

    /// Duration for panel show / hide animations.
    private let animationDuration: TimeInterval = 0.35

    // MARK: - Weak References

    weak var canvasController: CanvasController?
    weak var windowState: WindowStateController?
    weak var subtitleState: SubtitleStateController?
    var approvalController: ApprovalOverlayController?
    var coworkWindowProvider: (() -> NSWindow?)?

    private var modeCancellable: AnyCancellable?
    private var approvalCancellable: AnyCancellable?
    private var thoughtBubbleCancellable: AnyCancellable?
    private var coworkRoutingCancellable: AnyCancellable?
    private var canvasPanelDelegate: PanelCloseDelegate?
    private var isCoworkConversationActive: Bool = false

    // MARK: - Init

    init() {
        autoHideOnCollapse = UserDefaults.standard.bool(forKey: Self.autoHideKey)
        coworkRoutingCancellable = NotificationCenter.default.publisher(for: .faeCoworkConversationRoutingChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.isCoworkConversationActive = notification.userInfo?["active"] as? Bool ?? false
            }
    }

    // MARK: - Configuration

    /// Wire up observation of window mode changes. Call once after
    /// `windowState` is set.
    func observeWindowState() {
        guard let windowState else { return }
        modeCancellable = windowState.$mode
            .receive(on: RunLoop.main)
            .sink { [weak self] newMode in
                guard let self else { return }
                // Auto-hide panels when orb collapses due to inactivity.
                if newMode == .collapsed, self.autoHideOnCollapse {
                    self.hideCanvas()
                }
            }
    }

    /// Wire up observation of approval controller state. Call once after
    /// `approvalController` is set.
    func observeApprovalController() {
        guard let controller = approvalController else { return }
        approvalCancellable = Publishers.CombineLatest4(
            controller.$activeApproval,
            controller.$activeInput,
            controller.$activeToolModeRequest,
            controller.$activeGovernanceConfirmation
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] approval, input, toolMode, governance in
            if approval != nil || input != nil || toolMode != nil || governance != nil {
                self?.showApproval()
            } else {
                self?.hideApproval()
            }
        }
    }

    // MARK: - Focus Main Window

    /// Bring the main window to front and focus the input field.
    /// Replaces the old `showConversation()` — conversation is now inline.
    func focusMainWindow() {
        windowState?.showWindow()
        NotificationCenter.default.post(name: .faeWillFocusInputField, object: nil)
    }

    // MARK: - Canvas Window

    func showCanvas() {
        guard !isAnimating else { return }
        if canvasPanel == nil { canvasPanel = makeCanvasPanel() }
        guard let panel = canvasPanel else { return }
        canvasPanel?.minSize = NSSize(width: 360, height: 400)
        animatedShow(panel: panel, panelSize: canvasSize)
    }

    func hideCanvas() {
        // Always clear stale content immediately so it doesn't flash on next show.
        canvasController?.clear()

        guard isCanvasVisible else {
            canvasPanel?.orderOut(nil)
            return
        }
        if isAnimating {
            // A show animation is in progress — force-close immediately rather
            // than silently dropping the hide request (which caused stale cards).
            canvasPanel?.orderOut(nil)
            isCanvasVisible = false
            isAnimating = false
            if let orbFrame = orbFrameBeforePanels, let orbWindow = windowState?.window {
                orbWindow.setFrame(orbFrame, display: true)
            }
            orbFrameBeforePanels = nil
            return
        }
        animatedHide(panel: canvasPanel)
    }

    func toggleCanvas() {
        isCanvasVisible ? hideCanvas() : showCanvas()
    }

    // MARK: - Debug Console

    func showDebugConsole() {
        guard let controller = debugConsoleController else { return }
        if debugConsolePanel == nil { debugConsolePanel = makeDebugConsolePanel(controller: controller) }
        guard let panel = debugConsolePanel else { return }
        // Position at bottom-left of screen if no position set yet.
        if !panel.isVisible {
            if let screen = windowState?.window?.screen ?? NSScreen.main {
                let frame = panel.frame
                let x = screen.visibleFrame.minX + 20
                let y = screen.visibleFrame.minY + 20
                panel.setFrameOrigin(NSPoint(x: x, y: y))
                _ = frame // silence unused warning
            }
        }
        panel.orderFront(nil)
        isDebugConsoleVisible = true
    }

    func hideDebugConsole() {
        debugConsolePanel?.orderOut(nil)
        isDebugConsoleVisible = false
    }

    func toggleDebugConsole() {
        isDebugConsoleVisible ? hideDebugConsole() : showDebugConsole()
    }

    // MARK: - Approval Overlay

    func showApproval() {
        guard let controller = approvalController else { return }
        if approvalPanel == nil { approvalPanel = makeApprovalPanel(controller: controller) }
        guard let panel = approvalPanel else { return }

        let anchorWindow: NSWindow?
        if isCoworkConversationActive, let coworkWindow = coworkWindowProvider?() {
            anchorWindow = coworkWindow
        } else {
            anchorWindow = windowState?.window
            // Expand to compact so the approval card and conversation are both visible.
            windowState?.transitionToCompact()
        }
        guard let anchorWindow else { return }

        let anchorFrame = anchorWindow.frame
        let panelSize = NSSize(width: 340, height: 300)
        // Position ABOVE the active surface — orb window for main Fae, cowork window for Work with Fae.
        let y = anchorFrame.maxY + 8
        let x = anchorFrame.midX - panelSize.width / 2
        let frame = clampToScreen(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height))

        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        // Float above canvas panels so it's never obscured.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 1
        }
        isApprovalVisible = true
    }

    /// Deny any pending tool approval and send a `runtime.stop` command to the pipeline.
    ///
    /// Intended as an emergency kill-switch — call this when Fae is misbehaving
    /// during tool execution. Denying the approval prevents any pending tool from
    /// running; stopping the runtime halts generation completely.
    func emergencyStop() {
        approvalController?.deny()
        NotificationCenter.default.post(name: .faeEmergencyStop, object: nil)
    }

    func hideApproval() {
        guard let panel = approvalPanel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
            }
        })
        isApprovalVisible = false
    }

    // MARK: - Thought Bubble

    /// Observe subtitle state and auto-show/hide the thought bubble.
    func observeThinkingState() {
        guard let subtitles = subtitleState else { return }
        thoughtBubbleCancellable = subtitles.$thinkingText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                if text.isEmpty {
                    self.hideThoughtBubble()
                } else {
                    self.showThoughtBubble()
                }
            }
    }

    func showThoughtBubble() {
        guard let subtitles = subtitleState else { return }
        if thoughtBubblePanel == nil {
            thoughtBubblePanel = makeThoughtBubblePanel(subtitles: subtitles)
        }
        guard let panel = thoughtBubblePanel, let orbWindow = windowState?.window else { return }

        // Position above-left of the orb.
        let orbFrame = orbWindow.frame
        let panelSize = NSSize(width: 300, height: 200)
        let x = orbFrame.minX - panelSize.width + 60
        let y = orbFrame.maxY - 40
        let frame = clampToScreen(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height))

        panel.setFrame(frame, display: false)

        if !isThoughtBubbleVisible {
            // Slide in from 16 px below final position while fading up.
            var startFrame = frame
            startFrame.origin.y -= 16
            panel.setFrame(startFrame, display: false)
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
            isThoughtBubbleVisible = true
        }
    }

    func hideThoughtBubble() {
        guard isThoughtBubbleVisible, let panel = thoughtBubblePanel else { return }
        isThoughtBubbleVisible = false
        // Float upward 20 px while fading — thought bubble drifting away.
        var floatFrame = panel.frame
        floatFrame.origin.y += 20
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(floatFrame, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
            }
        })
    }

    // MARK: - Positioning (external)

    /// Reposition visible panels relative to the orb (e.g. after the user
    /// manually drags the orb window).
    func repositionWindows(relativeTo orbFrame: NSRect) {
        if let panel = canvasPanel, isCanvasVisible {
            panel.setFrame(canvasFrame(relativeTo: orbFrame), display: true)
        }
        if let panel = thoughtBubblePanel, isThoughtBubbleVisible {
            let panelSize = panel.frame.size
            let x = orbFrame.minX - panelSize.width + 60
            let y = orbFrame.maxY - 40
            panel.setFrame(clampToScreen(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height)), display: true)
        }
    }

    // MARK: - Dynamic Resize

    /// Smoothly resize the canvas panel to a new size.
    func resizeCanvas(to newSize: NSSize) {
        guard let panel = canvasPanel, isCanvasVisible else { return }
        guard let orbWindow = windowState?.window else { return }

        let side = preferredSide()
        let orbFrame = orbWindow.frame
        let y = orbFrame.maxY - newSize.height
        let x: CGFloat = side == .right
            ? orbFrame.maxX + panelGap
            : orbFrame.minX - newSize.width - panelGap
        let target = clampToScreen(NSRect(x: x, y: y, width: newSize.width, height: newSize.height))

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    // MARK: - Animated Show

    /// Animation logic for showing the canvas panel. The orb shifts to make
    /// room and the panel slides in from behind the orb edge.
    private func animatedShow(panel: NSPanel, panelSize: NSSize) {
        guard let orbWindow = windowState?.window else {
            // Fallback: just show without animation
            isCanvasVisible = true
            panel.orderFront(nil)
            return
        }

        isAnimating = true

        // Save original orb position before the shift (only on first panel open).
        if !isCanvasVisible {
            orbFrameBeforePanels = orbWindow.frame
        }

        // Mark visible immediately so frame calculations are correct.
        isCanvasVisible = true

        // Calculate the shifted orb position.
        let side = preferredSide()
        let targetOrbFrame = shiftedOrbFrame(
            original: orbWindow.frame,
            forPanelWidth: panelSize.width,
            side: side
        )

        // Final panel position.
        let targetPanelFrame = canvasFrame(relativeTo: targetOrbFrame)

        // Start the panel overlapping the orb edge, fully transparent.
        var startFrame = targetPanelFrame
        if side == .right {
            startFrame.origin.x = orbWindow.frame.maxX - panelSize.width * 0.3
        } else {
            startFrame.origin.x = orbWindow.frame.minX - panelSize.width * 0.7
        }
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true

            orbWindow.animator().setFrame(targetOrbFrame, display: true)
            panel.animator().setFrame(targetPanelFrame, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: {
            Task { @MainActor [weak self] in
                self?.isAnimating = false
            }
        })
    }

    // MARK: - Animated Hide

    /// Animation logic for hiding the canvas panel. The panel slides back
    /// toward the orb edge and fades out, and the orb returns to its
    /// original position.
    private func animatedHide(panel: NSPanel?) {
        guard let panel else { return }
        guard let orbWindow = windowState?.window else {
            panel.orderOut(nil)
            isCanvasVisible = false
            canvasController?.clear()
            return
        }

        isAnimating = true

        // Mark invisible immediately.
        isCanvasVisible = false

        let side = preferredSide()

        // Collapse frame: slide the panel back toward the orb edge.
        var collapseFrame = panel.frame
        if side == .right {
            collapseFrame.origin.x = orbWindow.frame.maxX - panel.frame.width * 0.3
        } else {
            collapseFrame.origin.x = orbWindow.frame.minX - panel.frame.width * 0.7
        }

        // Orb destination — return to original position.
        let orbTarget = orbFrameBeforePanels ?? orbWindow.frame

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true

            orbWindow.animator().setFrame(orbTarget, display: true)
            panel.animator().setFrame(collapseFrame, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                panel.orderOut(nil)
                self?.isAnimating = false

                // Clear canvas content after the panel has finished hiding so
                // it is blank and ready for next use (not stale content).
                self?.canvasController?.clear()

                // Clean up saved orb position.
                self?.orbFrameBeforePanels = nil
            }
        })
    }

    // MARK: - Panel Creation

    private func makeCanvasPanel() -> NSPanel {
        let delegate = PanelCloseDelegate { [weak self] in
            self?.hideCanvas()
        }
        canvasPanelDelegate = delegate
        let panel = makeUtilityPanel(size: canvasSize, title: "Canvas", delegate: delegate)

        // Clear panel — SwiftUI .ultraThinMaterial in CanvasWindowView handles the glass,
        // matching the main window exactly (same material, same rendering path).
        panel.backgroundColor = .clear
        panel.isOpaque = false

        guard let controller = canvasController else { return panel }
        guard let panelContentView = panel.contentView else { return panel }

        // SwiftUI content — CanvasWindowView applies .ultraThinMaterial background.
        let canvasView = CanvasWindowView(
            canvasController: controller,
            onClose: { [weak self] in self?.hideCanvas() }
        )
        let hosting = NSHostingView(rootView: canvasView.preferredColorScheme(.dark))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panelContentView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: panelContentView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: panelContentView.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: panelContentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: panelContentView.trailingAnchor),
        ])

        return panel
    }

    private func makeDebugConsolePanel(controller: DebugConsoleController) -> NSPanel {
        let delegate = PanelCloseDelegate { [weak self] in
            self?.hideDebugConsole()
        }
        debugConsolePanelDelegate = delegate
        let size = NSSize(width: 600, height: 400)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Fae Debug Console"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.hasShadow = true
        panel.minSize = NSSize(width: 400, height: 250)
        panel.delegate = delegate

        embedSwiftUI(DebugConsoleWindowView(controller: controller), in: panel)
        return panel
    }

    private func makeApprovalPanel(controller: ApprovalOverlayController) -> NSPanel {
        let size = NSSize(width: 340, height: 300)
        // Use InteractivePanel so approval buttons (Yes/No, Enable Tools) receive clicks.
        // Plain NSPanel with .nonactivatingPanel has canBecomeKey=false → clicks silently dropped.
        let panel = InteractivePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Approval"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.hasShadow = false

        let view = ApprovalOverlayView(controller: controller)
        embedSwiftUI(view.preferredColorScheme(.dark), in: panel)
        return panel
    }

    private func makeThoughtBubblePanel(subtitles: SubtitleStateController) -> NSPanel {
        let size = NSSize(width: 300, height: 200)
        let panel = InteractivePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Thought Bubble"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.backgroundColor = .clear
        panel.hasShadow = false  // macOS 26: hasShadow=true on borderless panels draws a 1px window frame; SwiftUI shadows on the shape are sufficient
        panel.isOpaque = false
        panel.ignoresMouseEvents = false

        let hosting = NSHostingView(
            rootView: ThoughtBubbleWindowContent()
                .environmentObject(subtitles)
                .preferredColorScheme(.dark)
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear

        guard let contentView = panel.contentView else { return panel }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = CGColor.clear
        contentView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: contentView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])

        return panel
    }

    private func makeUtilityPanel(size: NSSize, title: String, delegate: PanelCloseDelegate) -> NSPanel {
        // Use InteractivePanel so WKWebView content (governance buttons) receives clicks.
        let panel = InteractivePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .utilityWindow, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.backgroundColor = NSColor(red: 0.06, green: 0.063, blue: 0.075, alpha: 0.95)
        panel.hasShadow = true
        panel.minSize = NSSize(width: 260, height: 300)
        panel.delegate = delegate

        return panel
    }

    private func embedSwiftUI<V: View>(_ view: V, in panel: NSPanel) {
        let hosting = NSHostingView(rootView: view.preferredColorScheme(.dark))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        guard let contentView = panel.contentView else { return }
        contentView.addSubview(hosting)

        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: contentView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    // MARK: - Frame Calculations

    private func preferredSide() -> WindowStateController.PanelSide {
        windowState?.panelSide ?? .right
    }

    /// Calculate a shifted orb frame that makes room for a panel on the given side.
    /// Shifts by half the panel space so the orb + panel pair stay centred.
    private func shiftedOrbFrame(
        original: NSRect,
        forPanelWidth panelWidth: CGFloat,
        side: WindowStateController.PanelSide
    ) -> NSRect {
        let shiftAmount = (panelWidth + panelGap) / 2
        var shifted = original
        if side == .right {
            shifted.origin.x -= shiftAmount
        } else {
            shifted.origin.x += shiftAmount
        }
        return clampToScreen(shifted)
    }

    private func canvasFrame(relativeTo orbFrame: NSRect) -> NSRect {
        let side = preferredSide()
        let size = canvasSize
        let y = orbFrame.maxY - size.height

        let x: CGFloat = side == .right
            ? orbFrame.maxX + panelGap
            : orbFrame.minX - size.width - panelGap

        return clampToScreen(NSRect(x: x, y: y, width: size.width, height: size.height))
    }

    /// Clamp a frame to the visible area of the screen containing the orb window.
    /// Falls back to `NSScreen.main` if the orb screen can't be determined.
    private func clampToScreen(_ frame: NSRect) -> NSRect {
        let screen = windowState?.window?.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }
        var result = frame
        result.origin.x = max(visible.minX, min(result.origin.x, visible.maxX - result.width))
        result.origin.y = max(visible.minY, min(result.origin.y, visible.maxY - result.height))
        return result
    }
}

// MARK: - PanelCloseDelegate

/// Lightweight delegate that fires a callback when the user closes the panel
/// via the title bar button, then hides instead of destroying the window.
private final class PanelCloseDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose()
        return false
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted by `AuxiliaryWindowManager.emergencyStop()` to signal the pipeline
    /// to halt all active generation immediately.
    ///
    /// Observed by `HostCommandBridge` which dispatches `"runtime.stop"` to Rust.
    static let faeEmergencyStop = Notification.Name("faeEmergencyStop")
}
