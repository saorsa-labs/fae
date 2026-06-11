import XCTest
@testable import Fae

final class EchoSuppressorStaticTests: XCTestCase {

    // MARK: - extractNumbersFromText

    func testExtractNumbersSimple() {
        let numbers = EchoSuppressor.extractNumbersFromText("The value is 42 and the count is 100")
        XCTAssertFalse(numbers.isEmpty)
    }

    func testExtractNumbersNone() {
        let numbers = EchoSuppressor.extractNumbersFromText("No numbers here")
        XCTAssertTrue(numbers.isEmpty)
    }

    // MARK: - numbersFuzzyMatch

    func testNumbersFuzzyMatchExact() {
        XCTAssertTrue(EchoSuppressor.numbersFuzzyMatch("42", "42"))
    }

    func testNumbersFuzzyMatchDifferent() {
        XCTAssertFalse(EchoSuppressor.numbersFuzzyMatch("1", "999"))
    }

    // MARK: - normalizeForOverlap

    func testNormalizeForOverlap() {
        let normalized = EchoSuppressor.normalizeForOverlap("Hello World!")
        XCTAssertFalse(normalized.isEmpty)
    }

    // MARK: - extractDigitsFromNumberWords

    func testExtractDigitsFromNumberWords() {
        let digits = EchoSuppressor.extractDigitsFromNumberWords(["one", "two", "three"])
        XCTAssertFalse(digits.isEmpty)
    }

    func testExtractDigitsFromNumberWordsEmpty() {
        // No number words → empty string, not a spurious "0".
        let digits = EchoSuppressor.extractDigitsFromNumberWords([])
        XCTAssertEqual(digits, "")
    }
}
