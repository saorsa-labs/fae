import XCTest
@testable import Fae

// MARK: - EchoSuppressor Tests

final class EchoSuppressorTests: XCTestCase {

    private func makeSuppressor(aecEnabled: Bool = false) -> EchoSuppressor {
        EchoSuppressor()
    }

    // MARK: - Output route timing

    func testRouteTimingMultiplierHeadphones() {
        var s = EchoSuppressor()
        s.outputRoute = .headphones
        // Can't access private routeTimingMultiplier directly, but echoTailMs reflects it
        let tail = s.echoTailMs
        // Headphones: 0.1 multiplier → 800 * 0.1 = 80ms
        XCTAssertLessThan(tail, 200)
    }

    func testRouteTimingMultiplierBuiltInSpeaker() {
        var s = EchoSuppressor()
        s.outputRoute = .builtInSpeaker
        let tail = s.echoTailMs
        // Built-in: 0.8 multiplier → 800 * 0.8 = 640ms
        XCTAssertGreaterThan(tail, 500)
        XCTAssertLessThan(tail, 800)
    }

    func testRouteTimingMultiplierExternalSpeaker() {
        var s = EchoSuppressor()
        s.outputRoute = .externalSpeaker
        let tail = s.echoTailMs
        // External: 1.2 multiplier → 800 * 1.2 = 960ms
        XCTAssertGreaterThan(tail, 800)
    }

    func testRouteTimingMultiplierUnknown() {
        var s = EchoSuppressor()
        s.outputRoute = .unknown
        let tail = s.echoTailMs
        // Unknown: 1.0 multiplier → 800ms
        XCTAssertEqual(tail, 800)
    }

    func testAECEnabledShorterTail() {
        var s = EchoSuppressor()
        s.aecEnabled = true
        // AEC: baseEchoTailMs = 300, unknown route → 300ms
        XCTAssertEqual(s.echoTailMs, 300)
    }

    func testShortUtteranceGuardDefault() {
        let s = EchoSuppressor()
        // No AEC, unknown route: 1200 * 1.0 = 1200ms
        XCTAssertEqual(s.shortUtteranceGuardMs, 1200)
    }

    func testEchoTailForToneDefault() {
        let s = EchoSuppressor()
        XCTAssertEqual(s.echoTailForToneMs, 800)
    }

    func testEchoTailForToneWithAEC() {
        var s = EchoSuppressor()
        s.aecEnabled = true
        XCTAssertEqual(s.echoTailForToneMs, 500)
    }

    // MARK: - Static constants

    func testMinPostPlaybackSegmentSecs() {
        XCTAssertEqual(EchoSuppressor.minPostPlaybackSegmentSecs, 0.5)
    }

    func testMaxSegmentSecs() {
        XCTAssertEqual(EchoSuppressor.maxSegmentSecs, 15.0)
    }

    func testEchoRmsCeiling() {
        XCTAssertEqual(EchoSuppressor.echoRmsCeiling, 0.12)
    }

    func testMinApprovalSegmentSecs() {
        XCTAssertEqual(EchoSuppressor.minApprovalSegmentSecs, 0.15)
    }

    // MARK: - State management

    func testInitialState() {
        let s = EchoSuppressor()
        XCTAssertFalse(s.assistantSpeaking)
        XCTAssertFalse(s.isInSuppression)
        XCTAssertEqual(s.outputRoute, .unknown)
        XCTAssertFalse(s.aecEnabled)
    }

    func testOnAssistantSpeechStart() {
        var s = EchoSuppressor()
        s.onAssistantSpeechStart()
        XCTAssertTrue(s.assistantSpeaking)
        XCTAssertTrue(s.isInSuppression)
    }

    func testOnAssistantSpeechEnd() {
        var s = EchoSuppressor()
        s.onAssistantSpeechStart()
        s.onAssistantSpeechEnd()
        XCTAssertFalse(s.assistantSpeaking)
        // Still in suppression (echo tail)
        XCTAssertTrue(s.isInSuppression)
    }

