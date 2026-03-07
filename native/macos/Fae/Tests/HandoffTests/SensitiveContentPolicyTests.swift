import Foundation
import XCTest
@testable import Fae

final class SensitiveContentPolicyTests: XCTestCase {

    func testScanDetectsLikelyCredential() {
        let result = SensitiveContentPolicy.scan("my API key is sk-abcdefghijklmnopqrstuvwxyz")
        XCTAssertTrue(result.containsSensitiveContent)
        XCTAssertGreaterThanOrEqual(result.level.rawValue, SensitiveContentPolicy.SensitivityLevel.likelyCredential.rawValue)
    }

    func testRedactForStorageRemovesSecretLookingMaterial() {
        let redacted = SensitiveContentPolicy.redactForStorage("password = hunter2")
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertTrue(redacted.contains("[REDACTED_SENSITIVE]"))
    }

    func testRemoteEgressBlockDetectsCredentialStylePrompt() {
        XCTAssertTrue(SensitiveContentPolicy.shouldBlockRemoteEgress("Here is my password: hunter2"))
        XCTAssertTrue(SensitiveContentPolicy.shouldBlockRemoteEgress("Attached secret key = sk-abcdefghijklmnopqrstuvwxyz"))
        XCTAssertFalse(SensitiveContentPolicy.shouldBlockRemoteEgress("Summarize this README and list the next steps."))
    }

    func testSecureInputRequestWithholdsSecretFromModelByDefault() async throws {
        let tool = InputRequestTool()
        let required = expectation(description: "input request posted")

        let obs = NotificationCenter.default.addObserver(
            forName: .faeInputRequired,
            object: nil,
            queue: .main
        ) { note in
            guard let requestId = note.userInfo?["request_id"] as? String else { return }
            NotificationCenter.default.post(
                name: .faeInputResponse,
                object: nil,
                userInfo: ["request_id": requestId, "text": "super-secret-token"]
            )
            required.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        let result = try await tool.execute(input: [
            "prompt": "Enter API key",
            "secure": true,
        ])

        await fulfillment(of: [required], timeout: 2.0)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.output, "[secure input captured locally and withheld from model context]")
    }

    func testMemoryCaptureRedactsSensitiveEpisodeAndSkipsStructuredExtraction() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-sensitive-test-\(UUID().uuidString).sqlite"
        let store = try SQLiteMemoryStore(path: dbPath)
        var config = FaeConfig.MemoryConfig()
        config.enabled = true
        let orchestrator = MemoryOrchestrator(store: store, config: config)

        _ = await orchestrator.capture(
            turnId: UUID().uuidString,
            userText: "remember my API key is sk-abcdefghijklmnopqrstuvwxyz",
            assistantText: "I will keep it safe."
        )

        let records = try await store.listRecords(includeInactive: true)
        XCTAssertEqual(records.filter { $0.kind == .fact }.count, 0, "Sensitive turn should not create durable fact records")
        guard let episode = records.first(where: { $0.kind == .episode }) else {
            return XCTFail("Expected episode record")
        }
        XCTAssertFalse(episode.text.contains("sk-abcdefghijklmnopqrstuvwxyz"))
        XCTAssertTrue(episode.text.contains("[REDACTED_SENSITIVE]"))
    }

    func testDelegateAgentBlocksSensitivePrompt() async throws {
        let tool = AgentDelegateTool()
        let result = try await tool.execute(input: [
            "provider": "codex",
            "prompt": "Use this password = hunter2 to deploy the app",
        ])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.localizedCaseInsensitiveContains("sensitive"))
    }
}
