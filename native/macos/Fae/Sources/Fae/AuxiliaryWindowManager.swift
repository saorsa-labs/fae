import AppKit
import Combine
import SwiftUI

/// NSPanel subclass that allows becoming key window when clicked.
///
/// Standard `.nonactivatingPanel` prevents `canBecomeKey`, which means
/// button clicks inside hosted SwiftUI content are silently dropped. This
/// subclass re-enables key status so clicks work, while keeping
/// `.nonactivatingPanel` to avoid activating the app.
private final class InteractivePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns and positions auxiliary `NSPanel` windows (approval, debug console).
///
/// All panels are `.nonactivatingPanel` so they never steal keyboard
/// focus from the orb's input bar.
@MainActor
final class AuxiliaryWindowManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isApprovalVisible: Bool = false
    @Published private(set) var isDebugConsoleVisible: Bool = false

    // MARK: - Private State

    private var approvalPanel: NSPanel?
    private var debugConsolePanel: NSPanel?
    private var debugConsolePanelDelegate: PanelCloseDelegate?

    // MARK: - Debug Console Controller

    /// Set by FaeAppDelegate during wiring before the debug console is shown.
    var debugConsoleController: DebugConsoleController?

    // MARK: - Weak References

    weak var windowState: WindowStateController?
    weak var subtitleState: SubtitleStateController?
    var inputController: InputOverlayController?

    private var inputCancellable: AnyCancellable?

    // MARK: - Configuration

    /// Wire up observation of input overlay controller state. Call once after
    /// `inputController` is set.
    func observeInputController() {
        guard let controller = inputController else { return }
        inputCancellable = Publishers.CombineLatest3(
            controller.$activeInput,
            controller.$activeToolModeRequest,
            controller.$activeGovernanceConfirmation
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] input, toolMode, governance in
            if input != nil || toolMode != nil || governance != nil {
                self?.showApproval()
            } else {
                self?.hideApproval()
            }
        }
    }

    // MARK: - Focus Main Window

    /// Bring the retained non-conversation main window to front.
    ///
    /// The legacy Swift input bar has been removed; callers that want to send
    /// text should use the orb host composer or `FaeCore.injectText`.
    func focusMainWindow() {
        windowState?.showWindow()
    }

    // MARK: - Debug Console

    func showDebugConsole() {
        guard let controller = debugConsoleController else { return }
        if debugConsolePanel == nil { debugConsolePanel = makeDebugConsolePanel(controller: controller) }
        guard let panel = debugConsolePanel else { return }
        // Position at bottom-left of screen if no position set yet.
        if !panel.isVisible {
            if let screen = windowState?.window?.screen ?? NSScreen.main {
                let x = screen.visibleFrame.minX + 20
                let y = screen.visibleFrame.minY + 20
                panel.setFrameOrigin(NSPoint(x: x, y: y))
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
        guard let controller = inputController else { return }
        if approvalPanel == nil { approvalPanel = makeInputPanel(controller: controller) }
        guard let panel = approvalPanel else { return }

        // The approval card is a standalone floating panel — it must never
        // surface the hidden companion window (the orb host is the product
        // UI). Anchor over the companion window when it's visible, otherwise
        // center on the main screen.
        let panelSize = NSSize(width: 340, height: 300)
        let frame: NSRect
        if let anchorWindow = windowState?.window, anchorWindow.isVisible {
            let anchorFrame = anchorWindow.frame
            let x = anchorFrame.midX - panelSize.width / 2
            let y: CGFloat
            if anchorFrame.height > 400 {
                y = anchorFrame.midY - panelSize.height / 2
            } else {
                y = anchorFrame.maxY + 8
            }
            frame = clampToScreenFrame(
                NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height),
                screen: anchorWindow.screen
            )
        } else {
            let screen = NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            frame = NSRect(
                x: visible.midX - panelSize.width / 2,
                y: visible.midY - panelSize.height / 2,
                width: panelSize.width,
                height: panelSize.height
            )
        }

        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        // Float above other panels so it's never obscured.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 1
        }
        isApprovalVisible = true
    }

    /// Send a `runtime.stop` command to the pipeline.
    ///
    /// Intended as an emergency kill-switch — call this when Fae is misbehaving
    /// during tool execution. Stopping the runtime halts generation completely.
    func emergencyStop() {
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

    // MARK: - Panel Creation

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

    private func makeInputPanel(controller: InputOverlayController) -> NSPanel {
        let size = NSSize(width: 340, height: 300)
        // Use InteractivePanel so input buttons (Submit/Cancel, Enable Tools) receive clicks.
        // Plain NSPanel with .nonactivatingPanel has canBecomeKey=false -> clicks silently dropped.
        let panel = InteractivePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Input"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.hasShadow = false

        let view = InputOverlayView(controller: controller)
        embedSwiftUI(view.preferredColorScheme(.dark), in: panel)
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

    private func clampToScreenFrame(_ frame: NSRect, screen: NSScreen?) -> NSRect {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return frame }
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
