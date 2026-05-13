import XCTest
@testable import Fae

final class EntityContextFormatterTests: XCTestCase {

    // MARK: - formatRelationType

    func testFormatRelationTypeWorksAt() {
        XCTAssertEqual(EntityContextFormatter.formatRelationType("works_at"), "Works at")
    }

    func testFormatRelationTypeLivesIn() {
        XCTAssertEqual(EntityContextFormatter.formatRelationType("lives_in"), "Lives in")
    }

    func testFormatRelationTypeKnows() {
        XCTAssertEqual(EntityContextFormatter.formatRelationType("knows"), "Knows")
    }

    func testFormatRelationTypeReportsTo() {
        XCTAssertEqual(EntityContextFormatter.formatRelationType("reports_to"), "Reports to")
    }

    func testFormatRelationTypeUnknown() {
        let result = EntityContextFormatter.formatRelationType("custom_type")
        XCTAssertEqual(result, "Custom type")
    }

    // MARK: - formatMultiple

    func testFormatMultipleEmpty() {
        let result = EntityContextFormatter.formatMultiple(profiles: [])
        XCTAssertTrue(result.isEmpty)
    }
}
