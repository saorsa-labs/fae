import XCTest
@testable import Fae

final class EndToEndBuiltInAwarenessTaskTests: XCTestCase {
    private actor DispatchCapture {
        private(set) var taskIDs: [String] = []
        private(set) var allowedToolSets: [Set<String>] = []
        private(set) var consentFlags: [Bool] = []
        private(set) var silentFlags: [Bool] = []

        func record(taskID: String, allowedTools: Set<String>, consentGranted: Bool, silent: Bool) {
            taskIDs.append(taskID)
            allowedToolSets.append(allowedTools)
            consentFlags.append(consentGranted)
            silentFlags.append(silent)
        }

        func snapshot() -> (taskIDs: [String], allowedToolSets: [Set<String>], consentFlags: [Bool], silentFlags: [Bool]) {
            (taskIDs, allowedToolSets, consentFlags, silentFlags)
        }
    }

    func testScreenActivityCheckMatchesConsentAndQuietHoursPolicy() async throws {
        let scheduler = FaeScheduler(eventBus: FaeEventBus())
        var config = consentedAwarenessConfig()
        config.screenEnabled = true
        await scheduler.setAwarenessConfig(config)

        let capture = DispatchCapture()
        let maybeDispatches = expectation(description: "screen task dispatch")
        if AwarenessThrottle.isQuietHours() {
            maybeDispatches.isInverted = true
        }

        await scheduler.setProactiveQueryHandler { _, silent, taskID, allowedTools, consentGranted in
            await capture.record(taskID: taskID, allowedTools: allowedTools, consentGranted: consentGranted, silent: silent)
            maybeDispatches.fulfill()
        }

        await scheduler.triggerTask(id: "screen_activity_check")
        await fulfillment(of: [maybeDispatches], timeout: AwarenessThrottle.isQuietHours() ? 0.2 : 1.0)

        let snapshot = await capture.snapshot()
        if AwarenessThrottle.isQuietHours() {
            XCTAssertTrue(snapshot.taskIDs.isEmpty)
        } else {
            XCTAssertEqual(snapshot.taskIDs, ["screen_activity_check"])
            XCTAssertEqual(snapshot.allowedToolSets, [Set(["screenshot"])])
            XCTAssertEqual(snapshot.consentFlags, [true])
            XCTAssertEqual(snapshot.silentFlags, [true])
        }
    }

    func testOvernightWorkDispatchesWithResearchAllowlist() async throws {
        let scheduler = FaeScheduler(eventBus: FaeEventBus())
        let config = consentedAwarenessConfig()
        await scheduler.setAwarenessConfig(config)

        let capture = DispatchCapture()
        let dispatched = expectation(description: "overnight work dispatched")
        await scheduler.setProactiveQueryHandler { _, silent, taskID, allowedTools, consentGranted in
            await capture.record(taskID: taskID, allowedTools: allowedTools, consentGranted: consentGranted, silent: silent)
            dispatched.fulfill()
        }

        await scheduler.triggerTask(id: "overnight_work")
        await fulfillment(of: [dispatched], timeout: 1.0)

        let snapshot = await capture.snapshot()
        XCTAssertEqual(snapshot.taskIDs, ["overnight_work"])
        XCTAssertEqual(snapshot.allowedToolSets, [Set(["web_search", "fetch_url", "activate_skill"])])
        XCTAssertEqual(snapshot.consentFlags, [true])
        XCTAssertEqual(snapshot.silentFlags, [true])
    }

    func testEnhancedMorningBriefingDispatchesOnceAndMarksDelivered() async throws {
        let scheduler = FaeScheduler(eventBus: FaeEventBus())
        let config = consentedAwarenessConfig()
        await scheduler.setAwarenessConfig(config)

        let capture = DispatchCapture()
        let dispatched = expectation(description: "enhanced morning briefing dispatched")
        await scheduler.setProactiveQueryHandler { _, _, taskID, allowedTools, consentGranted in
            await capture.record(taskID: taskID, allowedTools: allowedTools, consentGranted: consentGranted, silent: false)
            dispatched.fulfill()
        }

        await scheduler.triggerTask(id: "enhanced_morning_briefing")
        await scheduler.triggerTask(id: "enhanced_morning_briefing")
        await fulfillment(of: [dispatched], timeout: 1.0)

        let snapshot = await capture.snapshot()
        XCTAssertEqual(snapshot.taskIDs.count, 1)
        XCTAssertEqual(snapshot.taskIDs.first, "enhanced_morning_briefing")
        XCTAssertEqual(snapshot.allowedToolSets.first, Set(["calendar", "reminders", "contacts", "mail", "notes", "activate_skill"]))
        XCTAssertEqual(snapshot.consentFlags.first, true)
        let delivered = await scheduler.isMorningBriefingDelivered()
        XCTAssertTrue(delivered)
    }

    private func consentedAwarenessConfig() -> FaeConfig.AwarenessConfig {
        var config = FaeConfig.AwarenessConfig()
        config.enabled = true
        config.cameraEnabled = true
        config.screenEnabled = false
        config.pauseOnBattery = false
        config.pauseOnThermalPressure = false
        config.consentGrantedAt = ISO8601DateFormatter().string(from: Date())
        return config
    }
}
