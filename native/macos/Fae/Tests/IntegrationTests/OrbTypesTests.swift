import XCTest
@testable import Fae

final class OrbTypesTests: XCTestCase {

    // MARK: - OrbMode

    func testOrbModeCaseIterable() {
        XCTAssertEqual(OrbMode.allCases.count, 4)
        XCTAssertTrue(OrbMode.allCases.contains(.idle))
        XCTAssertTrue(OrbMode.allCases.contains(.listening))
        XCTAssertTrue(OrbMode.allCases.contains(.thinking))
        XCTAssertTrue(OrbMode.allCases.contains(.speaking))
    }

    func testOrbModeLabels() {
        XCTAssertEqual(OrbMode.idle.label, "Idle")
        XCTAssertEqual(OrbMode.listening.label, "Listening")
        XCTAssertEqual(OrbMode.thinking.label, "Thinking")
        XCTAssertEqual(OrbMode.speaking.label, "Speaking")
    }

    func testOrbModeIdentifiable() {
        XCTAssertEqual(OrbMode.idle.id, "idle")
        XCTAssertEqual(OrbMode.listening.id, "listening")
    }

    func testOrbModeFogIntensity() {
        XCTAssertEqual(OrbMode.idle.fogIntensity, 1.0)
        XCTAssertGreaterThan(OrbMode.thinking.fogIntensity, OrbMode.idle.fogIntensity)
    }

    func testOrbModeStarIntensity() {
        XCTAssertEqual(OrbMode.idle.starIntensity, 1.0)
        XCTAssertGreaterThan(OrbMode.speaking.starIntensity, OrbMode.thinking.starIntensity)
    }

    func testOrbModeMorphIntensity() {
        XCTAssertEqual(OrbMode.idle.morphIntensity, 1.0)
        XCTAssertGreaterThan(OrbMode.listening.morphIntensity, OrbMode.idle.morphIntensity)
    }

    func testOrbModeBreathIntensity() {
        XCTAssertEqual(OrbMode.idle.breathIntensity, 1.0)
        // Thinking has highest breath
        let maxBreath = OrbMode.allCases.max { $0.breathIntensity < $1.breathIntensity }
        XCTAssertEqual(maxBreath, .thinking)
    }

    func testOrbModeCommandOverride() {
        XCTAssertNotNil(OrbMode.commandOverride(in: "set orb idle"))
        XCTAssertNotNil(OrbMode.commandOverride(in: "orb mode listening"))
        XCTAssertNotNil(OrbMode.commandOverride(in: "SET ORB THINKING"))
        XCTAssertNotNil(OrbMode.commandOverride(in: "set speaking mode"))
        XCTAssertNil(OrbMode.commandOverride(in: "do something else"))
    }

    func testOrbModeDefaultColors() {
        let idle = OrbMode.idle.defaultColors
        XCTAssertFalse(idle.0 == SIMD3<Float>(0, 0, 0)) // not black
    }

    // MARK: - OrbFeeling

    func testOrbFeelingCaseIterable() {
        XCTAssertEqual(OrbFeeling.allCases.count, 8)
        XCTAssertTrue(OrbFeeling.allCases.contains(.neutral))
        XCTAssertTrue(OrbFeeling.allCases.contains(.calm))
        XCTAssertTrue(OrbFeeling.allCases.contains(.curiosity))
        XCTAssertTrue(OrbFeeling.allCases.contains(.warmth))
        XCTAssertTrue(OrbFeeling.allCases.contains(.concern))
        XCTAssertTrue(OrbFeeling.allCases.contains(.delight))
        XCTAssertTrue(OrbFeeling.allCases.contains(.focus))
        XCTAssertTrue(OrbFeeling.allCases.contains(.playful))
    }

    func testOrbFeelingLabels() {
        XCTAssertEqual(OrbFeeling.neutral.label, "Neutral")
        XCTAssertEqual(OrbFeeling.calm.label, "Calm")
        XCTAssertEqual(OrbFeeling.curiosity.label, "Curiosity")
        XCTAssertEqual(OrbFeeling.warmth.label, "Warmth")
        XCTAssertEqual(OrbFeeling.concern.label, "Concern")
        XCTAssertEqual(OrbFeeling.delight.label, "Delight")
        XCTAssertEqual(OrbFeeling.focus.label, "Focus")
        XCTAssertEqual(OrbFeeling.playful.label, "Playful")
    }

    func testOrbFeelingProperties() {
        // Delight should have highest sparkle
        let delightProps = OrbFeeling.delight.properties
        let calmProps = OrbFeeling.calm.properties
        XCTAssertGreaterThan(delightProps.sparkleIntensity, calmProps.sparkleIntensity)

        // Concern should have tremor
        let concernProps = OrbFeeling.concern.properties
        XCTAssertGreaterThan(concernProps.tremor, 0)

        // Calm should be slowest
        XCTAssertLessThan(calmProps.speedScale, delightProps.speedScale)
    }

