import AppKit
import Combine

/// Manages the retained Swift main window for license/status chrome.
///
/// The Rust orb host owns the product conversation UI. This window stays
/// hidden while the orb host runs and is surfaced only by explicit user
/// actions (global hotkey, menu items) or when the orb host is unavailable.
/// It no longer contains the legacy transcript or text composer.
///
/// The window is fully frameless (`.borderless`) so there is no title bar to
/// fight with. `isMovableByWindowBackground` allows drag-to-move.
///
/// ## Glass Architecture
///
/// The frosted-glass effect uses SwiftUI's `.ultraThinMaterial` in dark mode
/// applied by the root status view. The window is configured with:
/// - `.borderless` styleMask (no title bar)
/// - `backgroundColor = .clear` + `isOpaque = false` for transparency
/// - `.fullSizeContentView` so SwiftUI fills the entire frame
@MainActor
final class WindowStateController: ObservableObject {

    // MARK: - Constants

    private let windowWidth: CGFloat = 400
    private let windowHeight: CGFloat = 740

    // MARK: - Window Reference

    weak var window: NSWindow? {
        didSet {
            guard let window, window !== oldValue else { return }

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
            guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            let size = NSSize(width: windowWidth, height: windowHeight)
            let x = visible.midX - size.width / 2
            let y = visible.midY - size.height / 2
            window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)

            window.minSize = NSSize(width: 400, height: 660)
            window.maxSize = NSSize(width: 400, height: 1400)

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

    // MARK: - Visibility

    func hideWindow() {
        window?.orderOut(nil)
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
