import Combine
import Foundation
import SwiftUI

/// Drives smooth transitions between orb visual states using spring interpolation.
///
/// Combines ``OrbMode``, ``OrbFeeling``, and ``OrbPalette`` into a unified
/// ``OrbSnapshot`` with colour triplet. When any input changes, a 500ms spring
/// transition from the current state to the new target begins.
///
/// The interpolated snapshot is published at display refresh rate (via
/// ``TimelineView(.animation)`` in ``NativeOrbView``).
///
/// ## Spring Easing
///
/// `springEase(t) = 1 - exp(-6t) * cos(2.5t)`
///
/// This produces a critically-damped oscillation that settles quickly with
/// a subtle overshoot — matching the JS orb transition feel exactly.
@MainActor
final class OrbAnimationState: ObservableObject {

    // MARK: - Per-Frame Output (non-published — TimelineView drives rendering)

    /// The current interpolated snapshot (read every frame by NativeOrbView).
    /// Not `@Published` because `TimelineView(.animation)` forces re-renders;
    /// publishing would cause a state-mutation-during-body-evaluation warning.
    private(set) var current: OrbSnapshot = OrbSnapshot()

    /// The current interpolated colours (read every frame).
    private(set) var colors: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) = (
        OrbColor.heatherMist, OrbColor.lochGreyGreen, OrbColor.silverMist
    )

    // MARK: - Anticipation State

    /// Active anticipation micro-animation type.
    enum AnticipationType {
        case contract, pause, burst

        var duration: TimeInterval {
            switch self {
            case .contract: return 0.180
            case .pause: return 0.220
            case .burst: return 0.280
            }
        }

        var amplitude: Float {
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

    // MARK: - Subscriptions

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialisation

    init() {
        let snap = OrbFeeling.neutral.properties.withModeMultipliers(from: .idle)
        current = snap
        fromSnapshot = snap
        toSnapshot = snap
        let modeColors = OrbMode.idle.defaultColors
        colors = modeColors
        fromColors = modeColors
        toColors = modeColors
    }

    /// Connect to the shared orb state controller to automatically trigger
    /// transitions on mode/palette/feeling changes.
    func bind(to orbState: OrbStateController) {
        orbState.$mode
            .combineLatest(orbState.$palette, orbState.$feeling)
            .sink { [weak self] mode, palette, feeling in
                self?.setTarget(mode: mode, palette: palette, feeling: feeling)
            }
            .store(in: &cancellables)
    }

    // MARK: - Target Setting

    /// Compute the target snapshot and colours from mode + palette + feeling,
    /// then begin a spring transition from the current state.
    func setTarget(mode: OrbMode, palette: OrbPalette, feeling: OrbFeeling) {
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

        // Compute target snapshot.
        let baseProps = feeling.properties.withModeMultipliers(from: mode)

        // Compute target colours.
        let targetColors: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
        if let paletteColors = palette.colors {
            targetColors = paletteColors
        } else {
            targetColors = mode.defaultColors
        }

        // Freeze current interpolated state as the transition origin.
        fromSnapshot = current
        fromColors = colors
        toSnapshot = baseProps
        toColors = targetColors
        transitionStart = now
        isTransitioning = true
    }

    // MARK: - Per-Frame Update

    /// Called every frame by the `TimelineView`. Updates the interpolated state.
    func update(at time: TimeInterval) {
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
    func anticipationScale(at time: TimeInterval) -> Float {
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

    /// `1 - exp(-6t) * cos(2.5t)` — critically-damped spring.
    private func springEase(_ t: Double) -> Double {
        1.0 - exp(-6.0 * t) * cos(2.5 * t)
    }

    // MARK: - Colour Interpolation

    /// Interpolate two colour triplets in HSL space.
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

    /// Interpolate two RGB colours through HSL space (shortest hue path).
    private func lerpColorHSL(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        let hslA = rgbToHSL(a)
        let hslB = rgbToHSL(b)

        // Shortest hue path.
        var dH = hslB.x - hslA.x
        if dH > 0.5 { dH -= 1.0 }
        if dH < -0.5 { dH += 1.0 }

        let h = hslA.x + dH * t
        let s = hslA.y + (hslB.y - hslA.y) * t
        let l = hslA.z + (hslB.z - hslA.z) * t

        return hslToRGB(SIMD3<Float>(h < 0 ? h + 1 : (h > 1 ? h - 1 : h), s, l))
    }

    // MARK: - RGB ↔ HSL Conversions

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
