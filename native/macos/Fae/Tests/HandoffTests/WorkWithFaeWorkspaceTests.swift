import XCTest
@testable import Fae

final class WorkWithFaeWorkspaceTests: XCTestCase {
    func testScanDirectorySkipsIgnoredFoldersAndFindsRegularFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("work-with-fae-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "hello".write(to: docs.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)

        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ignored".write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let results = WorkWithFaeWorkspaceStore.scanDirectory(root)
        XCTAssertTrue(results.contains(where: { $0.relativePath == "docs/guide.md" }))
        XCTAssertFalse(results.contains(where: { $0.relativePath.contains(".git") }))
    }

    func testFilteredFilesMatchesPathAndKind() {
        let files = [
            WorkWithFaeFileEntry(
                id: "/tmp/project/README.md",
                relativePath: "README.md",
                absolutePath: "/tmp/project/README.md",
                kind: "text",
                sizeBytes: 12,
                modifiedAt: nil
            ),
            WorkWithFaeFileEntry(
                id: "/tmp/project/image.png",
                relativePath: "assets/image.png",
                absolutePath: "/tmp/project/assets/image.png",
                kind: "image",
                sizeBytes: 12,
                modifiedAt: nil
            ),
        ]

        XCTAssertEqual(WorkWithFaeWorkspaceStore.filteredFiles(files, query: "readme").count, 1)
        XCTAssertEqual(WorkWithFaeWorkspaceStore.filteredFiles(files, query: "image").count, 1)
        XCTAssertEqual(WorkWithFaeWorkspaceStore.filteredFiles(files, query: "").count, 2)
    }

    func testPreparePromptKeepsLocalWorkspaceContextOnFaeLocalhost() {
        let state = WorkWithFaeWorkspaceState(
            selectedDirectoryPath: "/tmp/project",
            indexedFiles: [
                WorkWithFaeFileEntry(
                    id: "/tmp/project/README.md",
                    relativePath: "README.md",
                    absolutePath: "/tmp/project/README.md",
                    kind: "text",
                    sizeBytes: 12,
                    modifiedAt: nil
                )
            ],
            attachments: [
                WorkWithFaeAttachment(kind: .text, displayName: "note", inlineText: "Important pasted note")
            ]
        )

        let focusedPreview = WorkWithFaePreview(
            source: .workspaceFile,
            title: "README.md",
            subtitle: "Text",
            kind: "text",
            path: "/tmp/project/README.md",
            textPreview: "Project overview\nKey details"
        )

        let prepared = WorkWithFaeWorkspaceStore.preparePrompt(
            userPrompt: "Summarize this project",
            state: state,
            focusedPreview: focusedPreview
        )
        XCTAssertTrue(prepared.containsLocalOnlyContext)
        XCTAssertTrue(prepared.faeLocalPrompt.contains("Workspace root: /tmp/project"))
        XCTAssertTrue(prepared.faeLocalPrompt.contains("README.md"))
        XCTAssertTrue(prepared.faeLocalPrompt.contains("Important pasted note"))
        XCTAssertTrue(prepared.faeLocalPrompt.contains("Focused item:"))
        XCTAssertTrue(prepared.faeLocalPrompt.contains("Project overview"))
        XCTAssertTrue(prepared.faeLocalPrompt.contains("Summarize this project"))
    }

    func testPreparePromptStripsLocalWorkspaceContextFromShareablePrompt() {
        let state = WorkWithFaeWorkspaceState(
            selectedDirectoryPath: "/tmp/project",
            indexedFiles: [
                WorkWithFaeFileEntry(
                    id: "/tmp/project/README.md",
                    relativePath: "README.md",
                    absolutePath: "/tmp/project/README.md",
                    kind: "text",
                    sizeBytes: 12,
                    modifiedAt: nil
                )
            ],
            attachments: [
                WorkWithFaeAttachment(kind: .text, displayName: "note", inlineText: "Important pasted note")
            ]
        )

        let focusedPreview = WorkWithFaePreview(
            source: .workspaceFile,
            title: "README.md",
            subtitle: "Text",
            kind: "text",
            path: "/tmp/project/README.md",
            textPreview: "Project overview\nKey details"
        )

        let prepared = WorkWithFaeWorkspaceStore.preparePrompt(
            userPrompt: "Summarize this project",
            state: state,
            focusedPreview: focusedPreview
        )
        XCTAssertFalse(prepared.shareablePrompt.contains("Workspace root: /tmp/project"))
        XCTAssertFalse(prepared.shareablePrompt.contains("Indexed files:"))
        XCTAssertFalse(prepared.shareablePrompt.contains("Project overview"))
        XCTAssertTrue(prepared.shareablePrompt.contains("Important pasted note"))
        XCTAssertTrue(prepared.shareablePrompt.contains("Summarize this project"))
    }

