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
///
/// When the orb collapses due to inactivity, it docks to the top-left corner
/// of the screen (below the menu bar). When Fae starts speaking (assistant
/// generating), the window automatically expands back to compact mode and
/// comes to the front so the user can see the response.
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

    /// Padding from the left edge and top of the visible frame when collapsed.
    private let collapsedEdgePadding: CGFloat = 12

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

    /// Notification observers for pipeline events (assistant generating).
    private var observations: [NSObjectProtocol] = []

    // MARK: - Init / Deinit

    init() {
        subscribeToAssistantEvents()
    }

    deinit {
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
        }
    }

    // MARK: - Transitions

    func transitionToCollapsed() {
        guard mode != .collapsed else { return }

        mode = .collapsed
        titleBarTracker?.removeFromSuperview()
        titleBarTracker = nil

        guard let window else { return }

        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame
        let targetSize = NSSize(width: collapsedSize, height: collapsedSize)

        // Dock to top-left of the screen, just below the menu bar.
        // visibleFrame.maxY is the bottom of the menu bar in macOS coordinates
        // (origin at bottom-left), so we subtract the orb height to sit just below it.
        let originX = visibleFrame.minX + collapsedEdgePadding
        let originY = visibleFrame.maxY - targetSize.height - collapsedEdgePadding
        let targetFrame = NSRect(origin: NSPoint(x: originX, y: originY), size: targetSize)

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
        let visibleFrame = screen.visibleFrame

        let originX: CGFloat
        let originY: CGFloat

        if wasCollapsed {
            // When expanding from collapsed orb in top-left, position the
            // compact window anchored at the top-left of the visible frame
            // so it feels like a natural expansion from the orb's docked position.
            originX = visibleFrame.minX + collapsedEdgePadding
            originY = visibleFrame.maxY - targetSize.height - collapsedEdgePadding
        } else {
            // Already in compact mode — center on current position, clamped to screen.
            let currentFrame = window.frame
            var x = currentFrame.midX - targetSize.width / 2
            var y = currentFrame.midY - targetSize.height / 2
            x = max(visibleFrame.minX, min(x, visibleFrame.maxX - targetSize.width))
            y = max(visibleFrame.minY, min(y, visibleFrame.maxY - targetSize.height))
            originX = x
            originY = y
        }

        let targetFrame = NSRect(origin: NSPoint(x: originX, y: originY), size: targetSize)

        let duration = wasCollapsed ? 0.3 : 0.25
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(targetFrame, display: true)
        }

        // Bring the window to the front so the user can see Fae's response.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

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

    // MARK: - Assistant Event Subscription

    /// Subscribe to `.faeAssistantGenerating` so the window automatically
    /// expands from collapsed to compact when Fae starts speaking. This
    /// ensures the user always sees Fae's response even if the orb had
    /// auto-hidden due to inactivity.
    private func subscribeToAssistantEvents() {
        let center = NotificationCenter.default

        observations.append(
            center.addObserver(
                forName: .faeAssistantGenerating, object: nil, queue: .main
            ) { [weak self] notification in
                let active = notification.userInfo?["active"] as? Bool ?? false
                Task { @MainActor [weak self] in
                    guard let self, active else { return }
                    // Fae is generating a response — bring the window back
                    // to compact mode if it was collapsed.
                    self.noteActivity()
                }
            }
        )
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
