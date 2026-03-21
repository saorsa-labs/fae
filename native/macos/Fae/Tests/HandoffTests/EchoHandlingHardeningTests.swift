import XCTest
@testable import Fae

final class EchoHandlingHardeningTests: XCTestCase {

    // MARK: - Output Route Detection

    func testDefaultOutputRouteIsUnknown() {
        let suppressor = EchoSuppressor()
        XCTAssertEqual(suppressor.outputRoute, .unknown)
    }

    func testHeadphonesReduceEchoTail() {
        var headphones = EchoSuppressor()
        headphones.outputRoute = .headphones
        var speakers = EchoSuppressor()
        speakers.outputRoute = .builtInSpeaker

        XCTAssertLessThan(headphones.echoTailMs, speakers.echoTailMs,
                          "Headphones should have shorter echo tail than speakers")
    }

    func testExternalSpeakerIncreasesEchoTail() {
        var external = EchoSuppressor()
        external.outputRoute = .externalSpeaker
        var builtin = EchoSuppressor()
        builtin.outputRoute = .builtInSpeaker

        XCTAssertGreaterThan(external.echoTailMs, builtin.echoTailMs,
                             "External speakers should have longer echo tail")
    }

    func testHeadphonesReduceShortUtteranceGuard() {
        var headphones = EchoSuppressor()
        headphones.outputRoute = .headphones
        var speakers = EchoSuppressor()
        speakers.outputRoute = .builtInSpeaker

        XCTAssertLessThan(headphones.shortUtteranceGuardMs, speakers.shortUtteranceGuardMs,
                          "Headphones should have shorter guard window")
    }

    func testUnknownRouteMatchesBuiltInSpeaker() {
        var unknown = EchoSuppressor()
        unknown.outputRoute = .unknown
        var builtin = EchoSuppressor()
        builtin.outputRoute = .builtInSpeaker

        XCTAssertEqual(unknown.echoTailMs, builtin.echoTailMs,
                       "Unknown route should fall back to speaker timing")
    }

    func testAecEnabledReducesTimingRegardlessOfRoute() {
        var suppressor = EchoSuppressor()
        suppressor.outputRoute = .builtInSpeaker
        let noAecTail = suppressor.echoTailMs

        suppressor.aecEnabled = true
        let withAecTail = suppressor.echoTailMs

        XCTAssertLessThan(withAecTail, noAecTail,
                          "AEC should reduce echo tail")
    }

    // MARK: - Per-Band Energy Tracking

    func testBandEnergyDefaultsToZero() {
        let energy = EchoSuppressor.BandEnergy()
        XCTAssertEqual(energy.low, 0)
        XCTAssertEqual(energy.mid, 0)
        XCTAssertEqual(energy.high, 0)
    }

    func testSpectralTiltWithNoEnergy() {
        let energy = EchoSuppressor.BandEnergy()
        XCTAssertEqual(energy.spectralTilt, 0,
                       "Zero energy should have zero tilt")
    }

    func testSpectralTiltHighEnergyInHighBand() {
        let energy = EchoSuppressor.BandEnergy(low: 0.01, mid: 0.01, high: 0.02)
        XCTAssertGreaterThan(energy.spectralTilt, 0.5,
                             "High-band dominated signal should have high tilt")
    }

    func testSpectralTiltLowEnergyInHighBand() {
        let energy = EchoSuppressor.BandEnergy(low: 0.05, mid: 0.08, high: 0.002)
        XCTAssertLessThan(energy.spectralTilt, EchoSuppressor.BandEnergy.echoTiltThreshold,
                          "Low high-band energy should have low tilt (echo-like)")
    }

    func testLooksLikeSpeakerEchoWithRolledOffHighs() {
        let energy = EchoSuppressor.BandEnergy(low: 0.04, mid: 0.06, high: 0.003)
        XCTAssertTrue(energy.looksLikeSpeakerEcho,
                      "Rolled-off highs with audible low+mid should look like speaker echo")
    }

    func testDoesNotLookLikeEchoWithFlatSpectrum() {
        let energy = EchoSuppressor.BandEnergy(low: 0.03, mid: 0.04, high: 0.02)
        XCTAssertFalse(energy.looksLikeSpeakerEcho,
                       "Flat spectrum should not look like speaker echo")
    }

