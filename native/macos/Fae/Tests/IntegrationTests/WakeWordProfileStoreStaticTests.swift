import XCTest
@testable import Fae

final class WakeWordProfileStoreStaticTests: XCTestCase {

    // MARK: - sanitize

    func testSanitize() {
        let result = WakeWordProfileStore.sanitize("  Fae!  ")
        XCTAssertEqual(result, "fae")
    }

    func testSanitizeEmpty() {
        XCTAssertNil(WakeWordProfileStore.sanitize("   "))
    }

    func testSanitizeNumbersOnly() {
        XCTAssertNil(WakeWordProfileStore.sanitize("123"))
    }

    // MARK: - isLikelyFaeAlias

    func testIsLikelyFaeAliasExact() {
        XCTAssertTrue(WakeWordProfileStore.isLikelyFaeAlias("fae"))
    }

    func testIsLikelyFaeAliasClose() {
        XCTAssertTrue(WakeWordProfileStore.isLikelyFaeAlias("faye"))
    }

    func testIsLikelyFaeAliasFar() {
        XCTAssertFalse(WakeWordProfileStore.isLikelyFaeAlias("zebra"))
    }

    func testIsLikelyFaeAliasTooShort() {
        XCTAssertFalse(WakeWordProfileStore.isLikelyFaeAlias("f"))
    }

    // MARK: - editDistance

    func testEditDistanceSame() {
        XCTAssertEqual(WakeWordProfileStore.editDistance("hello", "hello"), 0)
    }

    func testEditDistanceOneChange() {
        XCTAssertEqual(WakeWordProfileStore.editDistance("cat", "bat"), 1)
    }

    func testEditDistanceEmpty() {
        XCTAssertEqual(WakeWordProfileStore.editDistance("", "abc"), 3)
    }
}
