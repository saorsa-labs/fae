import XCTest
@testable import Fae

final class ToolApprovalRegressionTests: XCTestCase {
    override func setUp() async throws {
        await ApprovedToolsStore.shared.revokeAll()
        await OutboundExfiltrationGuard.shared.resetForTesting()
    }

    override func tearDown() async throws {
        await ApprovedToolsStore.shared.revokeAll()
        await OutboundExfiltrationGuard.shared.resetForTesting()
    }

    func testToolRegistryModeFilteringAndNativeSpecsStayConsistent() {
        let registry = ToolRegistry.buildDefault()

        // Assistant mode: read-only tools only
        XCTAssertTrue(registry.isToolAllowed("read", mode: "assistant"))
        XCTAssertFalse(registry.isToolAllowed("write", mode: "assistant"))
        XCTAssertFalse(registry.isToolAllowed("bash", mode: "assistant"))

        // Full mode: all tools
        XCTAssertTrue(registry.isToolAllowed("bash", mode: "full"))
        XCTAssertTrue(registry.isToolAllowed("delegate_agent", mode: "full"))

        let assistantSpecs = registry.nativeToolSpecs(for: "assistant") ?? []
        let fullSpecs = registry.nativeToolSpecs(for: "full") ?? []

        XCTAssertFalse(assistantSpecs.isEmpty)
        XCTAssertGreaterThan(fullSpecs.count, assistantSpecs.count)
    }

    func testToolRegistryLimitedSchemasRespectSubsetAndStrictLocalPrivacy() {
        let registry = ToolRegistry.buildDefault()
        let limited = registry.toolSchemas(for: "full", limitedTo: ["read", "bash", "delegate_agent"])
        XCTAssertTrue(limited.contains("## read"))
        XCTAssertTrue(limited.contains("## bash"))
        XCTAssertTrue(limited.contains("## delegate_agent"))
        XCTAssertFalse(limited.contains("## write"))

        let strictLocalSpecs = registry.nativeToolSpecs(for: "full", privacyMode: "strict_local") ?? []
        let strictLocalNames = strictLocalSpecs.compactMap { spec in
            (spec["function"] as? [String: any Sendable])?["name"] as? String
        }
        XCTAssertFalse(strictLocalNames.contains("delegate_agent"))
        XCTAssertFalse(strictLocalNames.contains("web_search"))
        XCTAssertFalse(strictLocalNames.contains("fetch_url"))
    }

    func testApprovedToolsStoreAutoApprovalMatrixHonorsRiskAndScope() async {
        let store = ApprovedToolsStore.shared

        let initiallyApproved = await store.shouldAutoApprove(toolName: "read", riskLevel: .low)
        XCTAssertFalse(initiallyApproved)

        await store.approveTool("write")
        let writeApproved = await store.shouldAutoApprove(toolName: "write", riskLevel: .medium)
        let bashApprovedBeforeGlobal = await store.shouldAutoApprove(toolName: "bash", riskLevel: .high)
        XCTAssertTrue(writeApproved)
        XCTAssertFalse(bashApprovedBeforeGlobal)

        await store.setApproveAllReadonly(true)
        let readApprovedInReadonly = await store.shouldAutoApprove(toolName: "read", riskLevel: .low)
        let bashApprovedInReadonly = await store.shouldAutoApprove(toolName: "bash", riskLevel: .high)
        XCTAssertTrue(readApprovedInReadonly)
        XCTAssertFalse(bashApprovedInReadonly)

        await store.setApproveAll(true)
        let bashApprovedAfterGlobal = await store.shouldAutoApprove(toolName: "bash", riskLevel: .high)
        XCTAssertTrue(bashApprovedAfterGlobal)
    }

    func testRevokingSpecificToolApprovalRestoresPromptRequirement() async {
        let store = ApprovedToolsStore.shared

        await store.approveTool("write")
        let approvedBeforeRevoke = await store.shouldAutoApprove(toolName: "write", riskLevel: .medium)
        let approvedToolNamesBeforeRevoke = await store.approvedToolNames()
        XCTAssertTrue(approvedBeforeRevoke)
        XCTAssertEqual(approvedToolNamesBeforeRevoke, ["write"])

        await store.revokeTool("write")

        let approvedAfterRevoke = await store.shouldAutoApprove(toolName: "write", riskLevel: .medium)
        let approvedToolNamesAfterRevoke = await store.approvedToolNames()
        XCTAssertFalse(approvedAfterRevoke)
        XCTAssertEqual(approvedToolNamesAfterRevoke, [])
    }

    func testRevokeAllClearsGlobalApprovalFlagsAndSnapshot() async {
        let store = ApprovedToolsStore.shared

        await store.approveTool("read")
        await store.setApproveAllReadonly(true)
        await store.setApproveAll(true)

        let grantedSnapshot = await store.approvalSnapshot()
        XCTAssertEqual(grantedSnapshot.approvedTools, ["read"])
        XCTAssertTrue(grantedSnapshot.approveAllReadonly)
        XCTAssertTrue(grantedSnapshot.approveAll)

        await store.revokeAll()

        let revokedSnapshot = await store.approvalSnapshot()
        let readApprovedAfterRevoke = await store.shouldAutoApprove(toolName: "read", riskLevel: .low)
        let bashApprovedAfterRevoke = await store.shouldAutoApprove(toolName: "bash", riskLevel: .high)
        XCTAssertEqual(revokedSnapshot.approvedTools, [])
        XCTAssertFalse(revokedSnapshot.approveAllReadonly)
        XCTAssertFalse(revokedSnapshot.approveAll)
        XCTAssertFalse(readApprovedAfterRevoke)
        XCTAssertFalse(bashApprovedAfterRevoke)
    }

    func testOutboundExfiltrationGuardDeniesSensitivePayloads() async {
        let decision = await OutboundExfiltrationGuard.shared.evaluate(
            toolName: "mail",
            arguments: [
                "action": "send",
                "to": "friend@example.com",
                "body": "Here is my api_key=sk-1234567890123456789012345678901234567890",
            ]
        )

        guard case .deny(let message) = decision else {
            XCTFail("Expected sensitive outbound payload to be denied")
            return
        }
        XCTAssertTrue(message.lowercased().contains("blocked"))
    }

    func testOutboundExfiltrationGuardTreatsChannelIdentifiersAsRecipients() async {
        let decision = await OutboundExfiltrationGuard.shared.evaluate(
            toolName: "channel_out",
            arguments: [
                "action": "post",
                "channel_id": "C123456",
                "message": "status update",
            ]
        )

        guard case .confirm(let message) = decision else {
            XCTFail("Expected a novelty confirmation for a first-time channel recipient")
            return
        }
        XCTAssertTrue(message.lowercased().contains("new recipient"))
    }
}
