import Combine
import XCTest
@testable import Fae

final class ApprovalManagerTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        await ApprovedToolsStore.shared.revokeAll()
        cancellables.removeAll()
    }

    override func tearDown() async throws {
        await ApprovedToolsStore.shared.revokeAll()
        cancellables.removeAll()
    }

    func testRequestApprovalPublishesManualDisasterRequestAndResolves() async throws {
        let bus = FaeEventBus()
        let manager = ApprovalManager(eventBus: bus)

        let requested = expectation(description: "approval requested")
        let resolved = expectation(description: "approval resolved")
        var requestPayload: (id: UInt64, tool: String, manualOnly: Bool, isDisaster: Bool)?
        var resolutionPayload: (id: UInt64, approved: Bool, source: String)?

        bus.subject.sink { event in
            switch event {
            case .approvalRequested(let id, let toolName, _, let manualOnly, let isDisasterLevel):
                requestPayload = (id, toolName, manualOnly, isDisasterLevel)
                requested.fulfill()
            case .approvalResolved(let id, let approved, let source):
                resolutionPayload = (id, approved, source)
                resolved.fulfill()
            default:
                break
            }
        }.store(in: &cancellables)

        let task = Task {
            await manager.requestApproval(
                toolName: "bash",
                description: "Run a command",
                manualOnly: true,
                isDisasterLevel: true
            )
        }

        await fulfillment(of: [requested], timeout: 1.0)
        XCTAssertEqual(requestPayload?.tool, "bash")
        XCTAssertEqual(requestPayload?.manualOnly, true)
        XCTAssertEqual(requestPayload?.isDisaster, true)

        let handled = await manager.resolveMostRecent(approved: true, source: "voice")
        XCTAssertTrue(handled)
        let approved = await task.value

        await fulfillment(of: [resolved], timeout: 1.0)
        XCTAssertTrue(approved)
        XCTAssertEqual(resolutionPayload?.id, requestPayload?.id)
        XCTAssertEqual(resolutionPayload?.approved, true)
        XCTAssertEqual(resolutionPayload?.source, "voice")
    }

    func testResolveMostRecentUsesLifoOrderAcrossPendingApprovals() async throws {
        let bus = FaeEventBus()
        let manager = ApprovalManager(eventBus: bus)

        let requested = expectation(description: "two approval requests")
        requested.expectedFulfillmentCount = 2
        var requestedIDs: [UInt64] = []
        var resolvedIDs: [UInt64] = []

        bus.subject.sink { event in
            switch event {
            case .approvalRequested(let id, _, _, _, _):
                requestedIDs.append(id)
                requested.fulfill()
            case .approvalResolved(let id, _, _):
                resolvedIDs.append(id)
            default:
                break
            }
        }.store(in: &cancellables)

        let firstTask = Task {
            await manager.requestApproval(toolName: "write", description: "Write a file")
        }
        let secondTask = Task {
            await manager.requestApproval(toolName: "edit", description: "Edit a file")
        }

        await fulfillment(of: [requested], timeout: 1.0)
        XCTAssertEqual(requestedIDs, [1, 2])

        let handledSecond = await manager.resolveMostRecent(approved: false, source: "voice")
        XCTAssertTrue(handledSecond)
        let secondResult = await secondTask.value
        XCTAssertFalse(secondResult)

        let handledFirst = await manager.resolveMostRecent(approved: true, source: "voice")
        XCTAssertTrue(handledFirst)
        let firstResult = await firstTask.value
        XCTAssertTrue(firstResult)

        XCTAssertEqual(resolvedIDs, [2, 1])
    }

    func testAlwaysDecisionPersistsToolGrant() async throws {
        let bus = FaeEventBus()
        let manager = ApprovalManager(eventBus: bus)
        let requested = expectation(description: "approval requested")

        bus.subject.sink { event in
            if case .approvalRequested = event {
                requested.fulfill()
            }
        }.store(in: &cancellables)

        let task = Task {
            await manager.requestApproval(toolName: "write", description: "Write a file")
        }
        await fulfillment(of: [requested], timeout: 1.0)

        let handled = await manager.resolveMostRecent(decision: .always, source: "voice")
        XCTAssertTrue(handled)
        let approvedResult = await task.value
        XCTAssertTrue(approvedResult)
        try await Task.sleep(nanoseconds: 100_000_000)

        let approved = await ApprovedToolsStore.shared.isToolApproved("write")
        XCTAssertTrue(approved)
    }

    func testApproveAllEscalationsPersistGlobalFlags() async throws {
        let bus = FaeEventBus()
        let manager = ApprovalManager(eventBus: bus)
        let requested = expectation(description: "two approval requests")
        requested.expectedFulfillmentCount = 2

        bus.subject.sink { event in
            if case .approvalRequested = event {
                requested.fulfill()
            }
        }.store(in: &cancellables)

        let readOnlyTask = Task {
            await manager.requestApproval(toolName: "read", description: "Read a file")
        }
        let fullTask = Task {
            await manager.requestApproval(toolName: "bash", description: "Run a command")
        }

        await fulfillment(of: [requested], timeout: 1.0)

        let handledFull = await manager.resolveMostRecent(decision: .approveAll, source: "voice")
        XCTAssertTrue(handledFull)
        let fullApproved = await fullTask.value
        XCTAssertTrue(fullApproved)
        let handledReadonly = await manager.resolveMostRecent(decision: .approveAllReadOnly, source: "voice")
        XCTAssertTrue(handledReadonly)
        let readOnlyApproved = await readOnlyTask.value
        XCTAssertTrue(readOnlyApproved)
        try await Task.sleep(nanoseconds: 150_000_000)

        let approveAll = await ApprovedToolsStore.shared.isApproveAll()
        let approveAllReadonly = await ApprovedToolsStore.shared.isApproveAllReadonly()
        XCTAssertTrue(approveAll)
        XCTAssertTrue(approveAllReadonly)
    }

    func testRequestApprovalTimesOutPublishesResolutionAndClearsPendingState() async throws {
        let bus = FaeEventBus()
        let manager = ApprovalManager(eventBus: bus, timeoutSeconds: 0.05)
        let requested = expectation(description: "approval requested")
        let timedOut = expectation(description: "approval timed out")
        var resolvedEvents: [(id: UInt64, approved: Bool, source: String)] = []

        bus.subject.sink { event in
            switch event {
            case .approvalRequested:
                requested.fulfill()
            case .approvalResolved(let id, let approved, let source):
                resolvedEvents.append((id, approved, source))
                if source == "timeout" {
                    timedOut.fulfill()
                }
            default:
                break
            }
        }.store(in: &cancellables)

        let task = Task {
            await manager.requestApproval(toolName: "bash", description: "Run a command")
        }

        await fulfillment(of: [requested, timedOut], timeout: 1.0)
        let approved = await task.value
        XCTAssertFalse(approved)
        XCTAssertEqual(resolvedEvents.count, 1)
        XCTAssertEqual(resolvedEvents.first?.approved, false)
        XCTAssertEqual(resolvedEvents.first?.source, "timeout")

        let handled = await manager.resolveMostRecent(approved: true, source: "voice")
        XCTAssertFalse(handled)
    }

    func testLateManualResolutionAfterTimeoutDoesNotPublishDuplicateResolution() async throws {
        let bus = FaeEventBus()
        let manager = ApprovalManager(eventBus: bus, timeoutSeconds: 0.05)
        let requested = expectation(description: "approval requested")
        let timedOut = expectation(description: "approval timed out")
        var resolutionSources: [String] = []

        bus.subject.sink { event in
            switch event {
            case .approvalRequested:
                requested.fulfill()
            case .approvalResolved(_, _, let source):
                resolutionSources.append(source)
                if source == "timeout" {
                    timedOut.fulfill()
                }
            default:
                break
            }
        }.store(in: &cancellables)

        let task = Task {
            await manager.requestApproval(toolName: "edit", description: "Edit a file")
        }

        await fulfillment(of: [requested, timedOut], timeout: 1.0)
        let approved = await task.value
        XCTAssertFalse(approved)

        await manager.resolve(requestId: 1, approved: true, source: "voice")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(resolutionSources, ["timeout"])
    }

    func testPendingApprovalSnapshotsTrackAndClearCurrentRequests() async throws {
        let bus = FaeEventBus()
        let manager = ApprovalManager(eventBus: bus)
        let requested = expectation(description: "approval requested")

        bus.subject.sink { event in
            if case .approvalRequested = event {
                requested.fulfill()
            }
        }.store(in: &cancellables)

        let task = Task {
            await manager.requestApproval(toolName: "write", description: "Write a file")
        }

        await fulfillment(of: [requested], timeout: 1.0)
        let pending = await manager.pendingApprovalSnapshots()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?["tool"] as? String, "write")
        XCTAssertEqual(pending.first?["summary"] as? String, "Write a file")
        let mostRecentPendingID = await manager.mostRecentPendingApprovalID()
        XCTAssertEqual(mostRecentPendingID, pending.first?["id"] as? UInt64)

        await manager.clearPendingApprovals(source: "test")
        let denied = await task.value
        XCTAssertFalse(denied)
        let remainingPending = await manager.pendingApprovalSnapshots()
        let remainingPendingID = await manager.mostRecentPendingApprovalID()
        XCTAssertTrue(remainingPending.isEmpty)
        XCTAssertNil(remainingPendingID)
    }
}
