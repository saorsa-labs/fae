import XCTest
@testable import Fae

@MainActor
final class GovernanceActionRoutingTests: XCTestCase {
    private final class MockSender: HostCommandSender {
        var sent: [(name: String, payload: [String: Any])] = []

        func sendCommand(name: String, payload: [String: Any]) {
            sent.append((name, payload))
        }
    }

    func testSetSettingGovernanceActionRoutesToConfigPatch() async throws {
        let bridge = HostCommandBridge()
        let sender = MockSender()
        bridge.sender = sender

        NotificationCenter.default.post(
            name: .faeGovernanceActionRequested,
            object: nil,
            userInfo: [
                "action": "set_setting",
                "key": "conversation.require_direct_address",
                "value": true,
                "source": "canvas",
            ]
        )

        try await Task.sleep(nanoseconds: 150_000_000)

        let command = sender.sent.last
        XCTAssertEqual(command?.name, "config.patch")
        XCTAssertEqual(command?.payload["key"] as? String, "conversation.require_direct_address")
        XCTAssertEqual(command?.payload["value"] as? Bool, true)
    }

    func testRequestPermissionGovernanceActionPostsCapabilityNotification() async throws {
        let bridge = HostCommandBridge()
        _ = bridge

        let expectation = expectation(description: "capability notification posted")
        var capability: String?

        let observer = NotificationCenter.default.addObserver(
            forName: .faeCapabilityRequested,
            object: nil,
            queue: .main
        ) { note in
            capability = note.userInfo?["capability"] as? String
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        NotificationCenter.default.post(
            name: .faeGovernanceActionRequested,
            object: nil,
            userInfo: [
                "action": "request_permission",
                "capability": "camera",
                "source": "canvas",
            ]
        )

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(capability, "camera")
    }

    func testHighRiskCanvasSettingUsesPopupConfirmationBeforeDispatch() async throws {
        let bridge = HostCommandBridge()
        let sender = MockSender()
        bridge.sender = sender

        let popupExpectation = expectation(description: "governance popup requested")
        var requestID: String?
        let observer = NotificationCenter.default.addObserver(
            forName: .faeGovernanceConfirmationRequested,
            object: nil,
            queue: .main
        ) { note in
            requestID = note.userInfo?["request_id"] as? String
            popupExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        NotificationCenter.default.post(
            name: .faeGovernanceActionRequested,
            object: nil,
            userInfo: [
                "action": "set_setting",
                "key": "vision.enabled",
                "value": true,
                "source": "canvas",
            ]
        )

        await fulfillment(of: [popupExpectation], timeout: 2.0)
        XCTAssertTrue(sender.sent.isEmpty)

        NotificationCenter.default.post(
            name: .faeGovernanceConfirmationRespond,
            object: nil,
            userInfo: [
                "request_id": try XCTUnwrap(requestID),
                "approved": true,
            ]
        )

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(sender.sent.last?.name, "config.patch")
        XCTAssertEqual(sender.sent.last?.payload["key"] as? String, "vision.enabled")
    }

    func testToolModeSetViaCanvasDispatchesDirectly() async throws {
        let bridge = HostCommandBridge()
        let sender = MockSender()
        bridge.sender = sender

        NotificationCenter.default.post(
            name: .faeGovernanceActionRequested,
            object: nil,
            userInfo: [
                "action": "set_tool_mode",
                "value": "full",
                "source": "canvas",
            ]
        )

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(sender.sent.last?.name, "config.patch")
        XCTAssertEqual(sender.sent.last?.payload["key"] as? String, "tool_mode")
    }
}
