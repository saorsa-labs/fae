import XCTest
@testable import Fae

final class PipelineCoordinatorStaticTests: XCTestCase {

    // MARK: - normalizeForPhraseMatch

    func testNormalizeForPhraseMatch() {
        let normalized = PipelineCoordinator.normalizeForPhraseMatch("  Hello World!  ")
        XCTAssertFalse(normalized.hasPrefix(" "))
        XCTAssertFalse(normalized.hasSuffix(" "))
    }

    func testNormalizeForPhraseMatchEmpty() {
        let normalized = PipelineCoordinator.normalizeForPhraseMatch("")
        XCTAssertTrue(normalized.isEmpty)
    }

    // MARK: - detectExplicitUserAuthorization

    func testDetectExplicitAuthorizationYes() {
        XCTAssertTrue(PipelineCoordinator.detectExplicitUserAuthorization(in: "yes please do it"))
    }

    func testDetectExplicitAuthorizationNo() {
        XCTAssertFalse(PipelineCoordinator.detectExplicitUserAuthorization(in: "just a normal sentence"))
    }
}
