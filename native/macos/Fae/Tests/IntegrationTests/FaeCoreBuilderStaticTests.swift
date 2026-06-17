import XCTest
@testable import Fae

/// Coverage for FaeCore.swift's pure-logic static helpers (settings dictionary
/// builders, decimal formatter, WAV PCM parser). Previously uncovered (FaeCore
/// at 41%, these builders/parse paths dark). No instance state, no network.
@MainActor
final class FaeCoreBuilderStaticTests: XCTestCase {

    // MARK: - settingsSection / setting / option / settingsCard

    func testSettingsSectionShape() {
        let section = FaeCore.settingsSection(
            id: "audio", title: "Audio", description: "Audio prefs",
            settings: [["key": "vol"]]
        )
        XCTAssertEqual(section["id"] as? String, "audio")
        XCTAssertEqual(section["title"] as? String, "Audio")
        XCTAssertEqual(section["description"] as? String, "Audio prefs")
        XCTAssertNotNil(section["settings"] as? [[String: Any]])
    }

    func testSettingMinimal() {
        let s = FaeCore.setting(
            key: "vol", title: "Volume", description: "Loudness",
            kind: "slider", value: "0.5"
        )
        XCTAssertEqual(s["key"] as? String, "vol")
        XCTAssertEqual(s["kind"] as? String, "slider")
        XCTAssertEqual(s["value"] as? String, "0.5")
        XCTAssertEqual(s["read_only"] as? Bool, false)
        // Optional keys absent when nil.
        XCTAssertNil(s["options"])
        XCTAssertNil(s["min"])
        XCTAssertNil(s["unit"])
    }

    func testSettingFullWithOptions() {
        let s = FaeCore.setting(
            key: "mode", title: "Mode", description: "", kind: "select", value: "auto",
            options: [FaeCore.option("auto", "Automatic"), FaeCore.option("manual", "Manual")],
            min: "0", max: "100", step: "1", unit: "%", readOnly: true
        )
        XCTAssertEqual(s["read_only"] as? Bool, true)
        let opts = s["options"] as? [[String: String]]
        XCTAssertEqual(opts?.count, 2)
        XCTAssertEqual(opts?[0]["value"], "auto")
        XCTAssertEqual(opts?[1]["label"], "Manual")
        XCTAssertEqual(s["min"] as? String, "0")
        XCTAssertEqual(s["max"] as? String, "100")
        XCTAssertEqual(s["step"] as? String, "1")
        XCTAssertEqual(s["unit"] as? String, "%")
    }

    func testOptionKeyValuePair() {
        let opt = FaeCore.option("x", "Label X")
        XCTAssertEqual(opt, ["value": "x", "label": "Label X"])
    }

    func testSettingsCardShape() {
        let card = FaeCore.settingsCard(title: "T", body: "B", detail: "D")
        XCTAssertEqual(card["title"] as? String, "T")
        XCTAssertEqual(card["body"] as? String, "B")
        XCTAssertEqual(card["detail"] as? String, "D")
    }

    // MARK: - decimal

    func testDecimalFormatsTwoPlaces() {
        XCTAssertEqual(FaeCore.decimal(0.1), "0.10")
        XCTAssertEqual(FaeCore.decimal(1.005), "1.01") // banker's/printf rounding
        XCTAssertEqual(FaeCore.decimal(123.456), "123.46")
        XCTAssertEqual(FaeCore.decimal(0), "0.00")
    }

    // MARK: - loadWAVSamples

    private let tempDir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("fae-wav-\(UUID().uuidString)")

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Build a minimal valid WAV (44-byte header + PCM16 samples) and verify the
    /// parser converts Int16 → Float32 (-1.0…1.0).
    func testLoadWAVSamplesParsesPCM16() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let samples: [Int16] = [0, 16384, -16384, 32767, -32768]
        var data = Data()
        // RIFF header
        data.append("RIFF".data(using: .ascii)!)
        let pcmBytes = samples.count * 2
        data.append(UInt32(36 + pcmBytes).littleEndianBytes)
        data.append("WAVE".data(using: .ascii)!)
        // fmt chunk
        data.append("fmt ".data(using: .ascii)!)
        data.append(UInt32(16).littleEndianBytes) // PCM fmt chunk size
        data.append(UInt16(1).littleEndianBytes)  // PCM
        data.append(UInt16(1).littleEndianBytes)  // mono
        data.append(UInt32(16000).littleEndianBytes) // sample rate
        data.append(UInt32(16000 * 2).littleEndianBytes) // byte rate
        data.append(UInt16(2).littleEndianBytes)  // block align
        data.append(UInt16(16).littleEndianBytes) // bits
        // data chunk
        data.append("data".data(using: .ascii)!)
        data.append(UInt32(pcmBytes).littleEndianBytes)
        for s in samples { data.append(s.littleEndianBytes) }

        let url = tempDir.appendingPathComponent("tone.wav")
        try data.write(to: url)

        let parsed = try FaeCore.loadWAVSamples(at: url.path)
        XCTAssertEqual(parsed.count, samples.count)
        XCTAssertEqual(parsed[0], 0.0, accuracy: 1e-5)
        XCTAssertEqual(parsed[1], Float(16384) / 32768.0, accuracy: 1e-4)
        XCTAssertEqual(parsed[2], Float(-16384) / 32768.0, accuracy: 1e-4)
        XCTAssertEqual(parsed[3], Float(32767) / 32768.0, accuracy: 1e-4)
        XCTAssertEqual(parsed[4], Float(-32768) / 32768.0, accuracy: 1e-4)
    }

    func testLoadWAVSamplesRejectsTooSmall() {
        let url = tempDir.appendingPathComponent("tiny.wav")
        try? Data("RIFF".data(using: .ascii)!).write(to: url)
        XCTAssertThrowsError(try FaeCore.loadWAVSamples(at: url.path))
    }

    func testLoadWAVSamplesThrowsOnMissingFile() {
        XCTAssertThrowsError(
            try FaeCore.loadWAVSamples(at: "/nonexistent/fae-coverage/no-such.wav")
        )
    }
}

// Little-endian byte helpers for synthesising the WAV header in tests.
private extension UInt32 {
    var littleEndianBytes: Data {
        var v = self.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
}

private extension UInt16 {
    var littleEndianBytes: Data {
        var v = self.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
}

private extension Int16 {
    var littleEndianBytes: Data {
        var v = self.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
}
