import AVFoundation
import XCTest

@testable import Fae

// MARK: - Voice mapping
//
// The daemon resolves voice names itself: its local voices directory first
// (custom voices like Fae's own "fae", installed by installBundledVoices()),
// then the HF repo, then its fallback voice. The client therefore passes any
// plain voice name through verbatim — mapping "fae" to a stock voice here
// would permanently silence Fae's own voice. Only non-names (descriptions,
// empty strings) are mapped to the fallback client-side.

final class DaemonTTSVoiceMappingTests: XCTestCase {

    func testCustomFaeVoicePassesThroughToDaemon() {
        XCTAssertEqual(DaemonTTSEngine.daemonVoice(from: "fae"), "fae")
    }

    func testKokoroVoiceIdsPassThrough() {
        XCTAssertEqual(DaemonTTSEngine.daemonVoice(from: "af_heart"), "af_heart")
        XCTAssertEqual(DaemonTTSEngine.daemonVoice(from: "bm_daniel"), "bm_daniel")
        XCTAssertEqual(DaemonTTSEngine.daemonVoice(from: "BF_Emma"), "bf_emma")
    }

    func testRequestVoiceInstructOverridesOnlyWithRealVoiceId() {
        // A bare Kokoro id (voice preview) overrides for that request…
        XCTAssertEqual(
            DaemonTTSEngine.requestVoice(instruct: "af_bella", current: "bf_emma"),
            "af_bella")
        // …but a descriptive instruct must NOT silently reset a switched
        // voice to the fallback — the daemon has no instruct conditioning.
        XCTAssertEqual(
            DaemonTTSEngine.requestVoice(
                instruct: "A warm, calm female voice", current: "bf_emma"),
            "bf_emma")
        XCTAssertEqual(DaemonTTSEngine.requestVoice(instruct: nil, current: "bf_emma"), "bf_emma")
        // Asking for the fallback voice by name is honoured.
        XCTAssertEqual(
            DaemonTTSEngine.requestVoice(instruct: "af_heart", current: "bf_emma"),
            "af_heart")
    }

    func testNonNamesFallBackClientSide() {
        XCTAssertEqual(DaemonTTSEngine.daemonVoice(from: ""), DaemonTTSEngine.fallbackVoice)
        XCTAssertEqual(DaemonTTSEngine.daemonVoice(from: "   "), DaemonTTSEngine.fallbackVoice)
        // Descriptions (spaces) are instructs, not voice names.
        XCTAssertEqual(
            DaemonTTSEngine.daemonVoice(from: "totally custom voice"),
            DaemonTTSEngine.fallbackVoice)
    }

    func testUnknownPlainNamesPassThrough() {
        // Unknown plain names reach the daemon, which degrades them to its
        // own fallback voice — resolution lives daemon-side where the local
        // voices directory is visible.
        XCTAssertEqual(DaemonTTSEngine.daemonVoice(from: "abc_def"), "abc_def")
    }
}

// MARK: - WAV contract
//
// The daemon returns synthesized audio as base64 16-bit PCM mono WAV at the
// sample rate it reports (24 kHz Kokoro). The playback path consumes Float32
// AVAudioPCMBuffers and trusts their format's sample rate for resampling — a
// dropped sample or wrong rate shifts pitch/duration audibly. Round-trip
// through the same encoder the daemon path uses to pin the contract.

final class DaemonTTSAudioContractTests: XCTestCase {

    func testWavRoundTripPreservesSamplesAndRate() throws {
        let original: [Float] = (0..<480).map { sin(Float($0) * 0.05) * 0.7 }
        let wav = WAVEncoder.encode(samples: original, sampleRate: 24_000)

        let decoded = WAVParser.parseToFloat32(wav)
        XCTAssertEqual(decoded.count, original.count)
        XCTAssertEqual(WAVParser.parseSampleRate(wav), 24_000)

        let buffer = try DaemonTTSEngine.makePCMBuffer(samples: decoded, sampleRate: 24_000)
        XCTAssertEqual(buffer.frameLength, AVAudioFrameCount(original.count))
        XCTAssertEqual(buffer.format.sampleRate, 24_000)
        XCTAssertEqual(buffer.format.channelCount, 1)

        // 16-bit quantization tolerance only.
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in stride(from: 0, to: original.count, by: 37) {
            XCTAssertEqual(channel[index], original[index], accuracy: 1.0 / 32_768.0 * 2)
        }
    }

    func testMakePCMBufferRejectsNothingButProducesEmptyBuffer() throws {
        // Empty audio is handled upstream (performSynthesis returns nil);
        // makePCMBuffer itself must still allocate a valid zero-frame buffer
        // rather than trap if it is ever reached.
        let buffer = try DaemonTTSEngine.makePCMBuffer(samples: [], sampleRate: 24_000)
        XCTAssertEqual(buffer.frameLength, 0)
    }
}

// MARK: - Config
//
// The daemon TTS lane must be opt-in: shipping default stays on the proven
// in-process Kokoro adapter, and the dev profile turns the lane on via
// config.toml — so the key has to survive a save/load round trip.

final class DaemonTTSConfigTests: XCTestCase {

    func testUseDaemonEngineDefaultsOff() {
        XCTAssertFalse(FaeConfig().tts.useDaemonEngine)
    }

    func testUseDaemonEngineParsesAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaemonTTSConfigTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("config.toml")

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "[tts]\nuseDaemonEngine = true\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let parsed = FaeConfig.load(from: fileURL)
        XCTAssertTrue(parsed.tts.useDaemonEngine)

        var config = FaeConfig()
        config.tts.useDaemonEngine = true
        try config.save(to: fileURL)
        XCTAssertTrue(FaeConfig.load(from: fileURL).tts.useDaemonEngine)
    }
}
