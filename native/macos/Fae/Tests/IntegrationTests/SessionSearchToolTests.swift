import XCTest
@testable import Fae

final class SessionSearchToolTests: XCTestCase {

    // MARK: - formatDate

    func testFormatDate() {
        let date = Date(timeIntervalSince1970: 1609459200) // 2021-01-01 00:00 UTC
        let formatted = SessionSearchTool.formatDate(date)
        XCTAssertFalse(formatted.isEmpty)
        XCTAssertTrue(formatted.contains("-"))
    }
}
