import AppKit
import SwiftUI

/// SDF-based Metal shader rendering the Fae lifeform orb.
///
/// Uses `TimelineView(.animation(minimumInterval:paused:))` with adaptive frame
/// rate based on orb mode. The shader renders an organic blob shape via signed
/// distance fields with flowing gas texture, bioluminescent sparkles, rim glow,
/// and atmospheric halo.
///
/// ## Adaptive Frame Rate
///
/// | Mode      | FPS  | Interval | Rationale                              |
/// |-----------|------|----------|----------------------------------------|
/// | Idle      | ~1   | 1.0s     | Breathing is a 37s cycle — 1fps is enough |
/// | Listening | ~10  | 0.1s     | Responsive to audio level changes      |
/// | Thinking  | ~30  | 0.033s   | Smooth morphing/shimmer animation      |
/// | Speaking  | ~30  | 0.033s   | Audio-reactive with wisp movement      |
/// | Collapsed | pause| —        | Zero CPU when orb not visible          |
///
/// ## Fallback Behavior
///
/// If the Metal shader is unavailable, a CPU-side radial gradient is shown
/// underneath, ensuring the orb is always visible and clickable.
struct NativeOrbView: View {
    @ObservedObject var orbAnimation: OrbAnimationState
    var audioRMS: Double
    var windowMode: String
    /// Drop to minimum rendering when true (e.g. during voice enrollment).
    /// Frees GPU/Neural Engine for WeSpeaker speaker embedding inference.
    var reducedRendering: Bool = false

    var onLoad: (() -> Void)?
    var onOrbClicked: (() -> Void)?
    var onOrbContextMenu: (() -> Void)?

    /// Metal shader library loaded from the Fae resource bundle (pre-compiled metallib).
    private static let shaderLib: ShaderLibrary = .bundle(Bundle.faeResources)

    @State private var startDate = Date()
    @State private var hasNotifiedLoad = false
    @State private var pointerLocation: CGPoint = .zero
    @State private var isHovering = false

    /// Adaptive frame interval based on orb mode.
    /// Idle: 1.0s (~1fps) — breathing is so slow that higher cadence is wasted.
    /// Listening: 0.1s (~10fps) — responsive to audio but not wasteful.
    /// Thinking/Speaking: 0.033s (~30fps) — smooth animation.
    /// Reduced: 2.0s (~0.5fps) — during enrollment, free GPU for WeSpeaker.
    private var adaptiveInterval: Double {
        if reducedRendering { return 2.0 }
        switch orbAnimation.lastMode {
        case .idle: return 1.0       // ~1fps — breathing cycle is 37s, 1fps is plenty
        case .listening: return 0.1  // ~10fps — responsive to audio changes
        case .thinking, .speaking: return 0.033  // ~30fps — smooth animation
        }
    }

    /// Pause rendering when the window is collapsed (orb not visible).
    private var isPaused: Bool {
        windowMode == "collapsed"
    }

    var body: some View {
        Group {
            metalShaderCanvas
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

    // MARK: - Metal Shader Orb

    /// SDF-based Metal shader with organic blob shape and flowing gas.
    @ViewBuilder
    private var metalShaderCanvas: some View {
        TimelineView(.animation(minimumInterval: adaptiveInterval, paused: isPaused)) { context in
            let time = Float(context.date.timeIntervalSince(startDate))
            let now = CACurrentMediaTime()

            // Update spring interpolation each frame.
            let _ = orbAnimation.update(at: now)

            GeometryReader { geometry in
                orbShaderCanvas(time: time, size: geometry.size, now: now)
            }
        }
        // drawingGroup() flattens the TimelineView into a single Metal texture,
        // preventing SwiftUI layout invalidation from propagating to the parent
        // view tree on every frame.
        .drawingGroup()
    }

    // MARK: - Shader Canvas

    /// Renders the orb using Metal shader if available, with a gradient fallback
    /// always present underneath as a safety net for unsupported hardware.
    @ViewBuilder
    private func orbShaderCanvas(time: Float, size: CGSize, now: TimeInterval) -> some View {
        ZStack {
            // Gradient fallback — always rendered as the base layer.
            // If the Metal shader is unavailable or fails to compile on this
            // hardware, this gradient is the guaranteed visible orb.
            gradientFallback(size: size)

            // Metal shader canvas — layered on top.
            // If the shader is unavailable the colorEffect falls back to the
            // near-invisible base fill and the gradient underneath shows through.
            metalOrbCanvas(time: time, size: size, now: now)
        }
    }

    /// GPU-rendered orb via Metal shader.
    @ViewBuilder
    private func metalOrbCanvas(time: Float, size: CGSize, now: TimeInterval) -> some View {
        let snap = orbAnimation.current
        let colors = orbAnimation.colors
        let anticipation = orbAnimation.anticipationScale(at: now)

        // Normalised pointer position (0–1 range).
        let pX = Float(pointerLocation.x / max(size.width, 1))
        let pY = Float(pointerLocation.y / max(size.height, 1))
        let pInfluence: Float = isHovering ? 1.0 : 0.0

        Rectangle()
            .fill(Color.black.opacity(0.001))
            .colorEffect(
                Self.shaderLib.faeOrb(
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
                    .float(anticipation),
                    // Enchantment
                    .float(snap.tremor),
                    .float(snap.sparkleIntensity),
                    .float(snap.liquidFlow),
                    .float(snap.radiusBias)
                )
            )
    }

    /// CPU-side radial gradient fallback — always visible, no Metal required.
    ///
    /// Uses the orb's current color palette and breathing state to stay
    /// visually consistent with the normal orb appearance.
    @ViewBuilder
    private func gradientFallback(size: CGSize) -> some View {
        let colors = orbAnimation.colors
        let speed = Double(orbAnimation.current.speedScale)
        let breathe = sin(CACurrentMediaTime() * 0.42 * speed) > 0

        ZStack {
            // Outer glow
            RadialGradient(
                colors: [
                    Color(simd: colors.1).opacity(0.9),
                    Color(simd: colors.0).opacity(0.5),
                    Color.clear,
                ],
                center: .center,
                startRadius: size.width * 0.1,
                endRadius: size.width * 0.5
            )
            .scaleEffect(breathe ? 1.08 : 1.0)

            // Core glow
            RadialGradient(
                colors: [
                    Color.white.opacity(0.7),
                    Color(simd: colors.2).opacity(0.6),
                    Color.clear,
                ],
                center: .center,
                startRadius: 0,
                endRadius: size.width * 0.3
            )
            .scaleEffect(breathe ? 1.05 : 1.0)
        }
        .animation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true), value: breathe)
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

// MARK: - Color Helper

private extension Color {
    init(simd vector: SIMD3<Float>) {
        self.init(
            red: Double(vector.x),
            green: Double(vector.y),
            blue: Double(vector.z)
        )
    }
}
