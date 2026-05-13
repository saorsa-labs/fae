import Foundation

// MARK: - TillDone Manager

/// Session-scoped task manager for complex multi-step work.
///
/// Holds an ordered list of tasks with a three-state lifecycle: idle → inprogress → done.
/// Only one task can be "inprogress" at a time — starting a new task auto-pauses any active one.
/// Persists nothing across app restarts (session-scoped by design).
actor TillDoneManager {
    static let shared = TillDoneManager()

    enum TaskStatus: String, Codable, Sendable {
        case idle
        case inprogress
        case done
        case skipped
    }

    struct TaskItem: Sendable {
        let id: Int
        var text: String
        var status: TaskStatus
        var result: String?
        /// Number of times this task has been started (attempt counter).
        var attempts: Int = 0
        /// Brief descriptions of what was tried and why it failed.
        var failureLog: [String] = []
    }

    private var tasks: [TaskItem] = []
    /// Number of consecutive nudges fired without a task completing.
    private(set) var consecutiveNudges: Int = 0
    private var nextId = 1
    private(set) var listTitle: String?
    private(set) var listDescription: String?

    // MARK: - Queries

    var hasActiveTasks: Bool {
        !tasks.isEmpty && tasks.contains { $0.status != .done && $0.status != .skipped }
    }

    var hasIncompleteTasks: Bool {
        !tasks.isEmpty && tasks.contains { $0.status == .idle || $0.status == .inprogress }
    }

    var isListActive: Bool {
        !tasks.isEmpty
    }

    var currentTask: TaskItem? {
        tasks.first { $0.status == .inprogress }
    }

    var allDone: Bool {
        !tasks.isEmpty && tasks.allSatisfy { $0.status == .done || $0.status == .skipped }
    }

    var incompleteSummary: String {
        let incomplete = tasks.filter { $0.status == .idle || $0.status == .inprogress }
        return incomplete.map { task in
            let icon = task.status == .inprogress ? "●" : "○"
            return "\(icon) #\(task.id) [\(task.status.rawValue)]: \(task.text)"
        }.joined(separator: "\n")
    }

    var progressSummary: String {
        let done = tasks.filter { $0.status == .done }.count
        let total = tasks.count
        let title = listTitle ?? "TillDone"
        return "\(title): \(done)/\(total) complete"
    }

    // MARK: - Mutations

    func newList(title: String, description: String?) -> String {
        tasks = []
        nextId = 1
        listTitle = title
        listDescription = description
        return "New list: \"\(title)\"\(description.map { " — \($0)" } ?? "")"
    }

    func addTasks(_ texts: [String]) -> String {
        var added: [TaskItem] = []
        for text in texts {
            let task = TaskItem(id: nextId, text: text, status: .idle)
            nextId += 1
            tasks.append(task)
            added.append(task)
        }
        if added.count == 1 {
            return "Added task #\(added[0].id): \(added[0].text)"
        }
        return "Added \(added.count) tasks: \(added.map { "#\($0.id)" }.joined(separator: ", "))"
    }

    func startTask(id: Int) -> String {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else {
            return "Task #\(id) not found"
        }

        // Auto-pause any currently active task.
        var demoted: [Int] = []
        for i in tasks.indices where tasks[i].status == .inprogress && tasks[i].id != id {
            tasks[i].status = .idle
            demoted.append(tasks[i].id)
        }

        let prev = tasks[idx].status
        tasks[idx].status = .inprogress
        tasks[idx].attempts += 1
        consecutiveNudges = 0
        var msg = "Task #\(id): \(prev.rawValue) → inprogress — \(tasks[idx].text)"
        if tasks[idx].attempts > 1 {
            msg += " (attempt #\(tasks[idx].attempts))"
        }
        if !tasks[idx].failureLog.isEmpty {
            msg += "\nPrevious attempts that failed:"
            for entry in tasks[idx].failureLog {
                msg += "\n  - \(entry)"
            }
            msg += "\nYou MUST try a DIFFERENT approach this time."
        }
        if !demoted.isEmpty {
            msg += "\n(Auto-paused \(demoted.map { "#\($0)" }.joined(separator: ", ")) → idle)"
        }
        return msg
    }

    func completeTask(id: Int, result: String?) -> String {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else {
            return "Task #\(id) not found"
        }
        tasks[idx].status = .done
        tasks[idx].result = result
        consecutiveNudges = 0
        let remaining = tasks.filter { $0.status == .idle || $0.status == .inprogress }.count
        var msg = "Task #\(id) done: \(tasks[idx].text)"
        if let result { msg += "\nResult: \(result)" }
        msg += "\n\(remaining) task(s) remaining"
        if remaining == 0 {
            msg += "\nAll tasks complete! Use till_done report to generate the final summary."
        }
        return msg
    }

    func skipTask(id: Int, reason: String?) -> String {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else {
            return "Task #\(id) not found"
        }
        tasks[idx].status = .skipped
        tasks[idx].result = reason
        return "Task #\(id) skipped: \(tasks[idx].text)\(reason.map { " — \($0)" } ?? "")"
    }

    func updateTask(id: Int, text: String) -> String {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else {
            return "Task #\(id) not found"
        }
        let old = tasks[idx].text
        tasks[idx].text = text
        return "Updated #\(id): \"\(old)\" → \"\(text)\""
    }

    func removeTask(id: Int) -> String {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else {
            return "Task #\(id) not found"
        }
        let removed = tasks.remove(at: idx)
        return "Removed task #\(removed.id): \(removed.text)"
    }

    func listTasks() -> String {
        guard !tasks.isEmpty else { return "No tasks defined yet." }
        let header = listTitle.map { "\($0):" } ?? "TillDone:"
        let done = tasks.filter { $0.status == .done }.count
        let active = tasks.filter { $0.status == .inprogress }.count
        let idle = tasks.filter { $0.status == .idle }.count
        let skipped = tasks.filter { $0.status == .skipped }.count

        var lines = ["\(header) \(done)/\(tasks.count) done (\(active) active, \(idle) idle, \(skipped) skipped)"]
        for task in tasks {
            let icon: String
            switch task.status {
            case .done: icon = "✓"
            case .inprogress: icon = "●"
            case .idle: icon = "○"
            case .skipped: icon = "⊘"
            }
            var line = "\(icon) #\(task.id) [\(task.status.rawValue)]: \(task.text)"
            if let result = task.result { line += " → \(result)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    func generateReport() -> String {
        guard !tasks.isEmpty else { return "No tasks to report on." }
        let title = listTitle ?? "Task Report"
        let done = tasks.filter { $0.status == .done }.count
        let skipped = tasks.filter { $0.status == .skipped }.count
        let total = tasks.count

        var md = "# \(title)\n\n"
        if let desc = listDescription {
            md += "\(desc)\n\n"
        }
        md += "**Status: \(done)/\(total) completed"
        if skipped > 0 { md += ", \(skipped) skipped" }
        md += "**\n\n"

        for task in tasks {
            let icon: String
            switch task.status {
            case .done: icon = "✅"
            case .inprogress: icon = "🔄"
            case .idle: icon = "⬜"
            case .skipped: icon = "⏭️"
            }
            md += "### \(icon) \(task.text)\n"
            if let result = task.result {
                md += "\(result)\n"
            }
            md += "\n"
        }

        return md
    }

    /// Generate an HTML report for the canvas.
    func generateHTMLReport() -> String {
        guard !tasks.isEmpty else { return "" }
        let title = listTitle ?? "Task Report"
        let done = tasks.filter { $0.status == .done }.count
        let skipped = tasks.filter { $0.status == .skipped }.count
        let total = tasks.count

        var html = """
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 20px;
                 background: transparent; color: #e0e0e0; }
          h1 { color: #fff; font-size: 18px; margin-bottom: 4px; }
          .subtitle { color: #888; font-size: 13px; margin-bottom: 16px; }
          .progress { background: #333; border-radius: 6px; height: 8px; margin-bottom: 16px; overflow: hidden; }
          .progress-fill { background: linear-gradient(90deg, #4ade80, #22d3ee);
                           height: 100%; border-radius: 6px; transition: width 0.3s; }
          .task { padding: 8px 12px; margin: 4px 0; border-radius: 8px; background: #1a1a2e; }
          .task.done { border-left: 3px solid #4ade80; }
          .task.inprogress { border-left: 3px solid #fbbf24; }
          .task.idle { border-left: 3px solid #555; }
          .task.skipped { border-left: 3px solid #888; opacity: 0.6; }
          .task-title { font-weight: 600; font-size: 13px; }
          .task-result { color: #aaa; font-size: 12px; margin-top: 4px; }
          .icon { margin-right: 6px; }
        </style>
        <h1>\(Self.escapeHTML(title))</h1>
        """

        if let desc = listDescription {
            html += "<div class=\"subtitle\">\(Self.escapeHTML(desc))</div>"
        }

        let pct = total > 0 ? Int(Double(done) / Double(total) * 100) : 0
        html += """
        <div class="subtitle">\(done)/\(total) completed\(skipped > 0 ? ", \(skipped) skipped" : "")</div>
        <div class="progress"><div class="progress-fill" style="width: \(pct)%"></div></div>
        """

        for task in tasks {
            let (icon, cls): (String, String)
            switch task.status {
            case .done: (icon, cls) = ("✅", "done")
            case .inprogress: (icon, cls) = ("🔄", "inprogress")
            case .idle: (icon, cls) = ("⬜", "idle")
            case .skipped: (icon, cls) = ("⏭️", "skipped")
            }
            html += "<div class=\"task \(cls)\">"
            html += "<span class=\"icon\">\(icon)</span>"
            html += "<span class=\"task-title\">\(Self.escapeHTML(task.text))</span>"
            if let result = task.result {
                html += "<div class=\"task-result\">\(Self.escapeHTML(result))</div>"
            }
            html += "</div>"
        }

        return html
    }

    func clear() -> String {
        let count = tasks.count
        tasks = []
        nextId = 1
        listTitle = nil
        listDescription = nil
        consecutiveNudges = 0
        return "Cleared \(count) task(s)"
    }

    /// The next idle task to suggest (auto-advance).
    var nextIdleTask: TaskItem? {
        tasks.first { $0.status == .idle }
    }

    /// Record a nudge firing (for escalation tracking).
    func recordNudge() {
        consecutiveNudges += 1
    }

    /// Log a failure on the current inprogress task so the nudge can report what was tried.
    func logFailureOnCurrentTask(_ description: String) {
        guard let idx = tasks.firstIndex(where: { $0.status == .inprogress }) else { return }
        let trimmed = String(description.prefix(200))
        tasks[idx].failureLog.append(trimmed)
    }

    /// Context for the nudge: what the current task is, how many attempts, and what failed.
    var currentTaskContext: String {
        guard let task = tasks.first(where: { $0.status == .inprogress }) else {
            return "No task is currently inprogress."
        }
        var ctx = "Current task: #\(task.id) \"\(task.text)\" (attempt #\(task.attempts))"
        if !task.failureLog.isEmpty {
            ctx += "\nWhat was already tried and failed:"
            for entry in task.failureLog {
                ctx += "\n  - \(entry)"
            }
        }
        return ctx
    }

    /// Whether the current inprogress task is stalled (3+ attempts).
    var currentTaskStalled: Bool {
        guard let task = tasks.first(where: { $0.status == .inprogress }) else { return false }
        return task.attempts >= 3
    }

    // MARK: - Private

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - TillDone Tool

struct TillDoneTool: Tool {
    let name = "till_done"
    let description = """
        Manage a task list for complex multi-step work. You MUST create a task list \
        before starting complex work (research, coding, setup, reports). \
        Actions: new_list (title + description), add (text or texts for batch), \
        start (id — mark inprogress), complete (id + result summary), skip (id + reason), \
        log_failure (text — record what you tried and why it failed on the current task), \
        update (id + text), remove (id), list, report (final summary), clear. \
        Always start a task before working on it, and complete it with a result when done. \
        Only one task can be inprogress at a time. When something fails, use log_failure \
        before trying a different approach.
        """
    let parametersSchema = """
        {"action":{"type":"string","description":"new_list, add, start, complete, skip, log_failure, update, remove, list, report, clear","required":true},\
        "text":{"type":"string","description":"Task text (for add/update), or list title (for new_list)"},\
        "texts":{"type":"array","description":"Multiple task texts for batch add"},\
        "description":{"type":"string","description":"List description (for new_list)"},\
        "id":{"type":"integer","description":"Task ID (for start/complete/skip/update/remove)"},\
        "result":{"type":"string","description":"Result summary (for complete) or reason (for skip)"}}
        """
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .low
    let example = #"""
        <tool_call>{"name":"till_done","arguments":{"action":"new_list","text":"Discord Setup","description":"Set up Discord server for the project"}}</tool_call>
        """#

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let action = input["action"] as? String else {
            return .error("Missing required parameter: action")
        }

        let manager = TillDoneManager.shared
        let text = input["text"] as? String
        let texts = input["texts"] as? [String]
        let description = input["description"] as? String
        let id = (input["id"] as? NSNumber)?.intValue ?? (input["id"] as? Int)
        let result = input["result"] as? String

        switch action {
        case "new_list":
            guard let title = text else {
                return .error("Missing required parameter: text (list title)")
            }
            let msg = await manager.newList(title: title, description: description)
            return .success(msg)

        case "add":
            let items: [String]
            if let texts, !texts.isEmpty {
                items = texts
            } else if let text {
                items = [text]
            } else {
                return .error("Missing required parameter: text or texts")
            }
            let msg = await manager.addTasks(items)
            return .success(msg)

        case "start":
            guard let taskId = id else {
                return .error("Missing required parameter: id")
            }
            let msg = await manager.startTask(id: taskId)
            return .success(msg)

        case "complete":
            guard let taskId = id else {
                return .error("Missing required parameter: id")
            }
            let msg = await manager.completeTask(id: taskId, result: result)
            return .success(msg)

        case "skip":
            guard let taskId = id else {
                return .error("Missing required parameter: id")
            }
            let msg = await manager.skipTask(id: taskId, reason: result)
            return .success(msg)

        case "log_failure":
            guard let failureText = text else {
                return .error("Missing required parameter: text (what you tried and why it failed)")
            }
            await manager.logFailureOnCurrentTask(failureText)
            let ctx = await manager.currentTaskContext
            return .success("Failure logged. \(ctx)\nNow try a DIFFERENT approach.")

        case "update":
            guard let taskId = id, let newText = text else {
                return .error("Missing required parameters: id and text")
            }
            let msg = await manager.updateTask(id: taskId, text: newText)
            return .success(msg)

        case "remove":
            guard let taskId = id else {
                return .error("Missing required parameter: id")
            }
            let msg = await manager.removeTask(id: taskId)
            return .success(msg)

        case "list":
            let msg = await manager.listTasks()
            return .success(msg)

        case "report":
            let md = await manager.generateReport()
            return .success(md)

        case "clear":
            let msg = await manager.clear()
            return .success(msg)

        default:
            return .error("Unknown action: \(action). Use: new_list, add, start, complete, skip, log_failure, update, remove, list, report, clear")
        }
    }
}
