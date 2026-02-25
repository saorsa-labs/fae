import SwiftUI

/// A single scheduled task loaded from `scheduler.json`.
private struct ScheduledTaskItem: Identifiable {
    let id: String
    let name: String
    let scheduleDescription: String
    let nextRun: Date?
    let lastRun: Date?
    let enabled: Bool
    let isBuiltin: Bool
    let failureStreak: Int
    let lastError: String?
    /// Raw dict kept for sending `scheduler.update` back to the backend.
    let rawDict: [String: Any]

    static func load(from url: URL) -> [ScheduledTaskItem] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tasks = json["tasks"] as? [[String: Any]]
        else { return [] }
        return tasks.compactMap { Self.from(dict: $0) }
    }

    static func from(dict: [String: Any]) -> ScheduledTaskItem? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String
        else { return nil }

        let enabled = dict["enabled"] as? Bool ?? true
        let kind = dict["kind"] as? String ?? "Builtin"
        let failureStreak = dict["failure_streak"] as? Int ?? 0
        let lastError = dict["last_error"] as? String

        let nextRun = (dict["next_run"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let lastRun = (dict["last_run"] as? Double).map { Date(timeIntervalSince1970: $0) }

        let scheduleDesc = scheduleDescription(from: dict["schedule"])

        return ScheduledTaskItem(
            id: id, name: name,
            scheduleDescription: scheduleDesc,
            nextRun: nextRun, lastRun: lastRun,
            enabled: enabled,
            isBuiltin: kind == "Builtin",
            failureStreak: failureStreak,
            lastError: lastError,
            rawDict: dict
        )
    }

    private static func scheduleDescription(from schedule: Any?) -> String {
        guard let dict = schedule as? [String: Any] else { return "custom" }
        if let iv = dict["Interval"] as? [String: Any], let secs = iv["secs"] as? Int {
            if secs >= 86400 { return "daily" }
            if secs >= 3600 {
                let h = secs / 3600
                return h == 1 ? "every hour" : "every \(h) hours"
            }
            let m = secs / 60
            return m == 1 ? "every minute" : "every \(m) minutes"
        }
        if let d = dict["Daily"] as? [String: Any],
           let hour = d["hour"] as? Int, let min = d["min"] as? Int {
            return String(format: "daily at %02d:%02d", hour, min)
        }
        if let w = dict["Weekly"] as? [String: Any],
           let hour = w["hour"] as? Int, let min = w["min"] as? Int {
            let days = (w["weekdays"] as? [String] ?? []).joined(separator: ", ")
            return String(format: "weekly (%@) at %02d:%02d", days, hour, min)
        }
        return "custom"
    }
}

/// Settings tab: view and manage Fae's scheduled tasks.
struct SettingsSchedulesTab: View {
    let commandSender: HostCommandSender?

    @State private var tasks: [ScheduledTaskItem] = []
    @State private var triggeredIds: Set<String> = []

    private var schedulerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("fae/scheduler.json")
    }

    var body: some View {
        Form {
            Section {
                Text("Fae runs background tasks on a schedule — memory maintenance, briefings, health checks, and more. Built-in tasks can be triggered manually. User-created tasks can also be deleted.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if tasks.isEmpty {
                Section {
                    Text("No scheduled tasks found. Tasks appear here once Fae has started at least once.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                let builtinTasks = tasks.filter { $0.isBuiltin }
                let userTasks = tasks.filter { !$0.isBuiltin }

                if !builtinTasks.isEmpty {
                    Section("Built-in Tasks") {
                        ForEach(builtinTasks) { task in
                            taskRow(task)
                        }
                    }
                }

                if !userTasks.isEmpty {
                    Section("User Tasks") {
                        ForEach(userTasks) { task in
                            taskRow(task)
                        }
                        .onDelete { offsets in
                            for idx in offsets {
                                let t = userTasks[idx]
                                commandSender?.sendCommand(name: "scheduler.delete", payload: ["id": t.id])
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refresh() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    // MARK: - Task Row

    private func taskRow(_ task: ScheduledTaskItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text(task.scheduleDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(triggeredIds.contains(task.id) ? "✓ Triggered" : "Run Now") {
                    triggerTask(task)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(triggeredIds.contains(task.id))
            }

            HStack(spacing: 12) {
                if let next = task.nextRun {
                    Label {
                        Text("Next: \(next, style: .relative)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let last = task.lastRun {
                    Label {
                        Text("Last: \(last, style: .relative) ago")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "checkmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if task.failureStreak > 0 {
                    Label {
                        Text("\(task.failureStreak) failure\(task.failureStreak == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let err = task.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func triggerTask(_ task: ScheduledTaskItem) {
        commandSender?.sendCommand(name: "scheduler.trigger_now", payload: ["id": task.id])
        _ = withAnimation { triggeredIds.insert(task.id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { _ = self.triggeredIds.remove(task.id) }
        }
    }

    private func refresh() {
        tasks = ScheduledTaskItem.load(from: schedulerURL)
    }
}
