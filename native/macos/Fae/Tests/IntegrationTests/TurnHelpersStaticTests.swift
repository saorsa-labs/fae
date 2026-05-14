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

    // MARK: - parseArithmeticOperand

    func testParseArithmeticOperand() {
        let result = TurnHelpers.parseArithmeticOperand("42")
        XCTAssertEqual(result, 42.0)
    }

    func testParseArithmeticOperandNone() {
        let result = TurnHelpers.parseArithmeticOperand("hello")
        XCTAssertNil(result)
    }

    // MARK: - standaloneUserNameDeclaration

    func testStandaloneUserNameDeclaration() {
        let name = TurnHelpers.standaloneUserNameDeclaration(in: "my name is Alice")
        XCTAssertNotNil(name)
    }

    func testStandaloneUserNameDeclarationNone() {
        let name = TurnHelpers.standaloneUserNameDeclaration(in: "hello world")
        XCTAssertNil(name)
    }

    // MARK: - isSimpleUserNameRecallQuery

    func testIsSimpleUserNameRecallQuery() {
        XCTAssertTrue(TurnHelpers.isSimpleUserNameRecallQuery("what is my name"))
    }

    func testIsNotSimpleUserNameRecallQuery() {
        XCTAssertFalse(TurnHelpers.isSimpleUserNameRecallQuery("hello world"))
    }

    // MARK: - explicitInterestTopic

    func testExplicitInterestTopicInterestedIn() {
        let topic = TurnHelpers.explicitInterestTopic(in: "I'm interested in quantum physics", lower: "i'm interested in quantum physics")
        XCTAssertEqual(topic, "quantum physics")
    }

    func testExplicitInterestTopicLoveLearning() {
        let topic = TurnHelpers.explicitInterestTopic(in: "I love learning about cooking", lower: "i love learning about cooking")
        XCTAssertEqual(topic, "cooking")
    }

    func testExplicitInterestTopicFindFascinating() {
        let topic = TurnHelpers.explicitInterestTopic(in: "I find machine learning fascinating", lower: "i find machine learning fascinating")
        XCTAssertEqual(topic, "machine learning")
    }

    func testExplicitInterestTopicNoMatch() {
        let topic = TurnHelpers.explicitInterestTopic(in: "hello world", lower: "hello world")
        XCTAssertNil(topic)
    }

    // MARK: - cleanInterestTopic

    func testCleanInterestTopic() {
        let cleaned = TurnHelpers.cleanInterestTopic("  quantum physics. ")
        XCTAssertEqual(cleaned, "quantum physics")
    }

    func testCleanInterestTopicEmpty() {
        let cleaned = TurnHelpers.cleanInterestTopic("   ")
        XCTAssertNil(cleaned)
    }
}
