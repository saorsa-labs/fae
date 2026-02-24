import SwiftUI

// MARK: - OrbMode

public enum OrbMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case idle
    case listening
    case thinking
    case speaking

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        }
    }

    /// Mode-specific multipliers applied to feeling base values.
    public var fogIntensity: Float {
        switch self {
        case .idle: return 1.0
        case .listening: return 1.1
        case .thinking: return 1.3
        case .speaking: return 1.2
        }
    }

    public var starIntensity: Float {
        switch self {
        case .idle: return 1.0
        case .listening: return 1.3
        case .thinking: return 0.7
        case .speaking: return 1.5
        }
    }

    public var morphIntensity: Float {
        switch self {
        case .idle: return 1.0
        case .listening: return 1.2
        case .thinking: return 0.8
        case .speaking: return 1.4
        }
    }

    public var morphSpeedMul: Float {
        switch self {
        case .idle: return 1.0
        case .listening: return 1.3
        case .thinking: return 0.6
        case .speaking: return 1.1
        }
    }

    /// Default palette colours for each mode (when palette is .modeDefault).
    public var defaultColors: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        switch self {
        case .idle:
            return (OrbColor.heatherMist, OrbColor.lochGreyGreen, OrbColor.silverMist)
        case .listening:
            return (OrbColor.glenGreen, OrbColor.lochGreyGreen, OrbColor.silverMist)
        case .thinking:
            return (OrbColor.heatherMist, OrbColor.rowanBerry, OrbColor.lochGreyGreen)
        case .speaking:
            return (OrbColor.autumnBracken, OrbColor.rowanBerry, OrbColor.dawnLight)
        }
    }
}

// MARK: - OrbFeeling

public enum OrbFeeling: String, CaseIterable, Identifiable, Codable, Sendable {
    case neutral
    case calm
    case curiosity
    case warmth
    case concern
    case delight
    case focus
    case playful

    public var id: String { rawValue }

