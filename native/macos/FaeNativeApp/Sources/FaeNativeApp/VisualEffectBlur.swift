import AppKit
import SwiftUI

/// SwiftUI-native frosted-glass background using `NSVisualEffectView`.
///
/// Unlike the previous approach of wrapping `window.contentView` in an
/// `NSVisualEffectView` at the AppKit level (which broke every time
/// `styleMask` was set or SwiftUI recreated the hosting view), this
/// `NSViewRepresentable` lives **inside** the SwiftUI view hierarchy.
/// SwiftUI owns its lifecycle — it survives window property changes,
/// `styleMask` mutations, and view updates without any manual repair.
///
/// Usage:
/// ```swift
/// .background(VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow))
/// ```
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State

    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}
