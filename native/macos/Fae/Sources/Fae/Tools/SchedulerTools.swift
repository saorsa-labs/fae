import Foundation

// MARK: - Scheduler Task JSON Model

/// JSON-serializable scheduler task for persistence.
struct SchedulerTask: Codable {
    var id: String
    var name: String
    var kind: String // "builtin" or "user"
    var enabled: Bool
    var scheduleType: String // "interval", "daily", "weekly"
    var scheduleParams: [String: String]
    var action: String
    var nextRun: String?
    var allowedTools: [String]?
}

struct SchedulerFileEnvelope: Codable {
    var tasks: [SchedulerTask]
}

/// Shared scheduler file override used by tests to avoid touching the real app state.
var schedulerFileURLOverride: URL?

/// Shared path for the scheduler task file.
func resolvedSchedulerFileURL() -> URL {
    if let schedulerFileURLOverride {
        return schedulerFileURLOverride
    }
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")
    return appSupport.appendingPathComponent("fae/scheduler.json")
}

let schedulerISO8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

let defaultAutonomousSchedulerTools: Set<String> = [
    "activate_skill", "run_skill",
    "web_search", "fetch_url",
    "calendar", "reminders", "contacts", "mail", "notes",
    "scheduler_list",
]

func normalizedAutonomousSchedulerTools(from raw: [String]?) -> [String] {
    let requested = raw ?? []
    let cleaned = requested
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }
    let allowed = Set(cleaned).intersection(defaultAutonomousSchedulerTools)
    let final = allowed.isEmpty ? defaultAutonomousSchedulerTools : allowed
    return final.sorted()
}

func schedulerNextRunDate(for task: SchedulerTask, after reference: Date = Date()) -> Date? {
    let calendar = Calendar.current
    let anchor = reference.addingTimeInterval(1)

    switch task.scheduleType.lowercased() {
    case "interval":
        if let minutes = task.scheduleParams["minutes"].flatMap(Int.init), minutes > 0 {
            return reference.addingTimeInterval(TimeInterval(minutes * 60))
        }
        if let hours = task.scheduleParams["hours"].flatMap(Int.init), hours > 0 {
            return reference.addingTimeInterval(TimeInterval(hours * 3600))
        }
        return nil

    case "daily":
        guard let hour = task.scheduleParams["hour"].flatMap(Int.init),
              let minute = task.scheduleParams["minute"].flatMap(Int.init)
        else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: reference)
        components.hour = hour
        components.minute = minute
        components.second = 0
        if let sameDay = calendar.date(from: components), sameDay > reference {
            return sameDay
        }
        return calendar.date(byAdding: .day, value: 1, to: calendar.date(from: components) ?? reference)

    case "weekly":
        guard let day = task.scheduleParams["day"],
              let weekday = schedulerWeekday(for: day),
              let hour = task.scheduleParams["hour"].flatMap(Int.init),
              let minute = task.scheduleParams["minute"].flatMap(Int.init)
        else { return nil }
        let components = DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday)
        return calendar.nextDate(after: anchor, matching: components, matchingPolicy: .nextTime)

    default:
        return nil
    }
}

func schedulerNextRunString(for task: SchedulerTask, after reference: Date = Date()) -> String? {
    guard let nextRun = schedulerNextRunDate(for: task, after: reference) else { return nil }
    return schedulerISO8601Formatter.string(from: nextRun)
}

private func schedulerWeekday(for value: String) -> Int? {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "sunday": return 1
    case "monday": return 2
    case "tuesday": return 3
    case "wednesday": return 4
    case "thursday": return 5
    case "friday": return 6
    case "saturday": return 7
    default: return nil
    }
}

/// Read scheduler tasks from disk.
func readSchedulerTasks() -> [SchedulerTask] {
    let fileURL = resolvedSchedulerFileURL()
    guard FileManager.default.fileExists(atPath: fileURL.path),
          let data = FileManager.default.contents(atPath: fileURL.path)
    else {
        return defaultBuiltinTasks()
    }

    let decoder = JSONDecoder()
    if let envelope = try? decoder.decode(SchedulerFileEnvelope.self, from: data) {
        return envelope.tasks
    }
    if let tasks = try? decoder.decode([SchedulerTask].self, from: data) {
        return tasks
    }

    return defaultBuiltinTasks()
}

