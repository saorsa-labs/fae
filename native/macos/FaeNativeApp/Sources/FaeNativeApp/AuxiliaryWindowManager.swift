import AppKit
import Combine
import SwiftUI

/// Owns and positions two auxiliary `NSPanel` windows (conversation and canvas)
/// near the main orb window. Follows the `OnboardingWindowController` pattern
/// of embedding SwiftUI views via `NSHostingView`.
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

    private let panelGap: CGFloat = 8
    private let conversationSize = NSSize(width: 340, height: 500)
    private let canvasSize = NSSize(width: 380, height: 460)

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

    // MARK: - Conversation Window

    func showConversation() {
        if conversationPanel == nil {
            conversationPanel = makeConversationPanel()
        }
        guard let panel = conversationPanel else { return }
        repositionConversation(panel)
        panel.orderFront(nil)
        isConversationVisible = true
    }

    func hideConversation() {
        conversationPanel?.orderOut(nil)
        isConversationVisible = false
    }

    func toggleConversation() {
        if isConversationVisible {
            hideConversation()
        } else {
            showConversation()
        }
    }

    // MARK: - Canvas Window

    func showCanvas() {
        if canvasPanel == nil {
            canvasPanel = makeCanvasPanel()
        }
        guard let panel = canvasPanel else { return }
        repositionCanvas(panel)
        panel.orderFront(nil)
        isCanvasVisible = true
    }

    func hideCanvas() {
        canvasPanel?.orderOut(nil)
        isCanvasVisible = false
    }

    func toggleCanvas() {
        if isCanvasVisible {
            hideCanvas()
        } else {
            showCanvas()
        }
    }

    // MARK: - Positioning

    /// Reposition both windows relative to the orb window frame.
    func repositionWindows(relativeTo orbFrame: NSRect) {
        if let panel = conversationPanel, isConversationVisible {
            let frame = conversationFrame(relativeTo: orbFrame)
            panel.setFrame(frame, display: true)
        }
        if let panel = canvasPanel, isCanvasVisible {
            let frame = canvasFrame(relativeTo: orbFrame)
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: - Panel Creation

    private func makeConversationPanel() -> NSPanel {
        let delegate = PanelCloseDelegate { [weak self] in
            self?.isConversationVisible = false
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
            self?.isCanvasVisible = false
        }
        canvasPanelDelegate = delegate
        let panel = makeUtilityPanel(size: canvasSize, title: "Canvas", delegate: delegate)

        guard let controller = canvasController else { return panel }

        let contentView = CanvasWindowView(
            canvasController: controller,
            onClose: { [weak self] in self?.hideCanvas() }
        )
        embedSwiftUI(contentView, in: panel)
        return panel
    }

    private func makeUtilityPanel(size: NSSize, title: String, delegate: PanelCloseDelegate) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
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

    private func conversationFrame(relativeTo orbFrame: NSRect) -> NSRect {
        let side = preferredSide()
        let size = conversationSize
        let y = orbFrame.maxY - size.height

        let x: CGFloat
        if side == .right {
            x = orbFrame.maxX + panelGap
        } else {
            x = orbFrame.minX - size.width - panelGap
        }

        return clampToScreen(NSRect(x: x, y: y, width: size.width, height: size.height))
    }

    private func canvasFrame(relativeTo orbFrame: NSRect) -> NSRect {
        let side = preferredSide()
        let size = canvasSize

        // Stack below conversation if both visible, otherwise align to orb top.
        let topOffset: CGFloat
        if isConversationVisible {
            topOffset = conversationSize.height + panelGap
        } else {
            topOffset = 0
        }
        let y = orbFrame.maxY - topOffset - size.height

        let x: CGFloat
        if side == .right {
            x = orbFrame.maxX + panelGap
        } else {
            x = orbFrame.minX - size.width - panelGap
        }

        return clampToScreen(NSRect(x: x, y: y, width: size.width, height: size.height))
    }

    private func clampToScreen(_ frame: NSRect) -> NSRect {
        guard let screen = NSScreen.main else { return frame }
        let visible = screen.visibleFrame
        var result = frame
        result.origin.x = max(visible.minX, min(result.origin.x, visible.maxX - result.width))
        result.origin.y = max(visible.minY, min(result.origin.y, visible.maxY - result.height))
        return result
    }

    private func repositionConversation(_ panel: NSPanel) {
        guard let orbWindow = windowState?.window else { return }
        let frame = conversationFrame(relativeTo: orbWindow.frame)
        panel.setFrame(frame, display: true)
    }

    private func repositionCanvas(_ panel: NSPanel) {
        guard let orbWindow = windowState?.window else { return }
        let frame = canvasFrame(relativeTo: orbWindow.frame)
        panel.setFrame(frame, display: true)
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
        sender.orderOut(nil)
        return false
    }
}
