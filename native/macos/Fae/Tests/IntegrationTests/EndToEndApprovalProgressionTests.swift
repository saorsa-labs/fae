import XCTest
@testable import Fae

final class EndToEndApprovalProgressionTests: XCTestCase {
    override func setUp() async throws {
        await ApprovedToolsStore.shared.revokeAll()
    }

    override func tearDown() async throws {
        await ApprovedToolsStore.shared.revokeAll()
    }

    func testPerToolApprovalChangesBrokerDecisionFromConfirmToAllow() async {
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
            policyProfile: .balanced,
            argumentSummary: "Write a file to disk"
        )

        let initial = await broker.evaluate(intent)
        guard case .confirm = initial else {
            XCTFail("Expected write to require confirmation before a stored grant exists")
            return
        }

        await ApprovedToolsStore.shared.approveTool("write")
        let granted = await broker.evaluate(intent)

        guard case .allow(let reason) = granted else {
            XCTFail("Expected stored per-tool approval to auto-allow the same action")
            return
        }
        XCTAssertEqual(reason.code, .approvedByUserGrant)
    }

    func testApproveAllBypassesHighRiskForOwnerButNotVoiceIdentityGate() async {
        var speakerConfig = FaeConfig.SpeakerConfig()
        speakerConfig.requireOwnerForTools = true
        let ownerBroker = DefaultTrustedActionBroker(
            knownTools: ["bash"],
            speakerConfig: speakerConfig
        )
        await ApprovedToolsStore.shared.setApproveAll(true)

        let ownerIntent = ActionIntent(
            source: .voice,
            toolName: "bash",
            riskLevel: .high,
            requiresApproval: true,
            isOwner: true,
            livenessScore: 1.0,
            explicitUserAuthorization: false,
            hasCapabilityTicket: true,
            policyProfile: .balanced,
            argumentSummary: "Run bash command"
        )

        let ownerDecision = await ownerBroker.evaluate(ownerIntent)
        guard case .allow(let ownerReason) = ownerDecision else {
            XCTFail("Expected global approval to auto-allow owner high-risk action")
            return
        }
        XCTAssertEqual(ownerReason.code, .approvedByUserGrant)

        let nonOwnerDecision = await ownerBroker.evaluate(
            ActionIntent(
                source: .voice,
                toolName: "bash",
                riskLevel: .high,
                requiresApproval: true,
                isOwner: false,
                livenessScore: 1.0,
                explicitUserAuthorization: false,
                hasCapabilityTicket: true,
                policyProfile: .balanced,
                argumentSummary: "Run bash command"
            )
        )

        guard case .deny(let nonOwnerReason) = nonOwnerDecision else {
            XCTFail("Expected voice-identity gate to still deny a non-owner high-risk action")
            return
        }
        XCTAssertEqual(nonOwnerReason.code, .ownerRequired)
    }
}