    func testDoesNotLookLikeEchoWithSilence() {
        let energy = EchoSuppressor.BandEnergy(low: 0.0001, mid: 0.0002, high: 0.00001)
        XCTAssertFalse(energy.looksLikeSpeakerEcho,
                       "Very quiet signal should not be classified as echo")
    }

    func testBandBaselineUpdate() {
        var suppressor = EchoSuppressor()
        let energy = EchoSuppressor.BandEnergy(low: 0.05, mid: 0.08, high: 0.01)
        suppressor.updatePlaybackBandBaseline(energy: energy)

        XCTAssertEqual(suppressor.playbackBandBaseline.low, 0.05, accuracy: 0.001)
        XCTAssertEqual(suppressor.playbackBandBaseline.mid, 0.08, accuracy: 0.001)
        XCTAssertEqual(suppressor.playbackBandBaseline.high, 0.01, accuracy: 0.001)
    }

    func testBandBaselineEMASmoothing() {
        var suppressor = EchoSuppressor()
        suppressor.updatePlaybackBandBaseline(
            energy: EchoSuppressor.BandEnergy(low: 0.10, mid: 0.10, high: 0.10))
        suppressor.updatePlaybackBandBaseline(
            energy: EchoSuppressor.BandEnergy(low: 0.02, mid: 0.02, high: 0.02))

        // After EMA, should not jump all the way to 0.02.
        XCTAssertGreaterThan(suppressor.playbackBandBaseline.low, 0.05,
                             "EMA should smooth sudden drops")
    }

    func testBandEnergyLooksLikeSpeechAboveBaseline() {
        var suppressor = EchoSuppressor()
        // Seed with echo-like baseline (low tilt).
        suppressor.updatePlaybackBandBaseline(
            energy: EchoSuppressor.BandEnergy(low: 0.04, mid: 0.06, high: 0.003))

        // User speech: higher tilt and more energy.
        let userSpeech = EchoSuppressor.BandEnergy(low: 0.08, mid: 0.12, high: 0.04)
        XCTAssertTrue(suppressor.bandEnergyLooksLikeSpeech(userSpeech),
                      "User speech with higher tilt and energy should be detected")
    }

    func testBandEnergyDoesNotLookLikeSpeechWhenSimilarToBaseline() {
        var suppressor = EchoSuppressor()
        let baseline = EchoSuppressor.BandEnergy(low: 0.04, mid: 0.06, high: 0.003)
        suppressor.updatePlaybackBandBaseline(energy: baseline)

        // Echo: similar to baseline.
        let echo = EchoSuppressor.BandEnergy(low: 0.04, mid: 0.06, high: 0.003)
        XCTAssertFalse(suppressor.bandEnergyLooksLikeSpeech(echo),
                       "Energy matching baseline should not look like speech")
    }

    func testResetBandBaseline() {
        var suppressor = EchoSuppressor()
        suppressor.updatePlaybackBandBaseline(
            energy: EchoSuppressor.BandEnergy(low: 0.05, mid: 0.08, high: 0.01))
        suppressor.resetBandBaseline()

        let energy = EchoSuppressor.BandEnergy(low: 0.05, mid: 0.08, high: 0.02)
        XCTAssertFalse(suppressor.bandEnergyLooksLikeSpeech(energy),
                       "After reset, should not detect speech (no baseline)")
    }

    func testComputeBandEnergyWithSilence() {
        let silence = [Float](repeating: 0, count: 576)
        let energy = EchoSuppressor.computeBandEnergy(samples: silence, sampleRate: 16_000)
        XCTAssertEqual(energy.low, 0, accuracy: 0.0001)
        XCTAssertEqual(energy.mid, 0, accuracy: 0.0001)
        XCTAssertEqual(energy.high, 0, accuracy: 0.0001)
    }

    func testComputeBandEnergyWithLowFrequency() {
        // 200 Hz sine wave — should be in low band.
        let sampleRate = 16_000
        let n = 576
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n {
            samples[i] = 0.5 * sin(2 * Float.pi * 200 * Float(i) / Float(sampleRate))
        }

        let energy = EchoSuppressor.computeBandEnergy(samples: samples, sampleRate: sampleRate)
        XCTAssertGreaterThan(energy.low, energy.high,
                             "200 Hz tone should have more low-band than high-band energy")
    }

