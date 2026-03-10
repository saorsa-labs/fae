import AppKit
import Foundation
import UniformTypeIdentifiers

struct WorkWithFaeFileEntry: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let relativePath: String
    let absolutePath: String
    let kind: String
    let sizeBytes: Int64
    let modifiedAt: Date?

    init(id: String, relativePath: String, absolutePath: String, kind: String, sizeBytes: Int64, modifiedAt: Date?) {
        self.id = id
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }

    init(url: URL, relativeTo root: URL) {
        let standardized = url.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        let path = standardized.path
        let relative: String
        if path.hasPrefix(rootPath) {
            let trimmed = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            relative = trimmed.isEmpty ? standardized.lastPathComponent : trimmed
        } else {
            relative = standardized.lastPathComponent
        }

        let values = try? standardized.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
        self.id = path
        self.relativePath = relative
        self.absolutePath = path
        self.kind = Self.kindForFile(url: standardized, isDirectory: values?.isDirectory == true)
        self.sizeBytes = Int64(values?.fileSize ?? 0)
        self.modifiedAt = values?.contentModificationDate
    }

    private static func kindForFile(url: URL, isDirectory: Bool) -> String {
        if isDirectory { return "folder" }
        let ext = url.pathExtension.lowercased()
        if ["swift", "rs", "py", "js", "ts", "tsx", "jsx", "json", "toml", "yaml", "yml", "md", "txt", "html", "css", "c", "h", "cpp", "hpp", "go", "java", "kt"].contains(ext) {
            return "text"
        }
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext) {
            return "image"
        }
        if ["pdf", "doc", "docx", "rtf"].contains(ext) {
            return "document"
        }
        return ext.isEmpty ? "file" : ext
    }
}

struct WorkWithFaeAttachment: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case file
        case image
        case text
    }

    let id: UUID
    let kind: Kind
    let displayName: String
    let path: String?
    let inlineText: String?
    let createdAt: Date

    init(kind: Kind, displayName: String, path: String? = nil, inlineText: String? = nil, createdAt: Date = Date()) {
        self.id = UUID()
        self.kind = kind
        self.displayName = displayName
        self.path = path
        self.inlineText = inlineText
        self.createdAt = createdAt
    }
}

struct WorkWithFaeConversationMessage: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let role: String
    let content: String
    let timestamp: Date

    init(id: UUID = UUID(), role: String, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

struct WorkWithFaeWorkspaceState: Codable, Hashable, Sendable {
    var selectedDirectoryPath: String?
    var indexedFiles: [WorkWithFaeFileEntry]
    var attachments: [WorkWithFaeAttachment]
    var conversationMessages: [WorkWithFaeConversationMessage]

    static let empty = WorkWithFaeWorkspaceState(selectedDirectoryPath: nil, indexedFiles: [], attachments: [], conversationMessages: [])

    enum CodingKeys: String, CodingKey {
        case selectedDirectoryPath
        case indexedFiles
        case attachments
        case conversationMessages
    }

    init(
        selectedDirectoryPath: String?,
        indexedFiles: [WorkWithFaeFileEntry],
        attachments: [WorkWithFaeAttachment],
        conversationMessages: [WorkWithFaeConversationMessage] = []
    ) {
        self.selectedDirectoryPath = selectedDirectoryPath
        self.indexedFiles = indexedFiles
        self.attachments = attachments
        self.conversationMessages = conversationMessages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedDirectoryPath = try container.decodeIfPresent(String.self, forKey: .selectedDirectoryPath)
        indexedFiles = try container.decodeIfPresent([WorkWithFaeFileEntry].self, forKey: .indexedFiles) ?? []
        attachments = try container.decodeIfPresent([WorkWithFaeAttachment].self, forKey: .attachments) ?? []
        conversationMessages = try container.decodeIfPresent([WorkWithFaeConversationMessage].self, forKey: .conversationMessages) ?? []
    }
}

struct WorkWithFaePreview: Sendable, Equatable {
    enum Source: String, Sendable {
        case workspaceFile
        case attachment
    }

    let source: Source
    let title: String
    let subtitle: String?
    let kind: String
    let path: String?
    let textPreview: String?
}

struct WorkWithFaePreparedPrompt: Sendable, Equatable {
    let userVisiblePrompt: String
    let faeLocalPrompt: String
    let shareablePrompt: String
    let containsLocalOnlyContext: Bool
    let shareableExport: CoworkExportPacket?

    init(
        userVisiblePrompt: String,
        faeLocalPrompt: String,
        shareablePrompt: String,
        containsLocalOnlyContext: Bool,
        shareableExport: CoworkExportPacket? = nil
    ) {
        self.userVisiblePrompt = userVisiblePrompt
        self.faeLocalPrompt = faeLocalPrompt
        self.shareablePrompt = shareablePrompt
        self.containsLocalOnlyContext = containsLocalOnlyContext
        self.shareableExport = shareableExport
    }
}

enum WorkWithFaeRemoteExecutionPolicy: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case allowRemote
    case strictLocalOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .allowRemote:
            return "Remote allowed"
        case .strictLocalOnly:
            return "Strict local only"
        }
    }

    var shortDescription: String {
        switch self {
        case .allowRemote:
            return "Fae may use attached remote agents for this workspace."
        case .strictLocalOnly:
            return "Fae keeps this workspace on-device and blocks remote agent execution."
        }
    }
}

