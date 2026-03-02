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
}