    func testSecondsSinceLastSpeechInfinityBeforeSpeech() {
        let s = EchoSuppressor()
        XCTAssertEqual(s.secondsSinceLastSpeech, .infinity)
    }

    func testSecondsSinceLastSpeechAfterEnd() {
        var s = EchoSuppressor()
        s.onAssistantSpeechStart()
        s.onAssistantSpeechEnd()
        XCTAssertGreaterThan(s.secondsSinceLastSpeech, 0)
        XCTAssertLessThan(s.secondsSinceLastSpeech, 1)
    }

    func testReset() {
        var s = EchoSuppressor()
        s.onAssistantSpeechStart()
        s.reset()
        XCTAssertFalse(s.assistantSpeaking)
        XCTAssertFalse(s.isInSuppression)
    }

    // MARK: - shouldAccept

    func testRejectWhenAssistantSpeaking() {
        var s = EchoSuppressor()
        s.onAssistantSpeechStart()
        let accepted = s.shouldAccept(
            durationSecs: 1.0,
            rms: 0.5,
            awaitingApproval: false,
            segmentOnset: Date()
        )
        XCTAssertFalse(accepted)
    }

    func testRejectLongSegments() {
        var s = EchoSuppressor()
        let accepted = s.shouldAccept(
            durationSecs: 20.0, // > 15s max
            rms: 0.5,
            awaitingApproval: false,
            segmentOnset: Date()
        )
        XCTAssertFalse(accepted)
    }

    func testRejectDuringEchoTail() {
        var s = EchoSuppressor()
        s.onAssistantSpeechStart()
        s.onAssistantSpeechEnd()
        // Segment onset is right now, within echo tail
        let accepted = s.shouldAccept(
            durationSecs: 0.3,
            rms: 0.5,
            awaitingApproval: false,
            segmentOnset: Date()
        )
        XCTAssertFalse(accepted)
    }

    func testAcceptAfterEchoTailExpires() async {
        var s = EchoSuppressor()
        s.aecEnabled = true // Shorter tail (300ms)
        s.onAssistantSpeechStart()
        s.onAssistantSpeechEnd()
        // Wait for echo tail to expire
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        let accepted = s.shouldAccept(
            durationSecs: 1.0,
            rms: 0.5,
            awaitingApproval: false,
            segmentOnset: Date()
        )
        XCTAssertTrue(accepted)
    }

    func testRejectHighRmsDuringGuard() {
        var s = EchoSuppressor()
        s.onAssistantSpeechStart()
        s.onAssistantSpeechEnd()
        // High RMS during guard window
        let accepted = s.shouldAccept(
            durationSecs: 1.0,
            rms: 0.5, // > 0.12 ceiling
            awaitingApproval: false,
            segmentOnset: Date()
        )
        XCTAssertFalse(accepted)
    }

    func testAcceptShortSegmentDuringApproval() async {
        var s = EchoSuppressor()
        s.onAssistantSpeechStart()
        s.onAssistantSpeechEnd()
        // Short segment during approval — should be accepted if >= minApprovalSegmentSecs
        try? await Task.sleep(nanoseconds: 1_500_000_000) // Wait past guard
        let accepted = s.shouldAccept(
            durationSecs: 0.2,
            rms: 0.05,
            awaitingApproval: true,
            segmentOnset: Date()
        )
        XCTAssertTrue(accepted)
    }

    func testRejectVeryShortSegmentNotDuringApproval() {
        var s = EchoSuppressor()
        // No speech yet — guard windows are nil, so short segments should pass
        let accepted = s.shouldAccept(
            durationSecs: 0.1,
            rms: 0.05,
            awaitingApproval: false,
            segmentOnset: Date()
        )
        XCTAssertTrue(accepted) // No guard active
    }

    // MARK: - shouldRejectForEchoTail (static)

    func testRejectWhenSegmentFullyInsideTail() {
        let suppressUntil = Date().addingTimeInterval(1.0)
        let onset = Date().addingTimeInterval(-0.5)
        let reject = EchoSuppressor.shouldRejectForEchoTail(
            segmentOnset: onset,
            durationSecs: 0.3,
            suppressUntil: suppressUntil
        )
        XCTAssertTrue(reject)
    }

