import XCTest
@testable import Fae

final class VoiceCommandParserTests: XCTestCase {
    func testParsesGovernanceCommands() {
        XCTAssertEqual(
            VoiceCommandParser.parse("Fae, set tool mode to full no approval"),
            .setToolMode("full_no_approval")
        )
        XCTAssertEqual(VoiceCommandParser.parse("enable thinking mode"), .setThinking(true))
        XCTAssertEqual(VoiceCommandParser.parse("turn off barge in"), .setBargeIn(false))
        XCTAssertEqual(VoiceCommandParser.parse("require direct address"), .setDirectAddress(true))
        XCTAssertEqual(VoiceCommandParser.parse("unlock your voice"), .setVoiceIdentityLock(false))
    }

    func testParsesPermissionRequests() {
        XCTAssertEqual(VoiceCommandParser.parse("request camera permission"), .requestPermission("camera"))
        XCTAssertEqual(
            VoiceCommandParser.parse("please enable screen recording access"),
            .requestPermission("screen_recording")
        )
    }
}
