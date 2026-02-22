import AppKit
import Combine
import SwiftUI

/// Owns and positions two auxiliary `NSPanel` windows (conversation and canvas)
/// near the main orb window.
///
/// When a panel opens the orb window shifts to make room and the panel slides in
/// with a smooth animation.  Closing reverses the effect.  Both canvas and
/// conversation windows share the same animation system.
@MainActor
final class AuxiliaryWindowManager: ObservableObject {

    // MARK: - Published State

    /// When true, auxiliary windows hide when the orb collapses.
    @Published var autoHideOnCollapse: Bool {
        didSet { UserDefaults.standard.set(autoHideOnCollapse, forKey: Self.autoHideKey) }
    }

    @Published private(set) var isConversationVisible: Bool = false
    @Published private(set) var isCanvasVisible: Bool = false

    // MARK: - Private State

    private var conversationPanel: NSPanel?
    private var canvasPanel: NSPanel?

    private static let autoHideKey = "fae.windows.autoHideOnCollapse"

    private let panelGap: CGFloat = 12
    private let conversationSize = NSSize(width: 340, height: 500)
    private let canvasSize = NSSize(width: 400, height: 520)

    /// The orb window frame saved *before* the first panel-induced shift.
    /// Restored when all panels close.
    private var orbFrameBeforePanels: NSRect?

    /// Whether an animated show/hide is currently running.
    /// Prevents overlapping animations from fighting each other.
    private var isAnimating: Bool = false

    /// Duration for panel show / hide animations.
    private let animationDuration: TimeInterval = 0.35

    // MARK: - Weak References

    weak var conversationController: ConversationController?
    weak var canvasController: CanvasController?
    weak var windowState: WindowStateController?

    private var modeCancellable: AnyCancellable?
    private var conversationPanelDelegate: PanelCloseDelegate?
    private var canvasPanelDelegate: PanelCloseDelegate?

    // MARK: - Init

