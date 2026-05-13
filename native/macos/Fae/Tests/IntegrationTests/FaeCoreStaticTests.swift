import XCTest
@testable import Fae

@MainActor
final class FaeCoreStaticTests: XCTestCase {

    // MARK: - extractPrimaryName

    func testExtractPrimaryName() {
        let name = FaeCore.extractPrimaryName(from: "Primary user name is Alice")
        XCTAssertEqual(name, "Alice")
    }

    func testExtractPrimaryNameWithPeriod() {
        let name = FaeCore.extractPrimaryName(from: "Primary user name is Bob.")
        XCTAssertEqual(name, "Bob")
    }

    func testExtractPrimaryNameNoMatch() {
        let name = FaeCore.extractPrimaryName(from: "Some other text")
        XCTAssertNil(name)
    }

    func testExtractPrimaryNameEmpty() {
        let name = FaeCore.extractPrimaryName(from: "Primary user name is ")
        XCTAssertNil(name)
    }

    func testExtractPrimaryNameWithSpaces() {
        let name = FaeCore.extractPrimaryName(from: "Primary user name is  Alice Smith  .")
        XCTAssertEqual(name, "Alice Smith")
    }
}
