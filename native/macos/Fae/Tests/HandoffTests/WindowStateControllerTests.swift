import AppKit
import XCTest
@testable import Fae

@MainActor
final class WindowStateControllerTests: XCTestCase {
    func testCoworkVisibilityCollapsesAndDocksMainWindow() async throws {
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

        XCTAssertEqual(controller.mode, .collapsed)
    }

    func testAssistantActivityDoesNotReexpandMainWindowWhileCoworkIsVisible() async throws {
        let controller = WindowStateController()
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 740),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        controller.window = window

        NotificationCenter.default.post(
            name: .faeCoworkWindowVisibilityChanged,
            object: nil,
            userInfo: ["visible": true]
        )

        try await Task.sleep(nanoseconds: 150_000_000)

        NotificationCenter.default.post(
            name: .faeAssistantGenerating,
            object: nil,
            userInfo: ["active": true]
        )

        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(controller.mode, .collapsed)
    }

    func testAppActivationKeepsMainWindowDockedWhileCoworkIsVisible() async throws {
        let controller = WindowStateController()
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 740),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        controller.window = window

        NotificationCenter.default.post(
            name: .faeCoworkWindowVisibilityChanged,
            object: nil,
            userInfo: ["visible": true]
        )

        try await Task.sleep(nanoseconds: 150_000_000)
        controller.transitionToCompact()

        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(controller.mode, .collapsed)
    }
}