    func testComputeBandEnergyWithHighFrequency() {
        // 6000 Hz sine wave — should be in high band.
        let sampleRate = 16_000
        let n = 576
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n {
            samples[i] = 0.5 * sin(2 * Float.pi * 6000 * Float(i) / Float(sampleRate))
        }

        let energy = EchoSuppressor.computeBandEnergy(samples: samples, sampleRate: sampleRate)
        XCTAssertGreaterThan(energy.high, energy.low,
                             "6000 Hz tone should have more high-band than low-band energy")
    }

    func testComputeBandEnergyEmptySamples() {
        let energy = EchoSuppressor.computeBandEnergy(samples: [], sampleRate: 16_000)
        XCTAssertEqual(energy.low, 0)
        XCTAssertEqual(energy.mid, 0)
        XCTAssertEqual(energy.high, 0)
    }

    // MARK: - Room Decay Estimation

    func testDecayEstimateStartsNil() {
        let suppressor = EchoSuppressor()
        XCTAssertNil(suppressor.estimatedDecayMs)
    }

    func testDecayEstimateFromFastDecay() {
        var suppressor = EchoSuppressor()
        suppressor.updatePlaybackBaseline(rms: 0.05)
        suppressor.beginDecayMeasurement(currentRms: 0.05)

        let start = Date()
        // Simulate fast decay: drops below 10% within 100ms.
        suppressor.addDecaySample(timestamp: start, rms: 0.04)
        suppressor.addDecaySample(
            timestamp: start.addingTimeInterval(0.05), rms: 0.02)
        suppressor.addDecaySample(
            timestamp: start.addingTimeInterval(0.10), rms: 0.003)

        XCTAssertNotNil(suppressor.estimatedDecayMs)
        // Should be around 100ms (clamped to minimum 100).
        if let decay = suppressor.estimatedDecayMs {
            XCTAssertGreaterThanOrEqual(decay, 100,
                                        "Decay should be at least minimum floor")
            XCTAssertLessThanOrEqual(decay, 300,
                                     "Fast decay should measure short")
        }
    }

    func testDecayEstimateFromSlowDecay() {
        var suppressor = EchoSuppressor()
        suppressor.updatePlaybackBaseline(rms: 0.08)
        suppressor.beginDecayMeasurement(currentRms: 0.08)

        let start = Date()
        // Simulate slow decay over 600ms.
        suppressor.addDecaySample(timestamp: start, rms: 0.07)
        suppressor.addDecaySample(
            timestamp: start.addingTimeInterval(0.2), rms: 0.05)
        suppressor.addDecaySample(
            timestamp: start.addingTimeInterval(0.4), rms: 0.03)
        suppressor.addDecaySample(
            timestamp: start.addingTimeInterval(0.6), rms: 0.006)

        XCTAssertNotNil(suppressor.estimatedDecayMs)
        if let decay = suppressor.estimatedDecayMs {
            XCTAssertGreaterThan(decay, 300,
                                 "Slow decay should measure longer")
        }
    }

    func testDecayNotMeasuredWhenQuiet() {
        var suppressor = EchoSuppressor()
        // Very quiet playback — should not trigger measurement.
        suppressor.beginDecayMeasurement(currentRms: 0.001)

        let start = Date()
        suppressor.addDecaySample(timestamp: start, rms: 0.001)
        suppressor.addDecaySample(
            timestamp: start.addingTimeInterval(0.1), rms: 0.0005)

        XCTAssertNil(suppressor.estimatedDecayMs,
                     "Should not estimate decay from quiet playback")
    }

    func testEffectiveEchoTailUsesDecayEstimate() {
        var suppressor = EchoSuppressor()
        suppressor.outputRoute = .builtInSpeaker
        let defaultTail = suppressor.effectiveEchoTailMs

        // Simulate short measured decay.
        suppressor.updatePlaybackBaseline(rms: 0.05)
        suppressor.beginDecayMeasurement(currentRms: 0.05)
        let start = Date()
        suppressor.addDecaySample(timestamp: start, rms: 0.04)
        suppressor.addDecaySample(
            timestamp: start.addingTimeInterval(0.05), rms: 0.02)
        suppressor.addDecaySample(
            timestamp: start.addingTimeInterval(0.10), rms: 0.003)

        let adaptiveTail = suppressor.effectiveEchoTailMs

        XCTAssertLessThanOrEqual(adaptiveTail, defaultTail,
                                 "Short measured decay should reduce effective echo tail")
    }

