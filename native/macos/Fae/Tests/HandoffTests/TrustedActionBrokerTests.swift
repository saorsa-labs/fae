import XCTest
@testable import Fae

final class TrustedActionBrokerTests: XCTestCase {

    private func makeIntent(
        toolName: String,
        risk: ToolRiskLevel = .low,
        requiresApproval: Bool = false,
        isOwner: Bool = true,
        hasCapabilityTicket: Bool = true,
        explicitUserAuthorization: Bool = false,
        profile: PolicyProfile = .balanced,
        source: ActionSource = .voice,
        schedulerTaskId: String? = nil,
        schedulerConsentGranted: Bool = false
    ) -> ActionIntent {
        ActionIntent(
            source: source,
            toolName: toolName,
            riskLevel: risk,
            requiresApproval: requiresApproval,
            isOwner: isOwner,
            livenessScore: 1.0,
            explicitUserAuthorization: explicitUserAuthorization,
            hasCapabilityTicket: hasCapabilityTicket,
            policyProfile: profile,
            argumentSummary: "test",
            schedulerTaskId: schedulerTaskId,
            schedulerConsentGranted: schedulerConsentGranted
        )
    }

    func testUnknownToolDenied() async {
        let broker = DefaultTrustedActionBroker(
            knownTools: ["read", "write"],
            speakerConfig: FaeConfig.SpeakerConfig()
        )

        let decision = await broker.evaluate(makeIntent(toolName: "nope"))
        if case .deny(let reason) = decision {
            XCTAssertEqual(reason.code, .unknownTool)
        } else {
            XCTFail("Expected deny(unknownTool)")
        }
    }

    func testKnownButNoExplicitRuleDeniedByDefault() async {
        let broker = DefaultTrustedActionBroker(
            knownTools: ["custom_tool"],
            speakerConfig: FaeConfig.SpeakerConfig()
        )

        let decision = await broker.evaluate(makeIntent(toolName: "custom_tool"))
        if case .deny(let reason) = decision {
            XCTAssertEqual(reason.code, .noExplicitRule)
        } else {
            XCTFail("Expected deny(noExplicitRule)")
        }
    }

    func testMissingCapabilityTicketDenied() async {
        let broker = DefaultTrustedActionBroker(
            knownTools: ["read"],
            speakerConfig: FaeConfig.SpeakerConfig()
        )

        let decision = await broker.evaluate(
            makeIntent(toolName: "read", hasCapabilityTicket: false)
        )

        if case .deny(let reason) = decision {
            XCTAssertEqual(reason.code, .noCapabilityTicket)
        } else {
            XCTFail("Expected deny(noCapabilityTicket)")
        }
    }

    func testNonOwnerHighRiskDenied() async {
        var cfg = FaeConfig.SpeakerConfig()
        cfg.requireOwnerForTools = true

        let broker = DefaultTrustedActionBroker(
            knownTools: ["bash"],
            speakerConfig: cfg
        )

        let decision = await broker.evaluate(
            makeIntent(toolName: "bash", risk: .high, isOwner: false)
        )

        if case .deny(let reason) = decision {
            XCTAssertEqual(reason.code, .ownerRequired)
        } else {
            XCTFail("Expected ownerRequired deny")
        }
    }

    func testBalancedLowRiskAllows() async {
        let broker = DefaultTrustedActionBroker(
            knownTools: ["read"],
            speakerConfig: FaeConfig.SpeakerConfig()
        )

        let decision = await broker.evaluate(
            makeIntent(toolName: "read", risk: .low, profile: .balanced)
        )

        if case .allow = decision {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected allow")
        }
    }

