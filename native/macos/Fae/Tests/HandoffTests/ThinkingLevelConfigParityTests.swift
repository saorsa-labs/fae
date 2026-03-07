import Foundation
import XCTest
@testable import Fae

final class ThinkingLevelConfigParityTests: XCTestCase {
    func testExplicitThinkingLevelOverridesLegacyBooleanMirror() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-thinking-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let fileURL = tempRoot.appendingPathComponent("config.toml")

        let content = """
        [llm]
        thinkingEnabled = true
        thinkingLevel = "fast"
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let config = FaeConfig.load(from: fileURL)
        XCTAssertEqual(config.llm.resolvedThinkingLevel, .fast)
        XCTAssertFalse(config.llm.thinkingEnabled)
    }

    func testInvalidExplicitThinkingLevelFallsBackToLegacyBooleanAndNormalizes() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-thinking-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let fileURL = tempRoot.appendingPathComponent("config.toml")

        let content = """
        [llm]
        thinkingEnabled = true
        thinkingLevel = "turbo"
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let config = FaeConfig.load(from: fileURL)
        XCTAssertEqual(config.llm.resolvedThinkingLevel, .balanced)
        XCTAssertEqual(config.llm.thinkingLevel, FaeThinkingLevel.balanced.rawValue)
        XCTAssertTrue(config.llm.thinkingEnabled)
    }
}
