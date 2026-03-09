import AppKit
import XCTest
@testable import Fae

@MainActor
final class WindowStateControllerTests: XCTestCase {
    func testCoworkVisibilityExpandsAndPinsMainWindowInCompactMode() async throws {
        let controller = WindowStateController()
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 740),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        controller.window = window
        controller.transitionToCollapsed()

        NotificationCenter.default.post(
            name: .faeCoworkWindowVisibilityChanged,
            object: nil,
            userInfo: ["visible": true]
        )

        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(controller.mode, .compact)
    }
}