    func testDefaultRegistryIncludesTrustedLocalFaeAgent() {
        let registry = WorkWithFaeWorkspaceRegistry.default
        XCTAssertEqual(registry.workspaces.count, 1)
        XCTAssertTrue(registry.agents.contains(where: { $0.id == "fae-local" && $0.isTrustedLocal }))
        XCTAssertEqual(WorkWithFaeWorkspaceStore.selectedWorkspace(in: registry)?.agentID, "fae-local")
        XCTAssertEqual(WorkWithFaeWorkspaceStore.selectedWorkspace(in: registry)?.policy, .default)
        XCTAssertTrue(WorkWithFaeWorkspaceStore.selectedWorkspace(in: registry)?.policy.usesAutomaticConsensusSelection == true)
    }

    func testNormalizedRegistryRestoresMissingAgentBindingToLocalFae() {
        let workspace = WorkWithFaeWorkspaceRecord(name: "Client", agentID: "missing-agent")
        let registry = WorkWithFaeWorkspaceRegistry(
            selectedWorkspaceID: workspace.id,
            workspaces: [workspace],
            agents: []
        )

        let normalized = WorkWithFaeWorkspaceStore.normalized(registry)
        XCTAssertEqual(normalized.agents.first?.id, "fae-local")
        XCTAssertEqual(WorkWithFaeWorkspaceStore.selectedWorkspace(in: normalized)?.agentID, "fae-local")
        XCTAssertEqual(WorkWithFaeWorkspaceStore.selectedAgent(in: normalized)?.id, "fae-local")
    }

    func testNormalizedRegistryBackfillsBackendPresetMetadata() {
        let remoteAgent = WorkWithFaeAgentProfile(
            id: "agent-openai",
            name: "Remote OpenAI",
            providerKind: .openAICompatibleExternal,
            backendPresetID: nil,
            modelIdentifier: "gpt-4.1",
            baseURL: nil,
            credentialKey: "agents.openai.test.api_key",
            notes: nil,
            createdAt: Date()
        )
        let workspace = WorkWithFaeWorkspaceRecord(name: "Client", agentID: remoteAgent.id)
        let registry = WorkWithFaeWorkspaceRegistry(
            selectedWorkspaceID: workspace.id,
            workspaces: [workspace],
            agents: [remoteAgent]
        )

        let normalized = WorkWithFaeWorkspaceStore.normalized(registry)
        let agent = normalized.agents.first(where: { $0.id == remoteAgent.id })
        XCTAssertEqual(agent?.backendPresetID, "openai")
        XCTAssertEqual(agent?.baseURL, "https://api.openai.com")
        XCTAssertEqual(agent?.backendDisplayName, "OpenAI")
    }

    func testRegistryByUpsertingAgentUpdatesSelectedWorkspaceBinding() {
        var registry = WorkWithFaeWorkspaceRegistry.default
        let updatedAgent = WorkWithFaeAgentProfile(
            id: "agent-openrouter",
            name: "Research Router",
            providerKind: .openAICompatibleExternal,
            backendPresetID: "openrouter",
            modelIdentifier: "anthropic/claude-sonnet-4",
            baseURL: "https://openrouter.ai/api",
            credentialKey: "agents.openrouter.api_key",
            notes: "OpenRouter agent",
            createdAt: Date()
        )

        registry = WorkWithFaeWorkspaceStore.registryByUpsertingAgent(
            updatedAgent,
            assignToSelectedWorkspace: true,
            in: registry
        )

        XCTAssertTrue(registry.agents.contains(where: { $0.id == updatedAgent.id && $0.backendPresetID == "openrouter" }))
        XCTAssertEqual(WorkWithFaeWorkspaceStore.selectedWorkspace(in: registry)?.agentID, updatedAgent.id)
    }