/// Write scheduler tasks to disk.
func writeSchedulerTasks(_ tasks: [SchedulerTask]) throws {
    let fileURL = resolvedSchedulerFileURL()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(SchedulerFileEnvelope(tasks: tasks))
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil
    )
    try data.write(to: fileURL, options: .atomic)
}

/// Default builtin tasks (read-only, used when no file exists yet).
private func defaultBuiltinTasks() -> [SchedulerTask] {
    [
        SchedulerTask(id: "memory_reflect", name: "Memory Reflect", kind: "builtin", enabled: true,
                       scheduleType: "interval", scheduleParams: ["hours": "6"], action: "memory_reflect", nextRun: nil, allowedTools: nil),
        SchedulerTask(id: "memory_reindex", name: "Memory Reindex", kind: "builtin", enabled: true,
                       scheduleType: "interval", scheduleParams: ["hours": "3"], action: "memory_reindex", nextRun: nil, allowedTools: nil),
        SchedulerTask(id: "memory_migrate", name: "Memory Migrate", kind: "builtin", enabled: true,
                       scheduleType: "interval", scheduleParams: ["hours": "1"], action: "memory_migrate", nextRun: nil, allowedTools: nil),
        SchedulerTask(id: "memory_gc", name: "Memory GC", kind: "builtin", enabled: true,
                       scheduleType: "daily", scheduleParams: ["hour": "3", "minute": "30"], action: "memory_gc", nextRun: nil, allowedTools: nil),
        SchedulerTask(id: "memory_backup", name: "Memory Backup", kind: "builtin", enabled: true,
                       scheduleType: "daily", scheduleParams: ["hour": "2", "minute": "0"], action: "memory_backup", nextRun: nil, allowedTools: nil),
        SchedulerTask(id: "check_fae_update", name: "Check for Updates", kind: "builtin", enabled: true,
                       scheduleType: "interval", scheduleParams: ["hours": "6"], action: "check_fae_update", nextRun: nil, allowedTools: nil),
        SchedulerTask(id: "noise_budget_reset", name: "Noise Budget Reset", kind: "builtin", enabled: true,
                       scheduleType: "daily", scheduleParams: ["hour": "0", "minute": "0"], action: "noise_budget_reset", nextRun: nil, allowedTools: nil),
        SchedulerTask(id: "morning_briefing", name: "Morning Briefing", kind: "builtin", enabled: true,
                       scheduleType: "daily", scheduleParams: ["hour": "8", "minute": "0"], action: "morning_briefing", nextRun: nil, allowedTools: nil),
        SchedulerTask(id: "skill_proposals", name: "Skill Proposals", kind: "builtin", enabled: true,
                       scheduleType: "daily", scheduleParams: ["hour": "11", "minute": "0"], action: "skill_proposals", nextRun: nil, allowedTools: nil),
        SchedulerTask(id: "stale_relationships", name: "Stale Relationships", kind: "builtin", enabled: true,
                       scheduleType: "weekly", scheduleParams: ["day": "sunday", "hour": "10", "minute": "0"], action: "stale_relationships", nextRun: nil, allowedTools: nil),
        SchedulerTask(id: "skill_health_check", name: "Skill Health Check", kind: "builtin", enabled: true,
                       scheduleType: "interval", scheduleParams: ["minutes": "5"], action: "skill_health_check", nextRun: nil, allowedTools: nil),
    ]
}

// MARK: - Scheduler List Tool

/// Fae tool that returns all registered scheduler tasks with their schedule and enabled state.
///
/// Reads from the persisted `scheduler.json` file (or built-in defaults if no file exists).
/// Reports each task's name, kind (builtin/user), schedule, and enabled/disabled status.
struct SchedulerListTool: Tool {
    let name = "scheduler_list"
    let description = "List all scheduled tasks with their schedule and status."
    let parametersSchema = #"{}"#
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .low
    let example = #"<tool_call>{"name":"scheduler_list","arguments":{}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        let tasks = readSchedulerTasks()
        if tasks.isEmpty {
            return .success("No scheduled tasks found.")
        }

