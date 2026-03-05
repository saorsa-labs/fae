import XCTest
@testable import Fae

final class HeartbeatContractTests: XCTestCase {

    func testAckOnlyParsesAsNoOp() {
        let parsed = HeartbeatDecisionParser.parse(text: "HEARTBEAT_OK")
        XCTAssertEqual(parsed?.status, .ok)
    }

    func testTaggedDecisionParses() {
        let json = #"{"schemaVersion":1,"status":"teach","message":"Try the tools snapshot","nudgeTopic":"tools"}"#
        let text = "<heartbeat_result>\(json)</heartbeat_result>"

        let parsed = HeartbeatDecisionParser.parse(text: text)
        XCTAssertEqual(parsed?.status, .teach)
        XCTAssertEqual(parsed?.nudgeTopic, "tools")
    }

    func testAckWithShortSuffixStillNoOp() {
        let parsed = HeartbeatDecisionParser.parse(text: "HEARTBEAT_OK all quiet")
        XCTAssertEqual(parsed?.status, .ok)
    }

    func testRawJsonDecisionParsesCanvasIntent() {
        let text = #"{"schemaVersion":1,"status":"nudge","canvasIntent":{"kind":"capability_card","payload":{"title":"Try canvas","summary":"Use voice to open canvas"}}}"#
        let parsed = HeartbeatDecisionParser.parse(text: text)
        XCTAssertEqual(parsed?.status, .nudge)
        XCTAssertEqual(parsed?.canvasIntent?.kind, "capability_card")
    }

    func testAckWithLongSuffixIsNotNoOp() {
        let parsed = HeartbeatDecisionParser.parse(
            text: "HEARTBEAT_OK this trailing payload is too long",
            ackToken: "HEARTBEAT_OK",
            ackMaxChars: 5
        )
        XCTAssertNil(parsed)
    }

    func testHeartbeatResultParsesSuggestedStage() {
        let json = #"{"schemaVersion":1,"status":"teach","message":"Try workflow templates","suggestedStage":"habitForming"}"#
        let parsed = HeartbeatDecisionParser.parse(text: "<heartbeat_result>\(json)</heartbeat_result>")
        XCTAssertEqual(parsed?.status, .teach)
        XCTAssertEqual(parsed?.suggestedStage, .habitForming)
    }
}