    func testRegistryByRemovingAgentFallsBackToLocalFae() {
        let remoteAgent = WorkWithFaeAgentProfile(
            id: "agent-remote",
            name: "Remote",
            providerKind: .anthropic,
            backendPresetID: "anthropic",
            modelIdentifier: "claude-sonnet-4-5",
            baseURL: "https://api.anthropic.com",
            credentialKey: "agents.anthropic.api_key",
            notes: nil,
            createdAt: Date()
        )
        let workspace = WorkWithFaeWorkspaceRecord(name: "Client", agentID: remoteAgent.id)
        let registry = WorkWithFaeWorkspaceRegistry(
            selectedWorkspaceID: workspace.id,
            workspaces: [workspace],
            agents: [WorkWithFaeAgentProfile.faeLocal, remoteAgent]
        )

        let updated = WorkWithFaeWorkspaceStore.registryByRemovingAgent(id: remoteAgent.id, from: registry)
        XCTAssertFalse(updated.agents.contains(where: { $0.id == remoteAgent.id }))
        XCTAssertEqual(WorkWithFaeWorkspaceStore.selectedWorkspace(in: updated)?.agentID, WorkWithFaeAgentProfile.faeLocal.id)
    }

    func testRegistryByUpdatingWorkspaceNameRenamesSelectedWorkspace() {
        let registry = WorkWithFaeWorkspaceRegistry.default
        let updated = WorkWithFaeWorkspaceStore.registryByUpdatingWorkspaceName(
            workspaceID: registry.selectedWorkspaceID,
            name: "Client work",
            in: registry
        )

        XCTAssertEqual(WorkWithFaeWorkspaceStore.selectedWorkspace(in: updated)?.name, "Client work")
    }

    func testRegistryByDuplicatingWorkspaceSelectsCopy() {
        let registry = WorkWithFaeWorkspaceRegistry.default
        let updated = WorkWithFaeWorkspaceStore.registryByDuplicatingWorkspace(
            workspaceID: registry.selectedWorkspaceID,
            in: registry
        )

        XCTAssertEqual(updated.workspaces.count, 2)
        XCTAssertTrue(updated.workspaces.contains(where: { $0.name == "Main workspace Copy" }))
        XCTAssertEqual(WorkWithFaeWorkspaceStore.selectedWorkspace(in: updated)?.name, "Main workspace Copy")
    }

    func testRegistryByRemovingWorkspaceFallsBackToRemainingWorkspace() {
        let first = WorkWithFaeWorkspaceRecord(name: "One", agentID: WorkWithFaeAgentProfile.faeLocal.id)
        let second = WorkWithFaeWorkspaceRecord(name: "Two", agentID: WorkWithFaeAgentProfile.faeLocal.id)
        let registry = WorkWithFaeWorkspaceRegistry(
            selectedWorkspaceID: second.id,
            workspaces: [first, second],
            agents: [.faeLocal]
        )

        let updated = WorkWithFaeWorkspaceStore.registryByRemovingWorkspace(
            workspaceID: second.id,
            in: registry
        )

        XCTAssertEqual(updated.workspaces.count, 1)
        XCTAssertEqual(WorkWithFaeWorkspaceStore.selectedWorkspace(in: updated)?.name, "One")
    }

    func testRegistryByMovingWorkspaceReordersAndReindexes() {
        let first = WorkWithFaeWorkspaceRecord(name: "One", agentID: WorkWithFaeAgentProfile.faeLocal.id, sortOrder: 0)
        let second = WorkWithFaeWorkspaceRecord(name: "Two", agentID: WorkWithFaeAgentProfile.faeLocal.id, sortOrder: 1)
        let third = WorkWithFaeWorkspaceRecord(name: "Three", agentID: WorkWithFaeAgentProfile.faeLocal.id, sortOrder: 2)
        let registry = WorkWithFaeWorkspaceRegistry(
            selectedWorkspaceID: second.id,
            workspaces: [first, second, third],
            agents: [.faeLocal]
        )

        let updated = WorkWithFaeWorkspaceStore.registryByMovingWorkspace(
            workspaceID: third.id,
            beforeWorkspaceID: first.id,
            in: registry
        )

        XCTAssertEqual(updated.workspaces.map(\.name), ["Three", "One", "Two"])
        XCTAssertEqual(updated.workspaces.map(\.sortOrder), [0, 1, 2])
    }

