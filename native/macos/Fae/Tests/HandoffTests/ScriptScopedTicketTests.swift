import XCTest
@testable import Fae

// MARK: - CapabilityTicket Script Scope Tests

final class ScriptScopedTicketTests: XCTestCase {

    // MARK: - CapabilityTicket with scriptRunId

    func testTicketAllowsToolWhenValid() {
        let ticket = CapabilityTicket(
            id: "t1",
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(300),
            allowedTools: ["read", "write"],
            scriptRunId: "run-1"
        )

        XCTAssertTrue(ticket.allows(toolName: "read"))
        XCTAssertTrue(ticket.allows(toolName: "write"))
        XCTAssertFalse(ticket.allows(toolName: "bash"))
    }

    func testTicketRejectsAfterExpiry() {
        let ticket = CapabilityTicket(
            id: "t2",
            issuedAt: Date().addingTimeInterval(-600),
            expiresAt: Date().addingTimeInterval(-1),
            allowedTools: ["read"],
            scriptRunId: "run-2"
        )

        XCTAssertFalse(ticket.allows(toolName: "read"))
    }

    func testTicketPreservesScriptRunId() {
        let ticket = CapabilityTicket(
            id: "t3",
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(300),
            allowedTools: ["read"],
            scriptRunId: "run-abc"
        )

        XCTAssertEqual(ticket.scriptRunId, "run-abc")
    }

    func testTicketWithoutScriptRunId() {
        let ticket = CapabilityTicket(
            id: "t4",
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(300),
            allowedTools: ["read"]
        )

        XCTAssertNil(ticket.scriptRunId)
        XCTAssertTrue(ticket.allows(toolName: "read"))
    }

    // MARK: - CapabilityTicketIssuer.issueForScript

    func testIssueForScriptSetsRunId() {
        let ticket = CapabilityTicketIssuer.issueForScript(
            scriptRunId: "run-42",
            allowedTools: ["read", "write"]
        )

        XCTAssertEqual(ticket.scriptRunId, "run-42")
        XCTAssertEqual(ticket.allowedTools, ["read", "write"])
        XCTAssertTrue(ticket.allows(toolName: "read"))
        XCTAssertFalse(ticket.allows(toolName: "bash"))
    }

    func testIssueForScriptRespectsTTL() {
        let ticket = CapabilityTicketIssuer.issueForScript(
            scriptRunId: "run-ttl",
            allowedTools: ["read"],
            ttlSeconds: 10
        )

        // Expiry should be ~10s from now.
        let expectedExpiry = Date().addingTimeInterval(10)
        XCTAssertTrue(
            abs(ticket.expiresAt.timeIntervalSince(expectedExpiry)) < 2,
            "Expected expiry ~10s from now, got \(ticket.expiresAt)"
        )
    }

    // MARK: - ScriptScopedTicketManager — Issue & Revoke

    func testManagerIssuesTicket() {
        let manager = ScriptScopedTicketManager()

        let ticket = manager.issue(scriptRunId: "run-1", allowedTools: ["read"])
        XCTAssertNotNil(ticket)
        XCTAssertEqual(ticket?.scriptRunId, "run-1")
        XCTAssertEqual(manager.activeCount, 1)
    }

    func testManagerPreventsDoubleIssue() {
        let manager = ScriptScopedTicketManager()

        let first = manager.issue(scriptRunId: "run-1", allowedTools: ["read"])
        let second = manager.issue(scriptRunId: "run-1", allowedTools: ["write"])

        XCTAssertNotNil(first)
        XCTAssertNil(second, "Second issue for same run ID should return nil")
        XCTAssertEqual(manager.activeCount, 1)
    }

    func testManagerRevokesTicket() {
        let manager = ScriptScopedTicketManager()

        _ = manager.issue(scriptRunId: "run-1", allowedTools: ["read"])
        XCTAssertEqual(manager.activeCount, 1)

        let revoked = manager.revoke(scriptRunId: "run-1")
        XCTAssertNotNil(revoked)
        XCTAssertEqual(manager.activeCount, 0)
    }