    func testDecayEMASmoothsEstimate() {
        var suppressor = EchoSuppressor()
        suppressor.updatePlaybackBaseline(rms: 0.05)

        // First measurement: fast decay (~100ms).
        suppressor.beginDecayMeasurement(currentRms: 0.05)
        var start = Date()
        suppressor.addDecaySample(timestamp: start, rms: 0.04)
        suppressor.addDecaySample(
            timestamp: start.addingTimeInterval(0.05), rms: 0.02)
        suppressor.addDecaySample(
            timestamp: start.addingTimeInterval(0.10), rms: 0.003)
        let firstEstimate = suppressor.estimatedDecayMs

        // Second measurement: slow decay (~500ms).
        suppressor.beginDecayMeasurement(currentRms: 0.05)
        start = Date()
        suppressor.addDecaySample(timestamp: start, rms: 0.04)
        suppressor.addDecaySample(
            timestamp: start.addingTimeInterval(0.2), rms: 0.03)
        suppressor.addDecaySample(
            timestamp: start.addingTimeInterval(0.5), rms: 0.003)
        let secondEstimate = suppressor.estimatedDecayMs

        XCTAssertNotNil(firstEstimate)
        XCTAssertNotNil(secondEstimate)
        if let first = firstEstimate, let second = secondEstimate {
            // EMA should smooth — second estimate should be between first and raw 500ms.
            XCTAssertGreaterThan(second, first,
                                 "Longer decay measurement should increase EMA estimate")
        }
    }

    // MARK: - Enhanced fae_self Threshold

    func testFaeSelfThresholdNormalWhenNotSpeaking() {
        let suppressor = EchoSuppressor()
        let baseThreshold: Float = 0.45
        let adjusted = suppressor.faeSelfThresholdDuringPlayback(baseThreshold: baseThreshold)
        XCTAssertEqual(adjusted, baseThreshold, accuracy: 0.001,
                       "When not speaking, threshold should be unchanged")
    }

    func testFaeSelfThresholdLoweredDuringSpeaking() {
        var suppressor = EchoSuppressor()
        suppressor.onAssistantSpeechStart()

        let baseThreshold: Float = 0.45
        let adjusted = suppressor.faeSelfThresholdDuringPlayback(baseThreshold: baseThreshold)
        XCTAssertLessThan(adjusted, baseThreshold,
                          "During speaking, threshold should be lowered")
        XCTAssertEqual(adjusted, baseThreshold * EchoSuppressor.faeSelfPlaybackMultiplier,
                       accuracy: 0.001)
    }

    func testFaeSelfThresholdLoweredDuringEchoTail() {
        var suppressor = EchoSuppressor()
        suppressor.onAssistantSpeechStart()
        suppressor.onAssistantSpeechEnd(speechDurationSecs: 3.0)

        // Should still be in echo tail window.
        let baseThreshold: Float = 0.45
        let adjusted = suppressor.faeSelfThresholdDuringPlayback(baseThreshold: baseThreshold)
        XCTAssertLessThan(adjusted, baseThreshold,
                          "During echo tail, threshold should still be lowered")
    }

    // MARK: - Reset Clears All State

    func testResetClearsBandBaseline() {
        var suppressor = EchoSuppressor()
        suppressor.updatePlaybackBandBaseline(
            energy: EchoSuppressor.BandEnergy(low: 0.05, mid: 0.08, high: 0.01))
        suppressor.reset()

        XCTAssertEqual(suppressor.playbackBandBaseline.low, 0)
        XCTAssertEqual(suppressor.playbackBandBaseline.mid, 0)
        XCTAssertEqual(suppressor.playbackBandBaseline.high, 0)
    }

    func testResetStopsDecayCollection() {
        var suppressor = EchoSuppressor()
        suppressor.updatePlaybackBaseline(rms: 0.05)
        suppressor.beginDecayMeasurement(currentRms: 0.05)
        suppressor.reset()

        // After reset, decay samples should not accumulate.
        let start = Date()
        suppressor.addDecaySample(timestamp: start, rms: 0.003)
        XCTAssertNil(suppressor.estimatedDecayMs,
                     "Reset should stop decay collection")
    }

