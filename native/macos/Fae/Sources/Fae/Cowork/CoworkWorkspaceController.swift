import Foundation

@MainActor
final class CoworkWorkspaceController: ObservableObject {
    @Published var selectedSection: CoworkWorkspaceSection = .workspace
    @Published var draft: String = ""
    @Published private(set) var snapshot: CoworkWorkspaceSnapshot = .empty
    @Published private(set) var schedulerTasks: [CoworkSchedulerTask] = []
    @Published private(set) var activityItems: [CoworkActivityItem] = []
    @Published private(set) var isRefreshing: Bool = false

    private let faeCore: FaeCore
    private let conversation: ConversationController
    private var observations: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var refreshTimer: Timer?

    init(faeCore: FaeCore, conversation: ConversationController) {
        self.faeCore = faeCore
        self.conversation = conversation
        installObservers()
        schedulePeriodicRefresh()
        refreshNow()
    }

    deinit {
        observations.forEach(NotificationCenter.default.removeObserver)
        refreshTimer?.invalidate()
        refreshTask?.cancel()
    }

    func refreshNow() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    func scheduleRefresh(after delay: TimeInterval = 0.25) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let nanos = max(0, UInt64(delay * 1_000_000_000))
            if nanos > 0 {
                try? await Task.sleep(nanoseconds: nanos)
            }
            await self.refresh()
        }
    }

    func submitDraft() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        draft = ""
        selectedSection = .workspace
        conversation.lastInteractionTimestamp = Date()
        conversation.appendMessage(role: .user, content: prompt)
        faeCore.injectDesktopText(prompt)
        prependActivity(
            title: "Prompt sent",
            detail: prompt,
            tone: .neutral
        )
    }

    func useQuickPrompt(_ text: String) {
        draft = text
        submitDraft()
    }

    func setTask(_ task: CoworkSchedulerTask, enabled: Bool) {
        faeCore.sendCommand(name: "scheduler.set_enabled", payload: ["id": task.id, "enabled": enabled])
        if let index = schedulerTasks.firstIndex(where: { $0.id == task.id }) {
            schedulerTasks[index].enabled = enabled
        }
        prependActivity(
            title: enabled ? "Scheduler enabled" : "Scheduler paused",
            detail: task.name,
            tone: enabled ? .success : .warning
        )
        scheduleRefresh(after: 0.35)
    }

    func runTask(_ task: CoworkSchedulerTask) {
        faeCore.sendCommand(name: "scheduler.trigger_now", payload: ["id": task.id])
        prependActivity(
            title: "Scheduler run requested",
            detail: task.name,
            tone: .success
        )
        scheduleRefresh(after: 0.5)
    }

    func runTask(id: String) {
        faeCore.sendCommand(name: "scheduler.trigger_now", payload: ["id": id])
        prependActivity(
            title: "Scheduler run requested",
            detail: CoworkToolSummary.displayName(for: id),
            tone: .success
        )
        scheduleRefresh(after: 0.5)
    }

    func openSettings() {
        NotificationCenter.default.post(name: .faeOpenSettingsRequested, object: nil)
    }

    func toggleThinking() {
        faeCore.setThinkingEnabled(!faeCore.thinkingEnabled)
        scheduleRefresh(after: 0.1)
    }

    private func refresh() async {
        isRefreshing = true
        let snapshot = await faeCore.coworkWorkspaceSnapshot()
        let schedulerTasks = await Task.detached(priority: .utility) {
            CoworkSchedulerTask.load(statusesByID: snapshot.schedulerStatusesByID)
        }.value
        self.snapshot = snapshot
        self.schedulerTasks = schedulerTasks
        isRefreshing = false
    }

    private func installObservers() {
        let center = NotificationCenter.default

        observations.append(
            center.addObserver(
                forName: .faeToolExecution,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleToolEvent(notification.userInfo ?? [:])
                }
            }
        )

        observations.append(
            center.addObserver(
                forName: .faeRuntimeState,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let event = notification.userInfo?["event"] as? String else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.prependActivity(
                        title: "Runtime \(event.replacingOccurrences(of: "runtime.", with: ""))",
                        detail: "Cowork surface refreshed",
                        tone: event == "runtime.error" ? .warning : .neutral
                    )
                    self.scheduleRefresh(after: 0.05)
                }
            }
        )

        observations.append(
            center.addObserver(
                forName: .faePipelineState,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let event = notification.userInfo?["event"] as? String else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if event.hasPrefix("scheduler.") || event == "pipeline.model_selected" {
                        self.scheduleRefresh(after: 0.05)
                    }
                }
            }
        )
    }

    private func schedulePeriodicRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh(after: 0.05)
            }
        }
        refreshTimer?.tolerance = 5
    }

    private func handleToolEvent(_ userInfo: [AnyHashable: Any]) {
        let type = userInfo["type"] as? String ?? "executing"
        let name = (userInfo["name"] as? String).map(CoworkToolSummary.displayName(for:)) ?? "Tool"

        switch type {
        case "call":
            let detail = (userInfo["input_json"] as? String).map { truncate($0) } ?? "Preparing tool call"
            prependActivity(title: "\(name) call", detail: detail, tone: .neutral)
        case "result":
            let success = userInfo["success"] as? Bool ?? true
            let detail = (userInfo["output_text"] as? String).map { truncate($0) } ?? (success ? "Completed" : "Failed")
            prependActivity(
                title: success ? "\(name) completed" : "\(name) failed",
                detail: detail,
                tone: success ? .success : .warning
            )
        default:
            prependActivity(title: "\(name) running", detail: "Execution started", tone: .neutral)
        }

        if let rawName = userInfo["name"] as? String,
           rawName.hasPrefix("scheduler_")
        {
            scheduleRefresh(after: 0.35)
        }
    }

    private func prependActivity(title: String, detail: String, tone: CoworkActivityItem.Tone) {
        let item = CoworkActivityItem(title: title, detail: detail, tone: tone)
        activityItems.insert(item, at: 0)
        if activityItems.count > 18 {
            activityItems.removeLast(activityItems.count - 18)
        }
    }

    private func truncate(_ value: String, limit: Int = 160) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "..."
    }
}