    func testSetupStateMarksFreshWorkspaceUntilFolderAndContextExist() {
        let workspace = WorkWithFaeWorkspaceRecord(name: "Main workspace", agentID: WorkWithFaeAgentProfile.faeLocal.id)
        let fresh = WorkWithFaeWorkspaceStore.setupState(for: workspace, agents: [.faeLocal])

        XCTAssertTrue(fresh.isFreshWorkspace)
        XCTAssertFalse(fresh.isReadyForGroundedWork)
        XCTAssertEqual(fresh.completedRequiredCount, 0)
        XCTAssertEqual(fresh.totalRequiredCount, 2)
        XCTAssertEqual(fresh.nextStep?.id, "folder")

        let readyWorkspace = WorkWithFaeWorkspaceRecord(
            name: "Main workspace",
            agentID: WorkWithFaeAgentProfile.faeLocal.id,
            state: WorkWithFaeWorkspaceState(
                selectedDirectoryPath: "/tmp/project",
                indexedFiles: [
                    WorkWithFaeFileEntry(
                        id: "/tmp/project/README.md",
                        relativePath: "README.md",
                        absolutePath: "/tmp/project/README.md",
                        kind: "text",
                        sizeBytes: 12,
                        modifiedAt: nil
                    )
                ],
                attachments: []
            )
        )
        let ready = WorkWithFaeWorkspaceStore.setupState(for: readyWorkspace, agents: [.faeLocal])

        XCTAssertFalse(ready.isFreshWorkspace)
        XCTAssertTrue(ready.isReadyForGroundedWork)
        XCTAssertEqual(ready.completedRequiredCount, 2)
    }

    func testConsensusAgentsPrefersSelectedThenLocalThenOthers() {
        let local = WorkWithFaeAgentProfile.faeLocal
        let selected = WorkWithFaeAgentProfile(
            id: "agent-openai",
            name: "OpenAI",
            providerKind: .openAICompatibleExternal,
            backendPresetID: "openai",
            modelIdentifier: "gpt-4.1",
            baseURL: "https://api.openai.com",
            credentialKey: "agents.openai.key",
            notes: nil,
            createdAt: Date()
        )
        let other = WorkWithFaeAgentProfile(
            id: "agent-anthropic",
            name: "Anthropic",
            providerKind: .anthropic,
            backendPresetID: "anthropic",
            modelIdentifier: "claude-sonnet-4-5",
            baseURL: "https://api.anthropic.com",
            credentialKey: "agents.anthropic.key",
            notes: nil,
            createdAt: Date()
        )

        let ordered = WorkWithFaeWorkspaceStore.consensusAgents(
            selectedAgentID: selected.id,
            agents: [other, local, selected],
            limit: 4
        )

        XCTAssertEqual(ordered.map(\.id), [selected.id, local.id, other.id])
    }

    func testConsensusAgentsRespectStrictLocalPolicy() {
        let local = WorkWithFaeAgentProfile.faeLocal
        let selected = WorkWithFaeAgentProfile(
            id: "agent-openrouter",
            name: "OpenRouter",
            providerKind: .openAICompatibleExternal,
            backendPresetID: "openrouter",
            modelIdentifier: "openai/gpt-4.1-mini",
            baseURL: "https://openrouter.ai/api",
            credentialKey: "agents.openrouter.key",
            notes: nil,
            createdAt: Date()
        )
        let ordered = WorkWithFaeWorkspaceStore.consensusAgents(
            selectedAgentID: selected.id,
            agents: [selected, local],
            policy: WorkWithFaeWorkspacePolicy(remoteExecution: .strictLocalOnly, compareBehavior: .alwaysCompare),
            limit: 4
        )

        XCTAssertEqual(ordered.map(\.id), [local.id])
    }

    func testConsensusAgentsRespectExplicitWorkspaceSelection() {
        let local = WorkWithFaeAgentProfile.faeLocal
        let openRouter = WorkWithFaeAgentProfile(
            id: "agent-openrouter",
            name: "OpenRouter",
            providerKind: .openAICompatibleExternal,
            backendPresetID: "openrouter",
            modelIdentifier: "openai/gpt-4.1-mini",
            baseURL: "https://openrouter.ai/api",
            credentialKey: "agents.openrouter.key",
            notes: nil,
            createdAt: Date()
        )
        let anthropic = WorkWithFaeAgentProfile(
            id: "agent-anthropic",
            name: "Anthropic",
            providerKind: .anthropic,
            backendPresetID: "anthropic",
            modelIdentifier: "claude-sonnet-4-5",
            baseURL: "https://api.anthropic.com",
            credentialKey: "agents.anthropic.key",
            notes: nil,
            createdAt: Date()
        )

        let ordered = WorkWithFaeWorkspaceStore.consensusAgents(
            selectedAgentID: openRouter.id,
            agents: [local, openRouter, anthropic],
            policy: WorkWithFaeWorkspacePolicy(
                remoteExecution: .allowRemote,
                compareBehavior: .onDemand,
                consensusAgentIDs: [anthropic.id, local.id]
            ),
            limit: 4
        )

        XCTAssertEqual(ordered.map(\.id), [anthropic.id, local.id])
    }