    // MARK: - Cross-Correlation Echo Detection

    func testCrossCorrelationWithIdenticalAudio() {
        var suppressor = EchoSuppressor()
        // Create a tone signal.
        let n = 1600  // 100ms at 16kHz
        var tone = [Float](repeating: 0, count: n)
        for i in 0..<n {
            tone[i] = 0.3 * sin(2 * Float.pi * 440 * Float(i) / 16000)
        }

        // Record it as playback.
        suppressor.recordPlaybackAudio(samples: tone, sampleRate: 16_000)

        // Cross-correlate the same signal as mic input.
        let correlation = suppressor.peakCrossCorrelation(micSamples: tone)
        XCTAssertGreaterThan(correlation, 0.9,
                             "Identical audio should produce near-perfect correlation")
    }

    func testCrossCorrelationWithDifferentAudio() {
        var suppressor = EchoSuppressor()
        let n = 1600

        // Playback: 440 Hz tone.
        var playback = [Float](repeating: 0, count: n)
        for i in 0..<n {
            playback[i] = 0.3 * sin(2 * Float.pi * 440 * Float(i) / 16000)
        }
        suppressor.recordPlaybackAudio(samples: playback, sampleRate: 16_000)

        // Mic: completely different signal (1000 Hz).
        var mic = [Float](repeating: 0, count: n)
        for i in 0..<n {
            mic[i] = 0.3 * sin(2 * Float.pi * 1000 * Float(i) / 16000)
        }

        let correlation = suppressor.peakCrossCorrelation(micSamples: mic)
        XCTAssertLessThan(correlation, EchoSuppressor.crossCorrelationEchoThreshold,
                          "Different audio should have low correlation")
    }

    func testCrossCorrelationWithSilence() {
        var suppressor = EchoSuppressor()
        let silence = [Float](repeating: 0, count: 1600)
        suppressor.recordPlaybackAudio(samples: silence, sampleRate: 16_000)

        let correlation = suppressor.peakCrossCorrelation(micSamples: silence)
        XCTAssertEqual(correlation, 0, accuracy: 0.001,
                       "Silent audio should produce zero correlation")
    }

    func testCrossCorrelationWithEmptyBuffer() {
        let suppressor = EchoSuppressor()
        let mic = [Float](repeating: 0.1, count: 1600)
        let correlation = suppressor.peakCrossCorrelation(micSamples: mic)
        XCTAssertEqual(correlation, 0,
                       "Empty playback buffer should produce zero correlation")
    }

    func testIsLikelyAcousticEchoDetectsEcho() {
        var suppressor = EchoSuppressor()
        let n = 1600
        var tone = [Float](repeating: 0, count: n)
        for i in 0..<n {
            tone[i] = 0.3 * sin(2 * Float.pi * 440 * Float(i) / 16000)
        }
        suppressor.recordPlaybackAudio(samples: tone, sampleRate: 16_000)

        XCTAssertTrue(suppressor.isLikelyAcousticEcho(micSamples: tone),
                      "Identical audio should be detected as echo")
    }

    func testRecordPlaybackAudioDownsamplesFrom24kHz() {
        var suppressor = EchoSuppressor()
        // Record 24kHz audio — should downsample to 16kHz.
        let samples24k = [Float](repeating: 0.1, count: 2400)  // 100ms at 24kHz
        suppressor.recordPlaybackAudio(samples: samples24k, sampleRate: 24_000)

        // After downsampling, should have ~1600 samples.
        let mic = [Float](repeating: 0.1, count: 160)
        // Just verify it doesn't crash and produces a result.
        let _ = suppressor.peakCrossCorrelation(micSamples: mic)
    }

    func testPlaybackRingBufferTrimmed() {
        var suppressor = EchoSuppressor()
        // Fill beyond max capacity.
        let bigChunk = [Float](repeating: 0.1, count: 50_000)
        suppressor.recordPlaybackAudio(samples: bigChunk, sampleRate: 16_000)

        // Should still work (buffer trimmed to max).
        let mic = [Float](repeating: 0.1, count: 160)
        let _ = suppressor.peakCrossCorrelation(micSamples: mic)
    }