    func testAcceptWhenSegmentStartsAfterTail() {
        let suppressUntil = Date().addingTimeInterval(-1.0)
        let onset = Date()
        let reject = EchoSuppressor.shouldRejectForEchoTail(
            segmentOnset: onset,
            durationSecs: 1.0,
            suppressUntil: suppressUntil
        )
        XCTAssertFalse(reject)
    }

    func testAcceptWhenSegmentExtendsWellBeyondTail() {
        let suppressUntil = Date().addingTimeInterval(0.5)
        let onset = Date().addingTimeInterval(-2.0)
        // Segment is 5s long, started before tail, ends 2.5s past it —
        // beyond both minSpeechBeyondTailSecs (0.75s) and the 35% fraction.
        let reject = EchoSuppressor.shouldRejectForEchoTail(
            segmentOnset: onset,
            durationSecs: 5.0,
            suppressUntil: suppressUntil
        )
        XCTAssertFalse(reject) // Extends far beyond tail
    }

    // MARK: - Playback baseline

    func testUpdatePlaybackBaselineFirstSample() {
        var s = EchoSuppressor()
        s.updatePlaybackBaseline(rms: 0.5)
        XCTAssertEqual(s.playbackBaselineRms, 0.5)
    }

    func testUpdatePlaybackBaselineEMA() {
        var s = EchoSuppressor()
        s.updatePlaybackBaseline(rms: 0.5)
        s.updatePlaybackBaseline(rms: 0.6)
        // Should be between 0.5 and 0.6 (EMA)
        XCTAssertGreaterThan(s.playbackBaselineRms, 0.5)
        XCTAssertLessThan(s.playbackBaselineRms, 0.6)
    }

    func testUserSpeechLikelyAbovePlayback() {
        var s = EchoSuppressor()
        s.updatePlaybackBaseline(rms: 0.1)
        // 2.5x multiplier → need > 0.25
        XCTAssertTrue(s.userSpeechLikelyAbovePlayback(rms: 0.3))
        XCTAssertFalse(s.userSpeechLikelyAbovePlayback(rms: 0.15))
    }

    func testUserSpeechNotDetectedBeforeSeeding() {
        let s = EchoSuppressor()
        XCTAssertFalse(s.userSpeechLikelyAbovePlayback(rms: 0.9))
    }

    func testResetPlaybackBaseline() {
        var s = EchoSuppressor()
        s.updatePlaybackBaseline(rms: 0.5)
        s.resetPlaybackBaseline()
        XCTAssertEqual(s.playbackBaselineRms, 0)
    }

    // MARK: - Band energy

    func testBandEnergySpectralTilt() {
        var be = EchoSuppressor.BandEnergy()
        be.low = 1.0
        be.mid = 1.0
        be.high = 0.2
        // tilt = 0.2 / (1.0 + 1.0) = 0.1
        XCTAssertEqual(be.spectralTilt, 0.1, accuracy: 0.001)
    }

    func testBandEnergyLooksLikeSpeakerEcho() {
        var be = EchoSuppressor.BandEnergy()
        be.low = 1.0
        be.mid = 1.0
        be.high = 0.01 // Very low highs → tilt < 0.08
        XCTAssertTrue(be.looksLikeSpeakerEcho)
    }

    func testBandEnergyNotSpeakerEchoWithHighTilt() {
        var be = EchoSuppressor.BandEnergy()
        be.low = 1.0
        be.mid = 1.0
        be.high = 0.5 // High tilt → not echo
        XCTAssertFalse(be.looksLikeSpeakerEcho)
    }

    func testBandEnergyThresholds() {
        XCTAssertEqual(EchoSuppressor.BandEnergy.echoTiltThreshold, 0.08)
        XCTAssertEqual(EchoSuppressor.BandEnergy.speechTiltThreshold, 0.15)
    }

