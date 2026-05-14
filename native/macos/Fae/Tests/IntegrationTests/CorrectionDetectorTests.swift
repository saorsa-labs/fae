import XCTest
@testable import Fae

final class CorrectionDetectorTests: XCTestCase {

    // MARK: - capitalizeFirst

    func testCapitalizeFirst() {
        XCTAssertEqual(CorrectionDetector.capitalizeFirst("hello"), "Hello")
    }

    func testCapitalizeFirstAlreadyCapitalized() {
        XCTAssertEqual(CorrectionDetector.capitalizeFirst("Hello"), "Hello")
    }

    func testCapitalizeFirstEmpty() {
        XCTAssertEqual(CorrectionDetector.capitalizeFirst(""), "")
    }

    // MARK: - isPlausibleName

    func testIsPlausibleNameValid() {
        XCTAssertTrue(CorrectionDetector.isPlausibleName("Alice"))
        XCTAssertTrue(CorrectionDetector.isPlausibleName("Bob Smith"))
    }

    func testIsPlausibleNameInvalid() {
        XCTAssertFalse(CorrectionDetector.isPlausibleName(""))
        XCTAssertFalse(CorrectionDetector.isPlausibleName("12345"))
    }

    // MARK: - nameIsNotPattern

    func testNameIsNotPattern() {
        let result = CorrectionDetector.nameIsNotPattern("my name is not alice")
        XCTAssertNotNil(result)
    }

    func testNameIsNotPatternNoMatch() {
        let result = CorrectionDetector.nameIsNotPattern("hello world")
        XCTAssertNil(result)
    }

    // MARK: - itsNotPattern

    func testItsNotPattern() {
        let result = CorrectionDetector.itsNotPattern("it's bob not bill")
        XCTAssertNotNil(result)
    }

    func testItsNotPatternNoMatch() {
        let result = CorrectionDetector.itsNotPattern("hello world")
        XCTAssertNil(result)
    }

    // MARK: - iSaidPattern

    func testISaidPattern() {
        let result = CorrectionDetector.iSaidPattern("i said alice not alix")
        XCTAssertNotNil(result)
    }

    func testISaidPatternNoMatch() {
        let result = CorrectionDetector.iSaidPattern("hello world")
        XCTAssertNil(result)
    }
}
