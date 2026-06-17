import XCTest
@testable import Fae

/// Coverage for DeviceHandoff.swift (was 0% covered). DeviceCommandParser.parse
/// is a pure command-string parser — no system deps.
final class DeviceHandoffParsingTests: XCTestCase {

    // MARK: - DeviceCommandParser.parse

    private func parse(_ text: String) -> DeviceCommand {
        DeviceCommandParser.parse(text)
    }

    func testParseEmptyIsUnsupported() {
        if case .unsupported = parse("") {} else { XCTFail("expected unsupported") }
        if case .unsupported = parse("   ") {} else { XCTFail("expected unsupported for whitespace") }
    }

    func testParseGoHome() {
        if case .goHome = parse("go home") {} else { XCTFail("expected goHome") }
        if case .goHome = parse("please move home now") {} else { XCTFail("expected goHome for 'move home'") }
        if case .goHome = parse("back to mac") {} else { XCTFail("expected goHome for 'back to mac'") }
    }

    func testParseMoveToWatch() {
        if case .move(.watch) = parse("move to my watch") {} else { XCTFail("expected move watch") }
        if case .move(.watch) = parse("send to watch") {} else { XCTFail("expected move watch for 'to watch'") }
    }

    func testParseMoveToIPhone() {
        if case .move(.iphone) = parse("move to my phone") {} else { XCTFail("expected move iphone") }
        if case .move(.iphone) = parse("move to iphone") {} else { XCTFail("expected move iphone") }
        if case .move(.iphone) = parse("push to phone") {} else { XCTFail("expected move iphone for 'to phone'") }
    }

    func testParseNormalisesPunctuationAndCase() {
        // Apostrophes stripped, periods/commas -> spaces, case-insensitive.
        if case .move(.iphone) = parse("Move to my iPhone.") {} else { XCTFail("expected move iphone with punctuation") }
        if case .move(.watch) = parse("MOVE, TO, WATCH") {} else { XCTFail("expected move watch with commas") }
    }

    func testParseUnsupportedForUnrelatedText() {
        if case .unsupported = parse("what is the weather") {} else { XCTFail("expected unsupported") }
    }

    // MARK: - DeviceTarget

    func testDeviceTargetRawValues() {
        XCTAssertEqual(DeviceTarget.mac.rawValue, "mac")
        XCTAssertEqual(DeviceTarget.iphone.rawValue, "iphone")
        XCTAssertEqual(DeviceTarget.watch.rawValue, "watch")
        XCTAssertEqual(DeviceTarget.allCases.count, 3)
    }
}