    func testBalancedMediumHighImpactRequestsConfirmWhenAmbiguous() async {
        let broker = DefaultTrustedActionBroker(
            knownTools: ["run_skill"],
            speakerConfig: FaeConfig.SpeakerConfig()
        )

        let decision = await broker.evaluate(
            makeIntent(
                toolName: "run_skill",
                risk: .medium,
                explicitUserAuthorization: false,
                profile: .balanced
            )
        )

        if case .confirm = decision {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected confirm for ambiguous medium/high-impact action")
        }
    }

    func testAutonomousMediumWithExplicitIntentAllows() async {
        let broker = DefaultTrustedActionBroker(
            knownTools: ["run_skill"],
            speakerConfig: FaeConfig.SpeakerConfig()
        )

        let decision = await broker.evaluate(
            makeIntent(
                toolName: "run_skill",
                risk: .medium,
                explicitUserAuthorization: true,
                profile: .moreAutonomous
            )
        )

        if case .allow(let reason) = decision {
            XCTAssertEqual(
                reason.code.rawValue,
                DecisionReasonCode.allowAutonomousMediumRisk.rawValue
            )
        } else {
            XCTFail("Expected allow in autonomous mode for explicit medium-risk action")
        }
    }

    func testCautiousProfileAlwaysConfirms() async {
        let broker = DefaultTrustedActionBroker(
            knownTools: ["read"],
            speakerConfig: FaeConfig.SpeakerConfig()
        )

        let decision = await broker.evaluate(
            makeIntent(toolName: "read", risk: .low, profile: .moreCautious)
        )

        if case .confirm = decision {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected confirm in cautious profile")
        }
    }

    func testSchedulerRequiresConsent() async {
        let broker = DefaultTrustedActionBroker(
            knownTools: ["camera"],
            speakerConfig: FaeConfig.SpeakerConfig()
        )

        let decision = await broker.evaluate(
            makeIntent(
                toolName: "camera",
                source: .scheduler,
                schedulerTaskId: "camera_presence_check",
                schedulerConsentGranted: false
            )
        )

        if case .deny(let reason) = decision {
            XCTAssertEqual(reason.code, .noCapabilityTicket)
        } else {
            XCTFail("Expected deny when scheduler consent is absent")
        }
    }

    func testSchedulerUnknownTaskDenied() async {
        let broker = DefaultTrustedActionBroker(
            knownTools: ["camera"],
            speakerConfig: FaeConfig.SpeakerConfig()
        )

        let decision = await broker.evaluate(
            makeIntent(
                toolName: "camera",
                source: .scheduler,
                schedulerTaskId: "unknown_task",
                schedulerConsentGranted: true
            )
        )

        if case .deny(let reason) = decision {
            XCTAssertEqual(reason.code, .noExplicitRule)
        } else {
            XCTFail("Expected deny for unknown scheduler task")
        }
    }

    func testSchedulerNonAllowlistedToolDenied() async {
        let broker = DefaultTrustedActionBroker(
            knownTools: ["camera", "read"],
            speakerConfig: FaeConfig.SpeakerConfig()
        )

        let decision = await broker.evaluate(
            makeIntent(
                toolName: "read",
                source: .scheduler,
                schedulerTaskId: "camera_presence_check",
                schedulerConsentGranted: true
            )
        )

        if case .deny(let reason) = decision {
            XCTAssertEqual(reason.code, .noExplicitRule)
        } else {
            XCTFail("Expected deny for non-allowlisted scheduler tool")
        }
    }

    func testSchedulerAllowlistedToolAllowed() async {
        let broker = DefaultTrustedActionBroker(
            knownTools: ["camera"],
            speakerConfig: FaeConfig.SpeakerConfig()
        )

        let decision = await broker.evaluate(
            makeIntent(
                toolName: "camera",
                source: .scheduler,
                schedulerTaskId: "camera_presence_check",
                schedulerConsentGranted: true
            )
        )

        if case .allow(let reason) = decision {
            XCTAssertEqual(reason.code, .schedulerAutoAllowed)
        } else {
            XCTFail("Expected allow for scheduler allowlisted tool")
        }
    }
}
