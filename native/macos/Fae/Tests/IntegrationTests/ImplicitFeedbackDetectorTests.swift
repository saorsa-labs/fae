import XCTest
@testable import Fae

final class ImplicitFeedbackDetectorTests: XCTestCase {

    // MARK: - wordBigrams

    func testWordBigrams() {
        let bigrams = ImplicitFeedbackDetector.wordBigrams("hello world foo")
        XCTAssertFalse(bigrams.isEmpty)
    }

    func testWordBigramsSingleWord() {
        let bigrams = ImplicitFeedbackDetector.wordBigrams("hello")
        XCTAssertTrue(bigrams.isEmpty)
    }

    func testWordBigramsEmpty() {
        let bigrams = ImplicitFeedbackDetector.wordBigrams("")
        XCTAssertTrue(bigrams.isEmpty)
    }
}
