import CoreGraphics
import XCTest
@testable import Fae

final class VisionToolsPolicyTests: XCTestCase {
    func testSelectCaptureWindowPrefersPrimaryTitledWindowForSameApp() {
        let orb = DesktopWindowSelection.CaptureWindowCandidate(
            windowID: 101,
            processID: 10,
            appName: "Fae",
            title: nil,
            frame: CGRect(x: 0, y: 0, width: 220, height: 220)
        )
        let cowork = DesktopWindowSelection.CaptureWindowCandidate(
            windowID: 102,
            processID: 10,
            appName: "Fae",
            title: "Work with Fae",
            frame: CGRect(x: 10, y: 10, width: 1440, height: 900)
        )
        let ordered = [
            DesktopWindowSelection.VisibleWindow(
                windowID: 101,
                processID: 10,
                ownerName: "Fae",
                title: nil,
                layer: 5,
                bounds: orb.frame
            ),
            DesktopWindowSelection.VisibleWindow(
                windowID: 102,
                processID: 10,
                ownerName: "Fae",
                title: "Work with Fae",
                layer: 0,
                bounds: cowork.frame
            ),
        ]

        let selected = DesktopWindowSelection.selectCaptureWindow(
            candidates: [orb, cowork],
            preferredAppName: "Fae",
            frontmostPID: nil,
            orderedWindows: ordered
        )

        XCTAssertEqual(selected?.windowID, 102)
    }

    func testSelectCaptureWindowUsesFrontmostPIDWhenNoAppSpecified() {
        let safari = DesktopWindowSelection.CaptureWindowCandidate(
            windowID: 201,
            processID: 20,
            appName: "Safari",
            title: "Vision Test",
            frame: CGRect(x: 0, y: 0, width: 1280, height: 800)
        )
        let chrome = DesktopWindowSelection.CaptureWindowCandidate(
            windowID: 202,
            processID: 21,
            appName: "Google Chrome",
            title: "Elsewhere",
            frame: CGRect(x: 0, y: 0, width: 1280, height: 800)
        )
        let ordered = [
            DesktopWindowSelection.VisibleWindow(
                windowID: 202,
                processID: 21,
                ownerName: "Google Chrome",
                title: "Elsewhere",
                layer: 0,
                bounds: chrome.frame
            ),
            DesktopWindowSelection.VisibleWindow(
                windowID: 201,
                processID: 20,
                ownerName: "Safari",
                title: "Vision Test",
                layer: 0,
                bounds: safari.frame
            ),
        ]

        let selected = DesktopWindowSelection.selectCaptureWindow(
            candidates: [safari, chrome],
            preferredAppName: nil,
            frontmostPID: 20,
            orderedWindows: ordered
        )

        XCTAssertEqual(selected?.windowID, 201)
    }

    func testResolveFallbackTypingTargetSkipsFaeAndUsesVisibleDocumentWindow() {
        let ordered = [
            DesktopWindowSelection.VisibleWindow(
                windowID: 301,
                processID: 30,
                ownerName: "Fae",
                title: nil,
                layer: 5,
                bounds: CGRect(x: 0, y: 0, width: 220, height: 220)
            ),
            DesktopWindowSelection.VisibleWindow(
                windowID: 302,
                processID: 31,
                ownerName: "TextEdit",
                title: "fae-type-target.txt",
                layer: 0,
                bounds: CGRect(x: 40, y: 40, width: 900, height: 700)
            ),
        ]

        let target = DesktopWindowSelection.resolveFallbackTypingTargetName(
            explicitAppName: nil,
            frontmostAppName: "Fae",
            orderedWindows: ordered,
            excludedAppNames: ["fae"]
        )

        XCTAssertEqual(target, "TextEdit")
    }
}
