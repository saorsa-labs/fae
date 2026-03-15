import Foundation
import XCTest
@testable import Fae

final class EndToEndAllowWithTransformTests: XCTestCase {
    override func setUp() async throws {
        await ApprovedToolsStore.shared.revokeAll()
    }

    func testHighRiskWriteRequiresConfirmation() async {
        let broker = DefaultTrustedActionBroker(
            knownTools: ["write"],
            speakerConfig: FaeConfig.SpeakerConfig()
        )

        let intent = ActionIntent(
            source: .text,
            toolName: "write",
            riskLevel: .high,
            requiresApproval: true,
            isOwner: true,
            livenessScore: 1.0,
            explicitUserAuthorization: false,
            hasCapabilityTicket: true,
            argumentSummary: "I can write to /tmp/example.txt. Proceed?"
        )

        let decision = await broker.evaluate(intent)
        switch decision {
        case .confirm:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected confirm for high-risk write action")
        }
    }

    func testHighRiskManageSkillDeleteRequiresConfirmation() async {
        let broker = DefaultTrustedActionBroker(
            knownTools: ["manage_skill"],
            speakerConfig: FaeConfig.SpeakerConfig()
        )

        let intent = ActionIntent(
            source: .text,
            toolName: "manage_skill",
            riskLevel: .high,
            requiresApproval: true,
            isOwner: true,
            livenessScore: 1.0,
            explicitUserAuthorization: false,
            hasCapabilityTicket: true,
            argumentSummary: "I can delete a skill in your local skills library. Continue?"
        )

        let decision = await broker.evaluate(intent)
        switch decision {
        case .confirm:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected confirm for high-risk manage_skill delete action")
        }
    }

    func testCheckpointAndRollbackRestoresFileContents() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-transform-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let file = tempDir.appendingPathComponent("state.txt")
        try "before".write(to: file, atomically: true, encoding: .utf8)

        guard let checkpoint = ReversibilityEngine.createCheckpoint(for: file.path, reason: "test") else {
            XCTFail("checkpoint should be created")
            return
        }

        try "after".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: file), "after")

        let restored = ReversibilityEngine.restore(checkpointId: checkpoint)
        XCTAssertTrue(restored)
        XCTAssertEqual(try String(contentsOf: file), "before")
    }

    func testOutboundGuardConfirmsNovelRecipientThenLearnsIt() async {
        let guardrail = OutboundExfiltrationGuard.shared
        await guardrail.resetForTesting()

        let args: [String: Any] = [
            "recipient": "new@example.com",
            "message": "hello there"
        ]

        let first = await guardrail.evaluate(toolName: "mail_send", arguments: args)
        if case .confirm = first {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected confirm for novel recipient")
        }

        await guardrail.recordSuccessfulSend(toolName: "mail_send", arguments: args)

        let second = await guardrail.evaluate(toolName: "mail_send", arguments: args)
        XCTAssertNil(second)
    }

    func testOutboundGuardDeniesSensitivePayload() async {
        let guardrail = OutboundExfiltrationGuard.shared
        await guardrail.resetForTesting()

        let args: [String: Any] = [
            "recipient": "ops@example.com",
            "message": "Here is my api_key=ABCDEF1234567890ABCDEF1234567890ABCDEF"
        ]

        let decision = await guardrail.evaluate(toolName: "mail_send", arguments: args)
        if case .deny = decision {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected deny for sensitive outbound payload")
        }
    }
}
