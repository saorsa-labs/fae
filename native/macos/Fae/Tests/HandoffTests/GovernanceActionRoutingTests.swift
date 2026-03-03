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
                "key": "barge_in.enabled",
                "value": false,
                "source": "canvas",
            ]
        )

        try await Task.sleep(nanoseconds: 150_000_000)

        let command = sender.sent.last
        XCTAssertEqual(command?.name, "config.patch")
        XCTAssertEqual(command?.payload["key"] as? String, "barge_in.enabled")
        XCTAssertEqual(command?.payload["value"] as? Bool, false)
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
}