    func testOrbFeelingCommandOverride() {
        XCTAssertNotNil(OrbFeeling.commandOverride(in: "set feeling neutral"))
        XCTAssertNotNil(OrbFeeling.commandOverride(in: "feel calm"))
        XCTAssertNotNil(OrbFeeling.commandOverride(in: "feel curious"))
        XCTAssertNotNil(OrbFeeling.commandOverride(in: "feel warm"))
        XCTAssertNotNil(OrbFeeling.commandOverride(in: "feel concern"))
        XCTAssertNotNil(OrbFeeling.commandOverride(in: "feel delight"))
        XCTAssertNotNil(OrbFeeling.commandOverride(in: "feel focus"))
        XCTAssertNotNil(OrbFeeling.commandOverride(in: "feel playful"))
        XCTAssertNil(OrbFeeling.commandOverride(in: "do something else"))
    }

    func testOrbFeelingCommandOverrideWithSeparators() {
        // Hyphens and underscores normalize to spaces before matching.
        XCTAssertNotNil(OrbFeeling.commandOverride(in: "set-feeling-calm"))
        XCTAssertNotNil(OrbFeeling.commandOverride(in: "set_feeling_calm"))
        XCTAssertNil(OrbFeeling.commandOverride(in: "set_feeting_calm")) // typo must not match
    }

    // MARK: - OrbPalette

    func testOrbPaletteCaseIterable() {
        XCTAssertEqual(OrbPalette.allCases.count, 13)
    }

    func testOrbPaletteLabels() {
        XCTAssertEqual(OrbPalette.modeDefault.label, "Mode Default")
        XCTAssertEqual(OrbPalette.faeAmber.label, "Fae Amber")
        XCTAssertEqual(OrbPalette.highlandFire.label, "Highland Fire")
    }

    func testOrbPaletteColors() {
        XCTAssertNil(OrbPalette.modeDefault.colors) // modeDefault uses mode colors
        XCTAssertNotNil(OrbPalette.faeAmber.colors)
        XCTAssertNotNil(OrbPalette.highlandFire.colors)
    }

    func testOrbPaletteCommandOverride() {
        XCTAssertNotNil(OrbPalette.commandOverride(in: "reset orb color"))
        XCTAssertNotNil(OrbPalette.commandOverride(in: "fae amber"))
        XCTAssertNotNil(OrbPalette.commandOverride(in: "highland fire"))
        XCTAssertNotNil(OrbPalette.commandOverride(in: "golden dawn"))
        XCTAssertNotNil(OrbPalette.commandOverride(in: "glen green"))
        XCTAssertNotNil(OrbPalette.commandOverride(in: "loch grey green"))
        XCTAssertNotNil(OrbPalette.commandOverride(in: "rowan berry"))
        XCTAssertNotNil(OrbPalette.commandOverride(in: "moss stone"))
        XCTAssertNotNil(OrbPalette.commandOverride(in: "dawn light"))
        XCTAssertNotNil(OrbPalette.commandOverride(in: "peat earth"))
        XCTAssertNil(OrbPalette.commandOverride(in: "something random"))
    }

    func testOrbPaletteCommandOverrideWithSeparators() {
        XCTAssertNotNil(OrbPalette.commandOverride(in: "fae-amber"))
        XCTAssertNotNil(OrbPalette.commandOverride(in: "fae_amber"))
    }

    // MARK: - OrbColor

    func testOrbColorHexToRGB() {
        let white = SIMD3<Float>(1.0, 1.0, 1.0)
        let black = SIMD3<Float>(0.0, 0.0, 0.0)

        // All colors should be non-zero (not pure black)
        XCTAssertGreaterThan(OrbColor.faeGold[0], 0)
        XCTAssertGreaterThan(OrbColor.heatherMist[1], 0)
        XCTAssertGreaterThan(OrbColor.glenGreen[2], 0)

        // faeGold = 0xD4A934 → R=0xD4/255, G=0xA9/255, B=0x34/255
        let expectedR = Float(0xD4) / 255.0
        XCTAssertEqual(OrbColor.faeGold[0], expectedR, accuracy: 0.001)
    }

    // MARK: - OrbSnapshot

    func testOrbSnapshotDefaults() {
        let snapshot = OrbSnapshot()
        XCTAssertEqual(snapshot.hueShift, 0)
        XCTAssertEqual(snapshot.speedScale, 1.0)
        XCTAssertEqual(snapshot.fogDensity, 0.6)
    }

