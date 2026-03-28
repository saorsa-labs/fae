import SwiftUI

// MARK: - OrbMode

enum OrbMode: String, CaseIterable, Identifiable {
    case idle
    case listening
    case thinking
    case speaking

    var id: String { rawValue }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        }
    }

    // MARK: Mode Multipliers
    //
    // Applied to feeling base values via OrbSnapshot.withModeMultipliers().
    // Tuned so common combinations map to Benjamin's mood parameters:
    //
    //   neutral + idle     → calm      (speed 0.5, amp 1.3)
    //   neutral + thinking → working   (speed 2.0, amp 2.4)
    //   curiosity + listen → curious+  (speed 1.28, amp 1.73)
    //   delight + speaking → excited+  (speed 2.2, amp 2.64)

    /// Outer glow intensity multiplier.
    var fogIntensity: Float {
        switch self {
        case .idle: return 1.0
        case .listening: return 1.1
        case .thinking: return 1.3
        case .speaking: return 1.0
        }
    }

    /// Particle visibility multiplier.
    var starIntensity: Float {
        switch self {
        case .idle: return 1.0
        case .listening: return 1.3
        case .thinking: return 0.7
        case .speaking: return 1.5
        }
    }

    /// Noise displacement amplitude multiplier (Canvas: amplitude).
    var morphIntensity: Float {
        switch self {
        case .idle: return 1.0
        case .listening: return 1.15
        case .thinking: return 1.85
        case .speaking: return 1.2
        }
    }

    var morphSpeedMul: Float {
        switch self {
        case .idle: return 1.0
        case .listening: return 1.1
        case .thinking: return 1.5
        case .speaking: return 1.0
        }
    }

    /// Breathing depth multiplier.
    var breathIntensity: Float {
        switch self {
        case .idle: return 1.0
        case .listening: return 1.1
        case .thinking: return 1.5
        case .speaking: return 1.2
        }
    }

    /// Bright point intensity multiplier.
    var innerGlowIntensity: Float {
        switch self {
        case .idle: return 1.0
        case .listening: return 1.0
        case .thinking: return 1.5
        case .speaking: return 1.2
        }
    }

    var liquidFlowMul: Float {
        switch self {
        case .idle: return 1.0
        case .listening: return 1.2
        case .thinking: return 1.5
        case .speaking: return 1.2
        }
    }

    /// Animation speed multiplier (Canvas: mood.speed).
    var speedScaleMul: Float {
        switch self {
        case .idle: return 0.5
        case .listening: return 0.8
        case .thinking: return 2.0
        case .speaking: return 1.0
        }
    }

    /// Default palette colours for each mode (when palette is .modeDefault).
    /// Maps to Benjamin's mood palettes: (outer/bright, mid, inner/dark).
    var defaultColors: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        switch self {
        case .idle:
            // Calm amber — the resting state.
            return (OrbColor.hotAmber, OrbColor.richAmber, OrbColor.darkAmber)
        case .listening:
            // Curious lighter gold — attentive, reaching out.
            return (OrbColor.paleGold, OrbColor.softGold, OrbColor.deepHoney)
        case .thinking:
            // Working amber — active processing.
            return (OrbColor.hotAmber, OrbColor.burntGold, OrbColor.shadowAmber)
        case .speaking:
            // Warm peach — expressive, joyful.
            return (OrbColor.peachGlow, OrbColor.apricot, OrbColor.warmCoral)
        }
    }

    static func commandOverride(in text: String) -> OrbMode? {
        let normalized = text.lowercased()
        if normalized.contains("orb mode idle") || normalized.contains("set orb idle") {
            return .idle
        }
        if normalized.contains("orb mode listening")
            || normalized.contains("set orb listening")
            || normalized.contains("set listening mode")
        {
            return .listening
        }
        if normalized.contains("orb mode thinking")
            || normalized.contains("set orb thinking")
            || normalized.contains("set thinking mode")
        {
            return .thinking
        }
        if normalized.contains("orb mode speaking")
            || normalized.contains("set orb speaking")
            || normalized.contains("set speaking mode")
        {
            return .speaking
        }
        return nil
    }
}

// MARK: - OrbFeeling

enum OrbFeeling: String, CaseIterable, Identifiable {
    case neutral
    case calm
    case curiosity
    case warmth
    case concern
    case delight
    case focus
    case playful

    var id: String { rawValue }

    var label: String {
        switch self {
        case .neutral: return "Neutral"
        case .calm: return "Calm"
        case .curiosity: return "Curiosity"
        case .warmth: return "Warmth"
        case .concern: return "Concern"
        case .delight: return "Delight"
        case .focus: return "Focus"
        case .playful: return "Playful"
        }
    }