    func testManagerRevokeReturnsNilForUnknownRun() {
        let manager = ScriptScopedTicketManager()

        let revoked = manager.revoke(scriptRunId: "nonexistent")
        XCTAssertNil(revoked)
    }

    func testManagerLookupReturnsActiveTicket() {
        let manager = ScriptScopedTicketManager()
        _ = manager.issue(scriptRunId: "run-1", allowedTools: ["read", "write"])

        let ticket = manager.ticket(for: "run-1")
        XCTAssertNotNil(ticket)
        XCTAssertEqual(ticket?.allowedTools, ["read", "write"])
    }

    func testManagerLookupReturnsNilAfterRevoke() {
        let manager = ScriptScopedTicketManager()
        _ = manager.issue(scriptRunId: "run-1", allowedTools: ["read"])
        manager.revoke(scriptRunId: "run-1")

        let ticket = manager.ticket(for: "run-1")
        XCTAssertNil(ticket)
    }

    // MARK: - ScriptScopedTicketManager — Tool Checks

    func testManagerAllowsToolInScope() {
        let manager = ScriptScopedTicketManager()
        _ = manager.issue(scriptRunId: "run-1", allowedTools: ["read", "write"])

        XCTAssertTrue(manager.allows(toolName: "read", scriptRunId: "run-1"))
        XCTAssertTrue(manager.allows(toolName: "write", scriptRunId: "run-1"))
        XCTAssertFalse(manager.allows(toolName: "bash", scriptRunId: "run-1"))
    }

    func testManagerDeniesToolAfterRevoke() {
        let manager = ScriptScopedTicketManager()
        _ = manager.issue(scriptRunId: "run-1", allowedTools: ["read"])
        manager.revoke(scriptRunId: "run-1")

        XCTAssertFalse(manager.allows(toolName: "read", scriptRunId: "run-1"))
    }

    func testManagerDeniesToolForWrongRun() {
        let manager = ScriptScopedTicketManager()
        _ = manager.issue(scriptRunId: "run-1", allowedTools: ["read"])

        XCTAssertFalse(manager.allows(toolName: "read", scriptRunId: "run-2"))
    }

    // MARK: - ScriptScopedTicketManager — Expiry

    func testManagerAutoExpiresTicket() {
        let manager = ScriptScopedTicketManager()
        // Issue a ticket with 0-second TTL (already expired).
        _ = manager.issue(scriptRunId: "run-expired", allowedTools: ["read"], ttlSeconds: 0)

        // The ticket should be auto-expired on lookup.
        let ticket = manager.ticket(for: "run-expired")
        XCTAssertNil(ticket, "Expired ticket should return nil on lookup")
        XCTAssertFalse(manager.allows(toolName: "read", scriptRunId: "run-expired"))
    }

    // MARK: - ScriptScopedTicketManager — RevokeAll

    func testManagerRevokeAllClearsEverything() {
        let manager = ScriptScopedTicketManager()
        _ = manager.issue(scriptRunId: "run-1", allowedTools: ["read"])
        _ = manager.issue(scriptRunId: "run-2", allowedTools: ["write"])

        XCTAssertEqual(manager.activeCount, 2)
        manager.revokeAll()
        XCTAssertEqual(manager.activeCount, 0)
    }

    // MARK: - ScriptScopedTicketManager — Multiple Concurrent Runs

    func testManagerTracksMultipleConcurrentRuns() {
        let manager = ScriptScopedTicketManager()
        _ = manager.issue(scriptRunId: "run-a", allowedTools: ["read"])
        _ = manager.issue(scriptRunId: "run-b", allowedTools: ["write"])

        XCTAssertTrue(manager.allows(toolName: "read", scriptRunId: "run-a"))
        XCTAssertFalse(manager.allows(toolName: "write", scriptRunId: "run-a"))
        XCTAssertTrue(manager.allows(toolName: "write", scriptRunId: "run-b"))
        XCTAssertFalse(manager.allows(toolName: "read", scriptRunId: "run-b"))

        manager.revoke(scriptRunId: "run-a")
        XCTAssertFalse(manager.allows(toolName: "read", scriptRunId: "run-a"))
        XCTAssertTrue(manager.allows(toolName: "write", scriptRunId: "run-b"))
        XCTAssertEqual(manager.activeCount, 1)
    }