    public var label: String {
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
    public var properties: OrbSnapshot {
        switch self {
        case .neutral:
            return OrbSnapshot(
                hueShift: 0, speedScale: 1.0, breathAmplitude: 0.012,
                fogDensity: 0.6, morphAmplitude: 0.06, morphFreq: 2,
                morphSpeed: 0.18, shimmer: 0.03, asymmetry: 0.04,
                starAlpha: 0.55, outerAlpha: 0.35, wispSize: 0.25,
                wispAlpha: 0.05, blobAlpha: 0.14, innerGlow: 0.2
            )
        case .calm:
            return OrbSnapshot(
                hueShift: -5, speedScale: 0.7, breathAmplitude: 0.02,
                fogDensity: 0.7, morphAmplitude: 0.04, morphFreq: 2,
                morphSpeed: 0.12, shimmer: 0.02, asymmetry: 0.03,
                starAlpha: 0.4, outerAlpha: 0.25, wispSize: 0.3,
                wispAlpha: 0.06, blobAlpha: 0.12, innerGlow: 0.15
            )
        case .curiosity:
            return OrbSnapshot(
                hueShift: 15, speedScale: 1.15, breathAmplitude: 0.014,
                fogDensity: 0.65, morphAmplitude: 0.1, morphFreq: 3,
                morphSpeed: 0.3, shimmer: 0.06, asymmetry: 0.1,
                starAlpha: 0.55, outerAlpha: 0.3, wispSize: 0.38,
                wispAlpha: 0.07, blobAlpha: 0.12, innerGlow: 0.2
            )
        case .warmth:
            return OrbSnapshot(
                hueShift: 25, speedScale: 0.9, breathAmplitude: 0.016,
                fogDensity: 0.65, morphAmplitude: 0.06, morphFreq: 2,
                morphSpeed: 0.18, shimmer: 0.03, asymmetry: 0.04,
                starAlpha: 0.5, outerAlpha: 0.35, wispSize: 0.25,
                wispAlpha: 0.05, blobAlpha: 0.15, innerGlow: 0.25
            )
        case .concern:
            return OrbSnapshot(
                hueShift: -10, speedScale: 0.85, breathAmplitude: 0.008,
                fogDensity: 0.85, morphAmplitude: 0.05, morphFreq: 2,
                morphSpeed: 0.15, shimmer: 0.06, asymmetry: 0.06,
                starAlpha: 0.35, outerAlpha: 0.2, wispSize: 0.4,
                wispAlpha: 0.08, blobAlpha: 0.14, innerGlow: 0.12
            )
        case .delight:
            return OrbSnapshot(
                hueShift: 10, speedScale: 1.3, breathAmplitude: 0.018,
                fogDensity: 0.55, morphAmplitude: 0.09, morphFreq: 3,
                morphSpeed: 0.28, shimmer: 0.05, asymmetry: 0.08,
                starAlpha: 0.65, outerAlpha: 0.35, wispSize: 0.35,
                wispAlpha: 0.07, blobAlpha: 0.13, innerGlow: 0.22
            )
        case .focus:
            return OrbSnapshot(
                hueShift: 5, speedScale: 1.1, breathAmplitude: 0.01,
                fogDensity: 0.75, morphAmplitude: 0.03, morphFreq: 2,
                morphSpeed: 0.1, shimmer: 0.02, asymmetry: 0.02,
                starAlpha: 0.4, outerAlpha: 0.2, wispSize: 0.35,
                wispAlpha: 0.07, blobAlpha: 0.13, innerGlow: 0.18
            )
        case .playful:
            return OrbSnapshot(
                hueShift: 20, speedScale: 1.2, breathAmplitude: 0.015,
                fogDensity: 0.6, morphAmplitude: 0.12, morphFreq: 3,
                morphSpeed: 0.35, shimmer: 0.08, asymmetry: 0.12,
                starAlpha: 0.6, outerAlpha: 0.35, wispSize: 0.38,
                wispAlpha: 0.07, blobAlpha: 0.12, innerGlow: 0.2
            )
        }
    }
}

// MARK: - OrbPalette

public enum OrbPalette: String, CaseIterable, Identifiable, Codable, Sendable {
    case modeDefault = "mode-default"
    case heatherMist = "heather-mist"
    case glenGreen = "glen-green"
    case lochGreyGreen = "loch-grey-green"
    case autumnBracken = "autumn-bracken"
    case silverMist = "silver-mist"
    case rowanBerry = "rowan-berry"
    case mossStone = "moss-stone"
    case dawnLight = "dawn-light"
    case peatEarth = "peat-earth"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .modeDefault: return "Mode Default"
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
    public var colors: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)? {
        switch self {
        case .modeDefault: return nil
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
}

// MARK: - OrbColor Constants

/// Named colour constants as linear RGB SIMD3<Float> values (0–1 range).
public enum OrbColor {
    public static let heatherMist = hexToRGB(0xB4A8C4)
    public static let glenGreen = hexToRGB(0x5F7F6F)
    public static let lochGreyGreen = hexToRGB(0x7A9B8E)
    public static let autumnBracken = hexToRGB(0xA67B5B)
    public static let silverMist = hexToRGB(0xC8D3D5)
    public static let rowanBerry = hexToRGB(0x8B4653)
    public static let mossStone = hexToRGB(0x4A5D52)
    public static let dawnLight = hexToRGB(0xE8DED2)
    public static let peatEarth = hexToRGB(0x3D3630)

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
public struct OrbSnapshot: Equatable, Sendable {
    public var hueShift: Float
    public var speedScale: Float
    public var breathAmplitude: Float
    public var fogDensity: Float
    public var morphAmplitude: Float
    public var morphFreq: Float
    public var morphSpeed: Float
    public var shimmer: Float
    public var asymmetry: Float
    public var starAlpha: Float
    public var outerAlpha: Float
    public var wispSize: Float
    public var wispAlpha: Float
    public var blobAlpha: Float
    public var innerGlow: Float

    public init(
        hueShift: Float = 0, speedScale: Float = 1.0, breathAmplitude: Float = 0.012,
        fogDensity: Float = 0.6, morphAmplitude: Float = 0.06, morphFreq: Float = 2,
        morphSpeed: Float = 0.18, shimmer: Float = 0.03, asymmetry: Float = 0.04,
        starAlpha: Float = 0.55, outerAlpha: Float = 0.35, wispSize: Float = 0.25,
        wispAlpha: Float = 0.05, blobAlpha: Float = 0.14, innerGlow: Float = 0.2
    ) {
        self.hueShift = hueShift
        self.speedScale = speedScale
        self.breathAmplitude = breathAmplitude
        self.fogDensity = fogDensity
        self.morphAmplitude = morphAmplitude
        self.morphFreq = morphFreq
        self.morphSpeed = morphSpeed
        self.shimmer = shimmer
        self.asymmetry = asymmetry
        self.starAlpha = starAlpha
        self.outerAlpha = outerAlpha
        self.wispSize = wispSize
        self.wispAlpha = wispAlpha
        self.blobAlpha = blobAlpha
        self.innerGlow = innerGlow
    }

    /// Linearly interpolate all properties between two snapshots.
    public static func lerp(_ a: OrbSnapshot, _ b: OrbSnapshot, t: Float) -> OrbSnapshot {
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
            innerGlow: a.innerGlow + (b.innerGlow - a.innerGlow) * t
        )
    }

    /// Apply mode multipliers to base feeling properties.
    public func withModeMultipliers(from mode: OrbMode) -> OrbSnapshot {
        var result = self
        result.fogDensity *= mode.fogIntensity
        result.morphAmplitude *= mode.morphIntensity
        result.morphSpeed *= mode.morphSpeedMul
        result.starAlpha *= mode.starIntensity
        return result
    }
}