    /// Base property values for this feeling. Mode multipliers are applied on top.
    ///
    /// Tuned for the amber noise-displaced layer shader where:
    /// - `speedScale`     → animation speed (Canvas: mood.speed)
    /// - `morphAmplitude`  → noise displacement (Canvas: mood.amplitude)
    /// - `breathAmplitude` → breathing depth (Canvas: 0.015 + amp × 0.02)
    /// - `fogDensity`      → outer glow intensity
    /// - `starAlpha`       → particle visibility
    /// - `wispAlpha`       → flare/wisp intensity
    /// - `innerGlow`       → bright point intensity
    /// - `radiusBias`      → orb size offset (Canvas: mood.size − 1.0)
    var properties: OrbSnapshot {
        switch self {
        case .neutral:
            // Default idle state → Canvas "calm" (speed 0.5, amp 1.3, size 1.0)
            // with idle mode multiplier: speedScale 1.0 × 0.5 = 0.5 ✓
            return OrbSnapshot(
                hueShift: 0, speedScale: 1.0, breathAmplitude: 0.041,
                fogDensity: 1.0, morphAmplitude: 1.3, morphFreq: 2,
                morphSpeed: 0.18, shimmer: 0.03, asymmetry: 0.04,
                starAlpha: 0.5, outerAlpha: 0.35, wispSize: 0.25,
                wispAlpha: 0.3, blobAlpha: 0.14, innerGlow: 1.0,
                tremor: 0.0, sparkleIntensity: 0.3, liquidFlow: 1.0, radiusBias: 0.0
            )
        case .calm:
            // Quieter than neutral — slower, less particles.
            return OrbSnapshot(
                hueShift: 0, speedScale: 0.6, breathAmplitude: 0.041,
                fogDensity: 0.8, morphAmplitude: 1.3, morphFreq: 2,
                morphSpeed: 0.1, shimmer: 0.02, asymmetry: 0.03,
                starAlpha: 0.3, outerAlpha: 0.25, wispSize: 0.3,
                wispAlpha: 0.2, blobAlpha: 0.12, innerGlow: 0.8,
                tremor: 0.0, sparkleIntensity: 0.1, liquidFlow: 0.5, radiusBias: 0.0
            )
        case .curiosity:
            // Canvas "curious" (speed 0.8, amp 1.5, size 1.08)
            // Lighter gold, gently reaching out.
            return OrbSnapshot(
                hueShift: 0, speedScale: 1.6, breathAmplitude: 0.045,
                fogDensity: 1.0, morphAmplitude: 1.5, morphFreq: 3,
                morphSpeed: 0.3, shimmer: 0.06, asymmetry: 0.1,
                starAlpha: 0.6, outerAlpha: 0.3, wispSize: 0.38,
                wispAlpha: 0.4, blobAlpha: 0.12, innerGlow: 1.0,
                tremor: 0.0, sparkleIntensity: 0.6, liquidFlow: 1.4, radiusBias: 0.08
            )
        case .warmth:
            // Canvas "joyful" (speed 1.0, amp 1.6, size 1.12)
            // Bright warm peach/apricot.
            return OrbSnapshot(
                hueShift: 0, speedScale: 1.3, breathAmplitude: 0.047,
                fogDensity: 1.1, morphAmplitude: 1.6, morphFreq: 2,
                morphSpeed: 0.16, shimmer: 0.03, asymmetry: 0.04,
                starAlpha: 0.5, outerAlpha: 0.35, wispSize: 0.25,
                wispAlpha: 0.3, blobAlpha: 0.15, innerGlow: 1.2,
                tremor: 0.0, sparkleIntensity: 0.4, liquidFlow: 0.8, radiusBias: 0.12
            )
        case .concern:
            // Canvas "concerned" (speed 0.4, amp 1.0, size 0.92)
            // Muted, smaller, subdued with tremor.
            return OrbSnapshot(
                hueShift: 0, speedScale: 0.5, breathAmplitude: 0.035,
                fogDensity: 0.7, morphAmplitude: 1.0, morphFreq: 2,
                morphSpeed: 0.12, shimmer: 0.06, asymmetry: 0.06,
                starAlpha: 0.25, outerAlpha: 0.2, wispSize: 0.4,
                wispAlpha: 0.1, blobAlpha: 0.14, innerGlow: 0.6,
                tremor: 0.3, sparkleIntensity: 0.1, liquidFlow: 0.6, radiusBias: -0.08
            )
        case .delight:
            // Canvas "excited" (speed 1.8, amp 2.2, size 1.18)
            // Vivid flame, large, energetic.
            return OrbSnapshot(
                hueShift: 0, speedScale: 2.2, breathAmplitude: 0.059,
                fogDensity: 1.2, morphAmplitude: 2.2, morphFreq: 3,
                morphSpeed: 0.28, shimmer: 0.05, asymmetry: 0.08,
                starAlpha: 0.8, outerAlpha: 0.35, wispSize: 0.35,
                wispAlpha: 0.6, blobAlpha: 0.13, innerGlow: 1.4,
                tremor: 0.0, sparkleIntensity: 1.0, liquidFlow: 1.2, radiusBias: 0.18
            )
        case .focus:
            // Canvas "focused" (speed 1.2, amp 1.1, size 0.88)
            // Deep copper, tighter, concentrated.
            return OrbSnapshot(
                hueShift: 0, speedScale: 1.5, breathAmplitude: 0.037,
                fogDensity: 0.9, morphAmplitude: 1.1, morphFreq: 2,
                morphSpeed: 0.1, shimmer: 0.02, asymmetry: 0.02,
                starAlpha: 0.3, outerAlpha: 0.2, wispSize: 0.35,
                wispAlpha: 0.2, blobAlpha: 0.13, innerGlow: 0.9,
                tremor: 0.0, sparkleIntensity: 0.2, liquidFlow: 0.7, radiusBias: -0.12
            )
        case .playful:
            // Between joyful and excited — bouncy, bright.
            return OrbSnapshot(
                hueShift: 0, speedScale: 1.6, breathAmplitude: 0.051,
                fogDensity: 1.0, morphAmplitude: 1.8, morphFreq: 3,
                morphSpeed: 0.35, shimmer: 0.08, asymmetry: 0.12,
                starAlpha: 0.7, outerAlpha: 0.35, wispSize: 0.38,
                wispAlpha: 0.5, blobAlpha: 0.12, innerGlow: 1.1,
                tremor: 0.0, sparkleIntensity: 0.8, liquidFlow: 1.6, radiusBias: 0.1
            )
        }
    }

