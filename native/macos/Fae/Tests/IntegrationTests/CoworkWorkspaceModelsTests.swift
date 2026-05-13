import XCTest
@testable import Fae

final class CoworkWorkspaceModelsTests: XCTestCase {

    // MARK: - displayName

    func testDisplayNameSTT() {
        let name = CoworkToolSummary.displayName(for: "stt_transcription")
        XCTAssertEqual(name, "STT Transcription")
    }

    func testDisplayNameVLM() {
        let name = CoworkToolSummary.displayName(for: "vlm_analysis")
        XCTAssertEqual(name, "VLM Analysis")
    }

    func testDisplayNameURL() {
        let name = CoworkToolSummary.displayName(for: "url_fetch")
        XCTAssertEqual(name, "URL Fetch")
    }

    func testDisplayNameNormal() {
        let name = CoworkToolSummary.displayName(for: "web_search")
        XCTAssertEqual(name, "Web Search")
    }

    // MARK: - category

    func testCategoryApple() {
        XCTAssertEqual(CoworkToolSummary.category(for: "calendar"), "Apple")
        XCTAssertEqual(CoworkToolSummary.category(for: "reminders"), "Apple")
        XCTAssertEqual(CoworkToolSummary.category(for: "mail"), "Apple")
    }

    func testCategoryScheduler() {
        XCTAssertEqual(CoworkToolSummary.category(for: "scheduler_create"), "Scheduler")
    }

    func testCategoryComputerUse() {
        XCTAssertEqual(CoworkToolSummary.category(for: "screenshot"), "Computer Use")
        XCTAssertEqual(CoworkToolSummary.category(for: "camera"), "Computer Use")
    }

    func testCategoryCore() {
        XCTAssertEqual(CoworkToolSummary.category(for: "read"), "Core")
        XCTAssertEqual(CoworkToolSummary.category(for: "bash"), "Core")
    }

    func testCategoryVoice() {
        XCTAssertEqual(CoworkToolSummary.category(for: "voice_identity"), "Voice")
    }

    func testCategoryGeneral() {
        XCTAssertEqual(CoworkToolSummary.category(for: "unknown_tool_xyz"), "General")
    }

    // MARK: - scheduleDescription

    func testScheduleDescriptionIntervalMinutes() {
        let desc = CoworkSchedulerTask.scheduleDescription(
            for: "test", legacySchedule: nil, scheduleType: "interval",
            scheduleParams: ["minutes": "30"]
        )
        XCTAssertEqual(desc, "Every 30m")
    }

    func testScheduleDescriptionIntervalHours() {
        let desc = CoworkSchedulerTask.scheduleDescription(
            for: "test", legacySchedule: nil, scheduleType: "interval",
            scheduleParams: ["hours": "2"]
        )
        XCTAssertEqual(desc, "Every 2h")
    }

    func testScheduleDescriptionDaily() {
        let desc = CoworkSchedulerTask.scheduleDescription(
            for: "test", legacySchedule: nil, scheduleType: "daily",
            scheduleParams: ["hour": "9", "minute": "30"]
        )
        XCTAssertEqual(desc, "Daily at 9:30")
    }

    func testScheduleDescriptionWeekly() {
        let desc = CoworkSchedulerTask.scheduleDescription(
            for: "test", legacySchedule: nil, scheduleType: "weekly",
            scheduleParams: ["day": "monday", "hour": "10", "minute": "0"]
        )
        XCTAssertEqual(desc, "Weekly monday at 10:00")
    }

    func testScheduleDescriptionLegacyInterval() {
        let desc = CoworkSchedulerTask.scheduleDescription(
            for: "test", legacySchedule: ["Interval": ["secs": 7200]],
            scheduleType: nil, scheduleParams: nil
        )
        XCTAssertEqual(desc, "Every 2 hours")
    }

    func testScheduleDescriptionLegacyHour() {
        let desc = CoworkSchedulerTask.scheduleDescription(
            for: "test", legacySchedule: ["Interval": ["secs": 3600]],
            scheduleType: nil, scheduleParams: nil
        )
        XCTAssertEqual(desc, "Every hour")
    }

    // MARK: - title

    func testTitle() {
        let title = CoworkSchedulerTask.title(from: "memory_reflect")
        XCTAssertEqual(title, "Memory Reflect")
    }

    func testTitleSingleWord() {
        let title = CoworkSchedulerTask.title(from: "test")
        XCTAssertEqual(title, "Test")
    }

    // MARK: - iso8601Date

    func testIso8601DateValid() {
        let date = CoworkSchedulerTask.iso8601Date(from: "2025-01-01T00:00:00Z")
        XCTAssertNotNil(date)
    }

    func testIso8601DateInvalid() {
        let date = CoworkSchedulerTask.iso8601Date(from: "not-a-date")
        XCTAssertNil(date)
    }

    // MARK: - defaultScheduleDescription

    func testDefaultScheduleDescriptionMemoryReflect() {
        XCTAssertEqual(CoworkSchedulerTask.defaultScheduleDescription(for: "memory_reflect"), "Every 6 hours")
    }

    func testDefaultScheduleDescriptionMemoryGC() {
        XCTAssertEqual(CoworkSchedulerTask.defaultScheduleDescription(for: "memory_gc"), "Daily at 03:30")
    }

    func testDefaultScheduleDescriptionUnknown() {
        XCTAssertEqual(CoworkSchedulerTask.defaultScheduleDescription(for: "unknown_task"), "Managed by Fae")
    }
}
