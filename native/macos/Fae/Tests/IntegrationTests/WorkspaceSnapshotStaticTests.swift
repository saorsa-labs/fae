import XCTest
@testable import Fae

/// Coverage for WorkspaceSnapshot.swift (was 0% covered). Pure static helpers
/// for tool/skill display names, categories, schedule descriptions, and ISO8601
/// date parsing — no instance state, no system frameworks.
final class WorkspaceSnapshotStaticTests: XCTestCase {

    // MARK: - displayName

    func testDisplayNameCapitalises() {
        XCTAssertEqual(WorkspaceToolSummary.displayName(for: "web_search"), "Web Search")
        XCTAssertEqual(WorkspaceToolSummary.displayName(for: "calendar"), "Calendar")
    }

    func testDisplayNameAcronyms() {
        XCTAssertEqual(WorkspaceToolSummary.displayName(for: "stt"), "STT")
        XCTAssertEqual(WorkspaceToolSummary.displayName(for: "vlm_transcribe"), "VLM Transcribe")
        XCTAssertEqual(WorkspaceToolSummary.displayName(for: "fetch_url"), "Fetch URL")
    }

    func testDisplayNameSingleWord() {
        XCTAssertEqual(WorkspaceToolSummary.displayName(for: "read"), "Read")
    }

    // MARK: - category

    func testCategoryApple() {
        for id in ["calendar", "reminders", "contacts", "mail", "notes"] {
            XCTAssertEqual(WorkspaceToolSummary.category(for: id), "Apple", "for \(id)")
        }
    }

    func testCategoryScheduler() {
        XCTAssertEqual(WorkspaceToolSummary.category(for: "scheduler_skill_distill"), "Scheduler")
    }

    func testCategorySkills() {
        XCTAssertEqual(WorkspaceToolSummary.category(for: "run_skill_x"), "Skills")
        XCTAssertEqual(WorkspaceToolSummary.category(for: "agent_delegate"), "Skills")
    }

    func testCategoryComputerUse() {
        XCTAssertEqual(WorkspaceToolSummary.category(for: "screenshot"), "Computer Use")
        XCTAssertEqual(WorkspaceToolSummary.category(for: "read_screen"), "Computer Use")
    }

    func testCategoryCore() {
        XCTAssertEqual(WorkspaceToolSummary.category(for: "read"), "Core")
        XCTAssertEqual(WorkspaceToolSummary.category(for: "web_search"), "Core")
    }

    func testCategoryVoice() {
        XCTAssertEqual(WorkspaceToolSummary.category(for: "voice_capture"), "Voice")
    }

    func testCategoryGeneral() {
        XCTAssertEqual(WorkspaceToolSummary.category(for: "mystery_tool"), "General")
    }

    // MARK: - defaultScheduleDescription

    func testDefaultScheduleDescriptionKnown() {
        XCTAssertEqual(WorkspaceSchedulerTask.defaultScheduleDescription(for: "memory_reflect"), "Every 6 hours")
        XCTAssertEqual(WorkspaceSchedulerTask.defaultScheduleDescription(for: "memory_reindex"), "Every 3 hours")
        XCTAssertEqual(WorkspaceSchedulerTask.defaultScheduleDescription(for: "memory_migrate"), "Hourly")
        XCTAssertEqual(WorkspaceSchedulerTask.defaultScheduleDescription(for: "skill_health_check"), "Every 5 minutes")
        XCTAssertEqual(WorkspaceSchedulerTask.defaultScheduleDescription(for: "memory_gc"), "Daily at 03:30")
        XCTAssertEqual(WorkspaceSchedulerTask.defaultScheduleDescription(for: "memory_backup"), "Daily at 02:00")
        XCTAssertEqual(WorkspaceSchedulerTask.defaultScheduleDescription(for: "noise_budget_reset"), "Daily at 00:00")
        XCTAssertEqual(WorkspaceSchedulerTask.defaultScheduleDescription(for: "stale_relationships"), "Weekly relationship review")
    }

    func testDefaultScheduleDescriptionUnknown() {
        XCTAssertEqual(WorkspaceSchedulerTask.defaultScheduleDescription(for: "custom_task"), "Managed by Fae")
    }

    // MARK: - scheduleDescription

    func testScheduleDescriptionIntervalMinutes() {
        let desc = WorkspaceSchedulerTask.scheduleDescription(
            for: "x", legacySchedule: nil, scheduleType: "interval",
            scheduleParams: ["minutes": "15"])
        XCTAssertEqual(desc, "Every 15m")
    }

    func testScheduleDescriptionIntervalHours() {
        let desc = WorkspaceSchedulerTask.scheduleDescription(
            for: "x", legacySchedule: nil, scheduleType: "interval",
            scheduleParams: ["hours": "3"])
        XCTAssertEqual(desc, "Every 3h")
    }

    func testScheduleDescriptionDailyPadsMinute() {
        let desc = WorkspaceSchedulerTask.scheduleDescription(
            for: "x", legacySchedule: nil, scheduleType: "daily",
            scheduleParams: ["hour": "9", "minute": "5"])
        XCTAssertEqual(desc, "Daily at 9:05")
    }

    func testScheduleDescriptionWeeklyWithHourMinute() {
        let desc = WorkspaceSchedulerTask.scheduleDescription(
            for: "x", legacySchedule: nil, scheduleType: "weekly",
            scheduleParams: ["day": "monday", "hour": "8", "minute": "30"])
        // Weekly branch builds a descriptive string; just assert it mentions the day.
        XCTAssertTrue(desc.lowercased().contains("monday") || desc.lowercased().contains("weekly"))
    }

    func testScheduleDescriptionFallsBackToDefault() {
        let desc = WorkspaceSchedulerTask.scheduleDescription(
            for: "memory_reflect", legacySchedule: nil, scheduleType: nil, scheduleParams: nil)
        XCTAssertEqual(desc, "Every 6 hours")
    }

    // MARK: - title

    func testTitleCapitalises() {
        XCTAssertEqual(WorkspaceSchedulerTask.title(from: "morning_briefing"), "Morning Briefing")
        XCTAssertEqual(WorkspaceSchedulerTask.title(from: "calendar"), "Calendar")
    }

    // MARK: - iso8601Date

    func testIso8601DateValid() {
        let date = WorkspaceSchedulerTask.iso8601Date(from: "2026-06-17T12:00:00Z")
        XCTAssertNotNil(date)
    }

    func testIso8601DateInvalid() {
        XCTAssertNil(WorkspaceSchedulerTask.iso8601Date(from: "not-a-date"))
    }

    func testIso8601DateEmpty() {
        XCTAssertNil(WorkspaceSchedulerTask.iso8601Date(from: ""))
    }
}
