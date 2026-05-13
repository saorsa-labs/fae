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
}