    // MARK: - Ticket Does Not Leak Across Script Runs

    func testTicketDoesNotLeakAcrossRuns() {
        let manager = ScriptScopedTicketManager()

        // Simulate first script run.
        let ticket1 = manager.issue(scriptRunId: "run-1", allowedTools: ["read", "bash"])
        XCTAssertNotNil(ticket1)
        XCTAssertTrue(manager.allows(toolName: "bash", scriptRunId: "run-1"))

        // Revoke after first run completes.
        manager.revoke(scriptRunId: "run-1")

        // Second script run should NOT see the first ticket's tools.
        let ticket2 = manager.issue(scriptRunId: "run-2", allowedTools: ["read"])
        XCTAssertNotNil(ticket2)
        XCTAssertTrue(manager.allows(toolName: "read", scriptRunId: "run-2"))
        XCTAssertFalse(manager.allows(toolName: "bash", scriptRunId: "run-2"))

        // First run's ticket is still gone.
        XCTAssertFalse(manager.allows(toolName: "read", scriptRunId: "run-1"))
    }
}

// MARK: - JSCRuntime Ticket Integration Tests

final class JSCRuntimeTicketIntegrationTests: XCTestCase {

    // MARK: - Test Doubles

    private struct EchoTool: Tool {
        let name: String
        let description: String = "echoes input"
        let parametersSchema: String = "{}"
        let riskLevel: ToolRiskLevel = .low
        let requiresApproval: Bool = false

        func execute(input: [String: Any]) async throws -> ToolResult {
            if let data = try? JSONSerialization.data(withJSONObject: input),
               let json = String(data: data, encoding: .utf8)
            {
                return .success(json)
            }
            return .success("{}")
        }
    }

    private actor AllowBroker: TrustedActionBroker {
        func evaluate(_ intent: ActionIntent) async -> BrokerDecision {
            .allow(reason: DecisionReason(code: .allowLowRisk, message: "test allow"))
        }
    }

    // MARK: - Helpers

    private func makeRuntime(
        tools: [any Tool] = [],
        ticketManager: ScriptScopedTicketManager? = nil
    ) -> JSCRuntime {
        let registry = ToolRegistry(tools: tools)
        let executor = ToolExecutor(
            registry: registry,
            actionBroker: AllowBroker(),
            damageControlPolicy: DamageControlPolicy(),
            rateLimiter: ToolRateLimiter(),
            securityLogger: SecurityEventLogger.shared,
            outboundGuard: OutboundExfiltrationGuard.shared
        )

        return JSCRuntime(
            executor: executor,
            contextFactory: {
                ToolExecutorContext(
                    toolMode: "full",
                    privacyMode: "local_preferred",
                    modelLocality: .local,
                    capabilityTicket: nil,
                    hasCapabilityTicketForTool: true,
                    explicitUserAuthorization: false,
                    isOwner: true,
                    livenessScore: nil,
                    speakerId: nil,
                    actionSource: .voice,
                    proactiveContext: nil,
                    visionEnabled: false,
                    firstOwnerEnrollmentActive: false,
                    workflowTurnID: nil,
                    traceToolCallID: nil,
                    workflowRunID: nil
                )
            },
            callbacksFactory: {
                ToolExecutorCallbacks(
                    onApprovalPending: { _, _ in },
                    onVisionAutoEnabled: { },
                    onComputerUseStep: { 1 }
                )
            },
            ticketManager: ticketManager
        )
    }

    // MARK: - Ticket Scoped Tool Access

    func testAllowedToolSucceedsWithTicket() async {
        let ticketManager = ScriptScopedTicketManager()
        let echo = EchoTool(name: "read")
        let runtime = makeRuntime(tools: [echo], ticketManager: ticketManager)

        let result = await runtime.run(
            script: """
                var r = await fae.tool('read', '{"path":"test"}');
                return 'ok';
            """,
            allowedTools: ["read"]
        )

        XCTAssertEqual(result.status, .success, "Allowed tool should succeed, error: \(result.error ?? "none")")
        XCTAssertEqual(result.value, "ok")
    }

