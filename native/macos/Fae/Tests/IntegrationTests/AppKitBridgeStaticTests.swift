import AppKit
import XCTest
@testable import Fae

@MainActor
final class AppKitBridgeStaticTests: XCTestCase {
    func testVisualEffectBlurInitializerStoresConfiguration() {
        let blur = VisualEffectBlur(
            material: .sidebar,
            blendingMode: .withinWindow,
            state: .inactive
        )

        XCTAssertEqual(blur.material, .sidebar)
        XCTAssertEqual(blur.blendingMode, .withinWindow)
        XCTAssertEqual(blur.state, .inactive)
    }

    func testWindowObserverStoresCallbackAndIgnoresMissingWindow() {
        let observer = NSWindowAccessor.WindowObserverView(frame: .zero)
        var callbackCalled = false
        observer.onWindow = { _ in callbackCalled = true }

        observer.viewDidMoveToWindow()

        XCTAssertNotNil(observer.onWindow)
        XCTAssertFalse(callbackCalled)
    }
}