    func testExecutionAgentUsesLocalWhenWorkspaceIsStrictLocalOnly() {
        let remoteAgent = WorkWithFaeAgentProfile(
            id: "agent-openrouter",
            name: "OpenRouter",
            providerKind: .openAICompatibleExternal,
            backendPresetID: "openrouter",
            modelIdentifier: "openai/gpt-4.1-mini",
            baseURL: "https://openrouter.ai/api",
            credentialKey: "agents.openrouter.key",
            notes: nil,
            createdAt: Date()
        )
        let workspace = WorkWithFaeWorkspaceRecord(
            name: "Private client",
            agentID: remoteAgent.id,
            policy: WorkWithFaeWorkspacePolicy(remoteExecution: .strictLocalOnly, compareBehavior: .onDemand)
        )
        let registry = WorkWithFaeWorkspaceRegistry(
            selectedWorkspaceID: workspace.id,
            workspaces: [workspace],
            agents: [remoteAgent, .faeLocal]
        )

        let executionAgent = WorkWithFaeWorkspaceStore.executionAgent(in: registry)
        XCTAssertEqual(executionAgent?.id, WorkWithFaeAgentProfile.faeLocal.id)
    }

    func testRegistryByUpdatingWorkspacePolicyPersistsPolicyChange() {
        let registry = WorkWithFaeWorkspaceRegistry.default
        let updated = WorkWithFaeWorkspaceStore.registryByUpdatingWorkspacePolicy(
            workspaceID: registry.selectedWorkspaceID,
            policy: WorkWithFaeWorkspacePolicy(remoteExecution: .strictLocalOnly, compareBehavior: .alwaysCompare),
            in: registry
        )

        XCTAssertEqual(
            WorkWithFaeWorkspaceStore.selectedWorkspace(in: updated)?.policy,
            WorkWithFaeWorkspacePolicy(remoteExecution: .strictLocalOnly, compareBehavior: .alwaysCompare)
        )
    }

    func testRegistryByTogglingConsensusAgentTracksCustomSelection() {
        let remoteAgent = WorkWithFaeAgentProfile(
            id: "agent-openrouter",
            name: "OpenRouter",
            providerKind: .openAICompatibleExternal,
            backendPresetID: "openrouter",
            modelIdentifier: "openai/gpt-4.1-mini",
            baseURL: "https://openrouter.ai/api",
            credentialKey: "agents.openrouter.key",
            notes: nil,
            createdAt: Date()
        )
        let workspace = WorkWithFaeWorkspaceRecord(name: "Client", agentID: remoteAgent.id)
        let registry = WorkWithFaeWorkspaceRegistry(
            selectedWorkspaceID: workspace.id,
            workspaces: [workspace],
            agents: [WorkWithFaeAgentProfile.faeLocal, remoteAgent]
        )

        let updated = WorkWithFaeWorkspaceStore.registryByTogglingConsensusAgent(
            workspaceID: workspace.id,
            agentID: remoteAgent.id,
            in: registry
        )

        XCTAssertEqual(
            WorkWithFaeWorkspaceStore.selectedWorkspace(in: updated)?.policy.consensusAgentIDs,
            [remoteAgent.id]
        )
    }

    func testNormalizedRegistryFiltersConsensusSelectionToAllowedAgents() {
        let remoteAgent = WorkWithFaeAgentProfile(
            id: "agent-openrouter",
            name: "OpenRouter",
            providerKind: .openAICompatibleExternal,
            backendPresetID: "openrouter",
            modelIdentifier: "openai/gpt-4.1-mini",
            baseURL: "https://openrouter.ai/api",
            credentialKey: "agents.openrouter.key",
            notes: nil,
            createdAt: Date()
        )
        let workspace = WorkWithFaeWorkspaceRecord(
            name: "Private client",
            agentID: remoteAgent.id,
            policy: WorkWithFaeWorkspacePolicy(
                remoteExecution: .strictLocalOnly,
                compareBehavior: .alwaysCompare,
                consensusAgentIDs: [remoteAgent.id, WorkWithFaeAgentProfile.faeLocal.id]
            )
        )
        let registry = WorkWithFaeWorkspaceRegistry(
            selectedWorkspaceID: workspace.id,
            workspaces: [workspace],
            agents: [remoteAgent, .faeLocal]
        )

        let normalized = WorkWithFaeWorkspaceStore.normalized(registry)
        XCTAssertEqual(
            WorkWithFaeWorkspaceStore.selectedWorkspace(in: normalized)?.policy.consensusAgentIDs,
            [WorkWithFaeAgentProfile.faeLocal.id]
        )
    }
}
