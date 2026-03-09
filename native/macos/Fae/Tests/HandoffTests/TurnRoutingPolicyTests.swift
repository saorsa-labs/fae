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

    func testQuickVoiceGreetingPrefersToolFreeFastPath() {
        XCTAssertTrue(
            TurnRoutingPolicy.shouldPreferToolFreeFastPath(
                userText: "Fae, say hello",
                allowsAudibleOutput: true,
                toolsAvailable: true
            )
        )
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

    func testKeepsToolLookupVoiceTurnOnOperator() {
        let route = TurnRoutingPolicy.decide(
            userText: "Fae, check my calendar for tomorrow",
            dualModelEnabled: true,
            conciergeLoaded: true,
            allowConciergeDuringVoiceTurns: false,
            isToolFollowUp: false,
            proactive: false,
            allowsAudibleOutput: true,
            toolsAvailable: true
        )

        XCTAssertEqual(route, .operatorModel)
    }

    func testToolLookupDoesNotUseToolFreeFastPath() {
        XCTAssertFalse(
            TurnRoutingPolicy.shouldPreferToolFreeFastPath(
                userText: "Fae, check my calendar for tomorrow",
                allowsAudibleOutput: true,
                toolsAvailable: true
            )
        )
    }

    func testExplicitToolRequestDoesNotUseToolFreeFastPath() {
        XCTAssertFalse(
            TurnRoutingPolicy.shouldPreferToolFreeFastPath(
                userText: "Fae, write hello fae test to /tmp/fae-test-write.txt using the write tool.",
                allowsAudibleOutput: true,
                toolsAvailable: true
            )
        )
    }

    func testTurnRoutingPolicyOperatorWhenDualDisabled() {
        let route = TurnRoutingPolicy.decide(
            userText: "Please summarize this document for me",
            dualModelEnabled: false,
            conciergeLoaded: true,
            allowConciergeDuringVoiceTurns: true,
            isToolFollowUp: false,
            proactive: false,
            allowsAudibleOutput: false,
            toolsAvailable: false
        )
        XCTAssertEqual(route, .operatorModel)
    }

    func testTurnRoutingPolicyOperatorWhenConciergeNotLoaded() {
        let route = TurnRoutingPolicy.decide(
            userText: "Please summarize this document for me",
            dualModelEnabled: true,
            conciergeLoaded: false,
            allowConciergeDuringVoiceTurns: true,
            isToolFollowUp: false,
            proactive: false,
            allowsAudibleOutput: false,
            toolsAvailable: false
        )
        XCTAssertEqual(route, .operatorModel)
    }

    func testTurnRoutingPolicyConciergeForRichHint_summarize() {
        let route = TurnRoutingPolicy.decide(
            userText: "Can you summarize the main points of this article?",
            dualModelEnabled: true,
            conciergeLoaded: true,
            allowConciergeDuringVoiceTurns: true,
            isToolFollowUp: false,
            proactive: false,
            allowsAudibleOutput: false,
            toolsAvailable: false
        )
        XCTAssertEqual(route, .conciergeModel)
    }

    func testTurnRoutingPolicyConciergeForLongPrompt() {
        // Prompt with 220+ characters routes to concierge
        let longPrompt = String(repeating: "This is a longer sentence to fill up the character count. ", count: 5)
        XCTAssertGreaterThanOrEqual(longPrompt.count, 220)
        let route = TurnRoutingPolicy.decide(
            userText: longPrompt,
            dualModelEnabled: true,
            conciergeLoaded: true,
            allowConciergeDuringVoiceTurns: true,
            isToolFollowUp: false,
            proactive: false,
            allowsAudibleOutput: false,
            toolsAvailable: false
        )
        XCTAssertEqual(route, .conciergeModel)
    }

    func testTurnRoutingPolicyOperatorForToolBiasedHintOverridesRichHint() {
        // "search" keyword is tool-biased → always operator, even with "summarize" present
        let route = TurnRoutingPolicy.decide(
            userText: "Please summarize and search for recent news about this topic",
            dualModelEnabled: true,
            conciergeLoaded: true,
            allowConciergeDuringVoiceTurns: true,
            isToolFollowUp: false,
            proactive: false,
            allowsAudibleOutput: false,
            toolsAvailable: true
        )
        XCTAssertEqual(route, .operatorModel)
    }

    func testTurnRoutingPolicyAlwaysOperatorForToolFollowUp() {
        let route = TurnRoutingPolicy.decide(
            userText: "Please summarize the result above",
            dualModelEnabled: true,
            conciergeLoaded: true,
            allowConciergeDuringVoiceTurns: true,
            isToolFollowUp: true,
            proactive: false,
            allowsAudibleOutput: false,
            toolsAvailable: false
        )
        XCTAssertEqual(route, .operatorModel)
    }

    func testTurnRoutingPolicyAlwaysOperatorForProactiveTurn() {
        let route = TurnRoutingPolicy.decide(
            userText: "Here is your morning briefing with a comprehensive analysis",
            dualModelEnabled: true,
            conciergeLoaded: true,
            allowConciergeDuringVoiceTurns: true,
            isToolFollowUp: false,
            proactive: true,
            allowsAudibleOutput: false,
            toolsAvailable: false
        )
        XCTAssertEqual(route, .operatorModel)
    }

    func testTurnRoutingPolicyOperatorForVoiceTurnWhenConciergeDisabledDuringVoice() {
        let route = TurnRoutingPolicy.decide(
            userText: "Can you summarize everything we've discussed?",
            dualModelEnabled: true,
            conciergeLoaded: true,
            allowConciergeDuringVoiceTurns: false,
            isToolFollowUp: false,
            proactive: false,
            allowsAudibleOutput: true,
            toolsAvailable: false
        )
        XCTAssertEqual(route, .operatorModel)
    }
}