    func testDisallowedToolRejectedByTicket() async {
        let ticketManager = ScriptScopedTicketManager()
        let echo = EchoTool(name: "read")
        let runtime = makeRuntime(tools: [echo], ticketManager: ticketManager)

        let result = await runtime.run(
            script: """
                try {
                    await fae.tool('read', '{"path":"test"}');
                    return 'should not reach';
                } catch(e) {
                    fae.log('error: ' + e.message);
                    return 'rejected';
                }
            """,
            allowedTools: ["write"] // read is NOT in allowed tools
        )

        XCTAssertEqual(result.status, .success, "Script should catch rejection")
        XCTAssertEqual(result.value, "rejected")
        XCTAssertTrue(
            result.logs.first?.contains("Capability ticket") == true,
            "Expected ticket error in logs, got: \(result.logs)"
        )
    }

    func testTicketRevokedAfterSuccessfulRun() async {
        let ticketManager = ScriptScopedTicketManager()
        let echo = EchoTool(name: "read")
        let runtime = makeRuntime(tools: [echo], ticketManager: ticketManager)

        _ = await runtime.run(
            script: "return 'done';",
            allowedTools: ["read"]
        )

        // After the run, the ticket should be revoked.
        XCTAssertEqual(ticketManager.activeCount, 0, "Ticket should be revoked after run completes")
    }

    func testTicketRevokedAfterFailedRun() async {
        let ticketManager = ScriptScopedTicketManager()
        let runtime = makeRuntime(ticketManager: ticketManager)

        _ = await runtime.run(
            script: "throw new Error('intentional');",
            allowedTools: ["read"]
        )

        XCTAssertEqual(ticketManager.activeCount, 0, "Ticket should be revoked after run fails")
    }

    func testTicketRevokedAfterCancellation() async {
        let ticketManager = ScriptScopedTicketManager()
        let runtime = makeRuntime(ticketManager: ticketManager)

        // Launch a script that sleeps long enough for us to cancel.
        async let resultTask = runtime.run(
            script: """
                await fae.sleep(5000);
                return 'should not reach';
            """,
            budget: ScriptBudget(maxToolCalls: 10, maxWallClockSeconds: 60, maxConcurrentToolCalls: 5),
            allowedTools: ["read"]
        )

        // Wait a short time, then cancel.
        try? await Task.sleep(nanoseconds: 200_000_000)
        await runtime.cancelCurrent()

        let result = await resultTask

        XCTAssertTrue(
            result.status == .cancelled || result.status == .budgetExceeded,
            "Expected cancelled/budgetExceeded, got \(result.status)"
        )
        XCTAssertEqual(ticketManager.activeCount, 0, "Ticket should be revoked after cancellation")
    }

    func testNoTicketManagerAllowsBackwardCompat() async {
        // Without a ticket manager, scripts run as before.
        let echo = EchoTool(name: "read")
        let runtime = makeRuntime(tools: [echo], ticketManager: nil)

        let result = await runtime.run(
            script: """
                var r = await fae.tool('read', '{"path":"test"}');
                return 'ok';
            """
        )

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.value, "ok")
    }

    func testTicketDoesNotLeakBetweenRuns() async {
        let ticketManager = ScriptScopedTicketManager()
        let echo = EchoTool(name: "read")
        let runtime = makeRuntime(tools: [echo], ticketManager: ticketManager)

        // First run: allow "read".
        let r1 = await runtime.run(
            script: """
                var r = await fae.tool('read', '{"n":1}');
                return 'ok';
            """,
            allowedTools: ["read"]
        )
        XCTAssertEqual(r1.status, .success)
        XCTAssertEqual(ticketManager.activeCount, 0, "First run ticket should be revoked")

        // Second run: allow "write" only (NOT "read").
        let r2 = await runtime.run(
            script: """
                try {
                    await fae.tool('read', '{"n":2}');
                    return 'leaked';
                } catch(e) {
                    return 'blocked';
                }
            """,
            allowedTools: ["write"]
        )
        XCTAssertEqual(r2.status, .success)
        XCTAssertEqual(r2.value, "blocked", "Second run should NOT inherit first run's ticket")
        XCTAssertEqual(ticketManager.activeCount, 0)
    }
}