    func testClearPlaybackAudioBuffer() {
        var suppressor = EchoSuppressor()
        let n = 1600
        var tone = [Float](repeating: 0, count: n)
        for i in 0..<n {
            tone[i] = 0.3 * sin(2 * Float.pi * 440 * Float(i) / 16000)
        }
        suppressor.recordPlaybackAudio(samples: tone, sampleRate: 16_000)
        suppressor.clearPlaybackAudioBuffer()

        let correlation = suppressor.peakCrossCorrelation(micSamples: tone)
        XCTAssertEqual(correlation, 0,
                       "After clearing buffer, correlation should be zero")
    }

    func testResetClearsPlaybackAudioBuffer() {
        var suppressor = EchoSuppressor()
        let tone = [Float](repeating: 0.1, count: 1600)
        suppressor.recordPlaybackAudio(samples: tone, sampleRate: 16_000)
        suppressor.reset()

        let correlation = suppressor.peakCrossCorrelation(micSamples: tone)
        XCTAssertEqual(correlation, 0,
                       "Reset should clear playback audio buffer")
    }

    // MARK: - Spectral Envelope Comparison

    func testSpectralSimilarityIdenticalEnvelopes() {
        let energy = EchoSuppressor.BandEnergy(low: 0.05, mid: 0.08, high: 0.01)
        let similarity = EchoSuppressor.spectralEnvelopeSimilarity(
            micEnergy: energy, ttsEnergy: energy)
        XCTAssertEqual(similarity, 1.0, accuracy: 0.001,
                       "Identical spectral envelopes should have similarity 1.0")
    }

    func testSpectralSimilarityOrthogonalEnvelopes() {
        let mic = EchoSuppressor.BandEnergy(low: 0.0, mid: 0.0, high: 0.1)
        let tts = EchoSuppressor.BandEnergy(low: 0.1, mid: 0.0, high: 0.0)
        let similarity = EchoSuppressor.spectralEnvelopeSimilarity(
            micEnergy: mic, ttsEnergy: tts)
        XCTAssertEqual(similarity, 0.0, accuracy: 0.001,
                       "Orthogonal envelopes should have zero similarity")
    }

    func testSpectralSimilaritySimilarEnvelopes() {
        let mic = EchoSuppressor.BandEnergy(low: 0.04, mid: 0.07, high: 0.009)
        let tts = EchoSuppressor.BandEnergy(low: 0.05, mid: 0.08, high: 0.01)
        let similarity = EchoSuppressor.spectralEnvelopeSimilarity(
            micEnergy: mic, ttsEnergy: tts)
        XCTAssertGreaterThan(similarity, 0.99,
                             "Similar envelopes should have high similarity")
    }

    func testSpectralSimilarityWithSilence() {
        let silence = EchoSuppressor.BandEnergy()
        let energy = EchoSuppressor.BandEnergy(low: 0.05, mid: 0.08, high: 0.01)
        let similarity = EchoSuppressor.spectralEnvelopeSimilarity(
            micEnergy: silence, ttsEnergy: energy)
        XCTAssertEqual(similarity, 0,
                       "Silence should have zero similarity")
    }

    // MARK: - Synthetic Echo Scenarios

    /// Generate a tone signal at given frequency and duration.
    private func generateTone(
        frequency: Float,
        durationMs: Int,
        amplitude: Float = 0.3,
        sampleRate: Int = 16_000
    ) -> [Float] {
        let n = sampleRate * durationMs / 1000
        return (0..<n).map { i in
            amplitude * sin(2 * Float.pi * frequency * Float(i) / Float(sampleRate))
        }
    }

    /// Simulate speaker echo: attenuated, delayed, high-frequency rolloff.
    private func simulateSpeakerEcho(
        original: [Float],
        delayMs: Int = 50,
        attenuation: Float = 0.4,
        sampleRate: Int = 16_000
    ) -> [Float] {
        let delaySamples = sampleRate * delayMs / 1000
        let outputLength = original.count + delaySamples
        var output = [Float](repeating: 0, count: outputLength)

        // Copy with delay and attenuation.
        for i in 0..<original.count {
            output[i + delaySamples] = original[i] * attenuation
        }

        // Simple high-frequency rolloff (moving average as low-pass filter).
        let filterSize = 3
        for i in filterSize..<output.count {
            var sum: Float = 0
            for j in 0..<filterSize {
                sum += output[i - j]
            }
            output[i] = sum / Float(filterSize)
        }

        return output
    }

