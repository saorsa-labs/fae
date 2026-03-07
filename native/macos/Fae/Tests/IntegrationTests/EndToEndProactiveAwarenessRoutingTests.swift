import XCTest
@testable import Fae

final class EndToEndProactiveAwarenessRoutingTests: XCTestCase {
    private actor DispatchCapture {
        private(set) var taskIDs: [String] = []
        private(set) var allowedTools: [Set<String>] = []
        private(set) var consentFlags: [Bool] = []
        private(set) var silentFlags: [Bool] = []

        func record(taskID: String, allowedTools: Set<String>, consentGranted: Bool, silent: Bool) {
            taskIDs.append(taskID)
            self.allowedTools.append(allowedTools)
            consentFlags.append(consentGranted)
            silentFlags.append(silent)
        }

        func snapshot() -> (taskIDs: [String], allowedTools: [Set<String>], consentFlags: [Bool], silentFlags: [Bool]) {
            (taskIDs, allowedTools, consentFlags, silentFlags)
        }
    }

    func testCameraPresenceCheckDoesNotDispatchWithoutConsent() async throws {
        let scheduler = FaeScheduler(eventBus: FaeEventBus())
        var config = FaeConfig.AwarenessConfig()
        config.enabled = true
        config.cameraEnabled = true
        config.pauseOnBattery = false
        config.pauseOnThermalPressure = false
        config.consentGrantedAt = nil
        await scheduler.setAwarenessConfig(config)

        let notCalled = expectation(description: "camera task should not dispatch without consent")
        notCalled.isInverted = true
        await scheduler.setProactiveQueryHandler { _, _, _, _, _ in
            notCalled.fulfill()
        }

        await scheduler.triggerTask(id: "camera_presence_check")
        await fulfillment(of: [notCalled], timeout: 0.2)
    }

    func testCameraPresenceCheckDispatchesWithConsentAndCameraAllowlist() async throws {
        let scheduler = FaeScheduler(eventBus: FaeEventBus())
        var config = FaeConfig.AwarenessConfig()
        config.enabled = true
        config.cameraEnabled = true
        config.pauseOnBattery = false
        config.pauseOnThermalPressure = false
        config.consentGrantedAt = ISO8601DateFormatter().string(from: Date())
        await scheduler.setAwarenessConfig(config)

        let capture = DispatchCapture()
        let dispatched = expectation(description: "camera task dispatched at least once")
        await scheduler.setProactiveQueryHandler { _, silent, taskID, allowedTools, consentGranted in
            await capture.record(taskID: taskID, allowedTools: allowedTools, consentGranted: consentGranted, silent: silent)
            dispatched.fulfill()
        }

        await scheduler.triggerTask(id: "camera_presence_check")
        await scheduler.triggerTask(id: "camera_presence_check")
        await fulfillment(of: [dispatched], timeout: 1.0)

        let snapshot = await capture.snapshot()
        XCTAssertTrue(snapshot.taskIDs.contains("camera_presence_check"))
        XCTAssertTrue(snapshot.allowedTools.allSatisfy { $0 == Set(["camera"]) })
        XCTAssertTrue(snapshot.consentFlags.allSatisfy { $0 })
        XCTAssertFalse(snapshot.silentFlags.isEmpty)
    }
}