    static func commandOverride(in text: String) -> OrbFeeling? {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        if normalized.contains("set feeling neutral") || normalized.contains("feel neutral") { return .neutral }
        if normalized.contains("set feeling calm") || normalized.contains("feel calm") { return .calm }
        if normalized.contains("set feeling curiosity") || normalized.contains("feel curious") { return .curiosity }
        if normalized.contains("set feeling warmth") || normalized.contains("feel warm") { return .warmth }
        if normalized.contains("set feeling concern") || normalized.contains("feel concern") { return .concern }
        if normalized.contains("set feeling delight") || normalized.contains("feel delight") { return .delight }
        if normalized.contains("set feeling focus") || normalized.contains("feel focus") { return .focus }
        if normalized.contains("set feeling playful") || normalized.contains("feel playful") { return .playful }
        return nil
    }
}

// MARK: - OrbPalette

enum OrbPalette: String, CaseIterable, Identifiable {
    case modeDefault = "mode-default"
    case faeAmber = "fae-amber"
    case highlandFire = "highland-fire"
    case goldenDawn = "golden-dawn"
    case heatherMist = "heather-mist"
    case glenGreen = "glen-green"
    case lochGreyGreen = "loch-grey-green"
    case autumnBracken = "autumn-bracken"
    case silverMist = "silver-mist"
    case rowanBerry = "rowan-berry"
    case mossStone = "moss-stone"
    case dawnLight = "dawn-light"
    case peatEarth = "peat-earth"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .modeDefault: return "Mode Default"
        case .faeAmber: return "Fae Amber"
        case .highlandFire: return "Highland Fire"
        case .goldenDawn: return "Golden Dawn"
        case .heatherMist: return "Heather Mist"
        case .glenGreen: return "Glen Green"
        case .lochGreyGreen: return "Loch Grey-Green"
        case .autumnBracken: return "Autumn Bracken"
        case .silverMist: return "Silver Mist"
        case .rowanBerry: return "Rowan Berry"
        case .mossStone: return "Moss Stone"
        case .dawnLight: return "Dawn Light"
        case .peatEarth: return "Peat Earth"
        }
    }

    /// Palette-specific colour override (nil for .modeDefault — uses mode colours).
    var colors: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)? {
        switch self {
        case .modeDefault: return nil
        case .faeAmber: return (OrbColor.hotAmber, OrbColor.richAmber, OrbColor.darkAmber)
        case .highlandFire: return (OrbColor.flameOrange, OrbColor.richAmber, OrbColor.shadowAmber)
        case .goldenDawn: return (OrbColor.paleGold, OrbColor.hotAmber, OrbColor.dawnLight)
        case .heatherMist: return (OrbColor.heatherMist, OrbColor.lochGreyGreen, OrbColor.silverMist)
        case .glenGreen: return (OrbColor.glenGreen, OrbColor.lochGreyGreen, OrbColor.mossStone)
        case .lochGreyGreen: return (OrbColor.lochGreyGreen, OrbColor.silverMist, OrbColor.glenGreen)
        case .autumnBracken: return (OrbColor.autumnBracken, OrbColor.dawnLight, OrbColor.rowanBerry)
        case .silverMist: return (OrbColor.silverMist, OrbColor.heatherMist, OrbColor.dawnLight)
        case .rowanBerry: return (OrbColor.rowanBerry, OrbColor.autumnBracken, OrbColor.peatEarth)
        case .mossStone: return (OrbColor.mossStone, OrbColor.glenGreen, OrbColor.peatEarth)
        case .dawnLight: return (OrbColor.dawnLight, OrbColor.silverMist, OrbColor.autumnBracken)
        case .peatEarth: return (OrbColor.peatEarth, OrbColor.mossStone, OrbColor.dawnLight)
        }
    }

    static func commandOverride(in text: String) -> OrbPalette? {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        if normalized.contains("reset orb color") || normalized.contains("reset orb palette") || normalized.contains("mode default") {
            return .modeDefault
        }
        if normalized.contains("fae amber") { return .faeAmber }
        if normalized.contains("highland fire") { return .highlandFire }
        if normalized.contains("golden dawn") { return .goldenDawn }
        if normalized.contains("heather mist") { return .heatherMist }
        if normalized.contains("glen green") { return .glenGreen }
        if normalized.contains("loch grey green") || normalized.contains("loch green") { return .lochGreyGreen }
        if normalized.contains("autumn bracken") { return .autumnBracken }
        if normalized.contains("silver mist") { return .silverMist }
        if normalized.contains("rowan berry") { return .rowanBerry }
        if normalized.contains("moss stone") { return .mossStone }
        if normalized.contains("dawn light") { return .dawnLight }
        if normalized.contains("peat earth") { return .peatEarth }
        return nil
    }
}