    func testSyntheticEchoAtVariousAttenuations() {
        // Test that echo at different volume levels is handled correctly.
        let original = generateTone(frequency: 300, durationMs: 500)

        let attenuations: [Float] = [0.8, 0.5, 0.3, 0.1]
        for attenuation in attenuations {
            var suppressor = EchoSuppressor()
            suppressor.recordPlaybackAudio(samples: original, sampleRate: 16_000)

            let echo = simulateSpeakerEcho(original: original, attenuation: attenuation)
            // Take a segment from the echo (skip the delay prefix).
            let segment = Array(echo.suffix(original.count))

            if attenuation >= 0.3 {
                // Strong echo should be detected.
                let corr = suppressor.peakCrossCorrelation(micSamples: segment)
                XCTAssertGreaterThan(corr, 0.3,
                                     "Echo at attenuation \(attenuation) should show correlation")
            }
        }
    }

    func testSyntheticEchoAtVariousDelays() {
        let original = generateTone(frequency: 300, durationMs: 200)

        let delays = [10, 50, 100, 200]  // milliseconds
        for delayMs in delays {
            var suppressor = EchoSuppressor()
            suppressor.recordPlaybackAudio(samples: original, sampleRate: 16_000)

            let echo = simulateSpeakerEcho(original: original, delayMs: delayMs, attenuation: 0.5)
            let segment = Array(echo.suffix(original.count))

            // Should still detect echo regardless of delay (ring buffer has full history).
            let corr = suppressor.peakCrossCorrelation(micSamples: segment)
            XCTAssertGreaterThan(corr, 0.2,
                                 "Echo at delay \(delayMs)ms should show some correlation")
        }
    }

    func testUserSpeechDoesNotCorrelateWithTTS() {
        var suppressor = EchoSuppressor()
        // TTS: Fae's voice at 300 Hz (simulated).
        let tts = generateTone(frequency: 300, durationMs: 500)
        suppressor.recordPlaybackAudio(samples: tts, sampleRate: 16_000)

        // User speech: different frequency content.
        let userSpeech = generateTone(frequency: 800, durationMs: 500, amplitude: 0.4)
        let corr = suppressor.peakCrossCorrelation(micSamples: userSpeech)
        XCTAssertLessThan(corr, EchoSuppressor.crossCorrelationEchoThreshold,
                          "User speech at different frequency should not correlate with TTS")
    }

    func testOverlappingUserSpeechAndEcho() {
        // Scenario: user starts speaking while echo is still in the mic.
        // The combined signal should not be rejected as pure echo.
        var suppressor = EchoSuppressor()
        let tts = generateTone(frequency: 300, durationMs: 500)
        suppressor.recordPlaybackAudio(samples: tts, sampleRate: 16_000)

        // Mix echo (attenuated 300 Hz) + user speech (800 Hz).
        let n = tts.count
        var mixed = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let echo = 0.2 * sin(2 * Float.pi * 300 * Float(i) / 16000)
            let user = 0.4 * sin(2 * Float.pi * 800 * Float(i) / 16000)
            mixed[i] = echo + user
        }

