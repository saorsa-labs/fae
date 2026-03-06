import XCTest
@testable import Fae

final class ChannelSetupToolTests: XCTestCase {

    func testMissingActionReturnsError() async throws {
        let tool = ChannelSetupTool()
        let result = try await tool.execute(input: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("action"))
    }

    func testUnknownChannelStatusReturnsError() async throws {
        let tool = ChannelSetupTool()
        let result = try await tool.execute(
            input: [
                "action": "status",
                "channel": "not-a-real-channel",
            ]
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("not found"))
    }

    func testListIncludesBuiltInChannelSkills() async throws {
        let tool = ChannelSetupTool()
        let result = try await tool.execute(input: ["action": "list"])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("Discord"))
        XCTAssertTrue(result.output.contains("WhatsApp"))
        XCTAssertTrue(result.output.contains("iMessage"))
    }

    func testNextPromptReturnsPlainEnglishQuestionForMissingField() async throws {
        let tool = ChannelSetupTool()
        let result = try await tool.execute(
            input: [
                "action": "next_prompt",
                "channel": "discord",
            ]
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("Ask user:"))
        XCTAssertTrue(result.output.contains("bot_token"))
    }

    func testRequestFormRespectsRolloutFlag() async throws {
        let defaults = UserDefaults.standard
        let key = "fae.feature.channel_setup_forms"
        let hadValue = defaults.object(forKey: key) != nil
        let previous = defaults.bool(forKey: key)

        defaults.set(false, forKey: key)
        defer {
            if hadValue {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let tool = ChannelSetupTool()
        let result = try await tool.execute(
            input: [
                "action": "request_form",
                "channel": "discord",
            ]
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("disabled by rollout flag"))
    }

    func testSetAndDisconnectUseContractBackedStorageForCustomChannel() async throws {
        let manager = SkillManager()
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let skillName = "channel_matrix_\(suffix)"
        let channelKey = "matrix\(suffix)"

        defer {
            try? FileManager.default.removeItem(
                at: SkillManager.skillsDirectory.appendingPathComponent(skillName)
            )
            try? ChannelSettingsStore.clearValue(
                channelKey: channelKey,
                fieldID: "homeserver_url",
                store: .configStore
            )
            try? ChannelSettingsStore.clearValue(
                channelKey: channelKey,
                fieldID: "access_token",
                store: .secretStore
            )
        }

        try await createChannelSkill(
            manager: manager,
            skillName: skillName,
            channelKey: channelKey,
            displayName: "Matrix",
            requiredFields: ["homeserver_url", "access_token"]
        )

        let tool = ChannelSetupTool()
        let setResult = try await tool.execute(
            input: [
                "action": "set",
                "channel": channelKey,
                "values": [
                    "homeserver_url": "https://matrix.example.com",
                    "access_token": "matrix-secret-token",
                ],
            ]
        )

        XCTAssertFalse(setResult.isError)

        let statusResult = try await tool.execute(
            input: [
                "action": "status",
                "channel": channelKey,
            ]
        )

        XCTAssertFalse(statusResult.isError)
        XCTAssertTrue(statusResult.output.contains("State: configured"))
        XCTAssertEqual(
            ChannelSettingsStore.value(
                channelKey: channelKey,
                fieldID: "homeserver_url",
                store: .configStore
            ),
            "https://matrix.example.com"
        )
        XCTAssertEqual(
            ChannelSettingsStore.value(
                channelKey: channelKey,
                fieldID: "access_token",
                store: .secretStore
            ),
            "matrix-secret-token"
        )

        let disconnectResult = try await tool.execute(
            input: [
                "action": "disconnect",
                "channel": channelKey,
            ]
        )

        XCTAssertFalse(disconnectResult.isError)

        let disconnectedStatus = try await tool.execute(
            input: [
                "action": "status",
                "channel": channelKey,
            ]
        )

        XCTAssertFalse(disconnectedStatus.isError)
        XCTAssertTrue(disconnectedStatus.output.contains("State: missing_input"))
    }

    private func createChannelSkill(
        manager: SkillManager,
        skillName: String,
        channelKey: String,
        displayName: String,
        requiredFields: [String]
    ) async throws {
        _ = try await manager.createSkill(
            name: skillName,
            description: "Channel setup test fixture",
            body: "Fixture body for channel setup contract tests.",
            scriptContent: "print('ok')"
        )

        let skillDir = SkillManager.skillsDirectory.appendingPathComponent(skillName)
        let manifestURL = SkillManifestPolicy.manifestURL(for: skillDir)

        let fields = requiredFields.map { fieldID in
            SkillSettingsField(
                id: fieldID,
                type: fieldID.contains("token") ? .secret : .text,
                label: fieldID,
                required: true,
                prompt: "Enter \(fieldID)",
                placeholder: nil,
                help: nil,
                defaultValue: nil,
                options: nil,
                validation: nil,
                sensitive: fieldID.contains("token"),
                store: fieldID.contains("token") ? .secretStore : .configStore
            )
        }

        let manifest = SkillCapabilityManifest(
            schemaVersion: 1,
            capabilities: ["execute", "status", "configure", "disconnect"],
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
                key: channelKey,
                displayName: displayName,
                description: "Configure \(displayName)",
                fields: fields,
                actions: SkillSettingsActions(
                    status: "status",
                    configure: "configure",
                    test: nil,
                    disconnect: "disconnect",
                    sendSample: nil
                )
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL)
    }
}