// MARK: - OrbColor Constants

/// Named colour constants as linear RGB SIMD3<Float> values (0–1 range).
enum OrbColor {
    // ── Benjamin's amber orb palette (exact hex values) ────────────

    // Warm ambers (home base)
    static let hotAmber    = hexToRGB(0xF0A830)
    static let brightHoney = hexToRGB(0xE8B840)
    static let goldenCore  = hexToRGB(0xFFD068)
    static let richAmber   = hexToRGB(0xC47A20)
    static let deepHoney   = hexToRGB(0xB06818)
    static let burntGold   = hexToRGB(0xD49138)
    static let darkAmber   = hexToRGB(0x7A4010)
    static let deepResin   = hexToRGB(0x5C2E08)
    static let shadowAmber = hexToRGB(0x3A1A04)

    // Curious — lighter, warmer gold
    static let paleGold = hexToRGB(0xF5C84C)
    static let sunGlow  = hexToRGB(0xFADA70)
    static let softGold = hexToRGB(0xD4A520)

    // Focused — deeper, tighter copper
    static let deepCopper = hexToRGB(0xB8621A)
    static let darkCopper = hexToRGB(0x8B4513)
    static let bronzeCore = hexToRGB(0xA0522D)

    // Joyful — bright warm peach/apricot
    static let peachGlow = hexToRGB(0xFFB366)
    static let apricot   = hexToRGB(0xFF9944)
    static let warmCoral = hexToRGB(0xE87830)

    // Concerned — muted, cooler amber
    static let dustyAmber = hexToRGB(0xB89060)
    static let mutedGold  = hexToRGB(0xA08050)
    static let fadedResin = hexToRGB(0x6B5030)

    // Excited — vivid bright flame
    static let flameOrange = hexToRGB(0xFF8C1A)
    static let brightFlame = hexToRGB(0xFFB030)
    static let deepFlame   = hexToRGB(0xCC6600)

    // ── Scottish landscape palette (retained for named palettes) ───

    static let heatherMist    = hexToRGB(0xB4A8C4)
    static let glenGreen      = hexToRGB(0x5F7F6F)
    static let lochGreyGreen  = hexToRGB(0x7A9B8E)
    static let autumnBracken  = hexToRGB(0xA67B5B)
    static let silverMist     = hexToRGB(0xC8D3D5)
    static let rowanBerry     = hexToRGB(0x8B4653)
    static let mossStone      = hexToRGB(0x4A5D52)
    static let dawnLight      = hexToRGB(0xE8DED2)
    static let peatEarth      = hexToRGB(0x3D3630)