        // Mixed signal should have lower correlation than pure echo.
        let pureEchoCorr = suppressor.peakCrossCorrelation(micSamples: tts)
        let mixedCorr = suppressor.peakCrossCorrelation(micSamples: mixed)
        XCTAssertLessThan(mixedCorr, pureEchoCorr,
                          "Mixed echo+speech should have lower correlation than pure echo")
    }

    func testBandEnergyDistinguishesNearFieldVsFarFieldEcho() {
        // Near-field speech: full spectrum with sibilants.
        let nearField = EchoSuppressor.BandEnergy(low: 0.03, mid: 0.05, high: 0.02)
        XCTAssertFalse(nearField.looksLikeSpeakerEcho,
                       "Near-field speech should not look like echo")

        // Far-field echo through speakers: rolled-off highs.
        let farField = EchoSuppressor.BandEnergy(low: 0.04, mid: 0.06, high: 0.002)
        XCTAssertTrue(farField.looksLikeSpeakerEcho,
                      "Speaker echo with rolled-off highs should be detected")
    }

    func testTimingAndTextOverlapCombinedRejection() {
        // Test that the existing timing-based rejection still works in combination
        // with the new features.
        var suppressor = EchoSuppressor()
        suppressor.outputRoute = .builtInSpeaker
        suppressor.recordAssistantText("let me check your calendar for tomorrow morning")

        suppressor.onAssistantSpeechStart()
        suppressor.onAssistantSpeechEnd(speechDurationSecs: 3.0)

        // Text overlap should catch echo that slips past timing.
        XCTAssertTrue(
            suppressor.isLikelyEchoText("let me check your calendar for tomorrow morning"),
            "Text overlap should still work with new features active")
    }

    // MARK: - Output Route Scenario Matrix

    func testHeadphoneScenarioRelaxedTiming() {
        var suppressor = EchoSuppressor()
        suppressor.outputRoute = .headphones

        suppressor.onAssistantSpeechStart()
        suppressor.onAssistantSpeechEnd(speechDurationSecs: 2.0)

        // Headphones: shorter echo tail means segments are accepted sooner.
        let earlyOnset = Date().addingTimeInterval(0.2) // 200ms after speech end
        let accepted = suppressor.shouldAccept(
            durationSecs: 1.0, rms: 0.05,
            awaitingApproval: false,
            segmentOnset: earlyOnset)

        // With headphones (0.3x multiplier), echo tail is ~150ms base + tiny bonus.
        // At 200ms after speech end, segment onset should be past the echo tail.
        XCTAssertTrue(accepted,
                      "Headphones should have relaxed enough timing to accept at 200ms")
    }

    func testExternalSpeakerScenarioAggressiveTiming() {
        var suppressor = EchoSuppressor()
        suppressor.outputRoute = .externalSpeaker

        suppressor.onAssistantSpeechStart()
        suppressor.onAssistantSpeechEnd(speechDurationSecs: 2.0)

        // External speakers: longer echo tail.
        // At 500ms after speech end with 1.3x multiplier, should still be in tail.
        let earlyOnset = Date() // Right at speech end
        let accepted = suppressor.shouldAccept(
            durationSecs: 0.3, rms: 0.05,
            awaitingApproval: false,
            segmentOnset: earlyOnset)
        XCTAssertFalse(accepted,
                       "External speakers should reject segments within longer echo tail")
    }

    // MARK: - Existing Behavior Preserved

    func testShouldAcceptStillWorksWithNewFeatures() {
        var suppressor = EchoSuppressor()
        suppressor.outputRoute = .builtInSpeaker

        suppressor.onAssistantSpeechStart()
        let duringResult = suppressor.shouldAccept(
            durationSecs: 1.0, rms: 0.05,
            awaitingApproval: false,
            segmentOnset: Date())
        XCTAssertFalse(duringResult, "Should reject during active speaking")

        suppressor.onAssistantSpeechEnd(speechDurationSecs: 2.0)

        // Wait for echo tail to expire.
        let afterTail = Date().addingTimeInterval(2.0)
        let afterResult = suppressor.shouldAccept(
            durationSecs: 1.0, rms: 0.05,
            awaitingApproval: false,
            segmentOnset: afterTail)
        XCTAssertTrue(afterResult, "Should accept after echo tail expires")
    }

    func testEchoTailRejectionStillWorks() {
        // Verify the static method still works correctly.
        let now = Date()
        let suppressUntil = now.addingTimeInterval(0.5)

        // Segment starts before suppression end, ends before too.
        let shouldReject = EchoSuppressor.shouldRejectForEchoTail(
            segmentOnset: now,
            durationSecs: 0.3,
            suppressUntil: suppressUntil)
        XCTAssertTrue(shouldReject, "Segment within echo tail should be rejected")

        // Segment starts after suppression end.
        let shouldAccept = EchoSuppressor.shouldRejectForEchoTail(
            segmentOnset: suppressUntil.addingTimeInterval(0.1),
            durationSecs: 0.3,
            suppressUntil: suppressUntil)
        XCTAssertFalse(shouldAccept, "Segment after echo tail should not be rejected")
    }
}
