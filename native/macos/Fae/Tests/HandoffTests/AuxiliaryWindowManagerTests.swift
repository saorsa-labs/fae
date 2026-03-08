import XCTest
@testable import Fae

@MainActor
final class AuxiliaryWindowManagerTests: XCTestCase {
    func testToggleCanvasDoesNotShowEmptyCanvas() {
        let manager = AuxiliaryWindowManager()
        let canvas = CanvasController()
        manager.canvasController = canvas

        manager.toggleCanvas()

        XCTAssertFalse(manager.isCanvasVisible)
    }

    func testToggleCanvasShowsWhenContentExists() {
        let manager = AuxiliaryWindowManager()
        let canvas = CanvasController()
        canvas.setContent("<p>Hello</p>")
        manager.canvasController = canvas

        manager.toggleCanvas()

        XCTAssertTrue(manager.isCanvasVisible)
        manager.hideCanvas()
    }
}
