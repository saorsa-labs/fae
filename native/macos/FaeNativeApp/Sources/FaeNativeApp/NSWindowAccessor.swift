import AppKit
import SwiftUI

/// Captures the `NSWindow` reference from a SwiftUI view hierarchy so that
/// programmatic window manipulation (resizing, style changes) is possible.
struct NSWindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
