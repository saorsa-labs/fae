import Foundation

enum CoworkWorkspaceSection: String, CaseIterable, Identifiable, Sendable {
    case workspace
    case scheduler
    case skills
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspace: return "Workspace"
        case .scheduler: return "Scheduler"
        case .skills: return "Skills"
        case .tools: return "Tools"
        }
    }

    var systemImage: String {
        switch self {
        case .workspace: return "rectangle.3.group.bubble.left.fill"
        case .scheduler: return "calendar.badge.clock"
        case .skills: return "sparkles.rectangle.stack.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        }
    }
}

struct CoworkToolSummary: Identifiable, Sendable {
    let id: String
    let displayName: String
    let description: String
    let riskLevel: String
    let category: String

    init(name: String, description: String, riskLevel: String) {
        id = name
        displayName = Self.displayName(for: name)
        self.description = description
        self.riskLevel = riskLevel
        category = Self.category(for: name)
    }

    static func displayName(for identifier: String) -> String {
        identifier
            .split(separator: "_")
            .map { part in
                let lower = part.lowercased()
                switch lower {
                case "stt": return "STT"
                case "vlm": return "VLM"
                case "url": return "URL"
                default:
                    return lower.prefix(1).uppercased() + lower.dropFirst()
                }
            }
            .joined(separator: " ")
    }

    static func category(for identifier: String) -> String {
        if ["calendar", "reminders", "contacts", "mail", "notes"].contains(identifier) {
            return "Apple"
        }
        if identifier.hasPrefix("scheduler_") {
            return "Scheduler"
        }
        if identifier.contains("skill") || identifier == "agent_delegate" {
            return "Skills"
        }
        if ["screenshot", "camera", "read_screen", "click", "type_text", "scroll", "find_element"].contains(identifier) {
            return "Computer Use"
        }
        if ["read", "write", "edit", "bash", "fetch_url", "web_search"].contains(identifier) {
            return "Core"
        }
        if identifier.contains("voice") {
            return "Voice"
        }
        return "General"
    }
}

struct CoworkSkillSummary: Identifiable, Sendable {
    let id: String
    let description: String
    let type: String
    let tier: String
    let isEnabled: Bool
    let isActive: Bool
}

struct CoworkSchedulerStatus: Sendable {
    let enabled: Bool
    let lastRunAt: Date?
}

struct CoworkWorkspaceSnapshot: Sendable {
    let pipelineStateLabel: String
    let toolMode: String
    let thinkingEnabled: Bool
    let hasOwnerSetUp: Bool
    let userName: String?
    let tools: [CoworkToolSummary]
    let skills: [CoworkSkillSummary]
    let schedulerStatusesByID: [String: CoworkSchedulerStatus]

    static let empty = CoworkWorkspaceSnapshot(
        pipelineStateLabel: "Stopped",
        toolMode: "off",
        thinkingEnabled: false,
        hasOwnerSetUp: false,
        userName: nil,
        tools: [],
        skills: [],
        schedulerStatusesByID: [:]
    )

    var activeSkills: [CoworkSkillSummary] {
        skills.filter(\.isActive)
    }

    var appleTools: [CoworkToolSummary] {
        tools.filter { $0.category == "Apple" }
    }
}

struct CoworkSchedulerTask: Identifiable, Sendable {
    let id: String
    var name: String
    let scheduleDescription: String
    let nextRun: Date?
    var lastRun: Date?
    var enabled: Bool
    let isBuiltin: Bool
    let failureStreak: Int
    let lastError: String?

    static func load(
        from url: URL = resolvedSchedulerFileURL(),
        statusesByID: [String: CoworkSchedulerStatus]
    ) -> [CoworkSchedulerTask] {
        var tasksByID: [String: CoworkSchedulerTask] = [:]

        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data)
        {
            let entries: [[String: Any]]
            if let dict = json as? [String: Any],
               let wrapped = dict["tasks"] as? [[String: Any]]
            {
                entries = wrapped
            } else if let array = json as? [[String: Any]] {
                entries = array
            } else {
                entries = []
            }

            for entry in entries {
                guard let task = from(dict: entry, statusesByID: statusesByID) else { continue }
                tasksByID[task.id] = task
            }
        }

        for (id, status) in statusesByID where tasksByID[id] == nil {
            tasksByID[id] = CoworkSchedulerTask(
                id: id,
                name: title(from: id),
                scheduleDescription: defaultScheduleDescription(for: id),
                nextRun: nil,
                lastRun: status.lastRunAt,
                enabled: status.enabled,
                isBuiltin: true,
                failureStreak: 0,
                lastError: nil
            )
        }

