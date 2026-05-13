import XCTest
@testable import Fae

final class SchedulerToolsTests: XCTestCase {

    private func makeTask(scheduleType: String, scheduleParams: [String: String] = [:]) -> SchedulerTask {
        SchedulerTask(
            id: "test",
            name: "test-task",
            kind: "user",
            enabled: true,
            scheduleType: scheduleType,
            scheduleParams: scheduleParams,
            action: "test action"
        )
    }

    // MARK: - normalizedAutonomousSchedulerTools

    func testNormalizedToolsNil() {
        let tools = normalizedAutonomousSchedulerTools(from: nil)
        XCTAssertFalse(tools.isEmpty)
    }

    func testNormalizedToolsEmpty() {
        let tools = normalizedAutonomousSchedulerTools(from: [])
        XCTAssertFalse(tools.isEmpty)
    }

    func testNormalizedToolsWhitespace() {
        let tools = normalizedAutonomousSchedulerTools(from: ["  ", ""])
        XCTAssertFalse(tools.isEmpty)
    }

    func testNormalizedToolsSorted() {
        let tools = normalizedAutonomousSchedulerTools(from: ["noise_budget_reset", "memory_reflect"])
        XCTAssertEqual(tools, tools.sorted())
    }

    // MARK: - schedulerNextRunDate

    func testSchedulerNextRunIntervalMinutes() {
        let task = makeTask(scheduleType: "interval", scheduleParams: ["minutes": "30"])
        let now = Date()
        let nextRun = schedulerNextRunDate(for: task, after: now)
        XCTAssertNotNil(nextRun)
        XCTAssertEqual(nextRun!.timeIntervalSince(now), 30 * 60, accuracy: 1)
    }

    func testSchedulerNextRunIntervalHours() {
        let task = makeTask(scheduleType: "interval", scheduleParams: ["hours": "2"])
        let now = Date()
        let nextRun = schedulerNextRunDate(for: task, after: now)
        XCTAssertNotNil(nextRun)
        XCTAssertEqual(nextRun!.timeIntervalSince(now), 2 * 3600, accuracy: 1)
    }

    func testSchedulerNextRunDaily() {
        let task = makeTask(scheduleType: "daily", scheduleParams: ["hour": "3", "minute": "30"])
        let nextRun = schedulerNextRunDate(for: task, after: Date())
        XCTAssertNotNil(nextRun)
        XCTAssertGreaterThan(nextRun!, Date())
    }

    func testSchedulerNextRunWeekly() {
        let task = makeTask(scheduleType: "weekly", scheduleParams: ["day": "monday", "hour": "9", "minute": "0"])
        let nextRun = schedulerNextRunDate(for: task, after: Date())
        XCTAssertNotNil(nextRun)
        XCTAssertGreaterThan(nextRun!, Date())
    }

    func testSchedulerNextRunInvalidType() {
        let task = makeTask(scheduleType: "invalid")
        let nextRun = schedulerNextRunDate(for: task, after: Date())
        XCTAssertNil(nextRun)
    }

    func testSchedulerNextRunMissingParams() {
        let task = makeTask(scheduleType: "daily")
        let nextRun = schedulerNextRunDate(for: task, after: Date())
        XCTAssertNil(nextRun)
    }

    // MARK: - schedulerNextRunString

    func testSchedulerNextRunString() {
        let task = makeTask(scheduleType: "interval", scheduleParams: ["minutes": "5"])
        let nextRunStr = schedulerNextRunString(for: task, after: Date())
        XCTAssertNotNil(nextRunStr)
        XCTAssertTrue(nextRunStr!.contains("T"))
    }

    func testSchedulerNextRunStringNil() {
        let task = makeTask(scheduleType: "invalid")
        let nextRunStr = schedulerNextRunString(for: task, after: Date())
        XCTAssertNil(nextRunStr)
    }

    // MARK: - resolvedSchedulerFileURL

    func testResolvedSchedulerFileURL() {
        let url = resolvedSchedulerFileURL()
        XCTAssertFalse(url.path.isEmpty)
        XCTAssertTrue(url.path.hasSuffix(".json"))
    }
}
