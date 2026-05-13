import XCTest
@testable import Fae

final class WorkWithFaeWorkspaceTests: XCTestCase {

    // MARK: - selectedWorkspace

    func testSelectedWorkspaceDefault() {
        let registry = WorkWithFaeWorkspaceRegistry.default
        let selected = WorkWithFaeWorkspaceStore.selectedWorkspace(in: registry)
        XCTAssertNotNil(selected)
        XCTAssertEqual(selected?.name, "Main workspace")
    }

    func testSelectedWorkspaceEmpty() {
        let registry = WorkWithFaeWorkspaceRegistry(
            selectedWorkspaceID: nil,
            workspaces: [],
            agents: []
        )
        let selected = WorkWithFaeWorkspaceStore.selectedWorkspace(in: registry)
        XCTAssertNil(selected)
    }

    // MARK: - selectedAgent

    func testSelectedAgentDefault() {
        let registry = WorkWithFaeWorkspaceRegistry.default
        let agent = WorkWithFaeWorkspaceStore.selectedAgent(in: registry)
        XCTAssertNotNil(agent)
    }

    // MARK: - executionAgent

    func testExecutionAgentDefault() {
        let registry = WorkWithFaeWorkspaceRegistry.default
        let execAgent = WorkWithFaeWorkspaceStore.executionAgent(in: registry)
        XCTAssertNotNil(execAgent)
    }

    // MARK: - registryByUpsertingAgent

    func testUpsertingAgentNew() {
        var registry = WorkWithFaeWorkspaceRegistry.default
        let agent = WorkWithFaeAgentProfile.faeLocal
        registry = WorkWithFaeWorkspaceStore.registryByUpsertingAgent(
            agent, assignToSelectedWorkspace: false, in: registry
        )
        XCTAssertTrue(registry.agents.contains(where: { $0.id == agent.id }))
    }

    // MARK: - WorkWithFaeAgentProfile

    func testFaeLocalAgent() {
        let local = WorkWithFaeAgentProfile.faeLocal
        XCTAssertFalse(local.id.isEmpty)
        XCTAssertFalse(local.name.isEmpty)
    }

    // MARK: - WorkWithFaeRemoteExecutionPolicy

    func testRemoteExecutionPolicyCases() {
        XCTAssertEqual(WorkWithFaeRemoteExecutionPolicy.allCases.count, 3)
    }
}