        return tasksByID.values.sorted { lhs, rhs in
            if lhs.enabled != rhs.enabled {
                return lhs.enabled && !rhs.enabled
            }
            if lhs.isBuiltin != rhs.isBuiltin {
                return lhs.isBuiltin && !rhs.isBuiltin
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func from(
        dict: [String: Any],
        statusesByID: [String: CoworkSchedulerStatus]
    ) -> CoworkSchedulerTask? {
        guard let id = dict["id"] as? String else { return nil }

        let status = statusesByID[id]
        let enabled = status?.enabled ?? (dict["enabled"] as? Bool ?? true)
        let kind = (dict["kind"] as? String ?? "builtin").lowercased()
        let failureStreak = dict["failure_streak"] as? Int ?? 0
        let lastError = dict["last_error"] as? String
        let nextRun = (dict["next_run"] as? Double).map { Date(timeIntervalSince1970: $0) }
            ?? (dict["nextRun"] as? String).flatMap(iso8601Date(from:))
        let lastRun = status?.lastRunAt
            ?? (dict["last_run"] as? Double).map { Date(timeIntervalSince1970: $0) }
            ?? (dict["lastRun"] as? String).flatMap(iso8601Date(from:))

        let name = (dict["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title(from: id)
        let scheduleDescription = scheduleDescription(
            for: id,
            legacySchedule: dict["schedule"],
            scheduleType: dict["scheduleType"] as? String,
            scheduleParams: dict["scheduleParams"] as? [String: Any]
        )

        return CoworkSchedulerTask(
            id: id,
            name: name,
            scheduleDescription: scheduleDescription,
            nextRun: nextRun,
            lastRun: lastRun,
            enabled: enabled,
            isBuiltin: kind == "builtin",
            failureStreak: failureStreak,
            lastError: lastError
        )
    }

    private static func scheduleDescription(
        for id: String,
        legacySchedule: Any?,
        scheduleType: String?,
        scheduleParams: [String: Any]?
    ) -> String {
        if let type = scheduleType {
            switch type {
            case "interval":
                if let minutes = scheduleParams?["minutes"] as? String {
                    return "Every \(minutes)m"
                }
                if let hours = scheduleParams?["hours"] as? String {
                    return "Every \(hours)h"
                }
                return "Interval"
            case "daily":
                let hour = scheduleParams?["hour"] as? String ?? "0"
                let minute = scheduleParams?["minute"] as? String ?? "0"
                return "Daily at \(hour):\(minute.count == 1 ? "0\(minute)" : minute)"
            case "weekly":
                let day = scheduleParams?["day"] as? String ?? "weekly"
                if let hour = scheduleParams?["hour"] as? String,
                   let minute = scheduleParams?["minute"] as? String
                {
                    return "Weekly \(day) at \(hour):\(minute.count == 1 ? "0\(minute)" : minute)"
                }
                return "Weekly \(day)"
            default:
                return type.capitalized
            }
        }

        if let dict = legacySchedule as? [String: Any] {
            if let interval = dict["Interval"] as? [String: Any], let secs = interval["secs"] as? Int {
                if secs >= 3600 {
                    let hours = max(1, secs / 3600)
                    return hours == 1 ? "Every hour" : "Every \(hours) hours"
                }
                let minutes = max(1, secs / 60)
                return minutes == 1 ? "Every minute" : "Every \(minutes) minutes"
            }
            if let daily = dict["Daily"] as? [String: Any],
               let hour = daily["hour"] as? Int,
               let minute = daily["min"] as? Int
            {
                return String(format: "Daily at %02d:%02d", hour, minute)
            }
            if let weekly = dict["Weekly"] as? [String: Any],
               let hour = weekly["hour"] as? Int,
               let minute = weekly["min"] as? Int
            {
                return String(format: "Weekly at %02d:%02d", hour, minute)
            }
        }

        return defaultScheduleDescription(for: id)
    }

    private static func defaultScheduleDescription(for id: String) -> String {
        switch id {
        case "memory_reflect", "check_fae_update":
            return "Every 6 hours"
        case "memory_reindex":
            return "Every 3 hours"
        case "memory_migrate":
            return "Hourly"
        case "skill_health_check":
            return "Every 5 minutes"
        case "memory_gc":
            return "Daily at 03:30"
        case "memory_backup":
            return "Daily at 02:00"
        case "noise_budget_reset":
            return "Daily at 00:00"
        case "morning_briefing":
            return "Daily morning briefing"
        case "skill_proposals":
            return "Daily skill review"
        case "stale_relationships":
            return "Weekly relationship review"
        default:
            return "Managed by Fae"
        }
    }

    private static func title(from identifier: String) -> String {
        identifier
            .split(separator: "_")
            .map { part in
                let lower = part.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func iso8601Date(from raw: String) -> Date? {
        ISO8601DateFormatter().date(from: raw)
    }
}

struct CoworkActivityItem: Identifiable, Sendable {
    enum Tone: Sendable {
        case neutral
        case success
        case warning
    }

    let id: UUID
    let title: String
    let detail: String
    let timestamp: Date
    let tone: Tone

    init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        timestamp: Date = Date(),
        tone: Tone = .neutral
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.timestamp = timestamp
        self.tone = tone
    }
}
