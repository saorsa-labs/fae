import XCTest
@testable import Fae

final class PersonQueryDetectorTests: XCTestCase {

    // MARK: - extractNameAndLabel

    func testExtractNameAndLabelMyFriend() {
        let (name, label) = PersonQueryDetector.extractNameAndLabel(from: "my friend Alice")
        XCTAssertEqual(name, "Alice")
        XCTAssertEqual(label, "friend")
    }

    func testExtractNameAndLabelColleague() {
        let (name, label) = PersonQueryDetector.extractNameAndLabel(from: "colleague Bob Smith")
        XCTAssertNotNil(name)
        XCTAssertEqual(label, "colleague")
    }

    func testExtractNameAndLabelNoMatch() {
        let (name, label) = PersonQueryDetector.extractNameAndLabel(from: "random text here")
        XCTAssertNil(label)
    }
}
