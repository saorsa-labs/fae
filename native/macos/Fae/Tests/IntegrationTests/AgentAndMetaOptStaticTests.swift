import XCTest
@testable import Fae

/// Coverage for MetaOptimizer (score encoder). Pure. (The ACPSessionManager
/// noise-detector tests were removed in gap A2 when that acpx-subprocess manager
/// was deleted in favour of the daemon's native ACP sessions.)
final class AgentAndMetaOptStaticTests: XCTestCase {

    // MARK: - MetaOptimizer.encodeScores

    func testEncodeScoresProducesSortedJSON() {
        let scores = DimensionScores(
            toolCalling: 0.8, faeCapability: 0.6, assistantFit: nil, serialization: 0.9
        )
        let json = MetaOptimizer.encodeScores(scores)
        XCTAssertTrue(json.contains("toolCalling"))
        XCTAssertTrue(json.contains("serialization"))
        // sortedKeys means keys are alphabetical.
        if let tcRange = json.range(of: "assistantFit"),
           let serRange = json.range(of: "serialization") {
            XCTAssertLessThan(tcRange.lowerBound, serRange.lowerBound)
        }
    }

    func testEncodeScoresAllNilStillValid() {
        let scores = DimensionScores(toolCalling: nil, faeCapability: nil, assistantFit: nil, serialization: nil)
        let json = MetaOptimizer.encodeScores(scores)
        // Swift's synthesized Codable omits nil optionals (encodeIfPresent),
        // so all-nil scores encode to an empty JSON object.
        XCTAssertEqual(json, "{}")
    }
}
