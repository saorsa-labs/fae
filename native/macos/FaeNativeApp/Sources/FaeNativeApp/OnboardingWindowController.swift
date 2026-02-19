import AppKit
import Combine
import SwiftUI

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

// MARK: - OnboardingContentView

/// Internal SwiftUI wrapper that observes ``OnboardingController`` and renders
/// the onboarding web view. SwiftUI's observation system ensures the web view
/// refreshes when `userName` or `permissionStates` change.
private struct OnboardingContentView: View {
    @ObservedObject var onboarding: OnboardingController
    var onPermissionHelp: (String) -> Void
    var onClose: () -> Void

    var body: some View {
        OnboardingWebView(
            onLoad: { },
            onRequestPermission: { permission in
                switch permission {
                case "microphone":
                    onboarding.requestMicrophone()
                case "contacts":
                    onboarding.requestContacts()
                default:
                    NSLog("OnboardingContentView: unknown permission: %@", permission)
                }
            },
            onPermissionHelp: onPermissionHelp,
            onComplete: {
                onboarding.complete()
                onClose()
            },
            onAdvance: {
                onboarding.advance()
            },
            userName: onboarding.userName,
            permissionStates: onboarding.permissionStates
        )
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
/// controller.configure(onboarding: onboardingState)
/// controller.show()
/// // … when onboarding finishes, close() is called automatically …
/// ```
@MainActor
final class OnboardingWindowController: ObservableObject {

    // MARK: - Published State

    /// Whether the onboarding window is currently visible on screen.
    @Published private(set) var isVisible: Bool = false

    // MARK: - Private State

    private let window: NSWindow
    private let windowDelegate: OnboardingWindowDelegate

    /// Retained reference to the TTS helper so it lives as long as the window.
    private var ttsHelper: OnboardingTTSHelper?

    /// Retained reference to the hosting view that embeds the SwiftUI content.
    private var hostingView: NSView?

    // MARK: - Constants

    private enum Layout {
        static let windowSize = NSSize(width: 520, height: 640)
        static let minSize = NSSize(width: 440, height: 560)
        static let maxSize = NSSize(width: 600, height: 720)
    }

    // MARK: - Initialisation

    /// Creates the onboarding window and configures all visual properties.
    ///
    /// The window is not shown until ``show()`` is called. Call
    /// ``configure(onboarding:)`` to embed the onboarding web view.
    init() {
        // Build the window.
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: Layout.windowSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isReleasedWhenClosed = false
        win.backgroundColor = .clear
        win.minSize = Layout.minSize
        win.maxSize = Layout.maxSize

        // Glassmorphic blur background.
        // NSWindow automatically sizes its contentView to fill the content area,
        // so no additional AutoLayout constraints are needed on the effectView itself.
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

    // MARK: - Configuration

    /// Embeds the onboarding web view inside the glassmorphic window.
    ///
    /// This wires all permission request callbacks, TTS help, and completion
    /// handling. The web view renders with a transparent background so the
    /// `NSVisualEffectView` blur shows through.
    ///
    /// Call this once before calling ``show()``.
    ///
    /// - Parameter onboarding: The shared onboarding controller that manages
    ///   permission state and flow progression.
    func configure(onboarding: OnboardingController) {
        let tts = OnboardingTTSHelper()
        self.ttsHelper = tts

        let contentView = OnboardingContentView(
            onboarding: onboarding,
            onPermissionHelp: { permission in
                tts.speak(permission: permission)
            },
            onClose: { [weak self] in
                self?.close()
            }
        )

        let hosting = NSHostingView(rootView: contentView)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        // Make the hosting view transparent so the blur background shows through.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear

        guard let effectView = window.contentView else { return }
        effectView.addSubview(hosting)

        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: effectView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
        ])

        self.hostingView = hosting
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
        ttsHelper?.stop()
        window.close()
        isVisible = false
    }
}
