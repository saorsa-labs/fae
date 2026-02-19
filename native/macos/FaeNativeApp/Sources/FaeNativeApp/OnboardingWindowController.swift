import AppKit
import Combine

// MARK: - OnboardingWindowDelegate

/// Internal window delegate that prevents the user from dismissing the onboarding
/// window via the standard close button while onboarding is in progress.
private final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {

    // MARK: - NSWindowDelegate

    /// Prevents the window from closing while onboarding is active.
    ///
    /// - Parameter sender: The window requesting permission to close.
    /// - Returns: Always `false` — the onboarding flow controls dismissal programmatically.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return false
    }
}

// MARK: - OnboardingWindowController

/// Owns and manages the programmatic `NSWindow` used to present the onboarding
/// experience.
///
/// The window uses a full-size, transparent title bar over an
/// `NSVisualEffectView` background to achieve a glassmorphic blur effect.
/// It does not allow user-initiated closing; call ``close()`` from the
/// application after the onboarding flow completes.
///
/// Usage:
/// ```swift
/// let controller = OnboardingWindowController()
/// controller.show()
/// // … when onboarding finishes …
/// controller.close()
/// ```
@MainActor
final class OnboardingWindowController: ObservableObject {

    // MARK: - Published State

    /// Whether the onboarding window is currently visible on screen.
    @Published private(set) var isVisible: Bool = false

    // MARK: - Private State

    private let window: NSWindow
    private let windowDelegate: OnboardingWindowDelegate

    // MARK: - Constants

    private enum Layout {
        static let windowSize = NSSize(width: 520, height: 640)
    }

    // MARK: - Initialisation

    /// Creates the onboarding window and configures all visual properties.
    ///
    /// The window is not shown until ``show()`` is called.
    init() {
        // Build the window.
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: Layout.windowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isReleasedWhenClosed = false
        win.backgroundColor = .clear

        // Glassmorphic blur background.
        // NSWindow automatically sizes its contentView to fill the content area,
        // so no additional AutoLayout constraints are needed here.
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active

        win.contentView = effectView

        // Attach the delegate that blocks user-initiated closes.
        let delegate = OnboardingWindowDelegate()
        win.delegate = delegate

        self.window = win
        self.windowDelegate = delegate
    }

    // MARK: - Public Interface

    /// Shows the onboarding window, centered on the main screen, and makes it
    /// the key window.
    ///
    /// If the window is already visible this call is a no-op.
    func show() {
        guard !isVisible else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    /// Programmatically closes the onboarding window and updates ``isVisible``.
    ///
    /// This bypasses the delegate's `windowShouldClose` gate, so it is the
    /// only way to dismiss the window.
    func close() {
        window.close()
        isVisible = false
    }
}
