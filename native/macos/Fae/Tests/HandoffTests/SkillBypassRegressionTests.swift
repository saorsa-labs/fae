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

    func testActivateSkillRejectsTamperedExecutableSkill() async throws {
        let manager = SkillManager()
        let skillName = "tamper_activate_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        defer {
            try? FileManager.default.removeItem(
                at: SkillManager.skillsDirectory.appendingPathComponent(skillName)
            )
        }

        _ = try await manager.createSkill(
            name: skillName,
            description: "Skill for activation hardening regression test",
            body: "This skill body is valid before tampering.",
            scriptContent: "print('hello')"
        )

        let initialActivation = await manager.activate(skillName: skillName)
        XCTAssertNotNil(initialActivation)

        let scriptURL = SkillManager.skillsDirectory
            .appendingPathComponent(skillName)
            .appendingPathComponent("scripts")
            .appendingPathComponent("\(skillName).py")
        try "print('tampered')".write(to: scriptURL, atomically: true, encoding: .utf8)

        let activated = await manager.activate(skillName: skillName)
        XCTAssertNil(activated, "Tampered executable skill should not activate into prompt context")
        let activatedContext = await manager.activatedContext()
        XCTAssertNil(activatedContext, "Tampered executable skill should be removed from activated context cache")
    }

    func testValidSettingsContractKeepsExecutableSkillEnabled() async throws {
        let manager = SkillManager()
        let skillName = "settings_ok_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        defer {
            try? FileManager.default.removeItem(
                at: SkillManager.skillsDirectory.appendingPathComponent(skillName)
            )
        }

        _ = try await manager.createSkill(
            name: skillName,
            description: "Skill with valid settings contract",
            body: "This skill validates settings schema acceptance.",
            scriptContent: "print('ok')"
        )

        let skillDir = SkillManager.skillsDirectory.appendingPathComponent(skillName)
        let manifestURL = SkillManifestPolicy.manifestURL(for: skillDir)

        // Keep integrity valid by rewriting checksums from current files.
        let integrity = SkillManifestPolicy.buildIntegrity(for: skillDir)
        let manifest = SkillCapabilityManifest(
            schemaVersion: 1,
            capabilities: ["execute", "status", "configure"],
            allowedTools: ["run_skill"],
            allowedDomains: [],
            dataClasses: ["local_files"],
            riskTier: .medium,
            timeoutSeconds: 30,
            integrity: integrity,
            settings: SkillSettingsContract(
                version: 1,
                kind: "channel",
                key: "discord",
                displayName: "Discord",
                description: "Configure Discord",
                fields: [
                    SkillSettingsField(
                        id: "bot_token",
                        type: .secret,
                        label: "Bot token",
                        required: true,
                        prompt: "Enter your bot token",
                        placeholder: nil,
                        help: nil,
                        defaultValue: nil,
                        options: nil,
                        validation: nil,
                        sensitive: true,
                        store: .secretStore
                    )
                ],
                actions: SkillSettingsActions(
                    status: "status",
                    configure: "configure",
                    test: nil,
                    disconnect: nil,
                    sendSample: nil
                )
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL)

        let skills = await manager.discoverSkills()
        guard let skill = skills.first(where: { $0.name == skillName }) else {
            XCTFail("Expected skill in discovery results")
            return
        }

        XCTAssertTrue(skill.isEnabled, "Valid settings contract should keep skill enabled")

        let configurable = await manager.configurableSkills(kind: "channel")
        let found = configurable.first(where: { $0.name == skillName })
        XCTAssertNotNil(found, "Configurable channel skill should be auto-discovered")
        XCTAssertEqual(found?.key, "discord")
    }

    func testInvalidSettingsActionDisablesExecutableSkill() async throws {
        let manager = SkillManager()
        let skillName = "settings_bad_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        defer {
            try? FileManager.default.removeItem(
                at: SkillManager.skillsDirectory.appendingPathComponent(skillName)
            )
        }

        _ = try await manager.createSkill(
            name: skillName,
            description: "Skill with invalid settings actions",
            body: "This skill should be disabled due to manifest mismatch.",
            scriptContent: "print('ok')"
        )

        let skillDir = SkillManager.skillsDirectory.appendingPathComponent(skillName)
        let manifestURL = SkillManifestPolicy.manifestURL(for: skillDir)

        let invalidManifest = SkillCapabilityManifest(
            schemaVersion: 1,
            capabilities: ["execute", "status"],
            allowedTools: ["run_skill"],
            allowedDomains: [],
            dataClasses: ["local_files"],
            riskTier: .medium,
            timeoutSeconds: 30,
            integrity: SkillManifestPolicy.buildIntegrity(for: skillDir),
            settings: SkillSettingsContract(
                version: 1,
                kind: "channel",
                key: "discord",
                displayName: "Discord",
                description: "Configure Discord",
                fields: [
                    SkillSettingsField(
                        id: "bot_token",
                        type: .secret,
                        label: "Bot token",
                        required: true,
                        prompt: "Enter your bot token",
                        placeholder: nil,
                        help: nil,
                        defaultValue: nil,
                        options: nil,
                        validation: nil,
                        sensitive: true,
                        store: .secretStore
                    )
                ],
                actions: SkillSettingsActions(
                    status: "status",
                    configure: "configure",
                    test: nil,
                    disconnect: nil,
                    sendSample: nil
                )
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(invalidManifest)
        try data.write(to: manifestURL)

        let skills = await manager.discoverSkills()
        guard let skill = skills.first(where: { $0.name == skillName }) else {
            XCTFail("Expected skill in discovery results")
            return
        }

        XCTAssertFalse(skill.isEnabled, "Invalid settings action/capability mismatch should disable skill")
    }
}