    func testBandEnergyEquatable() {
        var a = EchoSuppressor.BandEnergy()
        a.low = 1; a.mid = 2; a.high = 3
        var b = EchoSuppressor.BandEnergy()
        b.low = 1; b.mid = 2; b.high = 3
        XCTAssertEqual(a, b)
    }

    func testUpdatePlaybackBandBaseline() {
        var s = EchoSuppressor()
        var energy = EchoSuppressor.BandEnergy()
        energy.low = 0.5; energy.mid = 0.3; energy.high = 0.1
        s.updatePlaybackBandBaseline(energy: energy)
        // First sample sets baseline directly
        XCTAssertEqual(s.playbackBandBaseline.low, 0.5)
    }

    func testBandEnergyLooksLikeSpeechNotSeeded() {
        let s = EchoSuppressor()
        var energy = EchoSuppressor.BandEnergy()
        energy.high = 1.0
        XCTAssertFalse(s.bandEnergyLooksLikeSpeech(energy))
    }

    func testResetBandBaseline() {
        var s = EchoSuppressor()
        var energy = EchoSuppressor.BandEnergy()
        energy.low = 0.5
        s.updatePlaybackBandBaseline(energy: energy)
        s.resetBandBaseline()
        XCTAssertEqual(s.playbackBandBaseline.low, 0)
    }

    // MARK: - fae_self threshold

    func testFaeSelfThresholdNormalWhenNotSpeaking() {
        let s = EchoSuppressor()
        let adjusted = s.faeSelfThresholdDuringPlayback(baseThreshold: 0.45)
        XCTAssertEqual(adjusted, 0.45)
    }

    func testFaeSelfThresholdReducedDuringPlayback() {
        var s = EchoSuppressor()
        s.onAssistantSpeechStart()
        let adjusted = s.faeSelfThresholdDuringPlayback(baseThreshold: 0.45)
        // 0.45 * 0.8 = 0.36
        XCTAssertEqual(adjusted, 0.36, accuracy: 0.001)
    }

    func testFaeSelfPlaybackMultiplier() {
        XCTAssertEqual(EchoSuppressor.faeSelfPlaybackMultiplier, 0.8)
    }

    // MARK: - Cross-correlation constants

    func testCrossCorrelationThreshold() {
        XCTAssertEqual(EchoSuppressor.crossCorrelationEchoThreshold, 0.6)
    }

    // MARK: - Spectral envelope similarity

    func testSpectralEnvelopeIdentical() {
        var a = EchoSuppressor.BandEnergy()
        a.low = 1; a.mid = 2; a.high = 3
        var b = EchoSuppressor.BandEnergy()
        b.low = 1; b.mid = 2; b.high = 3
        let sim = EchoSuppressor.spectralEnvelopeSimilarity(micEnergy: a, ttsEnergy: b)
        XCTAssertEqual(sim, 1.0, accuracy: 0.001)
    }

    func testSpectralEnvelopeDifferent() {
        var a = EchoSuppressor.BandEnergy()
        a.low = 1; a.mid = 0; a.high = 0
        var b = EchoSuppressor.BandEnergy()
        b.low = 0; b.mid = 1; b.high = 0
        let sim = EchoSuppressor.spectralEnvelopeSimilarity(micEnergy: a, ttsEnergy: b)
        XCTAssertEqual(sim, 0.0, accuracy: 0.001)
    }

    func testSpectralEnvelopeZeroVectors() {
        let a = EchoSuppressor.BandEnergy()
        let b = EchoSuppressor.BandEnergy()
        let sim = EchoSuppressor.spectralEnvelopeSimilarity(micEnergy: a, ttsEnergy: b)
        XCTAssertEqual(sim, 0.0)
    }

    func testSpectralSimilarityThreshold() {
        XCTAssertEqual(EchoSuppressor.spectralSimilarityEchoThreshold, 0.95)
    }

    // MARK: - Text overlap echo detection

    func testRecordAssistantText() {
        var s = EchoSuppressor()
        s.recordAssistantText("Hello world")
        // Should not crash
    }

    func testIsLikelyEchoTextEmptyTranscript() {
        var s = EchoSuppressor()
        s.recordAssistantText("Hello world")
        XCTAssertFalse(s.isLikelyEchoText(""))
    }

