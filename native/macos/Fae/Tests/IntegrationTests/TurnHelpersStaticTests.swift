import XCTest
@testable import Fae

final class TurnHelpersStaticTests: XCTestCase {

    // MARK: - isEphemeralArithmeticQuery

    func testIsEphemeralArithmeticQuery() {
        XCTAssertTrue(TurnHelpers.isEphemeralArithmeticQuery("what is 2 plus 2"))
    }

    func testIsNotEphemeralArithmeticQuery() {
        XCTAssertFalse(TurnHelpers.isEphemeralArithmeticQuery("hello world"))
    }

    // MARK: - normalizeEasyTurnInput

    func testNormalizeEasyTurnInput() {
        let normalized = TurnHelpers.normalizeEasyTurnInput("  Hello World!  ")
        XCTAssertFalse(normalized.hasPrefix(" "))
    }

    // MARK: - deterministicArithmeticReply

    func testDeterministicArithmeticReply() {
        let reply = TurnHelpers.deterministicArithmeticReply(for: "2 + 2")
        XCTAssertNotNil(reply)
    }

    func testDeterministicArithmeticReplyNone() {
        let reply = TurnHelpers.deterministicArithmeticReply(for: "hello world")
        XCTAssertNil(reply)
    }

    // MARK: - parseArithmeticExpression

    func testParseArithmeticExpression() {
        let result = TurnHelpers.parseArithmeticExpression("2 + 3")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.lhs, 2.0)
        XCTAssertEqual(result?.rhs, 3.0)
    }

    func testParseArithmeticExpressionNone() {
        let result = TurnHelpers.parseArithmeticExpression("hello world")
        XCTAssertNil(result)
    }

    // MARK: - isLikelyStandaloneHumanName

    func testIsLikelyStandaloneHumanName() {
        XCTAssertTrue(TurnHelpers.isLikelyStandaloneHumanName("Alice"))
    }

    func testIsNotLikelyStandaloneHumanName() {
        XCTAssertFalse(TurnHelpers.isLikelyStandaloneHumanName("12345"))
    }
}