    init() {
        autoHideOnCollapse = UserDefaults.standard.bool(forKey: Self.autoHideKey)
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
                if newMode == .collapsed, self.autoHideOnCollapse {
                    self.hideConversation()
                    self.hideCanvas()
                }
            }
    }

    // MARK: - Canvas Window

    func showCanvas() {
        guard !isAnimating else { return }
        if canvasPanel == nil { canvasPanel = makeCanvasPanel() }
        guard let panel = canvasPanel else { return }
        animatedShow(panel: panel, panelSize: canvasSize, isCanvas: true)
    }

    func hideCanvas() {
        guard isCanvasVisible else {
            canvasPanel?.orderOut(nil)
            return
        }
        guard !isAnimating else { return }
        animatedHide(panel: canvasPanel, isCanvas: true)
    }

    func toggleCanvas() {
        isCanvasVisible ? hideCanvas() : showCanvas()
    }

    // MARK: - Conversation Window

    func showConversation() {
        guard !isAnimating else { return }
        if conversationPanel == nil { conversationPanel = makeConversationPanel() }
        guard let panel = conversationPanel else { return }
        animatedShow(panel: panel, panelSize: conversationSize, isCanvas: false)
    }

    func hideConversation() {
        guard isConversationVisible else {
            conversationPanel?.orderOut(nil)
            return
        }
        guard !isAnimating else { return }
        animatedHide(panel: conversationPanel, isCanvas: false)
    }

    func toggleConversation() {
        isConversationVisible ? hideConversation() : showConversation()
    }

    // MARK: - Positioning (external)

    /// Reposition visible panels relative to the orb (e.g. after the user
    /// manually drags the orb window).
    func repositionWindows(relativeTo orbFrame: NSRect) {
        if let panel = conversationPanel, isConversationVisible {
            panel.setFrame(conversationFrame(relativeTo: orbFrame), display: true)
        }
        if let panel = canvasPanel, isCanvasVisible {
            panel.setFrame(canvasFrame(relativeTo: orbFrame), display: true)
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

    /// Shared animation logic for showing any panel. The orb shifts to make
    /// room and the panel slides in from behind the orb edge.
    private func animatedShow(panel: NSPanel, panelSize: NSSize, isCanvas: Bool) {
        guard let orbWindow = windowState?.window else {
            // Fallback: just show without animation
            if isCanvas { isCanvasVisible = true } else { isConversationVisible = true }
            panel.orderFront(nil)
            return
        }

        isAnimating = true

        let anyPanelAlreadyVisible = isConversationVisible || isCanvasVisible

        // Save original orb position before any shift (only on first panel open).
        if !anyPanelAlreadyVisible {
            orbFrameBeforePanels = orbWindow.frame
        }

        // Mark visible immediately so frame calculations account for stacking.
        if isCanvas { isCanvasVisible = true } else { isConversationVisible = true }

        // Calculate the shifted orb position.
        let side = preferredSide()
        let targetOrbFrame: NSRect
        if anyPanelAlreadyVisible {
            // Orb already shifted — keep it where it is.
            targetOrbFrame = orbWindow.frame
        } else {
            // First panel: shift the orb to make room.
            targetOrbFrame = shiftedOrbFrame(
                original: orbWindow.frame,
                forPanelWidth: panelSize.width,
                side: side
            )
        }

        // Final panel position.
        let targetPanelFrame = isCanvas
            ? canvasFrame(relativeTo: targetOrbFrame)
            : conversationFrame(relativeTo: targetOrbFrame)

        // Start the panel overlapping the orb edge, fully transparent.
        var startFrame = targetPanelFrame
        if side == .right {
            startFrame.origin.x = (anyPanelAlreadyVisible ? targetOrbFrame.maxX : orbWindow.frame.maxX) - panelSize.width * 0.3
        } else {
            startFrame.origin.x = (anyPanelAlreadyVisible ? targetOrbFrame.minX : orbWindow.frame.minX) - panelSize.width * 0.7
        }
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true

            if !anyPanelAlreadyVisible {
                orbWindow.animator().setFrame(targetOrbFrame, display: true)
            }
            panel.animator().setFrame(targetPanelFrame, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: {
            Task { @MainActor [weak self] in
                self?.isAnimating = false
            }
        })
    }

    // MARK: - Animated Hide

    /// Shared animation logic for hiding any panel. The panel slides back
    /// toward the orb edge and fades out.  If no other panels are visible
    /// the orb returns to its original position.
    private func animatedHide(panel: NSPanel?, isCanvas: Bool) {
        guard let panel else { return }
        guard let orbWindow = windowState?.window else {
            panel.orderOut(nil)
            if isCanvas { isCanvasVisible = false } else { isConversationVisible = false }
            return
        }

        isAnimating = true

        // Mark invisible immediately.
        if isCanvas { isCanvasVisible = false } else { isConversationVisible = false }

        let otherPanelStillVisible = isConversationVisible || isCanvasVisible
        let side = preferredSide()

        // Collapse frame: slide the panel back toward the orb edge.
        var collapseFrame = panel.frame
        if side == .right {
            collapseFrame.origin.x = orbWindow.frame.maxX - panel.frame.width * 0.3
        } else {
            collapseFrame.origin.x = orbWindow.frame.minX - panel.frame.width * 0.7
        }

        // Orb destination.
        let orbTarget: NSRect
        if otherPanelStillVisible {
            orbTarget = orbWindow.frame
        } else {
            orbTarget = orbFrameBeforePanels ?? orbWindow.frame
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true

            if !otherPanelStillVisible {
                orbWindow.animator().setFrame(orbTarget, display: true)
            }
            panel.animator().setFrame(collapseFrame, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                panel.orderOut(nil)
                self?.isAnimating = false

                // Clean up saved orb position when all panels closed.
                if self?.isConversationVisible != true, self?.isCanvasVisible != true {
                    self?.orbFrameBeforePanels = nil
                }

                // Reposition the remaining panel if the stacking changed.
                self?.repositionRemainingPanels(orbFrame: orbTarget)
            }
        })
    }

    /// After one panel hides, reposition any remaining visible panel to
    /// account for stacking changes (e.g. canvas moves up when conversation
    /// closes above it).
    private func repositionRemainingPanels(orbFrame: NSRect) {
        if let panel = canvasPanel, isCanvasVisible {
            let target = canvasFrame(relativeTo: orbFrame)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        }
        if let panel = conversationPanel, isConversationVisible {
            let target = conversationFrame(relativeTo: orbFrame)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        }
    }

    // MARK: - Panel Creation

    private func makeConversationPanel() -> NSPanel {
        let delegate = PanelCloseDelegate { [weak self] in
            self?.hideConversation()
        }
        conversationPanelDelegate = delegate
        let panel = makeUtilityPanel(size: conversationSize, title: "Conversation", delegate: delegate)

        guard let controller = conversationController else { return panel }

        let contentView = ConversationWindowView(
            conversationController: controller,
            onClose: { [weak self] in self?.hideConversation() }
        )
        embedSwiftUI(contentView, in: panel)
        return panel
    }

    private func makeCanvasPanel() -> NSPanel {
        let delegate = PanelCloseDelegate { [weak self] in
            self?.hideCanvas()
        }
        canvasPanelDelegate = delegate
        let panel = makeUtilityPanel(size: canvasSize, title: "Canvas", delegate: delegate)

        // Glass background: clear panel so NSVisualEffectView shows through.
        panel.backgroundColor = .clear

        guard let controller = canvasController else { return panel }
        guard let panelContentView = panel.contentView else { return panel }

        // Frosted glass layer using .sidebar material with dark appearance.
        // No tint overlay — .sidebar + darkAqua provides a natural dark glass.
        let effectView = NSVisualEffectView()
        effectView.material = .sidebar
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.appearance = NSAppearance(named: .darkAqua)
        effectView.translatesAutoresizingMaskIntoConstraints = false
        panelContentView.addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: panelContentView.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: panelContentView.bottomAnchor),
            effectView.leadingAnchor.constraint(equalTo: panelContentView.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: panelContentView.trailingAnchor),
        ])

        // SwiftUI content on top of glass — fully transparent so blur shows.
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

    private func makeUtilityPanel(size: NSSize, title: String, delegate: PanelCloseDelegate) -> NSPanel {
        let panel = NSPanel(
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

    private func conversationFrame(relativeTo orbFrame: NSRect) -> NSRect {
        let side = preferredSide()
        let size = conversationSize
        let y = orbFrame.maxY - size.height

        let x: CGFloat = side == .right
            ? orbFrame.maxX + panelGap
            : orbFrame.minX - size.width - panelGap

        return clampToScreen(NSRect(x: x, y: y, width: size.width, height: size.height))
    }

    private func canvasFrame(relativeTo orbFrame: NSRect) -> NSRect {
        let side = preferredSide()
        let size = canvasSize

        // Stack below conversation if both visible, otherwise align to orb top.
        let topOffset: CGFloat = isConversationVisible
            ? conversationSize.height + panelGap
            : 0
        let y = orbFrame.maxY - topOffset - size.height

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