enum WorkWithFaeCompareBehavior: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case onDemand
    case alwaysCompare

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDemand:
            return "Compare on demand"
        case .alwaysCompare:
            return "Always compare on send"
        }
    }

    var shortDescription: String {
        switch self {
        case .onDemand:
            return "Use the Compare button only when you want multi-agent fanout."
        case .alwaysCompare:
            return "Send runs a comparison first when more than one agent is available."
        }
    }
}

struct WorkWithFaeWorkspacePolicy: Codable, Hashable, Sendable {
    var remoteExecution: WorkWithFaeRemoteExecutionPolicy
    var compareBehavior: WorkWithFaeCompareBehavior
    var consensusAgentIDs: [String]

    static let `default` = WorkWithFaeWorkspacePolicy(
        remoteExecution: .allowRemote,
        compareBehavior: .onDemand,
        consensusAgentIDs: []
    )

    var usesAutomaticConsensusSelection: Bool {
        consensusAgentIDs.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case remoteExecution
        case compareBehavior
        case consensusAgentIDs
    }

    init(
        remoteExecution: WorkWithFaeRemoteExecutionPolicy,
        compareBehavior: WorkWithFaeCompareBehavior,
        consensusAgentIDs: [String] = []
    ) {
        self.remoteExecution = remoteExecution
        self.compareBehavior = compareBehavior
        self.consensusAgentIDs = consensusAgentIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remoteExecution = try container.decodeIfPresent(WorkWithFaeRemoteExecutionPolicy.self, forKey: .remoteExecution) ?? .allowRemote
        compareBehavior = try container.decodeIfPresent(WorkWithFaeCompareBehavior.self, forKey: .compareBehavior) ?? .onDemand
        consensusAgentIDs = try container.decodeIfPresent([String].self, forKey: .consensusAgentIDs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(remoteExecution, forKey: .remoteExecution)
        try container.encode(compareBehavior, forKey: .compareBehavior)
        try container.encode(consensusAgentIDs, forKey: .consensusAgentIDs)
    }
}

struct WorkWithFaeAgentProfile: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var providerKind: CoworkLLMProviderKind
    var backendPresetID: String?
    var modelIdentifier: String
    var baseURL: String?
    var credentialKey: String?
    var notes: String?
    var createdAt: Date

    var isTrustedLocal: Bool { providerKind == .faeLocalhost }

    var backendPreset: CoworkBackendPreset? {
        CoworkBackendPresetCatalog.preset(id: backendPresetID)
    }

    var backendDisplayName: String {
        backendPreset?.displayName ?? providerKind.displayName
    }

    static var faeLocal: WorkWithFaeAgentProfile {
        WorkWithFaeAgentProfile(
            id: "fae-local",
            name: "Fae Local",
            providerKind: .faeLocalhost,
            backendPresetID: "fae-local",
            modelIdentifier: "fae-agent-local",
            baseURL: "http://127.0.0.1:7434",
            credentialKey: nil,
            notes: "Trusted local runtime with memory, tools, scheduler, and approvals.",
            createdAt: Date()
        )
    }
}

struct WorkWithFaeWorkspaceRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var agentID: String
    var parentWorkspaceID: UUID?
    var sortOrder: Int
    var policy: WorkWithFaeWorkspacePolicy
    var state: WorkWithFaeWorkspaceState
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        agentID: String,
        parentWorkspaceID: UUID? = nil,
        sortOrder: Int = 0,
        policy: WorkWithFaeWorkspacePolicy = .default,
        state: WorkWithFaeWorkspaceState = .empty,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.agentID = agentID
        self.parentWorkspaceID = parentWorkspaceID
        self.sortOrder = sortOrder
        self.policy = policy
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case agentID
        case parentWorkspaceID
        case sortOrder
        case policy
        case state
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        agentID = try container.decode(String.self, forKey: .agentID)
        parentWorkspaceID = try container.decodeIfPresent(UUID.self, forKey: .parentWorkspaceID)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        policy = try container.decodeIfPresent(WorkWithFaeWorkspacePolicy.self, forKey: .policy) ?? .default
        state = try container.decode(WorkWithFaeWorkspaceState.self, forKey: .state)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(agentID, forKey: .agentID)
        try container.encodeIfPresent(parentWorkspaceID, forKey: .parentWorkspaceID)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(policy, forKey: .policy)
        try container.encode(state, forKey: .state)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

struct WorkWithFaeWorkspaceSetupState: Equatable, Sendable {
    struct Step: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let detail: String
        let isComplete: Bool
        let isOptional: Bool
    }

    let steps: [Step]

    var completionCount: Int {
        steps.filter(\.isComplete).count
    }

    var completedRequiredCount: Int {
        steps.filter { !$0.isOptional && $0.isComplete }.count
    }

    var totalRequiredCount: Int {
        steps.filter { !$0.isOptional }.count
    }

    var isFreshWorkspace: Bool {
        completedRequiredCount == 0
    }

    var isReadyForGroundedWork: Bool {
        completedRequiredCount == totalRequiredCount
    }

    var nextStep: Step? {
        steps.first(where: { !$0.isComplete })
    }
}

struct WorkWithFaeWorkspaceRegistry: Codable, Sendable {
    var selectedWorkspaceID: UUID?
    var workspaces: [WorkWithFaeWorkspaceRecord]
    var agents: [WorkWithFaeAgentProfile]

    static var `default`: WorkWithFaeWorkspaceRegistry {
        let localAgent = WorkWithFaeAgentProfile.faeLocal
        let workspace = WorkWithFaeWorkspaceRecord(name: "Main workspace", agentID: localAgent.id, sortOrder: 0)
        return WorkWithFaeWorkspaceRegistry(
            selectedWorkspaceID: workspace.id,
            workspaces: [workspace],
            agents: [localAgent]
        )
    }
}