        let lines = tasks.map { task in
            let status = task.enabled ? "enabled" : "disabled"
            let schedule: String
            switch task.scheduleType {
            case "interval":
                if let minutes = task.scheduleParams["minutes"] {
                    schedule = "every \(minutes)m"
                } else {
                    let hours = task.scheduleParams["hours"] ?? "?"
                    schedule = "every \(hours)h"
                }
            case "daily":
                let hour = task.scheduleParams["hour"] ?? "0"
                let minute = task.scheduleParams["minute"] ?? "0"
                schedule = "daily at \(hour):\(minute.count == 1 ? "0" + minute : minute)"
            case "weekly":
                let day = task.scheduleParams["day"] ?? "?"
                schedule = "weekly on \(day)"
            default:
                schedule = task.scheduleType
            }
            return "- \(task.name) [\(task.kind)] — \(schedule) (\(status))"
        }

        return .success("\(tasks.count) scheduled tasks:\n" + lines.joined(separator: "\n"))
    }
}

// MARK: - Scheduler Create Tool

/// Fae tool that creates a new user-defined scheduled task and persists it to `scheduler.json`.
///
/// Supports interval (every N hours/minutes), daily (at HH:MM), and weekly (day + time) schedules.
/// User tasks are assigned a unique `user_XXXXXXXX` ID and start enabled. Requires approval.
struct SchedulerCreateTool: Tool {
    let name = "scheduler_create"
    let description = "Create a new user-defined scheduled task."
    let parametersSchema = """
        {"name": "string (required)", \
        "schedule_type": "string (required: interval|daily|weekly)", \
        "schedule_params": "object (e.g. {hours: '6'} or {hour: '8', minute: '0'} or {day: 'monday'})", \
        "action": "string (required: description of what to do)", \
        "allowed_tools": "array<string> (optional: subset of autonomous scheduler tools such as activate_skill, run_skill, web_search, fetch_url, calendar, reminders, contacts, mail, notes, scheduler_list)"}
        """
    let requiresApproval = true
    let riskLevel: ToolRiskLevel = .high
    let example = #"<tool_call>{"name":"scheduler_create","arguments":{"name":"Weather Check","schedule_type":"daily","schedule_params":{"hour":"7","minute":"0"},"action":"Check weather forecast"}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let taskName = input["name"] as? String, !taskName.isEmpty else {
            return .error("Missing required parameter: name")
        }
        guard let scheduleType = input["schedule_type"] as? String else {
            return .error("Missing required parameter: schedule_type")
        }
        guard let action = input["action"] as? String, !action.isEmpty else {
            return .error("Missing required parameter: action")
        }

        let params = (input["schedule_params"] as? [String: Any])?.compactMapValues { "\($0)" } ?? [:]
        let requestedTools = input["allowed_tools"] as? [String]
        let allowedTools = normalizedAutonomousSchedulerTools(from: requestedTools)

        let id = "user_\(UUID().uuidString.prefix(8).lowercased())"
        var task = SchedulerTask(
            id: id,
            name: taskName,
            kind: "user",
            enabled: true,
            scheduleType: scheduleType,
            scheduleParams: params,
            action: action,
            nextRun: nil,
            allowedTools: allowedTools
        )
        task.nextRun = schedulerNextRunString(for: task, after: Date())

        var tasks = readSchedulerTasks()
        tasks.append(task)

        do {
            try writeSchedulerTasks(tasks)
            return .success("Created scheduled task '\(taskName)' (\(scheduleType)).")
        } catch {
            return .error("Failed to save task: \(error.localizedDescription)")
        }
    }
}

// MARK: - Scheduler Update Tool

