import AppKit
import Combine

/// Manages the orb window mode (collapsed / compact) and inactivity auto-hide.
///
/// Panel expansion logic has been removed — conversation and canvas are now
/// independent native windows managed by `AuxiliaryWindowManager`.
///
/// The window is fully frameless (`.borderless`) so there is no title bar to
/// fight with. `isMovableByWindowBackground` allows drag-to-move. The context
/// menu (right-click) provides Close/Hide/Quit actions.
///
/// When the orb collapses due to inactivity, it docks to the top-left corner
/// of the screen (below the menu bar). When Fae starts speaking (assistant
/// generating), the window automatically expands back to compact mode and
/// comes to the front so the user can see the response.
///
/// ## Glass Architecture
///
/// The frosted-glass effect uses SwiftUI's `.ultraThinMaterial` in dark mode
/// applied via `ContentView`. The window is configured with:
/// - `.borderless` styleMask (no title bar)
/// - `backgroundColor = .clear` + `isOpaque = false` for transparency
/// - `.fullSizeContentView` so SwiftUI fills the entire frame
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

    /// Padding from the left edge and top of the visible frame when collapsed.
    private let collapsedEdgePadding: CGFloat = 12

    // MARK: - Window Reference

    weak var window: NSWindow? {
        didSet {
            guard let window else { return }

            // Disable macOS state restoration — stale frames from previous
            // sessions cause windows to appear in wrong positions.
            window.isRestorable = false

            // ── Frameless window ────────────────────────────────────────
            // Remove .titled to eliminate the title bar entirely.
            // Keep .fullSizeContentView so SwiftUI fills the frame.
            // Keep .resizable so the user can still resize.
            window.styleMask = [.borderless, .fullSizeContentView, .resizable]
            window.isMovableByWindowBackground = true
            window.hasShadow = true

            // ── Transparency ─────────────────────────────────────────
            window.backgroundColor = .clear
            window.isOpaque = false

            // ── Frame on primary screen ──────────────────────────────
            let screen = NSScreen.screens.first ?? NSScreen.main ?? NSScreen.screens[0]
            let visible = screen.visibleFrame
            let size = NSSize(width: compactWidth, height: compactHeight)
            let x = visible.midX - size.width / 2
            let y = visible.midY - size.height / 2
            window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)

            window.minSize = NSSize(width: 280, height: 400)
            window.maxSize = NSSize(width: 500, height: 700)

            // ── Re-enforce after SwiftUI resets ──────────────────────
            DispatchQueue.main.async { [weak self] in
                self?.enforceWindowProperties()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.enforceWindowProperties()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.enforceWindowProperties()
            }
        }
    }

    // MARK: - Timer

    private var inactivityTimer: Timer?

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

        guard let window else { return }

        let screen = window.screen ?? NSScreen.screens.first ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame
        let targetSize = NSSize(width: collapsedSize, height: collapsedSize)

        // Dock to top-left of the screen, just below the menu bar.
        let originX = visibleFrame.minX + collapsedEdgePadding
        let originY = visibleFrame.maxY - targetSize.height - collapsedEdgePadding
        let targetFrame = NSRect(origin: NSPoint(x: originX, y: originY), size: targetSize)

        // Float above other windows when collapsed.
        window.level = .floating

        // Temporarily allow the window to go below its minSize for the
        // collapsed orb (80x80 is smaller than the 280x400 minimum).
        window.minSize = NSSize(width: collapsedSize, height: collapsedSize)

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

        // Restore normal window level and min size.
        window.level = .normal
        window.minSize = NSSize(width: 280, height: 400)

        let screen = window.screen ?? NSScreen.screens.first ?? NSScreen.screens[0]
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
        let screen = window.screen ?? NSScreen.screens.first ?? NSScreen.screens[0]
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

    // MARK: - Window Property Enforcement

    /// Re-apply critical window properties that SwiftUI's WindowGroup
    /// may reset after initial configuration.
    private func enforceWindowProperties() {
        guard let window = self.window else { return }

        window.backgroundColor = .clear
        window.isOpaque = false

        // Re-assert frameless style.
        window.styleMask = [.borderless, .fullSizeContentView, .resizable]
    }
}
