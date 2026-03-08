import XCTest
@testable import Fae

final class TurnRoutingPolicyTests: XCTestCase {
    func testKeepsToolBiasedRequestsOnOperator() {
        let route = TurnRoutingPolicy.decide(
            userText: "Can you search the web for the latest robotics news?",
            dualModelEnabled: true,
            conciergeLoaded: true,
            allowConciergeDuringVoiceTurns: true,
            isToolFollowUp: false,
            proactive: false,
            allowsAudibleOutput: true,
            toolsAvailable: true
        )

        XCTAssertEqual(route, .operatorModel)
    }

    func testRoutesRichLongFormRequestsToConciergeWhenAvailable() {
        let route = TurnRoutingPolicy.decide(
            userText: "Please summarize these notes into a polished strategy memo and compare the tradeoffs in detail.",
            dualModelEnabled: true,
            conciergeLoaded: true,
            allowConciergeDuringVoiceTurns: true,
            isToolFollowUp: false,
            proactive: false,
            allowsAudibleOutput: true,
            toolsAvailable: false
        )

        XCTAssertEqual(route, .conciergeModel)
    }

    func testFallsBackToOperatorWhenConciergeUnavailable() {
        let route = TurnRoutingPolicy.decide(
            userText: "Summarize this meeting in detail.",
            dualModelEnabled: true,
            conciergeLoaded: false,
            allowConciergeDuringVoiceTurns: true,
            isToolFollowUp: false,
            proactive: false,
            allowsAudibleOutput: true,
            toolsAvailable: false
        )

        XCTAssertEqual(route, .operatorModel)
    }
}
