import XCTest
@testable import Fae

/// Coverage for pure static helpers across three previously-partial files:
/// DaemonLLMEngine (token/byte/line helpers), WAVParser (little-endian byte
/// readers), and ToolAugmentationManager (git-remote + project-type detection).
/// All pure or temp-file-only — no network, no system frameworks.
final class PureHelpersStaticTests: XCTestCase {

    private let tempDir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("fae-pure-\(UUID().uuidString)")

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - DaemonLLMEngine

    func testEstimateTextTokens() {
        XCTAssertEqual(DaemonWire.estimateTextTokens(0), 0)
        XCTAssertEqual(DaemonWire.estimateTextTokens(1), 1)   // min 1
        XCTAssertEqual(DaemonWire.estimateTextTokens(4), 1)
        XCTAssertEqual(DaemonWire.estimateTextTokens(5), 2)
        XCTAssertEqual(DaemonWire.estimateTextTokens(100), 25)
    }

    func testJsonByteCountValid() {
        let bytes = DaemonWire.jsonByteCount(["a": 1, "b": "x"])
        XCTAssertGreaterThan(bytes, 0)
    }

    func testJsonByteCountInvalid() {
        // Non-JSON-serialisable (Date isn't valid JSONObject) -> 0.
        XCTAssertEqual(DaemonWire.jsonByteCount(Date()), 0)
    }

    func testValueAfterColon() {
        XCTAssertEqual(DaemonWire.valueAfterColon("key: value"), "value")
        XCTAssertEqual(DaemonWire.valueAfterColon("k:  spaced  "), "spaced")
        XCTAssertNil(DaemonWire.valueAfterColon("no colon here"))
        XCTAssertNil(DaemonWire.valueAfterColon("k:   ")) // empty after strip
    }

    func testStripTrailingAnnotation() {
        XCTAssertEqual(DaemonWire.stripTrailingAnnotation("value (annotation)"), "value")
        XCTAssertEqual(DaemonWire.stripTrailingAnnotation("  plain  "), "plain")
        XCTAssertEqual(DaemonWire.stripTrailingAnnotation("no-annotation"), "no-annotation")
    }

    // MARK: - WAVParser byte readers

    func testReadU16LittleEndian() {
        let data = Data([0x34, 0x12])
        XCTAssertEqual(WAVParser.readU16(data, at: 0), 0x1234)
    }

    func testReadU32LittleEndian() {
        let data = Data([0x78, 0x56, 0x34, 0x12])
        XCTAssertEqual(WAVParser.readU32(data, at: 0), 0x12345678)
    }

    func testReadI16Signed() {
        XCTAssertEqual(WAVParser.readI16(Data([0x00, 0x80]), at: 0), -32768) // 0x8000 sign-extended
        XCTAssertEqual(WAVParser.readI16(Data([0xFF, 0x7F]), at: 0), 32767)
        XCTAssertEqual(WAVParser.readI16(Data([0x00, 0x00]), at: 0), 0)
    }

    // MARK: - ToolAugmentationManager.detectProjectType

    func testDetectProjectTypeRust() throws {
        try writeTempFile(named: "Cargo.toml", content: "[package]\n")
        XCTAssertEqual(ToolAugmentationManager.detectProjectType(at: tempDir.path), "Rust")
    }

    func testDetectProjectTypeSwift() throws {
        try writeTempFile(named: "Package.swift", content: "// swift-tools\n")
        XCTAssertEqual(ToolAugmentationManager.detectProjectType(at: tempDir.path), "Swift")
    }

    func testDetectProjectTypeTypeScript() throws {
        try writeTempFile(named: "package.json", content: "{}")
        try writeTempFile(named: "tsconfig.json", content: "{}")
        XCTAssertEqual(ToolAugmentationManager.detectProjectType(at: tempDir.path), "TypeScript")
    }

    func testDetectProjectTypeJavaScript() throws {
        try writeTempFile(named: "package.json", content: "{}")
        XCTAssertEqual(ToolAugmentationManager.detectProjectType(at: tempDir.path), "JavaScript")
    }

    func testDetectProjectTypePython() throws {
        try writeTempFile(named: "pyproject.toml", content: "[project]\n")
        XCTAssertEqual(ToolAugmentationManager.detectProjectType(at: tempDir.path), "Python")
    }

    func testDetectProjectTypeNone() {
        // Empty temp dir -> nil.
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        XCTAssertNil(ToolAugmentationManager.detectProjectType(at: tempDir.path))
    }

    // MARK: - ToolAugmentationManager.extractGitRemote

    func testExtractGitRemoteParsesOriginURL() throws {
        let config = """
        [core]
        \trepositoryformatversion = 0
        [remote "origin"]
        \turl = git@github.com:saorsa-labs/fae.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [branch "main"]
        \tremote = origin
        """
        try writeGitConfig(config)
        let remote = ToolAugmentationManager.extractGitRemote(at: tempDir.path)
        XCTAssertNotNil(remote)
        XCTAssertTrue(remote?.contains("github.com") ?? false)
    }

    func testExtractGitRemoteReturnsNilWithoutConfig() {
        try? FileManager.default.createDirectory(at: tempDir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertNil(ToolAugmentationManager.extractGitRemote(at: tempDir.path))
    }

    // MARK: - Helpers

    private func writeTempFile(named name: String, content: String) throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try content.write(to: tempDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func writeGitConfig(_ content: String) throws {
        let gitDir = tempDir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try content.write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    }
}
