import AppKit
import Combine

/// Manages the window mode (collapsed / compact / expanded), inactivity auto-hide,
/// and frame calculations for side-extending panels.
@MainActor
final class WindowStateController: ObservableObject {

    // MARK: - Types

    enum Mode: String {
        case collapsed
        case compact
        case expanded
    }

    enum PanelSide: String {
        case left
        case right
    }

    // MARK: - Published State

    @Published var mode: Mode = .compact
    @Published var panelSide: PanelSide = .right
    @Published var conversationPanelOpen = false
    @Published var canvasPanelOpen = false
    /// Monotonic counter incremented when panels are force-closed (e.g. on
    /// inactivity collapse). `ConversationWebView` diffs this to strip `.open`
    /// CSS classes from the DOM so panels don't reappear on restore.
    @Published var panelCloseGeneration: Int = 0

    // MARK: - Constants

    private let compactWidth: CGFloat = 340
    private let compactHeight: CGFloat = 500
    private let collapsedSize: CGFloat = 80
    private let panelWidth: CGFloat = 420
    private let inactivityDelay: TimeInterval = 30.0

    // MARK: - Window Reference

    weak var window: NSWindow? {
        didSet { applyModeToWindow() }
    }

    // MARK: - Timer

    private var inactivityTimer: Timer?

    // MARK: - Transitions

    func transitionToCollapsed() {
        guard mode != .collapsed else { return }

        // Close panels first if expanded
        if mode == .expanded {
            closePanelsInternal()
        }

        mode = .collapsed

        guard let window else { return }

        let currentFrame = window.frame
        let targetSize = NSSize(width: collapsedSize, height: collapsedSize)

        // Center the collapsed orb on the previous window center
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
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isMovableByWindowBackground = false
            window.level = .normal
            window.backgroundColor = .windowBackgroundColor
            window.isOpaque = true
        }

        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let targetSize = NSSize(width: compactWidth, height: compactHeight)

        // Center on current position, clamped to screen
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

    func expandForPanel() {
        guard mode != .collapsed else { return }

        computePanelSide()

        let openCount = openPanelCount()
        guard openCount > 0 else { return }

        mode = .expanded

        guard let window else { return }

        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame
        let totalPanelWidth = CGFloat(openCount) * panelWidth
        let targetWidth = compactWidth + totalPanelWidth
        let currentFrame = window.frame

        var targetFrame: NSRect

        if panelSide == .right {
            // Extend rightward from the current left edge
            targetFrame = NSRect(
                x: currentFrame.minX,
                y: currentFrame.minY,
                width: targetWidth,
                height: currentFrame.height
            )

            // If extending off-screen right, flip to left
            if targetFrame.maxX > visibleFrame.maxX {
                // Try extending leftward instead
                let flippedX = currentFrame.maxX - targetWidth
                if flippedX >= visibleFrame.minX {
                    panelSide = .left
                    targetFrame.origin.x = flippedX
                } else {
                    // Clamp to screen right edge
                    targetFrame.origin.x = visibleFrame.maxX - targetWidth
                }
            }
        } else {
            // Extend leftward from the current right edge
            let originX = currentFrame.maxX - targetWidth
            targetFrame = NSRect(
                x: originX,
                y: currentFrame.minY,
                width: targetWidth,
                height: currentFrame.height
            )

            // If extending off-screen left, flip to right
            if targetFrame.minX < visibleFrame.minX {
                let flippedX = currentFrame.minX
                if flippedX + targetWidth <= visibleFrame.maxX {
                    panelSide = .right
                    targetFrame.origin.x = flippedX
                } else {
                    // Clamp to screen left edge
                    targetFrame.origin.x = visibleFrame.minX
                }
            }
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(targetFrame, display: true)
        }

        resetInactivityTimer()
    }

    func collapsePanel() {
        guard mode == .expanded else { return }

        let openCount = openPanelCount()

        if openCount == 0 {
            // No panels open, shrink to compact
            mode = .compact

            guard let window else { return }

            let currentFrame = window.frame
            let targetWidth = compactWidth

            var originX: CGFloat
            if panelSide == .right {
                originX = currentFrame.minX
            } else {
                originX = currentFrame.maxX - targetWidth
            }

            let targetFrame = NSRect(
                x: originX,
                y: currentFrame.minY,
                width: targetWidth,
                height: currentFrame.height
            )

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(targetFrame, display: true)
            }
        } else {
            // Still has panels open — resize to match
            expandForPanel()
        }

        resetInactivityTimer()
    }

    // MARK: - Panel Side Computation

    func computePanelSide() {
        guard let window else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let screenCenterX = screen.visibleFrame.midX
        let windowCenterX = window.frame.midX

        panelSide = windowCenterX > screenCenterX ? .left : .right
    }

    // MARK: - Panel Events

    func panelOpened(_ panel: String) {
        if panel == "conversation" {
            conversationPanelOpen = true
        } else if panel == "canvas" {
            canvasPanelOpen = true
        }
        expandForPanel()
    }

    func panelClosed(_ panel: String) {
        if panel == "conversation" {
            conversationPanelOpen = false
        } else if panel == "canvas" {
            canvasPanelOpen = false
        }
        collapsePanel()
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
        // Never collapse while panels are open
        if conversationPanelOpen || canvasPanelOpen {
            cancelInactivityTimer()
            return
        }
        startInactivityTimer()
    }

    private func cancelInactivityTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
    }

    private func handleInactivityTimeout() {
        // Don't collapse if panels are open
        guard !conversationPanelOpen, !canvasPanelOpen else {
            return
        }
        transitionToCollapsed()
    }

    // MARK: - Helpers

    private func openPanelCount() -> Int {
        var count = 0
        if conversationPanelOpen { count += 1 }
        if canvasPanelOpen { count += 1 }
        return count
    }

    private func closePanelsInternal() {
        conversationPanelOpen = false
        canvasPanelOpen = false
        panelCloseGeneration += 1
    }

    private func applyModeToWindow() {
        guard let window else { return }
        switch mode {
        case .collapsed:
            window.styleMask = [.borderless]
            window.isMovableByWindowBackground = true
            window.level = .floating
        case .compact, .expanded:
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isMovableByWindowBackground = false
            window.level = .normal
        }
    }
}
