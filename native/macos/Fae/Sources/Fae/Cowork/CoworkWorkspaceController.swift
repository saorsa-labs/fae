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
    @Published private(set) var workspaceRegistry: WorkWithFaeWorkspaceRegistry = WorkWithFaeWorkspaceStore.loadRegistry()
    @Published private(set) var workspaceState: WorkWithFaeWorkspaceState = WorkWithFaeWorkspaceStore.load()
    @Published var workspaceSearchText: String = ""
    @Published private(set) var selectedWorkspaceFile: WorkWithFaeFileEntry?
    @Published private(set) var selectedAttachment: WorkWithFaeAttachment?
    @Published private(set) var focusedPreview: WorkWithFaePreview?
    @Published private(set) var providerKind: CoworkLLMProviderKind = .faeLocalhost
    @Published private(set) var providerStatus: String = "Connecting to Fae localhost"
    @Published private(set) var latestConsensusResults: [WorkWithFaeConsensusResult] = []

    private let faeCore: FaeCore
    private let conversation: ConversationController
    private let runtimeDescriptor: FaeLocalRuntimeDescriptor?
    private let chatProvider: (any CoworkLLMProvider)?
    private var observations: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var refreshTimer: Timer?

    init(faeCore: FaeCore, conversation: ConversationController, runtimeDescriptor: FaeLocalRuntimeDescriptor? = nil) {
        self.faeCore = faeCore
        self.conversation = conversation
        self.runtimeDescriptor = runtimeDescriptor
        if let runtimeDescriptor {
            self.chatProvider = FaeLocalhostCoworkProvider(descriptor: runtimeDescriptor)
        } else {
            self.chatProvider = nil
        }
        self.workspaceRegistry = WorkWithFaeWorkspaceStore.loadRegistry()
        self.workspaceState = WorkWithFaeWorkspaceStore.selectedWorkspace(in: self.workspaceRegistry)?.state ?? .empty
        installObservers()
        schedulePeriodicRefresh()
        applySelectedWorkspaceState()
        refreshNow()
    }

    deinit {
        observations.forEach(NotificationCenter.default.removeObserver)
        refreshTimer?.invalidate()
        refreshTask?.cancel()
    }

    var workspaces: [WorkWithFaeWorkspaceRecord] {
        workspaceRegistry.workspaces.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    var agents: [WorkWithFaeAgentProfile] {
        workspaceRegistry.agents.sorted { lhs, rhs in
            if lhs.isTrustedLocal != rhs.isTrustedLocal {
                return lhs.isTrustedLocal && !rhs.isTrustedLocal
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var backendPresets: [CoworkBackendPreset] {
        CoworkBackendPresetCatalog.presets
    }

    var selectedWorkspace: WorkWithFaeWorkspaceRecord? {
        WorkWithFaeWorkspaceStore.selectedWorkspace(in: workspaceRegistry)
    }

    var selectedAgent: WorkWithFaeAgentProfile? {
        WorkWithFaeWorkspaceStore.selectedAgent(in: workspaceRegistry)
    }

    var selectedWorkspacePolicy: WorkWithFaeWorkspacePolicy {
        selectedWorkspace?.policy ?? .default
    }

    var executionAgent: WorkWithFaeAgentProfile? {
        WorkWithFaeWorkspaceStore.executionAgent(in: workspaceRegistry)
    }

    var isStrictLocalWorkspace: Bool {
        selectedWorkspacePolicy.remoteExecution == .strictLocalOnly
    }

    var remoteAgentBlockedByPolicy: Bool {
        isStrictLocalWorkspace && selectedAgent?.isTrustedLocal == false
    }

    var consensusParticipants: [WorkWithFaeAgentProfile] {
        WorkWithFaeWorkspaceStore.consensusAgents(
            selectedAgentID: selectedAgent?.id,
            agents: agents,
            policy: selectedWorkspacePolicy,
            limit: 4
        )
    }

    var canCompareAcrossAgents: Bool {
        consensusParticipants.count > 1
    }

    var usesAutomaticConsensusSelection: Bool {
        selectedWorkspacePolicy.usesAutomaticConsensusSelection
    }

    var selectedConsensusParticipantsSummary: String {
        if usesAutomaticConsensusSelection {
            return isStrictLocalWorkspace ? "Automatic — Fae Local only" : "Automatic — best available agents"
        }
        let selectedNames = selectedWorkspacePolicy.consensusAgentIDs.compactMap { id in
            agents.first(where: { $0.id == id })?.name
        }
        return selectedNames.isEmpty ? "No participants selected" : selectedNames.joined(separator: ", ")
    }

    func isConsensusParticipantSelected(_ agent: WorkWithFaeAgentProfile) -> Bool {
        if usesAutomaticConsensusSelection {
            return consensusParticipants.contains(where: { $0.id == agent.id })
        }
        return selectedWorkspacePolicy.consensusAgentIDs.contains(agent.id)
    }

    var shouldCompareOnSubmit: Bool {
        selectedWorkspacePolicy.compareBehavior == .alwaysCompare && canCompareAcrossAgents
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

        if shouldCompareOnSubmit {
            runConsensus(prompt: prompt, preparedPrompt: preparedPrompt, triggeredAutomatically: true)
            return
        }

        runSingleAgentSubmission(prompt: prompt, preparedPrompt: preparedPrompt)
    }

    func compareDraftAcrossAgents() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        let preparedPrompt = WorkWithFaeWorkspaceStore.preparePrompt(
            userPrompt: prompt,
            state: workspaceState,
            focusedPreview: focusedPreview
        )

        guard canCompareAcrossAgents else {
            let detail = isStrictLocalWorkspace
                ? "This workspace is set to strict local only, so remote agents stay out of the loop."
                : "Add at least one more agent to compare answers."
            prependActivity(title: "Comparison unavailable", detail: detail, tone: .warning)
            return
        }

        runConsensus(prompt: prompt, preparedPrompt: preparedPrompt, triggeredAutomatically: false)
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

    func createWorkspace(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let workspace = WorkWithFaeWorkspaceRecord(
            name: trimmed,
            agentID: selectedAgent?.id ?? WorkWithFaeAgentProfile.faeLocal.id,
            policy: selectedWorkspace?.policy ?? .default
        )
        workspaceRegistry.workspaces.append(workspace)
        workspaceRegistry.selectedWorkspaceID = workspace.id
        persistWorkspaceRegistry()
        applySelectedWorkspaceState()
        prependActivity(title: "Workspace created", detail: trimmed, tone: .success)
    }

    func selectWorkspace(_ workspace: WorkWithFaeWorkspaceRecord) {
        workspaceRegistry.selectedWorkspaceID = workspace.id
        persistWorkspaceRegistry()
        applySelectedWorkspaceState()
        prependActivity(title: "Workspace switched", detail: workspace.name, tone: .neutral)
    }

    func renameSelectedWorkspace(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != selectedWorkspace?.name
        else { return }
        workspaceRegistry = WorkWithFaeWorkspaceStore.registryByUpdatingWorkspaceName(
            workspaceID: selectedWorkspace?.id,
            name: trimmed,
            in: workspaceRegistry
        )
        persistWorkspaceRegistry()
        applySelectedWorkspaceState()
        prependActivity(title: "Workspace renamed", detail: trimmed, tone: .success)
    }

    func duplicateSelectedWorkspace() {
        guard selectedWorkspace != nil else { return }
        workspaceRegistry = WorkWithFaeWorkspaceStore.registryByDuplicatingWorkspace(
            workspaceID: selectedWorkspace?.id,
            in: workspaceRegistry
        )
        persistWorkspaceRegistry()
        applySelectedWorkspaceState()
        prependActivity(title: "Workspace duplicated", detail: selectedWorkspace?.name ?? "Workspace copy", tone: .success)
    }

    func deleteSelectedWorkspace() {
        guard let selectedWorkspace else { return }
        guard workspaceRegistry.workspaces.count > 1 else {
            prependActivity(title: "Workspace protected", detail: "Keep at least one workspace available.", tone: .warning)
            return
        }
        let deletedName = selectedWorkspace.name
        workspaceRegistry = WorkWithFaeWorkspaceStore.registryByRemovingWorkspace(
            workspaceID: selectedWorkspace.id,
            in: workspaceRegistry
        )
        persistWorkspaceRegistry()
        applySelectedWorkspaceState()
        prependActivity(title: "Workspace deleted", detail: deletedName, tone: .warning)
    }

    func updateWorkspaceRemoteExecution(_ remoteExecution: WorkWithFaeRemoteExecutionPolicy) {
        var policy = selectedWorkspacePolicy
        guard policy.remoteExecution != remoteExecution else { return }
        policy.remoteExecution = remoteExecution
        workspaceRegistry = WorkWithFaeWorkspaceStore.registryByUpdatingWorkspacePolicy(
            workspaceID: selectedWorkspace?.id,
            policy: policy,
            in: workspaceRegistry
        )
        persistWorkspaceRegistry()
        applySelectedWorkspaceState()
        prependActivity(title: "Workspace policy updated", detail: remoteExecution.displayName, tone: .success)
    }

    func updateWorkspaceCompareBehavior(_ compareBehavior: WorkWithFaeCompareBehavior) {
        var policy = selectedWorkspacePolicy
        guard policy.compareBehavior != compareBehavior else { return }
        policy.compareBehavior = compareBehavior
        workspaceRegistry = WorkWithFaeWorkspaceStore.registryByUpdatingWorkspacePolicy(
            workspaceID: selectedWorkspace?.id,
            policy: policy,
            in: workspaceRegistry
        )
        persistWorkspaceRegistry()
        applySelectedWorkspaceState()
        prependActivity(title: "Workspace policy updated", detail: compareBehavior.displayName, tone: .success)
    }

    func toggleConsensusParticipant(_ agent: WorkWithFaeAgentProfile) {
        if isStrictLocalWorkspace, !agent.isTrustedLocal {
            prependActivity(
                title: "Consensus participants unchanged",
                detail: "Strict local only keeps remote agents out of this workspace.",
                tone: .warning
            )
            return
        }

        if usesAutomaticConsensusSelection {
            var policy = selectedWorkspacePolicy
            policy.consensusAgentIDs = consensusParticipants.map(\.id)
            workspaceRegistry = WorkWithFaeWorkspaceStore.registryByUpdatingWorkspacePolicy(
                workspaceID: selectedWorkspace?.id,
                policy: policy,
                in: workspaceRegistry
            )
        }

        workspaceRegistry = WorkWithFaeWorkspaceStore.registryByTogglingConsensusAgent(
            workspaceID: selectedWorkspace?.id,
            agentID: agent.id,
            in: workspaceRegistry
        )
        persistWorkspaceRegistry()
        applySelectedWorkspaceState()
        let verb = selectedWorkspacePolicy.consensusAgentIDs.contains(agent.id) ? "included" : "removed"
        prependActivity(title: "Consensus participants updated", detail: "\(agent.name) \(verb)", tone: .success)
    }

    func resetConsensusParticipantsToAutomatic() {
        guard !usesAutomaticConsensusSelection else { return }
        workspaceRegistry = WorkWithFaeWorkspaceStore.registryByResettingConsensusAgents(
            workspaceID: selectedWorkspace?.id,
            in: workspaceRegistry
        )
        persistWorkspaceRegistry()
        applySelectedWorkspaceState()
        prependActivity(title: "Consensus participants updated", detail: "Using automatic selection again", tone: .success)
    }

    func createAgent(
        name: String,
        backendPresetID: String,
        providerKind: CoworkLLMProviderKind,
        modelIdentifier: String,
        baseURL: String?,
        apiKey: String?,
        assignToSelectedWorkspace: Bool
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let preset = CoworkBackendPresetCatalog.preset(id: backendPresetID) ?? providerKind.defaultPreset
        let credentialKey = providerKind.requiresAPIKey
            ? "agents.\(providerKind.rawValue).\(UUID().uuidString.lowercased()).api_key"
            : nil

        let fallbackAPIKey = preset.id == "openrouter"
            ? CredentialManager.retrieve(key: "llm.openrouter.api_key")
            : nil
        let effectiveAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? fallbackAPIKey

        if let credentialKey,
           let effectiveAPIKey,
           !effectiveAPIKey.isEmpty
        {
            do {
                try CredentialManager.store(key: credentialKey, value: effectiveAPIKey)
            } catch {
                prependActivity(title: "Credential save failed", detail: error.localizedDescription, tone: .warning)
            }
        }

        let normalizedModel = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBaseURL = CoworkProviderConnectionTester.normalizedBaseURL(baseURL, fallback: preset.defaultBaseURL)
        let agent = WorkWithFaeAgentProfile(
            id: "agent-\(UUID().uuidString.lowercased())",
            name: trimmedName,
            providerKind: providerKind,
            backendPresetID: preset.id,
            modelIdentifier: normalizedModel.isEmpty ? (preset.suggestedModels.first ?? (providerKind == .faeLocalhost ? "fae-agent-local" : "model-to-configure")) : normalizedModel,
            baseURL: normalizedBaseURL,
            credentialKey: credentialKey,
            notes: preset.setupHint,
            createdAt: Date()
        )

        workspaceRegistry = WorkWithFaeWorkspaceStore.registryByUpsertingAgent(
            agent,
            assignToSelectedWorkspace: assignToSelectedWorkspace,
            in: workspaceRegistry
        )
        persistWorkspaceRegistry()
        applySelectedWorkspaceState()
        prependActivity(title: "Agent added", detail: trimmedName, tone: .success)
    }

    func updateAgent(
        id: String,
        name: String,
        backendPresetID: String,
        providerKind: CoworkLLMProviderKind,
        modelIdentifier: String,
        baseURL: String?,
        apiKey: String?,
        clearStoredAPIKey: Bool,
        assignToSelectedWorkspace: Bool
    ) {
        guard let index = workspaceRegistry.agents.firstIndex(where: { $0.id == id }) else { return }
        let existingAgent = workspaceRegistry.agents[index]
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let preset = CoworkBackendPresetCatalog.preset(id: backendPresetID) ?? providerKind.defaultPreset
        let normalizedModel = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBaseURL = CoworkProviderConnectionTester.normalizedBaseURL(baseURL, fallback: preset.defaultBaseURL)

        var credentialKey = existingAgent.credentialKey
        if providerKind.requiresAPIKey {
            if credentialKey == nil {
                credentialKey = "agents.\(providerKind.rawValue).\(UUID().uuidString.lowercased()).api_key"
            }
            if clearStoredAPIKey, let credentialKey {
                CredentialManager.delete(key: credentialKey)
            }
            let fallbackAPIKey = preset.id == "openrouter"
                ? CredentialManager.retrieve(key: "llm.openrouter.api_key")
                : nil
            let effectiveAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? fallbackAPIKey
            if let credentialKey,
               let effectiveAPIKey,
               !effectiveAPIKey.isEmpty
            {
                do {
                    try CredentialManager.store(key: credentialKey, value: effectiveAPIKey)
                } catch {
                    prependActivity(title: "Credential save failed", detail: error.localizedDescription, tone: .warning)
                }
            }
        } else {
            if let oldKey = existingAgent.credentialKey {
                CredentialManager.delete(key: oldKey)
            }
            credentialKey = nil
        }

        let updatedAgent = WorkWithFaeAgentProfile(
            id: existingAgent.id,
            name: trimmedName,
            providerKind: providerKind,
            backendPresetID: preset.id,
            modelIdentifier: normalizedModel.isEmpty ? (preset.suggestedModels.first ?? (providerKind == .faeLocalhost ? "fae-agent-local" : existingAgent.modelIdentifier)) : normalizedModel,
            baseURL: normalizedBaseURL,
            credentialKey: credentialKey,
            notes: preset.setupHint,
            createdAt: existingAgent.createdAt
        )

        workspaceRegistry = WorkWithFaeWorkspaceStore.registryByUpsertingAgent(
            updatedAgent,
            assignToSelectedWorkspace: assignToSelectedWorkspace,
            in: workspaceRegistry
        )
        persistWorkspaceRegistry()
        applySelectedWorkspaceState()
        prependActivity(title: "Agent updated", detail: trimmedName, tone: .success)
    }

    func deleteAgent(_ agent: WorkWithFaeAgentProfile) {
        guard agent.id != WorkWithFaeAgentProfile.faeLocal.id else {
            prependActivity(title: "Trusted local agent protected", detail: "Fae Local cannot be removed.", tone: .warning)
            return
        }

        if let credentialKey = agent.credentialKey {
            CredentialManager.delete(key: credentialKey)
        }
        workspaceRegistry = WorkWithFaeWorkspaceStore.registryByRemovingAgent(id: agent.id, from: workspaceRegistry)
        persistWorkspaceRegistry()
        applySelectedWorkspaceState()
        prependActivity(title: "Agent removed", detail: agent.name, tone: .warning)
    }

    func hasStoredCredential(for agent: WorkWithFaeAgentProfile) -> Bool {
        guard let credentialKey = agent.credentialKey else { return false }
        return CredentialManager.retrieve(key: credentialKey) != nil
    }

    func credentialSummary(for agent: WorkWithFaeAgentProfile) -> String {
        guard let credentialKey = agent.credentialKey else {
            return agent.isTrustedLocal ? "No API key needed" : "No credential configured"
        }
        return CredentialManager.retrieve(key: credentialKey) == nil ? "API key needed" : "API key stored securely"
    }

    func testConnection(
        providerKind: CoworkLLMProviderKind,
        baseURL: String?,
        apiKey: String?
    ) async throws -> CoworkProviderConnectionReport {
        try await CoworkProviderConnectionTester.testConnection(
            providerKind: providerKind,
            runtimeDescriptor: runtimeDescriptor,
            baseURL: baseURL,
            apiKey: apiKey
        )
    }

    func assignAgent(_ agent: WorkWithFaeAgentProfile, to workspace: WorkWithFaeWorkspaceRecord? = nil) {
        let targetID = workspace?.id ?? workspaceRegistry.selectedWorkspaceID
        guard let targetID,
              let index = workspaceRegistry.workspaces.firstIndex(where: { $0.id == targetID })
        else { return }
        workspaceRegistry.workspaces[index].agentID = agent.id
        workspaceRegistry.workspaces[index].updatedAt = Date()
        persistWorkspaceRegistry()
        applySelectedWorkspaceState()
        prependActivity(title: "Agent attached", detail: "\(agent.name) → \(workspaceRegistry.workspaces[index].name)", tone: .success)
    }

    func testConnection(for agent: WorkWithFaeAgentProfile) async throws -> CoworkProviderConnectionReport {
        try await testConnection(
            providerKind: agent.providerKind,
            baseURL: agent.baseURL,
            apiKey: agent.credentialKey.flatMap(CredentialManager.retrieve(key:))
        )
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

    private func beginWorkspaceTurn(for prompt: String) {
        draft = ""
        selectedSection = .workspace
        conversation.lastInteractionTimestamp = Date()
        latestConsensusResults = []

        if remoteAgentBlockedByPolicy {
            prependActivity(
                title: "Workspace kept local",
                detail: "\(selectedWorkspace?.name ?? "This workspace") is strict local only, so Fae Local handled this turn instead of the attached remote agent.",
                tone: .neutral
            )
        }
    }

    private func runSingleAgentSubmission(prompt: String, preparedPrompt: WorkWithFaePreparedPrompt) {
        guard let executionAgent else {
            prependActivity(title: "No agent selected", detail: "Attach an agent to this workspace first.", tone: .warning)
            return
        }

        beginWorkspaceTurn(for: prompt)

        Task { [weak self] in
            guard let self else { return }
            let providerRequest = CoworkProviderRequest(
                model: executionAgent.modelIdentifier,
                preparedPrompt: preparedPrompt
            )

            if executionAgent.providerKind == .faeLocalhost {
                if let chatProvider = self.chatProvider {
                    do {
                        let response = try await chatProvider.submit(request: providerRequest)
                        await MainActor.run {
                            self.providerStatus = self.isStrictLocalWorkspace
                                ? "Strict local only — handled by Fae Local"
                                : (response.status == "completed"
                                    ? "Connected to Fae localhost"
                                    : "Fae localhost status: \(response.status)")
                            self.prependActivity(
                                title: "Prompt sent via Fae Local",
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
                return
            }

            do {
                let provider = try CoworkProviderFactory.provider(for: executionAgent, runtimeDescriptor: self.runtimeDescriptor)
                await MainActor.run {
                    self.conversation.appendMessage(role: .user, content: prompt)
                    self.conversation.isGenerating = true
                    self.prependActivity(
                        title: "Prompt sent to \(executionAgent.backendDisplayName)",
                        detail: CoworkPromptEgressPolicy.statusText(for: providerRequest),
                        tone: .neutral
                    )
                }

                let response: CoworkProviderResponse
                if let streamingProvider = provider as? any CoworkStreamingProvider {
                    await MainActor.run {
                        self.conversation.startStreaming()
                    }
                    response = try await streamingProvider.stream(request: providerRequest) { partialText in
                        await MainActor.run {
                            self.conversation.updateStreaming(text: partialText)
                        }
                    }
                } else {
                    response = try await provider.submit(request: providerRequest)
                }

                await MainActor.run {
                    self.conversation.isGenerating = false
                    if self.conversation.isStreaming {
                        self.conversation.finalizeStreaming()
                    } else {
                        self.conversation.appendMessage(role: .assistant, content: response.content)
                    }
                    self.providerStatus = "\(executionAgent.backendDisplayName) replied"
                    if preparedPrompt.containsLocalOnlyContext {
                        self.prependActivity(
                            title: "Privacy guard applied",
                            detail: "Local-only workspace inventory and focused local previews were kept on this Mac.",
                            tone: .success
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self.providerStatus = error.localizedDescription
                    self.conversation.isGenerating = false
                    let hadPartial = !self.conversation.streamingText.isEmpty
                    if self.conversation.isStreaming {
                        self.conversation.cancelStreaming()
                    }
                    if !hadPartial {
                        self.conversation.appendMessage(
                            role: .assistant,
                            content: "I couldn't reach \(executionAgent.backendDisplayName): \(error.localizedDescription)"
                        )
                    }
                    self.prependActivity(
                        title: "Remote request failed",
                        detail: error.localizedDescription,
                        tone: .warning
                    )
                }
            }
        }
    }

    private func runConsensus(
        prompt: String,
        preparedPrompt: WorkWithFaePreparedPrompt,
        triggeredAutomatically: Bool
    ) {
        let participants = consensusParticipants
        guard !participants.isEmpty else {
            prependActivity(title: "No agents available", detail: "Add or attach an agent before comparing answers.", tone: .warning)
            return
        }

        beginWorkspaceTurn(for: prompt)

        Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.conversation.appendMessage(role: .user, content: prompt)
                self.conversation.isGenerating = true
                self.prependActivity(
                    title: triggeredAutomatically ? "Auto-compare started" : "Consensus run started",
                    detail: participants.map(\.name).joined(separator: ", "),
                    tone: .neutral
                )
            }

            let results = await withTaskGroup(of: WorkWithFaeConsensusResult.self, returning: [WorkWithFaeConsensusResult].self) { group in
                for agent in participants {
                    group.addTask { [runtimeDescriptor = self.runtimeDescriptor, chatProvider = self.chatProvider] in
                        let request = CoworkProviderRequest(model: agent.modelIdentifier, preparedPrompt: preparedPrompt)
                        do {
                            let response: CoworkProviderResponse
                            if agent.providerKind == .faeLocalhost, let chatProvider {
                                response = try await chatProvider.submit(request: request)
                            } else {
                                let provider = try CoworkProviderFactory.provider(for: agent, runtimeDescriptor: runtimeDescriptor)
                                response = try await provider.submit(request: request)
                            }
                            return WorkWithFaeConsensusResult(
                                agentID: agent.id,
                                agentName: agent.name,
                                providerLabel: agent.backendDisplayName,
                                isTrustedLocal: agent.isTrustedLocal,
                                responseText: response.content,
                                errorText: nil
                            )
                        } catch {
                            return WorkWithFaeConsensusResult(
                                agentID: agent.id,
                                agentName: agent.name,
                                providerLabel: agent.backendDisplayName,
                                isTrustedLocal: agent.isTrustedLocal,
                                responseText: nil,
                                errorText: error.localizedDescription
                            )
                        }
                    }
                }

                var collected: [WorkWithFaeConsensusResult] = []
                for await result in group {
                    collected.append(result)
                }
                return collected.sorted { lhs, rhs in
                    let leftIndex = participants.firstIndex(where: { $0.id == lhs.agentID }) ?? .max
                    let rightIndex = participants.firstIndex(where: { $0.id == rhs.agentID }) ?? .max
                    return leftIndex < rightIndex
                }
            }

            let summary = await self.buildConsensusSummary(for: prompt, results: results)
            await MainActor.run {
                self.latestConsensusResults = results
                self.conversation.isGenerating = false
                self.conversation.appendMessage(role: .assistant, content: summary)
                self.providerStatus = triggeredAutomatically ? "Auto-compare ready" : "Consensus ready"
                self.prependActivity(
                    title: triggeredAutomatically ? "Auto-compare ready" : "Consensus ready",
                    detail: "Compared \(results.count) agents and summarized locally.",
                    tone: .success
                )
            }
        }
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

    private func buildConsensusSummary(
        for prompt: String,
        results: [WorkWithFaeConsensusResult]
    ) async -> String {
        let successful = results.filter { $0.responseText != nil }
        let failures = results.filter { $0.errorText != nil }

        let resultLines: String = results.map { result -> String in
            if let responseText = result.responseText {
                return "[\(result.agentName) — \(result.providerLabel)]\n\(responseText)"
            }
            return "[\(result.agentName) — \(result.providerLabel)]\nERROR: \(result.errorText ?? "Unknown error")"
        }.joined(separator: "\n\n")

        let fallbackSummary: String = {
            var lines: [String] = [
                "Fae consensus",
                "Prompt: \(prompt)",
                "Successful agents: \(successful.count)/\(results.count)",
            ]
            if let first = successful.first?.responseText {
                lines.append("Lead answer: \(first)")
            }
            if !failures.isEmpty {
                lines.append("Unavailable: \(failures.map(\.agentName).joined(separator: ", "))")
            }
            lines.append("\nAgent findings:\n\(resultLines)")
            return lines.joined(separator: "\n")
        }()

        guard let runtimeDescriptor else {
            return fallbackSummary
        }

        let synthesisPromptParts: [String] = [
            "You are Fae Local supervising multiple agents for a workspace task.",
            "Summarize the consensus for the user's request.",
            "Structure the answer with headings: Consensus, Differences, Recommended next step.",
            "Be concise and honest about uncertainty.",
            "User request:",
            prompt,
            "",
            "Agent findings:",
            resultLines,
        ]
        let synthesisPrompt = synthesisPromptParts.joined(separator: "\n")

        do {
            let provider = FaeLocalhostCoworkProvider(descriptor: runtimeDescriptor)
            let response = try await provider.submit(
                request: CoworkProviderRequest(
                    model: WorkWithFaeAgentProfile.faeLocal.modelIdentifier,
                    preparedPrompt: WorkWithFaePreparedPrompt(
                        userVisiblePrompt: prompt,
                        faeLocalPrompt: synthesisPrompt,
                        shareablePrompt: synthesisPrompt,
                        containsLocalOnlyContext: true
                    )
                )
            )
            let appendix: String = results.map { result in
                let status = result.errorText == nil ? "ok" : "failed"
                return "- \(result.agentName) (\(result.providerLabel)): \(status)"
            }.joined(separator: "\n")
            return response.content + "\n\nCompared agents:\n" + appendix
        } catch {
            return fallbackSummary
        }
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

    private func applySelectedWorkspaceState() {
        workspaceRegistry = WorkWithFaeWorkspaceStore.normalized(workspaceRegistry)
        workspaceState = selectedWorkspace?.state ?? .empty
        workspaceSearchText = ""
        selectedAttachment = nil
        selectedWorkspaceFile = workspaceState.indexedFiles.first
        focusedPreview = selectedWorkspaceFile.map(WorkWithFaeWorkspaceStore.preview(for:))

        if let executionAgent {
            providerKind = executionAgent.providerKind
            if isStrictLocalWorkspace {
                providerStatus = remoteAgentBlockedByPolicy
                    ? "Strict local only — attached remote agents stay idle for this workspace"
                    : "Strict local only — handled by Fae Local"
            } else {
                providerStatus = executionAgent.providerKind == .faeLocalhost
                    ? (chatProvider == nil ? "Fae localhost unavailable — direct fallback active" : "Connected to Fae localhost")
                    : credentialSummary(for: executionAgent)
            }
        } else {
            providerKind = .faeLocalhost
            providerStatus = "No agent attached"
        }
    }

    private func persistWorkspaceRegistry() {
        workspaceRegistry = WorkWithFaeWorkspaceStore.normalized(workspaceRegistry)
        WorkWithFaeWorkspaceStore.saveRegistry(workspaceRegistry)
    }

    private func persistWorkspaceState() {
        guard let selectedID = workspaceRegistry.selectedWorkspaceID,
              let index = workspaceRegistry.workspaces.firstIndex(where: { $0.id == selectedID })
        else {
            persistWorkspaceRegistry()
            return
        }
        workspaceRegistry.workspaces[index].state = workspaceState
        workspaceRegistry.workspaces[index].updatedAt = Date()
        persistWorkspaceRegistry()
    }

}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
