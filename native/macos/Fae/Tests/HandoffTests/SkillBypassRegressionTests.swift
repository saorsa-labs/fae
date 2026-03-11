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
            allowNetwork: false,
            allowSubprocess: false,
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

    func testBuiltInExecutableSkillsHaveValidManifests() async {
        let manager = SkillManager()
        let skills = await manager.discoverSkills()

        for skillName in ["forge", "toolbox", "voice-tools"] {
            guard let skill = skills.first(where: { $0.name == skillName }) else {
                XCTFail("Expected built-in skill \(skillName) to be discovered")
                continue
            }
            XCTAssertEqual(skill.type, .executable)
            XCTAssertTrue(skill.isEnabled, "Expected built-in skill \(skillName) to be enabled")
        }
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
            allowNetwork: false,
            allowSubprocess: false,
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

    func testExecutableSkillWithRawNetworkImportsIsRejectedWithoutManifestAllowance() async throws {
        guard await UVRuntime.shared.isAvailable() else {
            throw XCTSkip("uv is not installed on this system")
        }
        let manager = SkillManager()
        let skillName = "network_guard_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        defer {
            try? FileManager.default.removeItem(
                at: SkillManager.skillsDirectory.appendingPathComponent(skillName)
            )
        }

        _ = try await manager.createSkill(
            name: skillName,
            description: "Network policy guard regression test",
            body: "This skill should fail because it imports urllib without network permission.",
            scriptContent: "import urllib\nprint('nope')"
        )

        do {
            _ = try await manager.execute(
                skillName: skillName,
                scriptName: nil,
                input: [:],
                capabilityTicketId: UUID().uuidString
            )
            XCTFail("Expected network policy violation")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains("network"),
                "Unexpected error: \(error)"
            )
        }
    }

    func testCreateSkillSupportsCustomScriptNameAndManifestJSON() async throws {
        guard await UVRuntime.shared.isAvailable() else {
            throw XCTSkip("uv is not installed on this system")
        }
        let manager = SkillManager()
        let skillName = "network_ok_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        defer {
            try? FileManager.default.removeItem(
                at: SkillManager.skillsDirectory.appendingPathComponent(skillName)
            )
        }

        let manifestJSON = """
        {
          \"schemaVersion\": 1,
          \"capabilities\": [\"execute\"],
          \"allowedTools\": [\"run_skill\"],
          \"allowedDomains\": [],
          \"dataClasses\": [\"local_files\", \"network\"],
          \"riskTier\": \"medium\",
          \"timeoutSeconds\": 30,
          \"allowNetwork\": true,
          \"allowSubprocess\": false
        }
        """

        _ = try await manager.createSkill(
            name: skillName,
            description: "Skill with richer manifest authoring",
            body: "This skill uses a custom script filename and explicit manifest JSON.",
            scriptContent: "import urllib\nprint('ok')",
            scriptName: "runner",
            manifestJSON: manifestJSON
        )

        let output = try await manager.execute(
            skillName: skillName,
            scriptName: "runner",
            input: [:],
            capabilityTicketId: UUID().uuidString
        )
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
    }

    func testRunSkillToolForwardsStructuredParamsAndSecretBindings() async throws {
        guard await UVRuntime.shared.isAvailable() else {
            throw XCTSkip("uv is not installed on this system")
        }
        let manager = SkillManager()
        let tool = RunSkillTool(skillManager: manager)
        let skillName = "exec_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let secretKey = "tests.skill.\(skillName)"
        let originalSecret = CredentialManager.retrieve(key: secretKey)

        defer {
            try? FileManager.default.removeItem(
                at: SkillManager.skillsDirectory.appendingPathComponent(skillName)
            )
            if let originalSecret {
                try? CredentialManager.store(key: secretKey, value: originalSecret)
            } else {
                CredentialManager.delete(key: secretKey)
            }
        }

        let script = """
            import json
            import os
            import sys

            request = json.loads(sys.stdin.read())
            params = request.get("params", {})
            result = {
                "method": params.get("method"),
                "timeout": params.get("timeout"),
                "input": params.get("input"),
                "skill_name": os.environ.get("FAE_SKILL_NAME"),
                "secret": os.environ.get("FAE_TEST_SECRET"),
            }
            print(json.dumps(result, sort_keys=True))
            """

        _ = try await manager.createSkill(
            name: skillName,
            description: "Executable regression test skill",
            body: "Echo structured params and secret bindings for test verification.",
            scriptContent: script
        )
        try CredentialManager.store(key: secretKey, value: "super-secret-value")

        let result = try await tool.execute(input: [
            "name": skillName,
            "capability_ticket": "ticket-123",
            "params": [
                "method": "bonjour",
                "timeout": 5,
            ],
            "input": "compat input",
            "secret_bindings": [
                "FAE_TEST_SECRET": secretKey,
            ],
        ])

        XCTAssertFalse(result.isError, "Unexpected tool error: \(result.output)")
        let data = try XCTUnwrap(result.output.data(using: .utf8))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(payload["method"] as? String, "bonjour")
        XCTAssertEqual(payload["timeout"] as? Int, 5)
        XCTAssertEqual(payload["input"] as? String, "compat input")
        XCTAssertEqual(payload["skill_name"] as? String, skillName)
        XCTAssertEqual(payload["secret"] as? String, "super-secret-value")
    }

    func testDiscoverSkillsIncludesSharedAgentSkillsDirectory() async throws {
        let manager = SkillManager()
        let skillName = "shared_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let skillDir = SkillManager.sharedSkillsDirectory.appendingPathComponent(skillName, isDirectory: true)
        let skillMD = skillDir.appendingPathComponent("SKILL.md")

        defer { try? FileManager.default.removeItem(at: skillDir) }

        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try """
            ---
            name: \(skillName)
            description: Shared Agent Skills discovery regression test.
            metadata:
              author: tests
              version: "1.0"
            ---

            This skill exists to verify shared `.agents/skills` discovery.
            """.write(to: skillMD, atomically: true, encoding: .utf8)

        let skills = await manager.discoverSkills()
        let discovered = skills.first(where: { $0.name == skillName })

        XCTAssertNotNil(discovered, "Expected skill from ~/.agents/skills to be discovered")
        XCTAssertTrue(SkillManager.installedSkillNames().contains(skillName))
    }
}
