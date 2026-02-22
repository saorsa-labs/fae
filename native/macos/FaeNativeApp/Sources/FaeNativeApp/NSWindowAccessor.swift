import AppKit
import SwiftUI

/// Captures the `NSWindow` reference from a SwiftUI view hierarchy so that
/// programmatic window manipulation (resizing, style changes) is possible.
///
/// Uses `viewDidMoveToWindow()` instead of `DispatchQueue.main.async` to
/// reliably detect window attachment — the async approach can miss the window
/// when launched from a `.app` bundle (different SwiftUI lifecycle timing).
struct NSWindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {}

    /// Custom `NSView` subclass that fires a callback the moment AppKit
    /// attaches it to a window via `viewDidMoveToWindow()`.
    class WindowObserverView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        private var didFire = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !didFire, let window = self.window else { return }
            didFire = true
            onWindow?(window)
        }
    }
}
