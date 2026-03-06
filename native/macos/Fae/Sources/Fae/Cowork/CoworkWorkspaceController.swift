import AppKit
import Foundation

@MainActor
final class CoworkWorkspaceController: ObservableObject {
    @Published var selectedSection: CoworkWorkspaceSection = .workspace
    @Published var draft: String = ""
    @Published private(set) var snapshot: CoworkWorkspaceSnapshot = .empty
    @Published private(set) var schedulerTasks: [CoworkSchedulerTask] = []
    @Published private(set) var activityItems: [CoworkActivityItem] = []
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var workspaceState: WorkWithFaeWorkspaceState = WorkWithFaeWorkspaceStore.load()
    @Published var workspaceSearchText: String = ""
    @Published private(set) var selectedWorkspaceFile: WorkWithFaeFileEntry?
    @Published private(set) var selectedAttachment: WorkWithFaeAttachment?
    @Published private(set) var focusedPreview: WorkWithFaePreview?
    @Published private(set) var providerKind: CoworkLLMProviderKind = .faeLocalhost
    @Published private(set) var providerStatus: String = "Connecting to Fae localhost"

    private let faeCore: FaeCore
    private let conversation: ConversationController
    private let chatProvider: (any CoworkLLMProvider)?
    private var observations: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var refreshTimer: Timer?

    init(faeCore: FaeCore, conversation: ConversationController, runtimeDescriptor: FaeLocalRuntimeDescriptor? = nil) {
        self.faeCore = faeCore
        self.conversation = conversation
        if let runtimeDescriptor {
            self.chatProvider = FaeLocalhostCoworkProvider(descriptor: runtimeDescriptor)
            self.providerKind = .faeLocalhost
            self.providerStatus = "Connected to Fae localhost"
        } else {
            self.chatProvider = nil
            self.providerKind = .faeLocalhost
            self.providerStatus = "Fae localhost unavailable — direct fallback active"
        }
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
        let preparedPrompt = WorkWithFaeWorkspaceStore.preparePrompt(
            userPrompt: prompt,
            state: workspaceState,
            focusedPreview: focusedPreview
        )
        draft = ""
        selectedSection = .workspace
        conversation.lastInteractionTimestamp = Date()

        Task { [weak self] in
            guard let self else { return }
            if let chatProvider = self.chatProvider {
                do {
                    let response = try await chatProvider.submit(
                        request: CoworkProviderRequest(
                            model: "fae-agent-local",
                            preparedPrompt: preparedPrompt
                        )
                    )
                    await MainActor.run {
                        self.providerStatus = response.status == "completed"
                            ? "Connected to Fae localhost"
                            : "Fae localhost status: \(response.status)"
                        self.prependActivity(
                            title: "Prompt sent via Fae localhost",
                            detail: prompt,
                            tone: .neutral
                        )
                    }
                    return
                } catch {
                    await MainActor.run {
                        self.providerStatus = "Fae localhost unavailable — direct fallback active"
                    }
                }
            }

            await MainActor.run {
                self.conversation.appendMessage(role: .user, content: prompt)
                self.faeCore.injectDesktopText(preparedPrompt.faeLocalPrompt)
                self.prependActivity(
                    title: "Prompt sent",
                    detail: prompt,
                    tone: .neutral
                )
            }
        }
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

    func createTask(
        name: String,
        scheduleType: String,
        scheduleParams: [String: String],
        action: String,
        allowedTools: [String]
    ) {
        let payload: [String: Any] = [
            "name": name,
            "scheduleType": scheduleType,
            "scheduleParams": scheduleParams,
            "action": action,
            "allowedTools": allowedTools,
        ]
        faeCore.sendCommand(name: "scheduler.create", payload: payload)
        prependActivity(
            title: "Scheduler task created",
            detail: name,
            tone: .success
        )
        scheduleRefresh(after: 0.35)
    }

    func deleteTask(_ task: CoworkSchedulerTask) {
        guard !task.isBuiltin else {
            prependActivity(
                title: "Built-in task protected",
                detail: "Pause \(task.name) instead of deleting it.",
                tone: .warning
            )
            return
        }

        faeCore.sendCommand(name: "scheduler.delete", payload: ["id": task.id])
        schedulerTasks.removeAll { $0.id == task.id }
        prependActivity(
            title: "Scheduler task deleted",
            detail: task.name,
            tone: .warning
        )
    }

    func updateTask(
        _ task: CoworkSchedulerTask,
        name: String,
        scheduleType: String,
        scheduleParams: [String: String],
        action: String,
        allowedTools: [String]
    ) {
        let payload: [String: Any] = [
            "id": task.id,
            "name": name,
            "scheduleType": scheduleType,
            "scheduleParams": scheduleParams,
            "action": action,
            "allowedTools": allowedTools,
        ]
        faeCore.sendCommand(name: "scheduler.update", payload: payload)
        prependActivity(
            title: "Scheduler updated",
            detail: name,
            tone: .success
        )
        scheduleRefresh(after: 0.35)
    }

    func openSettings() {
        NotificationCenter.default.post(name: .faeOpenSettingsRequested, object: nil)
    }

    func chooseWorkspaceDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.title = "Choose a workspace folder"
        if panel.runModal() == .OK, let url = panel.url {
            setWorkspaceDirectory(url)
        }
    }

