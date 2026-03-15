import XCTest
@testable import Fae

@MainActor
final class ApprovalOverlayControllerTests: XCTestCase {
    func testApprovalRequestNotificationPopulatesOverlayState() async throws {
        let controller = ApprovalOverlayController()

        NotificationCenter.default.post(
            name: .faeApprovalRequested,
            object: nil,
            userInfo: [
                "request_id": 42,
                "tool_name": "write",
                "input_json": "{\"path\":\"/tmp/demo.txt\"}",
                "manual_only": true,
                "disaster_level": true,
            ]
        )
        try await flushNotifications()

        XCTAssertEqual(controller.activeApproval?.id, 42)
        XCTAssertEqual(controller.activeApproval?.toolName, "write")
        XCTAssertEqual(controller.activeApproval?.description, "Create: /tmp/demo.txt")
        XCTAssertEqual(controller.activeApproval?.manualOnly, true)
        XCTAssertEqual(controller.activeApproval?.isDisasterLevel, true)
    }

    func testApproveAlwaysPostsExpectedDecisionPayload() async throws {
        let controller = ApprovalOverlayController()
        controller.activeApproval = .init(
            id: 7,
            toolName: "bash",
            description: "Run: echo hello",
            manualOnly: false,
            isDisasterLevel: false
        )

        let expectation = expectation(forNotification: .faeApprovalRespond, object: nil) { notification in
            let info = notification.userInfo
            return info?["request_id"] as? String == "7"
                && info?["approved"] as? Bool == true
                && info?["decision"] as? String == "always"
                && info?["tool_name"] as? String == "bash"
        }

        controller.approveAlways()

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertNil(controller.activeApproval)
    }

    // testApproveAllReadOnly removed — bulk-approve methods were removed in UX simplification.

    func testInputRequestFormBuildsFieldsAndSubmitFormResponds() async throws {
        let controller = ApprovalOverlayController()

        NotificationCenter.default.post(
            name: .faeInputRequired,
            object: nil,
            userInfo: [
                "request_id": "req-1",
                "mode": "form",
                "title": "Channel setup",
                "prompt": "Fill in the missing fields",
                "fields": [
                    [
                        "id": "url",
                        "label": "Webhook URL",
                        "placeholder": "https://example.com/webhook",
                        "required": true,
                        "must_be_https": true,
                    ],
                    [
                        "id": "token",
                        "label": "Token",
                        "is_secure": true,
                        "required": true,
                    ],
                ],
            ]
        )
        try await flushNotifications()

        XCTAssertEqual(controller.activeInput?.id, "req-1")
        XCTAssertEqual(controller.activeInput?.fields.count, 2)
        XCTAssertEqual(controller.activeInput?.fields.first?.mustBeHttps, true)
        XCTAssertEqual(controller.activeInput?.fields.last?.isSecure, true)

        let expectation = expectation(forNotification: .faeInputResponse, object: nil) { notification in
            let values = notification.userInfo?["form_values"] as? [String: String]
            return notification.userInfo?["request_id"] as? String == "req-1"
                && values == ["url": "https://example.com/webhook", "token": "secret"]
        }

        controller.submitForm(values: ["url": "https://example.com/webhook", "token": "secret"])

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertNil(controller.activeInput)
    }

    func testGovernanceConfirmationPostsDecisionAndClearsState() async throws {
        let controller = ApprovalOverlayController()
        NotificationCenter.default.post(
            name: .faeGovernanceConfirmationRequested,
            object: nil,
            userInfo: [
                "request_id": "gov-1",
                "title": "Apply change",
                "message": "Allow this governance change?",
                "confirm_label": "Apply",
            ]
        )
        try await flushNotifications()

        XCTAssertEqual(controller.activeGovernanceConfirmation?.id, "gov-1")

        let expectation = expectation(forNotification: .faeGovernanceConfirmationRespond, object: nil) { notification in
            notification.userInfo?["request_id"] as? String == "gov-1"
                && notification.userInfo?["approved"] as? Bool == true
        }

        controller.confirmGovernanceRequest()

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertNil(controller.activeGovernanceConfirmation)
    }

    func testToolModeUpgradeRequestUsesPopupPathBeforeSettingsFallback() async throws {
        let controller = ApprovalOverlayController()

        NotificationCenter.default.post(
            name: .faeToolModeUpgradeRequested,
            object: nil,
            userInfo: ["reason": "toolMode=off"]
        )
        try await flushNotifications()

        XCTAssertEqual(controller.activeToolModeRequest?.reason, "toolMode=off")

        let expectation = expectation(forNotification: .faeToolModeUpgradeRespond, object: nil) { notification in
            notification.userInfo?["action"] as? String == "set_mode"
                && notification.userInfo?["mode"] as? String == "read_only"
        }

        controller.upgradeToolMode("read_only")

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertNil(controller.activeToolModeRequest)
    }

    func testToolModeOpenSettingsRequiresExplicitUserChoice() async throws {
        let controller = ApprovalOverlayController()

        NotificationCenter.default.post(
            name: .faeToolModeUpgradeRequested,
            object: nil,
            userInfo: ["reason": "tool_not_called"]
        )
        try await flushNotifications()

        XCTAssertEqual(controller.activeToolModeRequest?.reason, "tool_not_called")

        let expectation = expectation(forNotification: .faeToolModeUpgradeRespond, object: nil) { notification in
            notification.userInfo?["action"] as? String == "open_settings"
        }

        controller.openSettingsFromToolMode()

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertNil(controller.activeToolModeRequest)
    }

    private func flushNotifications() async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}
