import AppKit
import Combine

/// Manages the orb window mode (collapsed / compact) and inactivity auto-hide.
///
/// Panel expansion logic has been removed — conversation and canvas are now
/// independent native windows managed by `AuxiliaryWindowManager`.
///
/// In compact mode the macOS title bar is transparent and the standard
/// window buttons (close/minimize/zoom) are hidden until the mouse enters
/// the title bar region. This gives Fae a frameless feel while still
/// supporting standard window management on hover.
@MainActor
final class WindowStateController: ObservableObject {

    // MARK: - Types

    enum Mode: String {
        case collapsed
        case compact
    }

    enum PanelSide: String {
        case left
        case right
    }

    // MARK: - Published State

    @Published var mode: Mode = .compact
    @Published var panelSide: PanelSide = .right

    // MARK: - Constants

    private let compactWidth: CGFloat = 340
    private let compactHeight: CGFloat = 500
    private let collapsedSize: CGFloat = 80
    private let inactivityDelay: TimeInterval = 300.0

    /// Height of the title bar hover region (points).
    private let titleBarHoverHeight: CGFloat = 28

    // MARK: - Window Reference

    weak var window: NSWindow? {
        didSet {
            applyModeToWindow()
            installTitleBarTracker()
        }
    }

    // MARK: - Timer

    private var inactivityTimer: Timer?

    /// Tracking area installed on the window's content view to detect
    /// mouse entry/exit in the title bar region.
    private var titleBarTracker: TitleBarTrackingHelper?

    // MARK: - Transitions

    func transitionToCollapsed() {
        guard mode != .collapsed else { return }

        mode = .collapsed
        titleBarTracker?.removeFromSuperview()
        titleBarTracker = nil

        guard let window else { return }

        let currentFrame = window.frame
        let targetSize = NSSize(width: collapsedSize, height: collapsedSize)

        let centerX = currentFrame.midX - targetSize.width / 2
        let centerY = currentFrame.midY - targetSize.height / 2
        let targetFrame = NSRect(origin: NSPoint(x: centerX, y: centerY), size: targetSize)

        window.styleMask = [.borderless]
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.hasShadow = true
        window.backgroundColor = .clear
        window.isOpaque = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(targetFrame, display: true)
        }

        cancelInactivityTimer()
    }

    func transitionToCompact() {
        let wasCollapsed = mode == .collapsed
        mode = .compact

        guard let window else { return }

        if wasCollapsed {
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.level = .normal
            window.backgroundColor = .clear
            window.isOpaque = false
            setWindowButtonsHidden(true)
            installTitleBarTracker()
        }

        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let targetSize = NSSize(width: compactWidth, height: compactHeight)

        let currentFrame = window.frame
        var originX = currentFrame.midX - targetSize.width / 2
        var originY = currentFrame.midY - targetSize.height / 2

        let visibleFrame = screen.visibleFrame
        originX = max(visibleFrame.minX, min(originX, visibleFrame.maxX - targetSize.width))
        originY = max(visibleFrame.minY, min(originY, visibleFrame.maxY - targetSize.height))

        let targetFrame = NSRect(origin: NSPoint(x: originX, y: originY), size: targetSize)

        let duration = wasCollapsed ? 0.3 : 0.25
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(targetFrame, display: true)
        }

        startInactivityTimer()
    }

    // MARK: - Panel Side Computation

    func computePanelSide() {
        guard let window else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let screenCenterX = screen.visibleFrame.midX
        let windowCenterX = window.frame.midX

        panelSide = windowCenterX > screenCenterX ? .left : .right
    }

    // MARK: - Interaction / Inactivity

    func noteActivity() {
        if mode == .collapsed {
            transitionToCompact()
        }
        resetInactivityTimer()
    }

    private func startInactivityTimer() {
        cancelInactivityTimer()
        inactivityTimer = Timer.scheduledTimer(
            withTimeInterval: inactivityDelay,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleInactivityTimeout()
            }
        }
    }

    private func resetInactivityTimer() {
        startInactivityTimer()
    }

    private func cancelInactivityTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
    }

    private func handleInactivityTimeout() {
        transitionToCollapsed()
    }

    // MARK: - Visibility

    func hideWindow() {
        cancelInactivityTimer()
        window?.orderOut(nil)
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        startInactivityTimer()
    }

    // MARK: - Helpers

    private func applyModeToWindow() {
        guard let window else { return }
        switch mode {
        case .collapsed:
            window.styleMask = [.borderless]
            window.isMovableByWindowBackground = true
            window.level = .floating
        case .compact:
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.level = .normal
            window.backgroundColor = .clear
            window.isOpaque = false
            setWindowButtonsHidden(true)
        }
    }

    // MARK: - Title Bar Hover (show/hide window buttons)

    /// Hide or show the standard traffic-light window buttons.
    private func setWindowButtonsHidden(_ hidden: Bool) {
        guard let window else { return }
        for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(buttonType)?.isHidden = hidden
        }
    }

    /// Install a tracking helper on the window's content view so we
    /// can show/hide the traffic-light buttons on hover.
    private func installTitleBarTracker() {
        guard let window, let contentView = window.contentView else { return }

        // Remove previous helper if any
        titleBarTracker?.removeFromSuperview()

        let helper = TitleBarTrackingHelper(
            titleBarHeight: titleBarHoverHeight,
            onMouseEnter: { [weak self] in self?.setWindowButtonsHidden(false) },
            onMouseExit: { [weak self] in self?.setWindowButtonsHidden(true) }
        )
        helper.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(helper)

        NSLayoutConstraint.activate([
            helper.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            helper.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            helper.topAnchor.constraint(equalTo: contentView.topAnchor),
            helper.heightAnchor.constraint(equalToConstant: titleBarHoverHeight)
        ])

        titleBarTracker = helper
    }
}

// MARK: - TitleBarTrackingHelper

/// A transparent view placed at the top of the content view that
/// installs an `NSTrackingArea` to detect mouse entry / exit
/// in the title bar region.
private final class TitleBarTrackingHelper: NSView {
    private let onMouseEnter: () -> Void
    private let onMouseExit: () -> Void
    private let titleBarHeight: CGFloat

    init(titleBarHeight: CGFloat, onMouseEnter: @escaping () -> Void, onMouseExit: @escaping () -> Void) {
        self.titleBarHeight = titleBarHeight
        self.onMouseEnter = onMouseEnter
        self.onMouseExit = onMouseExit
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEnter()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExit()
    }
}