    func setWorkspaceDirectory(_ url: URL) {
        workspaceState.selectedDirectoryPath = url.standardizedFileURL.path
        workspaceState.indexedFiles = WorkWithFaeWorkspaceStore.scanDirectory(url)
        selectedAttachment = nil
        selectedWorkspaceFile = workspaceState.indexedFiles.first
        focusedPreview = selectedWorkspaceFile.map(WorkWithFaeWorkspaceStore.preview(for:))
        persistWorkspaceState()
        prependActivity(
            title: "Workspace selected",
            detail: url.lastPathComponent,
            tone: .success
        )
    }

    func clearWorkspaceDirectory() {
        workspaceState.selectedDirectoryPath = nil
        workspaceState.indexedFiles = []
        selectedWorkspaceFile = nil
        if selectedAttachment == nil {
            focusedPreview = nil
        }
        persistWorkspaceState()
        prependActivity(title: "Workspace cleared", detail: "Folder context removed", tone: .warning)
    }

    func addAttachmentsViaPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.title = "Add files to Work with Fae"
        if panel.runModal() == .OK {
            addAttachments(from: panel.urls)
        }
    }

    func addAttachments(from urls: [URL]) {
        let newItems = WorkWithFaeWorkspaceStore.attachments(from: urls)
        guard !newItems.isEmpty else { return }
        workspaceState.attachments.append(contentsOf: newItems)
        if let first = newItems.first {
            selectAttachment(first)
        } else {
            persistWorkspaceState()
        }
        prependActivity(
            title: "Added attachments",
            detail: newItems.map(\.displayName).joined(separator: ", "),
            tone: .success
        )
    }

    func addPastedContent() {
        let pasteboard = NSPasteboard.general

        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !fileURLs.isEmpty {
            addAttachments(from: fileURLs)
            return
        }

        if let image = NSImage(pasteboard: pasteboard),
           let attachment = WorkWithFaeWorkspaceStore.attachmentFromPasteboardImage(image)
        {
            workspaceState.attachments.append(attachment)
            selectAttachment(attachment)
            prependActivity(title: "Pasted image", detail: attachment.displayName, tone: .success)
            return
        }

        if let text = pasteboard.string(forType: .string),
           let attachment = WorkWithFaeWorkspaceStore.textAttachment(text)
        {
            workspaceState.attachments.append(attachment)
            selectAttachment(attachment)
            prependActivity(title: "Pasted text", detail: attachment.displayName, tone: .success)
        }
    }

    func removeAttachment(id: UUID) {
        workspaceState.attachments.removeAll { $0.id == id }
        if selectedAttachment?.id == id {
            selectedAttachment = nil
            focusedPreview = selectedWorkspaceFile.map(WorkWithFaeWorkspaceStore.preview(for:))
        }
        persistWorkspaceState()
    }

    func selectWorkspaceFile(_ file: WorkWithFaeFileEntry) {
        selectedAttachment = nil
        selectedWorkspaceFile = file
        focusedPreview = WorkWithFaeWorkspaceStore.preview(for: file)
    }

    func selectAttachment(_ attachment: WorkWithFaeAttachment) {
        selectedWorkspaceFile = nil
        selectedAttachment = attachment
        focusedPreview = WorkWithFaeWorkspaceStore.preview(for: attachment)
        persistWorkspaceState()
    }

    func inspectScreen() {
        useQuickPrompt("Please use the screenshot tool to look at my current screen and help me with what is visible.")
    }

    func inspectCamera() {
        useQuickPrompt("Please use the camera tool now and tell me what you see.")
    }

    func toggleThinking() {
        faeCore.setThinkingEnabled(!faeCore.thinkingEnabled)
        scheduleRefresh(after: 0.1)
    }

    func createSkill(name: String, description: String, body: String) {
        Task {
            do {
                _ = try await SkillManager().createSkill(name: name, description: description, body: body)
                prependActivity(title: "Skill created", detail: name, tone: .success)
                faeCore.sendCommand(name: "skills.reload", payload: [:])
                scheduleRefresh(after: 0.35)
            } catch {
                prependActivity(title: "Skill creation failed", detail: error.localizedDescription, tone: .warning)
            }
        }
    }

    func updateSkill(name: String, description: String, body: String) {
        Task {
            do {
                _ = try await SkillManager().updateSkill(name: name, description: description, body: body)
                prependActivity(title: "Skill updated", detail: name, tone: .success)
                faeCore.sendCommand(name: "skills.reload", payload: [:])
                scheduleRefresh(after: 0.35)
            } catch {
                prependActivity(title: "Skill update failed", detail: error.localizedDescription, tone: .warning)
            }
        }
    }

    func deleteSkill(name: String) {
        Task {
            do {
                try await SkillManager().deleteSkill(name: name)
                prependActivity(title: "Skill removed", detail: name, tone: .warning)
                faeCore.sendCommand(name: "skills.reload", payload: [:])
                scheduleRefresh(after: 0.35)
            } catch {
                prependActivity(title: "Skill removal failed", detail: error.localizedDescription, tone: .warning)
            }
        }
    }

    var filteredWorkspaceFiles: [WorkWithFaeFileEntry] {
        WorkWithFaeWorkspaceStore.filteredFiles(workspaceState.indexedFiles, query: workspaceSearchText)
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

    private func persistWorkspaceState() {
        WorkWithFaeWorkspaceStore.save(workspaceState)
    }
}
