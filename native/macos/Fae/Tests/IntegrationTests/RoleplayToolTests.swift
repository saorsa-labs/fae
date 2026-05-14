import XCTest
@testable import Fae

final class RoleplayToolTests: XCTestCase {

    // MARK: - formatDate

    func testFormatDate() {
        let formatted = RoleplaySessionStore.formatDate(Date())
        XCTAssertTrue(formatted.hasPrefix("("))
        XCTAssertTrue(formatted.hasSuffix(")"))
    }
}
