import XCTest
@testable import Fae

final class CoworkModelRegistryTests: XCTestCase {

    // MARK: - buildCatalog

    func testBuildCatalogNotEmpty() {
        let catalog = CoworkKnownModelRegistry.buildCatalog()
        XCTAssertFalse(catalog.isEmpty)
    }

    func testBuildCatalogHasKnownModels() {
        let catalog = CoworkKnownModelRegistry.buildCatalog()
        XCTAssertTrue(catalog.keys.contains { $0.contains("claude") })
    }
}
