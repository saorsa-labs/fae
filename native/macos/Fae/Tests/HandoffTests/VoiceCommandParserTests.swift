import XCTest
@testable import Fae

final class VoiceCommandParserTests: XCTestCase {
    func testParsesGovernanceCommands() {
        XCTAssertEqual(
            VoiceCommandParser.parse("Fae, switch to full access"),
            .setToolMode("full")
        )
        XCTAssertEqual(VoiceCommandParser.parse("enable thinking mode"), .setThinking(true))
        XCTAssertEqual(VoiceCommandParser.parse("turn off barge in"), .setBargeIn(false))
        XCTAssertEqual(VoiceCommandParser.parse("require direct address"), .setDirectAddress(true))
        XCTAssertEqual(VoiceCommandParser.parse("unlock your voice"), .setVoiceIdentityLock(false))
        // Settings/window control is now skill-driven (window-control skill + tool).
        XCTAssertEqual(VoiceCommandParser.parse("close settings"), .none)
        XCTAssertEqual(VoiceCommandParser.parse("of our settings"), .none)
    }

    func testParsesPermissionRequests() {
        XCTAssertEqual(VoiceCommandParser.parse("request camera permission"), .requestPermission("camera"))
        XCTAssertEqual(
            VoiceCommandParser.parse("please enable screen recording access"),
            .requestPermission("screen_recording")
        )
    }

    // MARK: - Progressive Approval Response Tests

    func testApprovalResponseYes() {
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("yes"), .yes)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("yeah"), .yes)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("yep"), .yes)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("sure"), .yes)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("okay"), .yes)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("go ahead"), .yes)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("do it"), .yes)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("approve"), .yes)
    }

    func testApprovalResponseNo() {
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("no"), .no)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("nah"), .no)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("nope"), .no)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("don't"), .no)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("stop"), .no)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("cancel"), .no)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("deny"), .no)
    }

    func testApprovalResponseAlways() {
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("always"), .always)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("always allow"), .always)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("always approve"), .always)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("trust this tool"), .always)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("always trust"), .always)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("yeah always"), .always)
    }

    func testFormerBulkApprovePhrasesFallThrough() {
        // Former bulk-approve phrases now fall through to simpler matches since bulk approval was removed.
        // "approve" is a yes-word; "trust" alone is not recognized.
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("approve all reads"), .yes)
        XCTAssertNil(VoiceCommandParser.parseApprovalResponse("trust all read tools"))
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("approve all"), .yes)
        XCTAssertNil(VoiceCommandParser.parseApprovalResponse("trust everything"))
    }

    func testApprovalResponseAmbiguous() {
        XCTAssertNil(VoiceCommandParser.parseApprovalResponse("hmm"))
        XCTAssertNil(VoiceCommandParser.parseApprovalResponse("what"))
        XCTAssertNil(VoiceCommandParser.parseApprovalResponse("maybe"))
        // Note: "I'm not sure" contains substring "no" → returns .no (known substring matching).
        // This is acceptable for the approval context where inputs are short voice phrases.
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("I'm not sure"), .no)
    }

    // MARK: - Regression: "always deny" must return .no, not .always

    func testAlwaysDenyReturnsNo() {
        // This was a real bug: "always deny" matched .always because
        // the bare "always" check ran before deny word matching.
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("always deny"), .no)
    }

    func testAlwaysWithDenyContextReturnsNo() {
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("not always"), .no)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("I don't always want that"), .no)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("always cancel"), .no)
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("nah not always"), .no)
    }

    // MARK: - Ordering: most-specific phrases win over bare keywords

    func testApproveAllNowReturnsYes() {
        // "approve all" falls through to "yes" since bulk-approve was removed.
        // "approve" is a yes-word.
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("approve all"), .yes)
    }

    func testAlwaysAllowWinsOverBareAlways() {
        // Both "always allow" and bare "always" would match — specific phrase wins
        XCTAssertEqual(VoiceCommandParser.parseApprovalResponse("always allow"), .always)
    }
}