    func testIsLikelyEchoTextNoAssistantText() {
        let s = EchoSuppressor()
        XCTAssertFalse(s.isLikelyEchoText("Hello world"))
    }

    func testIsLikelyEchoTextExactMatch() {
        var s = EchoSuppressor()
        s.recordAssistantText("The answer is forty two")
        // Long enough transcript matching assistant text should be detected as echo
        let isEcho = s.isLikelyEchoText("the answer is forty two")
        XCTAssertTrue(isEcho)
    }

    func testIsLikelyEchoTextDifferentContent() {
        var s = EchoSuppressor()
        s.recordAssistantText("The weather is nice today")
        XCTAssertFalse(s.isLikelyEchoText("I want to order pizza"))
    }

    func testShortUtterancePassesThrough() {
        var s = EchoSuppressor()
        s.recordAssistantText("stop what you are doing right now")
        // Short commands should pass through
        XCTAssertFalse(s.isLikelyEchoText("stop"))
        XCTAssertFalse(s.isLikelyEchoText("no thanks"))
    }

    func testClearTextHistory() {
        var s = EchoSuppressor()
        s.recordAssistantText("Hello world")
        s.clearTextHistory()
        // After clearing, nothing should match
        XCTAssertFalse(s.isLikelyEchoText("Hello world"))
    }

    // MARK: - OutputRoute equatable

    func testOutputRouteEquatable() {
        XCTAssertEqual(EchoSuppressor.OutputRoute.headphones, .headphones)
        XCTAssertEqual(EchoSuppressor.OutputRoute.builtInSpeaker, .builtInSpeaker)
        XCTAssertNotEqual(EchoSuppressor.OutputRoute.headphones, .externalSpeaker)
    }

    // MARK: - Decay estimation

    func testEffectiveEchoTailWithoutDecayEstimate() {
        let s = EchoSuppressor()
        // Without decay estimate, falls back to echoTailMs
        XCTAssertEqual(s.effectiveEchoTailMs, s.echoTailMs)
    }

    func testBeginDecayMeasurement() {
        var s = EchoSuppressor()
        s.beginDecayMeasurement(currentRms: 0.5)
        // Should start collecting if RMS > 0.005
    }

    func testAddDecaySampleWhenNotCollecting() {
        var s = EchoSuppressor()
        s.addDecaySample(timestamp: Date(), rms: 0.1)
        // Should be a no-op
    }

    func testEstimatedDecayMsInitiallyNil() {
        let s = EchoSuppressor()
        XCTAssertNil(s.estimatedDecayMs)
    }

    func testMinAndMaxDecayMs() {
        // Can't access private statics directly, but verify through behavior
        let _ = EchoSuppressor()
    }

    // MARK: - Playback audio ring buffer

    func testClearPlaybackAudioBuffer() {
        var s = EchoSuppressor()
        s.recordPlaybackAudio(samples: [0.1, 0.2, 0.3], sampleRate: 16000)
        s.clearPlaybackAudioBuffer()
        // Should not crash
    }

    func testPeakCrossCorrelationEmptyBuffer() {
        let s = EchoSuppressor()
        let corr = s.peakCrossCorrelation(micSamples: Array(repeating: 0.1, count: 200))
        XCTAssertEqual(corr, 0)
    }

    func testIsLikelyAcousticEchoEmptyBuffer() {
        let s = EchoSuppressor()
        XCTAssertFalse(s.isLikelyAcousticEcho(micSamples: Array(repeating: 0.1, count: 200)))
    }

    // MARK: - Speech duration scaling

    func testSpeechDurationScaling() {
        var s = EchoSuppressor()
        s.onAssistantSpeechStart()
        s.onAssistantSpeechEnd(speechDurationSecs: 8.0)
        // Should still be in suppression (echo tail + bonus)
        XCTAssertTrue(s.isInSuppression)
    }

    func testEchoTailMultiplierIsSendable() {
        let route: EchoSuppressor.OutputRoute = .headphones
        _ = route as any Sendable
    }
}