    func testOrbSnapshotEquatable() {
        var a = OrbSnapshot()
        a.hueShift = 5
        a.speedScale = 1.2
        var b = OrbSnapshot()
        b.hueShift = 5
        b.speedScale = 1.2
        var c = OrbSnapshot()
        c.hueShift = 10
        c.speedScale = 1.2

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testOrbSnapshotLerpAtZero() {
        var a = OrbSnapshot(); a.fogDensity = 0.5
        var b = OrbSnapshot(); b.fogDensity = 1.0

        let result = OrbSnapshot.lerp(a, b, t: 0)
        XCTAssertEqual(result.speedScale, 1.0)
        XCTAssertEqual(result.fogDensity, 0.5)
    }

    func testOrbSnapshotLerpAtOne() {
        var a = OrbSnapshot(); a.speedScale = 1.0; a.fogDensity = 0.5
        var b = OrbSnapshot(); b.speedScale = 2.0; b.fogDensity = 1.0

        let result = OrbSnapshot.lerp(a, b, t: 1.0)
        XCTAssertEqual(result.speedScale, 2.0)
        XCTAssertEqual(result.fogDensity, 1.0)
    }

    func testOrbSnapshotLerpAtHalf() {
        var a = OrbSnapshot(); a.speedScale = 1.0; a.fogDensity = 0.4
        var b = OrbSnapshot(); b.speedScale = 3.0; b.fogDensity = 0.8

        let result = OrbSnapshot.lerp(a, b, t: 0.5)
        XCTAssertEqual(result.speedScale, 2.0)
        XCTAssertEqual(result.fogDensity, 0.6)
    }

    func testOrbSnapshotLerpClamped() {
        var a = OrbSnapshot()
        a.speedScale = 1.0
        var b = OrbSnapshot()
        b.speedScale = 3.0

        // t < 0 should clamp to 0
        let resultNeg = OrbSnapshot.lerp(a, b, t: -0.5)
        XCTAssertEqual(resultNeg.speedScale, 1.0)

        // t > 1 should clamp to 1
        let resultOver = OrbSnapshot.lerp(a, b, t: 1.5)
        XCTAssertEqual(resultOver.speedScale, 3.0)
    }

    func testOrbSnapshotWithModeMultipliers() {
        var base = OrbSnapshot()
        base.fogDensity = 0.5
        base.morphAmplitude = 0.1
        base.morphSpeed = 0.2
        base.starAlpha = 0.5
        base.breathAmplitude = 0.02
        base.speedScale = 1.0
        base.innerGlow = 0.3
        base.liquidFlow = 1.0

        let thinking = base.withModeMultipliers(from: OrbMode.thinking)
        // thinking.fogIntensity = 1.3
        XCTAssertEqual(thinking.fogDensity, 0.5 * 1.3)
        // thinking.morphIntensity = 0.8
        XCTAssertEqual(thinking.morphAmplitude, 0.1 * 0.8)
        // thinking.breathIntensity = 3.5
        XCTAssertEqual(thinking.breathAmplitude, 0.02 * 3.5)

        let idle = base.withModeMultipliers(from: OrbMode.idle)
        // All idle multipliers are 1.0 except speedScaleMul = 0.4
        XCTAssertEqual(idle.fogDensity, 0.5)
        XCTAssertEqual(idle.speedScale, 1.0 * 0.4)
    }

    func testOrbSnapshotLerpAllProperties() {
        let a = OrbSnapshot(
            hueShift: 0, speedScale: 1.0, breathAmplitude: 0.01,
            fogDensity: 0.5, morphAmplitude: 0.05, morphFreq: 2,
            morphSpeed: 0.1, shimmer: 0.02, asymmetry: 0.03,
            starAlpha: 0.4, outerAlpha: 0.3, wispSize: 0.2,
            wispAlpha: 0.04, blobAlpha: 0.1, innerGlow: 0.15,
            tremor: 0.0, sparkleIntensity: 0.2, liquidFlow: 0.8, radiusBias: -0.05
        )
        let b = OrbSnapshot(
            hueShift: 20, speedScale: 2.0, breathAmplitude: 0.03,
            fogDensity: 0.9, morphAmplitude: 0.15, morphFreq: 4,
            morphSpeed: 0.3, shimmer: 0.06, asymmetry: 0.09,
            starAlpha: 0.8, outerAlpha: 0.5, wispSize: 0.4,
            wispAlpha: 0.08, blobAlpha: 0.2, innerGlow: 0.3,
            tremor: 0.5, sparkleIntensity: 0.6, liquidFlow: 1.6, radiusBias: 0.1
        )

        let mid = OrbSnapshot.lerp(a, b, t: 0.5)
        // Float lerp accumulates rounding error — compare with accuracy.
        XCTAssertEqual(mid.hueShift, 10, accuracy: 1e-5)
        XCTAssertEqual(mid.speedScale, 1.5, accuracy: 1e-5)
        XCTAssertEqual(mid.sparkleIntensity, 0.4, accuracy: 1e-5)
        XCTAssertEqual(mid.radiusBias, 0.025, accuracy: 1e-5)
    }
}
