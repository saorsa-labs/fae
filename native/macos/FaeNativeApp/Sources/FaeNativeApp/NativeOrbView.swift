import AppKit
import SwiftUI

/// Pure SwiftUI + Metal view rendering the fog-cloud orb animation.
///
/// Replaces `OrbAnimationWebView` (Phase 2 of native migration).
/// Uses `TimelineView(.animation)` for display-rate rendering and
/// `ShaderLibrary.bundle(Bundle.module).fogCloudOrb(...)` for the GPU-computed orb.
///
/// ## Architecture
///
/// ```
/// TimelineView(.animation)          ← fires every frame
///   └─ GeometryReader               ← provides view size
///        └─ Rectangle.colorEffect()  ← applies Metal fragment shader
///
/// OrbClickTarget (overlay)           ← handles mouse clicks & hover
/// ```
///
/// The shader runs as a single-pass fragment shader applied via
/// `.colorEffect()`, computing fog layers, blobs, wisps, stars, and
/// grain per-pixel on the GPU.
struct NativeOrbView: View {
    @ObservedObject var orbAnimation: OrbAnimationState
    var audioRMS: Double
    var windowMode: String

    var onLoad: (() -> Void)?
    var onOrbClicked: (() -> Void)?
    var onOrbContextMenu: (() -> Void)?

    /// Metal shader library loaded from the Fae resource bundle (pre-compiled metallib).
    private static let shaderLib: ShaderLibrary = .bundle(Bundle.faeResources)

    @State private var startDate = Date()
    @State private var hasNotifiedLoad = false
    @State private var pointerLocation: CGPoint = .zero
    @State private var isHovering = false

    var body: some View {
        TimelineView(.animation) { context in
            let time = Float(context.date.timeIntervalSince(startDate))
            let now = CACurrentMediaTime()

            // Update spring interpolation each frame. Safe to call here:
            // `current` and `colors` are NOT @Published, so no SwiftUI
            // state-mutation-during-body warning is triggered.
            let _ = orbAnimation.update(at: now)

            GeometryReader { geometry in
                orbShaderCanvas(time: time, size: geometry.size, now: now)
            }
        }
        .overlay {
            OrbClickTarget(
                onClicked: { onOrbClicked?() },
                onContextMenu: { onOrbContextMenu?() },
                onHover: { location in
                    pointerLocation = location ?? .zero
                    isHovering = location != nil
                }
            )
        }
        .onAppear {
            guard !hasNotifiedLoad else { return }
            hasNotifiedLoad = true
            onLoad?()
        }
    }

    // MARK: - Shader Canvas

    @ViewBuilder
    private func orbShaderCanvas(time: Float, size: CGSize, now: TimeInterval) -> some View {
        let snap = orbAnimation.current
        let colors = orbAnimation.colors
        let anticipation = orbAnimation.anticipationScale(at: now)

        // Normalised pointer position (0–1 range).
        let pX = Float(pointerLocation.x / max(size.width, 1))
        let pY = Float(pointerLocation.y / max(size.height, 1))
        let pInfluence: Float = isHovering ? 1.0 : 0.0

        Rectangle()
            .fill(Color.black)
            .colorEffect(
                Self.shaderLib.fogCloudOrb(
                    // Time & geometry
                    .float(time),
                    .float2(Float(size.width), Float(size.height)),
                    // Audio & interaction
                    .float(Float(audioRMS)),
                    .float2(pX, pY),
                    .float(pInfluence),
                    // Snapshot properties (15 floats)
                    .float(snap.hueShift),
                    .float(snap.speedScale),
                    .float(snap.breathAmplitude),
                    .float(snap.fogDensity),
                    .float(snap.morphAmplitude),
                    .float(snap.morphFreq),
                    .float(snap.morphSpeed),
                    .float(snap.shimmer),
                    .float(snap.asymmetry),
                    .float(snap.starAlpha),
                    .float(snap.outerAlpha),
                    .float(snap.wispSize),
                    .float(snap.wispAlpha),
                    .float(snap.blobAlpha),
                    .float(snap.innerGlow),
                    // Colors (9 individual components)
                    .float(colors.0.x), .float(colors.0.y), .float(colors.0.z),
                    .float(colors.1.x), .float(colors.1.y), .float(colors.1.z),
                    .float(colors.2.x), .float(colors.2.y), .float(colors.2.z),
                    // Flash
                    .float(0), // flashType: 0=none
                    .float(0), // flashProgress
                    // Anticipation
                    .float(anticipation)
                )
            )
    }
}

// MARK: - Click Target

/// Transparent NSView overlay that captures mouse clicks and hover position.
///
/// SwiftUI on macOS lacks built-in right-click gesture support, so we use
/// a thin `NSViewRepresentable` to forward mouseUp (click), rightMouseDown
/// (context menu), and mouseMoved (pointer tracking) events.
private struct OrbClickTarget: NSViewRepresentable {
    var onClicked: () -> Void
    var onContextMenu: () -> Void
    var onHover: (CGPoint?) -> Void

    func makeNSView(context: Context) -> OrbClickNSView {
        let view = OrbClickNSView()
        view.onClicked = onClicked
        view.onContextMenu = onContextMenu
        view.onHover = onHover

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: view,
            userInfo: nil
        )
        view.addTrackingArea(trackingArea)

        return view
    }

    func updateNSView(_ nsView: OrbClickNSView, context: Context) {
        nsView.onClicked = onClicked
        nsView.onContextMenu = onContextMenu
        nsView.onHover = onHover
    }
}

/// Concrete NSView subclass that forwards mouse events to closures.
private final class OrbClickNSView: NSView {
    var onClicked: (() -> Void)?
    var onContextMenu: (() -> Void)?
    var onHover: ((CGPoint?) -> Void)?

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 1 {
            onClicked?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?()
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onHover?(location)
    }

    override func mouseEntered(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onHover?(location)
    }

    override func mouseExited(with event: NSEvent) {
        _ = event
        onHover?(nil)
    }
}
