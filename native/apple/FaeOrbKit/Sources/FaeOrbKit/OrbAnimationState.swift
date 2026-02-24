import Foundation
import SwiftUI

/// Drives smooth transitions between orb visual states using spring interpolation.
///
/// When any input changes, a 500ms spring transition from the current state
/// to the new target begins. The interpolated snapshot is consumed at display
/// refresh rate (via ``TimelineView(.animation)``).
///
/// ## Spring Easing
/// `springEase(t) = 1 - exp(-6t) * cos(2.5t)`
@MainActor
public final class OrbAnimationState: ObservableObject {

    // MARK: - Per-Frame Output

    /// Current interpolated snapshot (read every frame).
    public private(set) var current: OrbSnapshot = OrbSnapshot()

    /// Current interpolated colours (read every frame).
    public private(set) var colors: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) = (
        OrbColor.heatherMist, OrbColor.lochGreyGreen, OrbColor.silverMist
    )

    // MARK: - Anticipation State

    public enum AnticipationType {
        case contract, pause, burst

        public var duration: TimeInterval {
            switch self {
            case .contract: return 0.180
            case .pause: return 0.220
            case .burst: return 0.280
            }
        }

        public var amplitude: Float {
            switch self {
            case .contract: return -0.04
            case .pause: return -0.02
            case .burst: return 0.06
            }
        }
    }

    private var anticipation: AnticipationType?
    private var anticipationStart: TimeInterval = 0

    // MARK: - Transition State

    private static let transitionDuration: TimeInterval = 0.5

    private var fromSnapshot: OrbSnapshot = OrbSnapshot()
    private var toSnapshot: OrbSnapshot = OrbSnapshot()
    private var fromColors: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) = (
        OrbColor.heatherMist, OrbColor.lochGreyGreen, OrbColor.silverMist
    )
    private var toColors: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) = (
        OrbColor.heatherMist, OrbColor.lochGreyGreen, OrbColor.silverMist
    )
    private var transitionStart: TimeInterval = 0
    private var isTransitioning = false

    // MARK: - Input Tracking

    private var lastMode: OrbMode = .idle
    private var lastPalette: OrbPalette = .modeDefault
    private var lastFeeling: OrbFeeling = .neutral

    // MARK: - Init

    public init() {
        let snap = OrbFeeling.neutral.properties.withModeMultipliers(from: .idle)
        current = snap
        fromSnapshot = snap
        toSnapshot = snap
        let modeColors = OrbMode.idle.defaultColors
        colors = modeColors
        fromColors = modeColors
        toColors = modeColors
    }

    // MARK: - Target Setting

    /// Compute the target snapshot and colours from mode + palette + feeling,
    /// then begin a spring transition from the current state.
    public func setTarget(mode: OrbMode, palette: OrbPalette, feeling: OrbFeeling) {
        let now = CACurrentMediaTime()

        // Trigger anticipation if mode changed.
        if mode != lastMode {
            switch mode {
            case .thinking: anticipation = .contract
            case .listening: anticipation = .pause
            case .speaking: anticipation = .burst
            case .idle: anticipation = nil
            }
            if anticipation != nil {
                anticipationStart = now
            }
        }

        lastMode = mode
        lastPalette = palette
        lastFeeling = feeling

        let baseProps = feeling.properties.withModeMultipliers(from: mode)

        let targetColors: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
        if let paletteColors = palette.colors {
            targetColors = paletteColors
        } else {
            targetColors = mode.defaultColors
        }

        fromSnapshot = current
        fromColors = colors
        toSnapshot = baseProps
        toColors = targetColors
        transitionStart = now
        isTransitioning = true
    }

    // MARK: - Per-Frame Update

    /// Called every frame by the `TimelineView`. Updates the interpolated state.
    public func update(at time: TimeInterval) {
        if isTransitioning {
            let elapsed = time - transitionStart
            let progress = min(elapsed / Self.transitionDuration, 1.0)
            let t = Float(springEase(progress))

            current = OrbSnapshot.lerp(fromSnapshot, toSnapshot, t: t)
            colors = lerpColors(fromColors, toColors, t: t)

            if progress >= 1.0 {
                isTransitioning = false
                current = toSnapshot
                colors = toColors
            }
        }
    }

    /// Compute the anticipation scale for the current frame.
    public func anticipationScale(at time: TimeInterval) -> Float {
        guard let type = anticipation else { return 1.0 }
        let elapsed = time - anticipationStart
        let t = min(elapsed / type.duration, 1.0)
        if t >= 1.0 {
            anticipation = nil
            return 1.0
        }
        let eased = sin(Float(t) * .pi)
        return 1.0 + type.amplitude * eased
    }

    // MARK: - Spring Easing

    private func springEase(_ t: Double) -> Double {
        1.0 - exp(-6.0 * t) * cos(2.5 * t)
    }

    // MARK: - Colour Interpolation

    private func lerpColors(
        _ a: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>),
        _ b: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>),
        t: Float
    ) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        (
            lerpColorHSL(a.0, b.0, t: t),
            lerpColorHSL(a.1, b.1, t: t),
            lerpColorHSL(a.2, b.2, t: t)
        )
    }

    private func lerpColorHSL(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        let hslA = rgbToHSL(a)
        let hslB = rgbToHSL(b)

        var dH = hslB.x - hslA.x
        if dH > 0.5 { dH -= 1.0 }
        if dH < -0.5 { dH += 1.0 }

        let h = hslA.x + dH * t
        let s = hslA.y + (hslB.y - hslA.y) * t
        let l = hslA.z + (hslB.z - hslA.z) * t

        return hslToRGB(SIMD3<Float>(h < 0 ? h + 1 : (h > 1 ? h - 1 : h), s, l))
    }

    // MARK: - RGB <-> HSL

    private func rgbToHSL(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let r = rgb.x, g = rgb.y, b = rgb.z
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let l = (maxC + minC) / 2
        guard maxC != minC else { return SIMD3<Float>(0, 0, l) }
        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        var h: Float
        if maxC == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if maxC == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h /= 6
        return SIMD3<Float>(h, s, l)
    }

    private func hslToRGB(_ hsl: SIMD3<Float>) -> SIMD3<Float> {
        let h = hsl.x, s = hsl.y, l = hsl.z
        guard s > 0 else { return SIMD3<Float>(l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return SIMD3<Float>(
            hue2rgb(p, q, h + 1.0 / 3.0),
            hue2rgb(p, q, h),
            hue2rgb(p, q, h - 1.0 / 3.0)
        )
    }

    private func hue2rgb(_ p: Float, _ q: Float, _ tRaw: Float) -> Float {
        var t = tRaw
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0 / 6.0 { return p + (q - p) * 6 * t }
        if t < 1.0 / 2.0 { return q }
        if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6 }
        return p
    }
}
