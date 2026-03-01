import Foundation
import XCTest
@testable import Fae

final class SkillBypassRegressionTests: XCTestCase {

    func testBrokerDeniesRunSkillWithoutCapabilityTicket() async {
        let broker = DefaultTrustedActionBroker(
            knownTools: ["run_skill"],
            speakerConfig: FaeConfig.SpeakerConfig()
        )

        let intent = ActionIntent(
            source: .text,
            toolName: "run_skill",
            riskLevel: .medium,
            requiresApproval: true,
            isOwner: true,
            livenessScore: 1.0,
            explicitUserAuthorization: false,
            hasCapabilityTicket: false,
            policyProfile: .balanced,
            argumentSummary: "run skill"
        )

        let decision = await broker.evaluate(intent)
        if case .deny(let reason) = decision {
            XCTAssertEqual(reason.code, .noCapabilityTicket)
        } else {
            XCTFail("Expected deny(noCapabilityTicket)")
        }
    }

    func testRunSkillToolRejectsDirectCallWithoutCapabilityTicket() async throws {
        let manager = SkillManager()
        let tool = RunSkillTool(skillManager: manager)

        let result = try await tool.execute(input: ["name": "demo-skill"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("capability_ticket"))
    }

    func testSkillManagerExecuteRequiresCapabilityTicket() async {
        let manager = SkillManager()

        do {
            _ = try await manager.execute(
                skillName: "demo_skill",
                scriptName: nil,
                input: [:],
                capabilityTicketId: ""
            )
            XCTFail("Expected policy violation for missing ticket")
        } catch {
            let text = error.localizedDescription.lowercased()
            XCTAssertTrue(text.contains("capability"), "Unexpected error: \(error)")
        }
    }

    func testTamperedExecutableSkillIsDisabledDuringDiscovery() async throws {
        let manager = SkillManager()
        let skillName = "tamper_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        defer {
            try? FileManager.default.removeItem(
                at: SkillManager.skillsDirectory.appendingPathComponent(skillName)
            )
        }

        _ = try await manager.createSkill(
            name: skillName,
            description: "Skill for integrity regression test",
            body: "This is a test skill body with enough content for validation.",
            scriptContent: "print('hello')"
        )

        // Tamper with script after manifest integrity was generated.
        let scriptURL = SkillManager.skillsDirectory
            .appendingPathComponent(skillName)
            .appendingPathComponent("scripts")
            .appendingPathComponent("\(skillName).py")
        try "print('tampered')".write(to: scriptURL, atomically: true, encoding: .utf8)

        let skills = await manager.discoverSkills()
        guard let tampered = skills.first(where: { $0.name == skillName }) else {
            XCTFail("Expected skill in discovery results")
            return
        }

        XCTAssertFalse(tampered.isEnabled, "Tampered executable skill should be disabled")
    }
}