struct WorkWithFaeConsensusResult: Identifiable, Equatable, Sendable {
    let agentID: String
    let agentName: String
    let providerLabel: String
    let isTrustedLocal: Bool
    let responseText: String?
    let errorText: String?

    var id: String { agentID }
}

enum WorkWithFaeWorkspaceStore {
    private static let maxIndexedFiles = 800
    private static let ignoredDirectoryNames: Set<String> = [
        ".git", ".build", "build", "dist", "node_modules", ".next", ".idea", ".swiftpm", "DerivedData"
    ]
    static var storageURLOverride: URL?

    static var storageURL: URL {
        if let storageURLOverride {
            return storageURLOverride
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("fae/work_with_fae_workspace.json")
    }

    static var attachmentsDirectory: URL {
        storageURL.deletingLastPathComponent().appendingPathComponent("workspace-attachments", isDirectory: true)
    }

    static func loadRegistry() -> WorkWithFaeWorkspaceRegistry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: storageURL) else {
            return .default
        }
        if let decoded = try? decoder.decode(WorkWithFaeWorkspaceRegistry.self, from: data) {
            return normalized(decoded)
        }
        if let legacyState = try? decoder.decode(WorkWithFaeWorkspaceState.self, from: data) {
            let localAgent = WorkWithFaeAgentProfile.faeLocal
            let workspace = WorkWithFaeWorkspaceRecord(name: "Main workspace", agentID: localAgent.id, sortOrder: 0, state: legacyState)
            return WorkWithFaeWorkspaceRegistry(
                selectedWorkspaceID: workspace.id,
                workspaces: [workspace],
                agents: [localAgent]
            )
        }
        return .default
    }

    static func saveRegistry(_ registry: WorkWithFaeWorkspaceRegistry) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(normalized(registry)) else { return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storageURL, options: .atomic)
    }

    static func load() -> WorkWithFaeWorkspaceState {
        let registry = loadRegistry()
        return selectedWorkspace(in: registry)?.state ?? .empty
    }

    static func save(_ state: WorkWithFaeWorkspaceState) {
        var registry = loadRegistry()
        let sanitizedState = sanitizedConversationState(state)
        if let selectedID = registry.selectedWorkspaceID,
           let index = registry.workspaces.firstIndex(where: { $0.id == selectedID })
        {
            registry.workspaces[index].state = sanitizedState
            registry.workspaces[index].updatedAt = Date()
            saveRegistry(registry)
            return
        }

        if registry.workspaces.isEmpty {
            let workspace = WorkWithFaeWorkspaceRecord(name: "Main workspace", agentID: normalized(registry).agents.first?.id ?? WorkWithFaeAgentProfile.faeLocal.id, sortOrder: 0, state: sanitizedState)
            registry.workspaces = [workspace]
            registry.selectedWorkspaceID = workspace.id
        }
        saveRegistry(registry)
    }

    static func selectedWorkspace(in registry: WorkWithFaeWorkspaceRegistry) -> WorkWithFaeWorkspaceRecord? {
        if let selectedWorkspaceID = registry.selectedWorkspaceID,
           let selected = registry.workspaces.first(where: { $0.id == selectedWorkspaceID })
        {
            return selected
        }
        return registry.workspaces.first
    }

    static func selectedAgent(in registry: WorkWithFaeWorkspaceRegistry) -> WorkWithFaeAgentProfile? {
        guard let workspace = selectedWorkspace(in: registry) else { return registry.agents.first }
        return registry.agents.first(where: { $0.id == workspace.agentID }) ?? registry.agents.first
    }

    static func executionAgent(in registry: WorkWithFaeWorkspaceRegistry) -> WorkWithFaeAgentProfile? {
        guard let workspace = selectedWorkspace(in: normalized(registry)) else {
            return normalized(registry).agents.first
        }
        return executionAgent(for: workspace, agents: normalized(registry).agents)
    }

    static func executionAgent(
        for workspace: WorkWithFaeWorkspaceRecord,
        agents: [WorkWithFaeAgentProfile]
    ) -> WorkWithFaeAgentProfile? {
        if workspace.policy.remoteExecution == .strictLocalOnly {
            return agents.first(where: { $0.id == WorkWithFaeAgentProfile.faeLocal.id }) ?? agents.first
        }
        return agents.first(where: { $0.id == workspace.agentID }) ?? agents.first
    }

    static func registryByUpsertingAgent(
        _ agent: WorkWithFaeAgentProfile,
        assignToSelectedWorkspace: Bool,
        in registry: WorkWithFaeWorkspaceRegistry
    ) -> WorkWithFaeWorkspaceRegistry {
        var copy = normalized(registry)
        if let index = copy.agents.firstIndex(where: { $0.id == agent.id }) {
            copy.agents[index] = agent
        } else {
            copy.agents.append(agent)
        }

        if assignToSelectedWorkspace,
           let selectedID = copy.selectedWorkspaceID,
           let workspaceIndex = copy.workspaces.firstIndex(where: { $0.id == selectedID })
        {
            copy.workspaces[workspaceIndex].agentID = agent.id
            copy.workspaces[workspaceIndex].updatedAt = Date()
        }

        return normalized(copy)
    }

    static func registryByRemovingAgent(
        id agentID: String,
        from registry: WorkWithFaeWorkspaceRegistry
    ) -> WorkWithFaeWorkspaceRegistry {
        guard agentID != WorkWithFaeAgentProfile.faeLocal.id else {
            return normalized(registry)
        }

        var copy = normalized(registry)
        copy.agents.removeAll { $0.id == agentID }
        for index in copy.workspaces.indices where copy.workspaces[index].agentID == agentID {
            copy.workspaces[index].agentID = WorkWithFaeAgentProfile.faeLocal.id
            copy.workspaces[index].updatedAt = Date()
        }
        return normalized(copy)
    }

    static func registryByUpdatingWorkspaceName(
        workspaceID: UUID?,
        name: String,
        in registry: WorkWithFaeWorkspaceRegistry
    ) -> WorkWithFaeWorkspaceRegistry {
        var copy = normalized(registry)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetWorkspaceID = workspaceID ?? copy.selectedWorkspaceID
        guard !trimmed.isEmpty,
              let targetWorkspaceID,
              let index = copy.workspaces.firstIndex(where: { $0.id == targetWorkspaceID })
        else {
            return copy
        }
        copy.workspaces[index].name = trimmed
        copy.workspaces[index].updatedAt = Date()
        return normalized(copy)
    }

    static func registryByDuplicatingWorkspace(
        workspaceID: UUID?,
        in registry: WorkWithFaeWorkspaceRegistry
    ) -> WorkWithFaeWorkspaceRegistry {
        var copy = normalized(registry)
        let targetWorkspaceID = workspaceID ?? copy.selectedWorkspaceID
        guard let targetWorkspaceID,
              let sourceIndex = copy.workspaces.firstIndex(where: { $0.id == targetWorkspaceID })
        else {
            return copy
        }

        let workspace = copy.workspaces[sourceIndex]
        let duplicate = WorkWithFaeWorkspaceRecord(
            name: duplicatedWorkspaceName(from: workspace.name, existingNames: copy.workspaces.map(\.name)),
            agentID: workspace.agentID,
            parentWorkspaceID: workspace.id,
            sortOrder: sourceIndex + 1,
            policy: workspace.policy,
            state: sanitizedConversationState(workspace.state)
        )
        copy.workspaces.insert(duplicate, at: min(sourceIndex + 1, copy.workspaces.count))
        copy.workspaces = reindexed(copy.workspaces)
        copy.selectedWorkspaceID = duplicate.id
        return normalized(copy)
    }

    static func registryByDuplicatingWorkspace(
        workspaceID: UUID?,
        truncatingToMessageIndex index: Int,
        in registry: WorkWithFaeWorkspaceRegistry
    ) -> WorkWithFaeWorkspaceRegistry {
        var copy = normalized(registry)
        let targetWorkspaceID = workspaceID ?? copy.selectedWorkspaceID
        guard let targetWorkspaceID,
              let sourceIndex = copy.workspaces.firstIndex(where: { $0.id == targetWorkspaceID })
        else {
            return copy
        }
        let workspace = copy.workspaces[sourceIndex]
        var truncatedState = workspace.state
        if index >= 0 && index < truncatedState.conversationMessages.count {
            truncatedState.conversationMessages = Array(truncatedState.conversationMessages.prefix(index + 1))
        }
        let duplicate = WorkWithFaeWorkspaceRecord(
            name: duplicatedWorkspaceName(from: workspace.name, existingNames: copy.workspaces.map(\.name)),
            agentID: workspace.agentID,
            parentWorkspaceID: workspace.id,
            sortOrder: sourceIndex + 1,
            policy: workspace.policy,
            state: truncatedState
        )
        copy.workspaces.insert(duplicate, at: min(sourceIndex + 1, copy.workspaces.count))
        copy.workspaces = reindexed(copy.workspaces)
        copy.selectedWorkspaceID = duplicate.id
        return normalized(copy)
    }

    static func registryByRemovingWorkspace(
        workspaceID: UUID?,
        in registry: WorkWithFaeWorkspaceRegistry
    ) -> WorkWithFaeWorkspaceRegistry {
        var copy = normalized(registry)
        guard copy.workspaces.count > 1 else {
            return copy
        }
        let targetWorkspaceID = workspaceID ?? copy.selectedWorkspaceID
        guard let targetWorkspaceID,
              let index = copy.workspaces.firstIndex(where: { $0.id == targetWorkspaceID })
        else {
            return copy
        }

        copy.workspaces.remove(at: index)
        if copy.selectedWorkspaceID == targetWorkspaceID {
            copy.selectedWorkspaceID = copy.workspaces.indices.contains(index)
                ? copy.workspaces[index].id
                : copy.workspaces.last?.id
        }
        copy.workspaces = reindexed(copy.workspaces)
        return normalized(copy)
    }

    static func registryByMovingWorkspace(
        workspaceID: UUID,
        beforeWorkspaceID: UUID?,
        in registry: WorkWithFaeWorkspaceRegistry
    ) -> WorkWithFaeWorkspaceRegistry {
        var copy = normalized(registry)
        guard let sourceIndex = copy.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return copy
        }

        let movingWorkspace = copy.workspaces.remove(at: sourceIndex)
        if let beforeWorkspaceID,
           let rawTargetIndex = copy.workspaces.firstIndex(where: { $0.id == beforeWorkspaceID })
        {
            copy.workspaces.insert(movingWorkspace, at: rawTargetIndex)
        } else {
            copy.workspaces.append(movingWorkspace)
        }

        copy.workspaces = reindexed(copy.workspaces)
        return normalized(copy)
    }

    static func registryByUpdatingWorkspacePolicy(
        workspaceID: UUID?,
        policy: WorkWithFaeWorkspacePolicy,
        in registry: WorkWithFaeWorkspaceRegistry
    ) -> WorkWithFaeWorkspaceRegistry {
        var copy = normalized(registry)
        let targetWorkspaceID = workspaceID ?? copy.selectedWorkspaceID
        guard let targetWorkspaceID,
              let index = copy.workspaces.firstIndex(where: { $0.id == targetWorkspaceID })
        else {
            return copy
        }
        copy.workspaces[index].policy = policy
        copy.workspaces[index].updatedAt = Date()
        return normalized(copy)
    }

    static func registryByTogglingConsensusAgent(
        workspaceID: UUID?,
        agentID: String,
        in registry: WorkWithFaeWorkspaceRegistry
    ) -> WorkWithFaeWorkspaceRegistry {
        var copy = normalized(registry)
        let targetWorkspaceID = workspaceID ?? copy.selectedWorkspaceID
        guard let targetWorkspaceID,
              let index = copy.workspaces.firstIndex(where: { $0.id == targetWorkspaceID })
        else {
            return copy
        }

        var policy = copy.workspaces[index].policy
        if let existingIndex = policy.consensusAgentIDs.firstIndex(of: agentID) {
            policy.consensusAgentIDs.remove(at: existingIndex)
        } else {
            policy.consensusAgentIDs.append(agentID)
        }
        copy.workspaces[index].policy = policy
        copy.workspaces[index].updatedAt = Date()
        return normalized(copy)
    }

    static func registryByResettingConsensusAgents(
        workspaceID: UUID?,
        in registry: WorkWithFaeWorkspaceRegistry
    ) -> WorkWithFaeWorkspaceRegistry {
        var copy = normalized(registry)
        let targetWorkspaceID = workspaceID ?? copy.selectedWorkspaceID
        guard let targetWorkspaceID,
              let index = copy.workspaces.firstIndex(where: { $0.id == targetWorkspaceID })
        else {
            return copy
        }
        copy.workspaces[index].policy.consensusAgentIDs = []
        copy.workspaces[index].updatedAt = Date()
        return normalized(copy)
    }

    static func consensusAgents(
        selectedAgentID: String?,
        agents: [WorkWithFaeAgentProfile],
        policy: WorkWithFaeWorkspacePolicy = .default,
        limit: Int = 4
    ) -> [WorkWithFaeAgentProfile] {
        let normalizedAgents = agents.sorted { lhs, rhs in
            if lhs.isTrustedLocal != rhs.isTrustedLocal {
                return lhs.isTrustedLocal && !rhs.isTrustedLocal
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        let local = normalizedAgents.first(where: { $0.id == WorkWithFaeAgentProfile.faeLocal.id })

        if policy.remoteExecution == .strictLocalOnly {
            return local.map { [$0] } ?? Array(normalizedAgents.prefix(1))
        }

        if !policy.consensusAgentIDs.isEmpty {
            var seen = Set<String>()
            return policy.consensusAgentIDs
                .compactMap { agentID in normalizedAgents.first(where: { $0.id == agentID }) }
                .filter { seen.insert($0.id).inserted }
                .prefix(limit)
                .map { $0 }
        }

        var seen = Set<String>()
        let selected = normalizedAgents.first(where: { $0.id == selectedAgentID })
        return ([selected, local].compactMap { $0 } + normalizedAgents)
            .filter { seen.insert($0.id).inserted }
            .prefix(limit)
            .map { $0 }
    }

    static func setupState(
        for workspace: WorkWithFaeWorkspaceRecord,
        agents: [WorkWithFaeAgentProfile]
    ) -> WorkWithFaeWorkspaceSetupState {
        let hasFolder = workspace.state.selectedDirectoryPath != nil
        let hasContext = !workspace.state.attachments.isEmpty || !workspace.state.indexedFiles.isEmpty
        let hasRemoteSpecialist = agents.contains(where: { !$0.isTrustedLocal })
        let compareParticipants = consensusAgents(
            selectedAgentID: workspace.agentID,
            agents: agents,
            policy: workspace.policy,
            limit: 4
        )
        let canCompare = compareParticipants.count > 1

        return WorkWithFaeWorkspaceSetupState(steps: [
            .init(
                id: "folder",
                title: hasFolder ? "Folder connected" : "Choose a folder",
                detail: hasFolder ? "Fae can scan the workspace tree for grounding." : "Point Work with Fae at the project or notes folder you want her to understand.",
                isComplete: hasFolder,
                isOptional: false
            ),
            .init(
                id: "context",
                title: hasContext ? "Context added" : "Add focused context",
                detail: hasContext ? "Attachments or indexed files are ready for grounded answers." : "Drop files, paste text, or add screenshots to steer the current session.",
                isComplete: hasContext,
                isOptional: false
            ),
            .init(
                id: "specialist",
                title: hasRemoteSpecialist ? "Specialist ready" : "Add a specialist agent",
                detail: hasRemoteSpecialist ? "You can bring in another model when you want a second opinion." : "Optional: connect OpenAI, Anthropic, or another backend for broader comparison.",
                isComplete: hasRemoteSpecialist,
                isOptional: true
            ),
            .init(
                id: "compare",
                title: canCompare ? "Compare enabled" : "Turn on compare",
                detail: canCompare ? "This workspace can fan out across multiple agents when needed." : "Optional: compare drafts across Fae Local and a specialist to gather multiple answers.",
                isComplete: canCompare,
                isOptional: true
            ),
        ])
    }

    static func normalized(_ registry: WorkWithFaeWorkspaceRegistry) -> WorkWithFaeWorkspaceRegistry {
        var copy = registry
        copy.agents = copy.agents.map { agent in
            var mutable = agent
            if mutable.backendPresetID == nil {
                mutable.backendPresetID = CoworkBackendPresetCatalog.defaultPreset(for: mutable.providerKind).id
            }
            if mutable.baseURL == nil {
                mutable.baseURL = mutable.providerKind.defaultBaseURL
            }
            return mutable
        }
        if !copy.agents.contains(where: { $0.id == WorkWithFaeAgentProfile.faeLocal.id }) {
            copy.agents.insert(WorkWithFaeAgentProfile.faeLocal, at: 0)
        }
        if copy.workspaces.isEmpty {
            let workspace = WorkWithFaeWorkspaceRecord(name: "Main workspace", agentID: copy.agents.first?.id ?? WorkWithFaeAgentProfile.faeLocal.id, sortOrder: 0)
            copy.workspaces = [workspace]
            copy.selectedWorkspaceID = workspace.id
        }
        copy.workspaces = reindexed(copy.workspaces.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.createdAt < rhs.createdAt
        })
        if copy.selectedWorkspaceID == nil || !copy.workspaces.contains(where: { $0.id == copy.selectedWorkspaceID }) {
            copy.selectedWorkspaceID = copy.workspaces.first?.id
        }
        let validWorkspaceIDs = Set(copy.workspaces.map(\.id))
        copy.workspaces = copy.workspaces.map { workspace in
            var mutable = workspace
            if !copy.agents.contains(where: { $0.id == workspace.agentID }) {
                mutable.agentID = WorkWithFaeAgentProfile.faeLocal.id
            }
            if let parentWorkspaceID = mutable.parentWorkspaceID,
               !validWorkspaceIDs.contains(parentWorkspaceID)
            {
                mutable.parentWorkspaceID = nil
            }
            let validAgentIDs = Set(copy.agents.map(\.id))
            mutable.policy.consensusAgentIDs = mutable.policy.consensusAgentIDs.filter { validAgentIDs.contains($0) }
            if mutable.policy.remoteExecution == .strictLocalOnly {
                mutable.policy.consensusAgentIDs = mutable.policy.consensusAgentIDs.filter { $0 == WorkWithFaeAgentProfile.faeLocal.id }
            }
            mutable.state = sanitizedConversationState(mutable.state)
            return mutable
        }
        return copy
    }

    private static func sanitizedConversationState(_ state: WorkWithFaeWorkspaceState) -> WorkWithFaeWorkspaceState {
        return state
    }

    private static func reindexed(_ workspaces: [WorkWithFaeWorkspaceRecord]) -> [WorkWithFaeWorkspaceRecord] {
        workspaces.enumerated().map { index, workspace in
            var mutable = workspace
            mutable.sortOrder = index
            return mutable
        }
    }

    private static func duplicatedWorkspaceName(from baseName: String, existingNames: [String]) -> String {
        let normalizedExisting = Set(existingNames.map { $0.lowercased() })
        let firstCandidate = "\(baseName) Fork"
        if !normalizedExisting.contains(firstCandidate.lowercased()) {
            return firstCandidate
        }

        var index = 2
        while true {
            let candidate = "\(baseName) Fork \(index)"
            if !normalizedExisting.contains(candidate.lowercased()) {
                return candidate
            }
            index += 1
        }
    }

    static func scanDirectory(_ root: URL) -> [WorkWithFaeFileEntry] {
        let fm = FileManager.default
        let standardizedRoot = root.standardizedFileURL
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isHiddenKey, .nameKey]
        guard let enumerator = fm.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [WorkWithFaeFileEntry] = []
        results.reserveCapacity(256)

        for case let fileURL as URL in enumerator {
            if results.count >= maxIndexedFiles { break }
            let values = try? fileURL.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                if let name = values?.name, ignoredDirectoryNames.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            results.append(WorkWithFaeFileEntry(url: fileURL, relativeTo: standardizedRoot))
        }

        return results.sorted { lhs, rhs in
            lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
        }
    }

    static func attachments(from urls: [URL]) -> [WorkWithFaeAttachment] {
        urls.compactMap { url in
            let ext = url.pathExtension.lowercased()
            let kind: WorkWithFaeAttachment.Kind = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext) ? .image : .file
            return WorkWithFaeAttachment(kind: kind, displayName: url.lastPathComponent, path: url.standardizedFileURL.path)
        }
    }

    static func filteredFiles(_ files: [WorkWithFaeFileEntry], query: String) -> [WorkWithFaeFileEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return files }
        let lowered = trimmed.lowercased()
        return files.filter {
            $0.relativePath.lowercased().contains(lowered)
                || $0.kind.lowercased().contains(lowered)
        }
    }

    static func preview(for file: WorkWithFaeFileEntry) -> WorkWithFaePreview {
        let path = file.absolutePath
        let url = URL(fileURLWithPath: path)
        if file.kind == "image" {
            return WorkWithFaePreview(
                source: .workspaceFile,
                title: file.relativePath,
                subtitle: "Image file",
                kind: file.kind,
                path: path,
                textPreview: nil
            )
        }

        let previewText = loadTextPreview(from: url)
        return WorkWithFaePreview(
            source: .workspaceFile,
            title: file.relativePath,
            subtitle: file.kind.capitalized,
            kind: file.kind,
            path: path,
            textPreview: previewText
        )
    }

    static func preview(for attachment: WorkWithFaeAttachment) -> WorkWithFaePreview {
        switch attachment.kind {
        case .text:
            return WorkWithFaePreview(
                source: .attachment,
                title: attachment.displayName,
                subtitle: "Pasted text",
                kind: "text",
                path: nil,
                textPreview: attachment.inlineText
            )
        case .image:
            return WorkWithFaePreview(
                source: .attachment,
                title: attachment.displayName,
                subtitle: "Image attachment",
                kind: "image",
                path: attachment.path,
                textPreview: nil
            )
        case .file:
            let previewText = attachment.path.map { loadTextPreview(from: URL(fileURLWithPath: $0)) }
            let ext = attachment.path.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? "file"
            return WorkWithFaePreview(
                source: .attachment,
                title: attachment.displayName,
                subtitle: "File attachment",
                kind: ext.isEmpty ? "file" : ext,
                path: attachment.path,
                textPreview: previewText ?? nil
            )
        }
    }

    static func attachmentFromPasteboardImage(_ image: NSImage) -> WorkWithFaeAttachment? {
        try? FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        let fileURL = attachmentsDirectory.appendingPathComponent("pasted-\(UUID().uuidString).png")
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else {
            return nil
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            return WorkWithFaeAttachment(kind: .image, displayName: fileURL.lastPathComponent, path: fileURL.path)
        } catch {
            return nil
        }
    }

    static func textAttachment(_ text: String) -> WorkWithFaeAttachment? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let preview = String(trimmed.prefix(40))
        return WorkWithFaeAttachment(kind: .text, displayName: preview + (trimmed.count > 40 ? "…" : ""), inlineText: trimmed)
    }

    static func dropURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                } else if let url = item as? URL {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            completion(urls)
        }
    }

    static func preparePrompt(
        userPrompt: String,
        state: WorkWithFaeWorkspaceState,
        focusedPreview: WorkWithFaePreview? = nil
    ) -> WorkWithFaePreparedPrompt {
        let trimmedPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let priorConversation = formattedConversationHistory(from: state.conversationMessages)
        let shareableExport = buildShareableExportPacket(
            userPrompt: trimmedPrompt,
            state: state,
            focusedPreview: focusedPreview
        )
        let hasExtraContext = state.selectedDirectoryPath != nil || !state.attachments.isEmpty || focusedPreview != nil
        guard hasExtraContext || priorConversation != nil else {
            return WorkWithFaePreparedPrompt(
                userVisiblePrompt: trimmedPrompt,
                faeLocalPrompt: trimmedPrompt,
                shareablePrompt: shareableExport.renderedPrompt,
                containsLocalOnlyContext: shareableExport.containsLocalOnlyContext,
                shareableExport: shareableExport
            )
        }

        var localLines: [String] = [
            "[WORK WITH FAE CONTEXT]",
            "Use this workspace context to ground your answer. Prefer the selected workspace and attached files before asking the user to re-explain.",
        ]
        var containsLocalOnlyContext = false

        if let priorConversation {
            localLines.append("Recent conversation:")
            localLines.append(priorConversation)
            localLines.append("Continue naturally from that conversation unless the user is clearly starting a new topic.")
        }

        if let selectedDirectoryPath = state.selectedDirectoryPath {
            containsLocalOnlyContext = true
            localLines.append("Workspace root: \(selectedDirectoryPath)")
            localLines.append("Indexed files: \(state.indexedFiles.count)")
            if !state.indexedFiles.isEmpty {
                localLines.append("Workspace file inventory sample:")
                for entry in state.indexedFiles.prefix(40) {
                    localLines.append("- \(entry.relativePath) [\(entry.kind)]")
                }
                localLines.append("If you need more detail from these files, inspect the relevant paths directly.")
            }
        }

        if !state.attachments.isEmpty {
            localLines.append("Attached items:")
            for attachment in state.attachments.prefix(12) {
                switch attachment.kind {
                case .text:
                    localLines.append("- text: \(attachment.displayName)")
                    if let inlineText = attachment.inlineText {
                        let snippet = String(inlineText.prefix(1200))
                        localLines.append("  snippet: \(snippet)")
                    }
                case .image:
                    let line = "- image: \(attachment.displayName) @ \(attachment.path ?? "unknown")"
                    localLines.append(line)
                case .file:
                    let line = "- file: \(attachment.displayName) @ \(attachment.path ?? "unknown")"
                    localLines.append(line)
                }
            }
        }

        if let focusedPreview {
            localLines.append("Focused item:")
            localLines.append("- title: \(focusedPreview.title)")
            if let subtitle = focusedPreview.subtitle {
                localLines.append("- type: \(subtitle)")
            }
            if let path = focusedPreview.path {
                localLines.append("- path: \(path)")
            }
            if let textPreview = focusedPreview.textPreview, !textPreview.isEmpty {
                localLines.append("- preview:\n\(String(textPreview.prefix(2400)))")
            }
            localLines.append("Prioritize this focused item when answering if it appears relevant.")

            if focusedPreview.source != .attachment {
                containsLocalOnlyContext = true
            }
        }

        localLines.append("[/WORK WITH FAE CONTEXT]")
        localLines.append(trimmedPrompt)

        return WorkWithFaePreparedPrompt(
            userVisiblePrompt: trimmedPrompt,
            faeLocalPrompt: localLines.joined(separator: "\n"),
            shareablePrompt: shareableExport.renderedPrompt,
            containsLocalOnlyContext: containsLocalOnlyContext || shareableExport.containsLocalOnlyContext,
            shareableExport: shareableExport
        )
    }

    private static func buildShareableExportPacket(
        userPrompt: String,
        state: WorkWithFaeWorkspaceState,
        focusedPreview: WorkWithFaePreview?
    ) -> CoworkExportPacket {
        var sections: [CoworkExportSection] = []
        var excludedDataClasses: Set<CoworkExportDataClass> = []
        var excludedContext: [String] = []

        if !state.conversationMessages.isEmpty {
            excludedDataClasses.insert(.privateLocalOnly)
            appendUnique("recent conversation history", to: &excludedContext)
        }

        if state.selectedDirectoryPath != nil {
            excludedDataClasses.insert(.workspaceConfidential)
            appendUnique("workspace root and indexed file inventory", to: &excludedContext)
        }

        if !state.attachments.isEmpty {
            var lines = ["Attached items:"]
            var transforms: [CoworkExportTransform] = [.userSelected]
            var handles: [String] = []

            for attachment in state.attachments.prefix(12) {
                let handle = attachmentHandle(for: attachment)
                handles.append(handle)

                switch attachment.kind {
                case .text:
                    lines.append("- text: \(attachment.displayName)")
                    if let inlineText = attachment.inlineText {
                        let snippet = String(inlineText.prefix(1200))
                        lines.append("  snippet: \(snippet)")
                    }
                    transforms.append(.truncated)
                case .image:
                    lines.append("- image: \(attachment.displayName)")
                    if attachment.path != nil {
                        transforms.append(.pathStripped)
                        excludedDataClasses.insert(.workspaceConfidential)
                        appendUnique("absolute attachment path metadata", to: &excludedContext)
                    }
                case .file:
                    lines.append("- file: \(attachment.displayName)")
                    if attachment.path != nil {
                        transforms.append(.pathStripped)
                        excludedDataClasses.insert(.workspaceConfidential)
                        appendUnique("absolute attachment path metadata", to: &excludedContext)
                    }
                }
            }

            if lines.count > 1 {
                sections.append(
                    CoworkExportSection(
                        id: "attachments",
                        kind: .attachmentSummary,
                        dataClass: .shareableContext,
                        transforms: deduplicatedTransforms(transforms),
                        artifactHandle: handles.isEmpty ? nil : handles.joined(separator: ","),
                        content: lines.joined(separator: "\n")
                    )
                )
            }
        }

        if let focusedPreview, focusedPreview.source == .attachment {
            var lines = [
                "Focused attachment:",
                "- title: \(focusedPreview.title)",
            ]
            var transforms: [CoworkExportTransform] = [.userSelected]

            if let subtitle = focusedPreview.subtitle {
                lines.append("- type: \(subtitle)")
            }
            if focusedPreview.path != nil {
                transforms.append(.pathStripped)
                excludedDataClasses.insert(.workspaceConfidential)
                appendUnique("focused attachment path metadata", to: &excludedContext)
            }
            if let textPreview = focusedPreview.textPreview, !textPreview.isEmpty {
                lines.append("- preview:\n\(String(textPreview.prefix(2400)))")
                transforms.append(.truncated)
            }
            lines.append("Prioritize this focused attachment when answering if it appears relevant.")

            sections.append(
                CoworkExportSection(
                    id: "focused_attachment",
                    kind: .focusedAttachment,
                    dataClass: .shareableContext,
                    transforms: deduplicatedTransforms(transforms),
                    artifactHandle: attachmentHandle(for: focusedPreview.title),
                    content: lines.joined(separator: "\n")
                )
            )
        } else if focusedPreview != nil {
            excludedDataClasses.insert(.workspaceConfidential)
            appendUnique("focused workspace file preview", to: &excludedContext)
        }

        sections.append(
            CoworkExportSection(
                id: "user_prompt",
                kind: .userPrompt,
                dataClass: .generalPublic,
                transforms: [.trimmed],
                artifactHandle: nil,
                content: userPrompt
            )
        )

        return CoworkExportPacket(
            destinationTrustTier: .thirdPartyCloud,
            mode: .redactedRemote,
            sections: sections,
            excludedDataClasses: excludedDataClasses.sorted { $0.rawValue < $1.rawValue },
            excludedContext: excludedContext
        )
    }

    private static func formattedConversationHistory(from messages: [WorkWithFaeConversationMessage], limit: Int = 12) -> String? {
        let relevant = messages.suffix(limit)
        guard !relevant.isEmpty else { return nil }
        let lines = relevant.compactMap { message -> String? in
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let role = message.role.capitalized
            return "- \(role): \(String(trimmed.prefix(1200)))"
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    static func contextualPrompt(
        userPrompt: String,
        state: WorkWithFaeWorkspaceState,
        focusedPreview: WorkWithFaePreview? = nil
    ) -> String {
        preparePrompt(userPrompt: userPrompt, state: state, focusedPreview: focusedPreview).faeLocalPrompt
    }

    private static func loadTextPreview(from url: URL, maxCharacters: Int = 8_000) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return String(trimmed.prefix(maxCharacters))
        }
        return nil
    }

    private static func attachmentHandle(for attachment: WorkWithFaeAttachment) -> String {
        attachmentHandle(for: attachment.displayName, fallback: attachment.id.uuidString)
    }

    private static func attachmentHandle(for title: String, fallback: String = "") -> String {
        let slug = title.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let suffix = String(fallback.prefix(8)).lowercased()
        if slug.isEmpty {
            return suffix.isEmpty ? "attachment" : "attachment-\(suffix)"
        }
        return suffix.isEmpty ? "attachment-\(slug)" : "attachment-\(slug)-\(suffix)"
    }

    private static func deduplicatedTransforms(_ transforms: [CoworkExportTransform]) -> [CoworkExportTransform] {
        var seen: Set<CoworkExportTransform> = []
        return transforms.filter { seen.insert($0).inserted }
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        guard !values.contains(value) else { return }
        values.append(value)
    }
}