/// Fae tool that updates an existing scheduler task's enabled state or schedule.
///
/// Enable/disable changes are routed through `NotificationCenter` (`.faeSchedulerUpdate`)
/// so `FaeScheduler` stays in sync without requiring a restart. Requires approval.
struct SchedulerUpdateTool: Tool {
    let name = "scheduler_update"
    let description = "Update a scheduled task (enable/disable, change schedule)."
    let parametersSchema = """
        {"id": "string (required)", \
        "enabled": "bool (optional)", \
        "schedule_type": "string (optional)", \
        "schedule_params": "object (optional)", \
        "allowed_tools": "array<string> (optional)"}
        """
    let requiresApproval = true
    let riskLevel: ToolRiskLevel = .high
    let example = #"<tool_call>{"name":"scheduler_update","arguments":{"id":"morning_briefing","enabled":false}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let taskId = input["id"] as? String else {
            return .error("Missing required parameter: id")
        }

        var tasks = readSchedulerTasks()
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else {
            return .error("Task not found: \(taskId)")
        }

        if let enabled = input["enabled"] as? Bool {
            tasks[index].enabled = enabled

            // Route enabled/disabled state change through FaeScheduler (single source of truth).
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .faeSchedulerUpdate,
                    object: nil,
                    userInfo: ["id": taskId, "enabled": enabled]
                )
            }
        }
        if let scheduleType = input["schedule_type"] as? String {
            tasks[index].scheduleType = scheduleType
        }
        if let params = input["schedule_params"] as? [String: Any] {
            tasks[index].scheduleParams = params.compactMapValues { "\($0)" }
        }
        if input.keys.contains("allowed_tools") {
            tasks[index].allowedTools = normalizedAutonomousSchedulerTools(from: input["allowed_tools"] as? [String])
        }
        if input["schedule_type"] != nil || input["schedule_params"] != nil {
            tasks[index].nextRun = schedulerNextRunString(for: tasks[index], after: Date())
        } else if let enabled = input["enabled"] as? Bool, enabled, tasks[index].nextRun == nil {
            tasks[index].nextRun = schedulerNextRunString(for: tasks[index], after: Date())
        }

        do {
            try writeSchedulerTasks(tasks)
            return .success("Updated task '\(tasks[index].name)'.")
        } catch {
            return .error("Failed to save: \(error.localizedDescription)")
        }
    }
}

// MARK: - Scheduler Delete Tool

/// Fae tool that permanently removes a user-created scheduled task from `scheduler.json`.
///
/// Only `kind == "user"` tasks can be deleted. Builtin tasks (memory, briefing, etc.)
/// must be disabled via `scheduler_update` instead. Requires approval.
struct SchedulerDeleteTool: Tool {
    let name = "scheduler_delete"
    let description = "Delete a user-created scheduled task. Cannot delete builtin tasks."
    let parametersSchema = #"{"id": "string (required)"}"#
    let requiresApproval = true
    let riskLevel: ToolRiskLevel = .high
    let example = #"<tool_call>{"name":"scheduler_delete","arguments":{"id":"user_abc12345"}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let taskId = input["id"] as? String else {
            return .error("Missing required parameter: id")
        }

        var tasks = readSchedulerTasks()
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else {
            return .error("Task not found: \(taskId)")
        }

        guard tasks[index].kind == "user" else {
            return .error("Cannot delete builtin task '\(tasks[index].name)'. You can disable it instead.")
        }

        let name = tasks[index].name
        tasks.remove(at: index)

        do {
            try writeSchedulerTasks(tasks)
            return .success("Deleted task '\(name)'.")
        } catch {
            return .error("Failed to save: \(error.localizedDescription)")
        }
    }
}

// MARK: - Scheduler Trigger Tool

/// Fae tool that fires a scheduled task immediately, bypassing its normal schedule.
///
/// Posts `.faeSchedulerTrigger` on `NotificationCenter` with the task ID.
/// `FaeCore` observes this notification and forwards it to `FaeScheduler.trigger(id:)`.
/// Useful for testing or manually running tasks like `morning_briefing`.
struct SchedulerTriggerTool: Tool {
    let name = "scheduler_trigger"
    let description = "Trigger a scheduled task to run immediately."
    let parametersSchema = #"{"id": "string (required)"}"#
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .low
    let example = #"<tool_call>{"name":"scheduler_trigger","arguments":{"id":"morning_briefing"}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let taskId = input["id"] as? String else {
            return .error("Missing required parameter: id")
        }

        let tasks = readSchedulerTasks()
        guard let task = tasks.first(where: { $0.id == taskId }) else {
            return .error("Task not found: \(taskId)")
        }

        // Send trigger command via NotificationCenter for FaeCore to handle.
        await MainActor.run {
            NotificationCenter.default.post(
                name: .faeSchedulerTrigger,
                object: nil,
                userInfo: ["id": taskId]
            )
        }

        return .success("Triggered '\(task.name)' to run now.")
    }
}

/// `NotificationCenter` names used by the scheduler tool layer to communicate
/// with `FaeScheduler` without creating a direct dependency.
extension Notification.Name {
    /// Posted by `SchedulerTriggerTool` to run a task immediately. `userInfo["id"]` is the task ID.
    static let faeSchedulerTrigger = Notification.Name("faeSchedulerTrigger")
    /// Posted by `SchedulerUpdateTool` when a task's enabled state changes. `userInfo["id"]` and `userInfo["enabled"]`.
    static let faeSchedulerUpdate = Notification.Name("faeSchedulerUpdate")
}