    // ── Legacy gold / amber (retained for backward compatibility) ──

    static let faeGold        = hexToRGB(0xD4A934)
    static let highlandAmber  = hexToRGB(0xC17F24)
    static let cairngormTopaz = hexToRGB(0xE6B85C)
    static let islaySunset    = hexToRGB(0xE87D3E)
    static let thistleGold    = hexToRGB(0xB8962E)

    private static func hexToRGB(_ hex: UInt32) -> SIMD3<Float> {
        let r = Float((hex >> 16) & 0xFF) / 255.0
        let g = Float((hex >> 8) & 0xFF) / 255.0
        let b = Float(hex & 0xFF) / 255.0
        return SIMD3<Float>(r, g, b)
    }
}

// MARK: - OrbSnapshot

/// A snapshot of all orb visual properties at a point in time.
/// Used for interpolation between states during transitions.
struct OrbSnapshot: Equatable {
    var hueShift: Float = 0
    var speedScale: Float = 1.0
    var breathAmplitude: Float = 0.041
    var fogDensity: Float = 1.0
    var morphAmplitude: Float = 1.3
    var morphFreq: Float = 2
    var morphSpeed: Float = 0.18
    var shimmer: Float = 0.03
    var asymmetry: Float = 0.04
    var starAlpha: Float = 0.5
    var outerAlpha: Float = 0.35
    var wispSize: Float = 0.25
    var wispAlpha: Float = 0.3
    var blobAlpha: Float = 0.14
    var innerGlow: Float = 1.0
    var tremor: Float = 0.0
    var sparkleIntensity: Float = 0.3
    var liquidFlow: Float = 1.0
    var radiusBias: Float = 0.0

    /// Linearly interpolate all properties between two snapshots.
    static func lerp(_ a: OrbSnapshot, _ b: OrbSnapshot, t: Float) -> OrbSnapshot {
        let t = min(max(t, 0), 1)
        return OrbSnapshot(
            hueShift: a.hueShift + (b.hueShift - a.hueShift) * t,
            speedScale: a.speedScale + (b.speedScale - a.speedScale) * t,
            breathAmplitude: a.breathAmplitude + (b.breathAmplitude - a.breathAmplitude) * t,
            fogDensity: a.fogDensity + (b.fogDensity - a.fogDensity) * t,
            morphAmplitude: a.morphAmplitude + (b.morphAmplitude - a.morphAmplitude) * t,
            morphFreq: a.morphFreq + (b.morphFreq - a.morphFreq) * t,
            morphSpeed: a.morphSpeed + (b.morphSpeed - a.morphSpeed) * t,
            shimmer: a.shimmer + (b.shimmer - a.shimmer) * t,
            asymmetry: a.asymmetry + (b.asymmetry - a.asymmetry) * t,
            starAlpha: a.starAlpha + (b.starAlpha - a.starAlpha) * t,
            outerAlpha: a.outerAlpha + (b.outerAlpha - a.outerAlpha) * t,
            wispSize: a.wispSize + (b.wispSize - a.wispSize) * t,
            wispAlpha: a.wispAlpha + (b.wispAlpha - a.wispAlpha) * t,
            blobAlpha: a.blobAlpha + (b.blobAlpha - a.blobAlpha) * t,
            innerGlow: a.innerGlow + (b.innerGlow - a.innerGlow) * t,
            tremor: a.tremor + (b.tremor - a.tremor) * t,
            sparkleIntensity: a.sparkleIntensity + (b.sparkleIntensity - a.sparkleIntensity) * t,
            liquidFlow: a.liquidFlow + (b.liquidFlow - a.liquidFlow) * t,
            radiusBias: a.radiusBias + (b.radiusBias - a.radiusBias) * t
        )
    }

    /// Apply mode multipliers to base feeling properties.
    func withModeMultipliers(from mode: OrbMode) -> OrbSnapshot {
        var result = self
        result.fogDensity *= mode.fogIntensity
        result.morphAmplitude *= mode.morphIntensity
        result.morphSpeed *= mode.morphSpeedMul
        result.starAlpha *= mode.starIntensity
        result.breathAmplitude *= mode.breathIntensity
        result.speedScale *= mode.speedScaleMul
        result.innerGlow *= mode.innerGlowIntensity
        result.liquidFlow *= mode.liquidFlowMul
        return result
    }
}
