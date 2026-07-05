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

// MARK: - Bundled voice install
//
// The daemon resolves "fae" from `<data dir>/voices/fae.safetensors` before the
// HF repo; if that file is missing it degrades to the generic `af_heart`
// fallback (the live-pass "not like Lauren" regression). `installBundledVoice`
// must therefore populate a fresh voices directory with no manual copy AND
// self-heal a prior failed attempt (truncated / size-mismatched file), so a
// second call is idempotent and a broken file is replaced rather than trusted.
// These tests exercise the pure filesystem installer in hermetic temp dirs.

final class DaemonTTSBundledVoiceInstallTests: XCTestCase {

    /// Deterministic stand-in for the bundled embedding (real bytes are opaque;
    /// the installer only cares about presence + byte size).
    private func makeFakeBundledVoice(bytes: Int) throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaemonTTSVoiceInstall-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("fae.safetensors")
        try Data(repeating: 0xAB, count: bytes).write(to: file)
        return (dir, file)
    }

    func testInstallsIntoFreshDirectoryWithNoManualCopy() throws {
        let (srcDir, bundled) = try makeFakeBundledVoice(bytes: 4096)
        defer { try? FileManager.default.removeItem(at: srcDir) }

        // A fresh data dir: the `voices/` subdirectory does not exist yet.
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaemonTTSVoiceInstall-fresh-\(UUID().uuidString)")
        let voicesDir = dataDir.appendingPathComponent("voices")
        defer { try? FileManager.default.removeItem(at: dataDir) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: voicesDir.path))

        XCTAssertTrue(DaemonTTSEngine.installBundledVoice(from: bundled, into: voicesDir))

        let target = voicesDir.appendingPathComponent("fae.safetensors")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: bundled))
    }

    func testSecondCallIsIdempotent() throws {
        let (srcDir, bundled) = try makeFakeBundledVoice(bytes: 2048)
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let voicesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaemonTTSVoiceInstall-idem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: voicesDir) }

        XCTAssertTrue(DaemonTTSEngine.installBundledVoice(from: bundled, into: voicesDir))
        let target = voicesDir.appendingPathComponent("fae.safetensors")
        let firstModified = try FileManager.default
            .attributesOfItem(atPath: target.path)[.modificationDate] as? Date

        // Second call must succeed without re-copying the already-correct file.
        XCTAssertTrue(DaemonTTSEngine.installBundledVoice(from: bundled, into: voicesDir))
        let secondModified = try FileManager.default
            .attributesOfItem(atPath: target.path)[.modificationDate] as? Date
        XCTAssertEqual(firstModified, secondModified,
            "an already-consistent voice file must not be re-copied")
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: bundled))
    }

    func testSelfHealsTruncatedPriorFailure() throws {
        let (srcDir, bundled) = try makeFakeBundledVoice(bytes: 8192)
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let voicesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaemonTTSVoiceInstall-heal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: voicesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: voicesDir) }

        // Simulate a prior failed attempt: a truncated file of the wrong size.
        let target = voicesDir.appendingPathComponent("fae.safetensors")
        try Data(repeating: 0x00, count: 16).write(to: target)
        XCTAssertNotEqual(
            (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize),
            (try? bundled.resourceValues(forKeys: [.fileSizeKey]).fileSize))

        // The installer must replace the broken file, not trust it.
        XCTAssertTrue(DaemonTTSEngine.installBundledVoice(from: bundled, into: voicesDir))
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: bundled))
    }

    func testDaemonVoicesDirectoryIsProductionDataDir() {
        // The daemon is not dev-isolated: the install target must stay the
        // production `fae/voices` (matching fae-daemon's local_voices_directory),
        // never `fae-dev/voices` which the daemon never reads.
        XCTAssertEqual(DaemonTTSEngine.daemonVoicesDirectory.lastPathComponent, "voices")
        XCTAssertEqual(
            DaemonTTSEngine.daemonVoicesDirectory.deletingLastPathComponent().lastPathComponent,
            "fae")
    }
}

// MARK: - Config
//
// The daemon TTS lane must be opt-in: shipping default stays on the proven
// in-process Kokoro adapter, and the dev profile turns the lane on via
// config.toml — so the key has to survive a save/load round trip.

final class DaemonTTSConfigTests: XCTestCase {

    func testUseDaemonEngineDefaultsOn() {
        // Daemon TTS is the primary lane (daemon-default, 2026-06-13): a fresh
        // install synthesizes via the daemon's Kokoro, with FaeTTSAdapter as
        // the loud fallback.
        XCTAssertTrue(FaeConfig().tts.useDaemonEngine)
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
