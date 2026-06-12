import XCTest

@testable import Fae

// MARK: - MLX-lane custom voice
//
// The default config (voiceIdentityLock=true) synthesizes with voice "fae",
// which is NOT a stock Kokoro voice — KokoroModel.loadVoice would throw on
// every sentence and silence the in-process lane. FaeTTSAdapter therefore
// loads the bundled embedding and passes it as refAudio; these tests pin the
// asset and the classification that decides between the two paths.
//
// Note: loadBundledVoiceEmbedding itself needs the MLX Metal runtime, which
// `swift test` cannot provide (metallib only exists in xcodebuild bundles) —
// the asset is validated here by parsing the safetensors header directly.

final class FaeTTSAdapterVoiceTests: XCTestCase {

    func testStockVoiceClassification() {
        XCTAssertTrue(FaeTTSAdapter.isStockKokoroVoice("af_heart"))
        XCTAssertTrue(FaeTTSAdapter.isStockKokoroVoice("bm_daniel"))
        // Fae's own voice must NOT classify as stock — that path throws.
        XCTAssertFalse(FaeTTSAdapter.isStockKokoroVoice("fae"))
        XCTAssertFalse(FaeTTSAdapter.isStockKokoroVoice(""))
        XCTAssertFalse(FaeTTSAdapter.isStockKokoroVoice("abc_def"))
        XCTAssertFalse(FaeTTSAdapter.isStockKokoroVoice("af_"))
    }

    func testBundledFaeVoiceAssetHasKokoroVoicePackShape() throws {
        let url = try XCTUnwrap(
            Bundle.faeResources.url(forResource: "fae", withExtension: "safetensors"),
            "bundled fae.safetensors must exist — without it the default voice degrades")
        let data = try Data(contentsOf: url)

        // safetensors layout: u64 LE header length, then a JSON header
        // mapping tensor name → {dtype, shape, data_offsets}.
        XCTAssertGreaterThan(data.count, 8)
        let headerLength = data[0..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        let headerEnd = 8 + Int(UInt64(littleEndian: headerLength))
        XCTAssertGreaterThan(data.count, headerEnd)
        let header = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data[8..<headerEnd]) as? [String: Any])
        let voice = try XCTUnwrap(header["voice"] as? [String: Any], "tensor must be named 'voice'")

        // KokoroModel and voice-tts both expect the full voice pack: one
        // (1, 256) style row per phoneme count. A different shape would
        // crash or mis-style synthesis in BOTH TTS lanes.
        XCTAssertEqual(voice["shape"] as? [Int], [510, 1, 256])
        XCTAssertEqual(voice["dtype"] as? String, "F32")

        // Payload must hold exactly 510*1*256 float32 values.
        XCTAssertEqual(data.count - headerEnd, 510 * 256 * 4)
    }
}
