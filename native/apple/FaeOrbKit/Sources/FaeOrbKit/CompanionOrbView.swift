import SwiftUI

/// Cross-platform orb view that renders the fog-cloud orb via Metal shader.
///
/// Uses `ShaderLibrary` with the same `fogCloudOrb` fragment shader as macOS.
/// On iOS, touch interaction replaces mouse hover tracking.
/// On watchOS, falls back to a simplified SwiftUI gradient animation.
public struct CompanionOrbView: View {
    @ObservedObject public var orbAnimation: OrbAnimationState
    public var audioRMS: Double

    public var onOrbTapped: (() -> Void)?

    @State private var startDate = Date()

    public init(
        orbAnimation: OrbAnimationState,
        audioRMS: Double = 0,
        onOrbTapped: (() -> Void)? = nil
    ) {
        self.orbAnimation = orbAnimation
        self.audioRMS = audioRMS
        self.onOrbTapped = onOrbTapped
    }

    public var body: some View {
        #if os(watchOS)
        watchOrbView
        #else
        metalOrbView
        #endif
    }

    // MARK: - Metal Orb (iOS / macOS)

    #if !os(watchOS)
    private var metalOrbView: some View {
        TimelineView(.animation) { context in
            let time = Float(context.date.timeIntervalSince(startDate))
            let now = CACurrentMediaTime()
            let _ = orbAnimation.update(at: now)

            GeometryReader { geometry in
                orbShaderCanvas(time: time, size: geometry.size, now: now)
            }
        }
        .contentShape(Circle())
        .onTapGesture {
            onOrbTapped?()
        }
    }

    @ViewBuilder
    private func orbShaderCanvas(time: Float, size: CGSize, now: TimeInterval) -> some View {
        let snap = orbAnimation.current
        let colors = orbAnimation.colors
        let anticipation = orbAnimation.anticipationScale(at: now)

        Rectangle()
            .fill(Color.black.opacity(0.001))
            .colorEffect(
                ShaderLibrary.bundle(Bundle.module).fogCloudOrb(
                    .float(time),
                    .float2(Float(size.width), Float(size.height)),
                    .float(Float(audioRMS)),
                    .float2(0.5, 0.5),  // No pointer on iOS
                    .float(0),           // No hover influence
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
                    .float(colors.0.x), .float(colors.0.y), .float(colors.0.z),
                    .float(colors.1.x), .float(colors.1.y), .float(colors.1.z),
                    .float(colors.2.x), .float(colors.2.y), .float(colors.2.z),
                    .float(0),           // flashType: none
                    .float(0),           // flashProgress
                    .float(anticipation)
                )
            )
    }
    #endif

    // MARK: - Simplified Orb (watchOS)

    #if os(watchOS)
    private var watchOrbView: some View {
        TimelineView(.animation) { context in
            let now = CACurrentMediaTime()
            let _ = orbAnimation.update(at: now)
            let time = context.date.timeIntervalSince(startDate)
            let colors = orbAnimation.colors
            let snap = orbAnimation.current

            let breathScale = 1.0 + Double(snap.breathAmplitude) * sin(time * Double(snap.speedScale) * 2.0)

            ZStack {
                // Outer glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(simd: colors.0).opacity(Double(snap.outerAlpha)),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 20,
                            endRadius: 40
                        )
                    )
                    .scaleEffect(breathScale * 1.3)

                // Core
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(simd: colors.1).opacity(0.9),
                                Color(simd: colors.0).opacity(0.6),
                                Color(simd: colors.2).opacity(0.3),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 30
                        )
                    )
                    .scaleEffect(breathScale)

                // Inner glow
                Circle()
                    .fill(Color.white.opacity(Double(snap.innerGlow) * 0.5))
                    .scaleEffect(breathScale * 0.4)
                    .blur(radius: 4)
            }
            .frame(width: 60, height: 60)
            .contentShape(Circle())
            .onTapGesture { onOrbTapped?() }
        }
    }
    #endif
}

// MARK: - Color Helper

private extension Color {
    init(simd: SIMD3<Float>) {
        self.init(
            red: Double(simd.x),
            green: Double(simd.y),
            blue: Double(simd.z)
        )
    }
}
