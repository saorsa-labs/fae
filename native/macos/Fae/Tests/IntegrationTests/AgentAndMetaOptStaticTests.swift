import XCTest
@testable import Fae

/// Coverage for two more previously-0% files: ACPSessionManager (static
/// agent-noise detector) and MetaOptimizer (score encoder). Both pure.
final class AgentAndMetaOptStaticTests: XCTestCase {

    // MARK: - ACPSessionManager.isAgentTransportNoise

    func testIsAgentTransportNoiseDetectsWebSocketFallback() {
        XCTAssertTrue(
            ACPSessionManager.isAgentTransportNoise(
                "Warning: Falling back from WebSockets to HTTPS transport"))
    }

    func testIsAgentTransportNoiseDetectsStreamDisconnect() {
        XCTAssertTrue(
            ACPSessionManager.isAgentTransportNoise(
                "Error: stream disconnected before completion"))
    }

    func testIsAgentTransportNoiseDetectsRootCA() {
        XCTAssertTrue(
            ACPSessionManager.isAgentTransportNoise(
                "no native root CA certificates found in keychain"))
    }

    func testIsAgentTransportNoiseRejectsNormalText() {
        XCTAssertFalse(ACPSessionManager.isAgentTransportNoise("Here is your answer."))
        XCTAssertFalse(ACPSessionManager.isAgentTransportNoise(""))
    }

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
        // Encodes to a JSON object with null values, not "{}".
        XCTAssertFalse(json.isEmpty)
        XCTAssertTrue(json.contains("null") || json.contains("toolCalling"))
    }
}
