import Foundation
import XCTest
@testable import Fae

private actor RequestRecorder {
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }

    func snapshot() -> [URLRequest] {
        requests
    }
}

@MainActor
final class ThinkingLevelModelSwitchContinuityTests: XCTestCase {
    func testMidConversationRemoteModelSwitchKeepsThreadAndUsesLatestThinkingLevel() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("thinking-model-switch-\(UUID().uuidString)", isDirectory: true)
        let storageURL = tempRoot.appendingPathComponent("work_with_fae_workspace.json")
        let originalStorageOverride = WorkWithFaeWorkspaceStore.storageURLOverride
        let configURL = FaeConfig.configFileURL
        let fileManager = FileManager.default
        let originalConfig = try? Data(contentsOf: configURL)
        let originalThinkingLevel = UserDefaults.standard.string(forKey: "thinkingLevel")
        let originalThinkingEnabled = UserDefaults.standard.object(forKey: "thinkingEnabled") as? Bool
        let credentialKey = "agents.openrouter.model-switch-test.api_key"
        let originalCredential = CredentialManager.retrieve(key: credentialKey)
        let originalLoader = CoworkNetworkTransport.loader
        let originalStreamer = CoworkNetworkTransport.streamer

        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        WorkWithFaeWorkspaceStore.storageURLOverride = storageURL

        defer {
            WorkWithFaeWorkspaceStore.storageURLOverride = originalStorageOverride
            if let originalConfig {
                try? originalConfig.write(to: configURL, options: .atomic)
            } else {
                try? fileManager.removeItem(at: configURL)
            }
            if let originalThinkingLevel {
                UserDefaults.standard.set(originalThinkingLevel, forKey: "thinkingLevel")
            } else {
                UserDefaults.standard.removeObject(forKey: "thinkingLevel")
            }
            if let originalThinkingEnabled {
                UserDefaults.standard.set(originalThinkingEnabled, forKey: "thinkingEnabled")
            } else {
                UserDefaults.standard.removeObject(forKey: "thinkingEnabled")
            }
            if let originalCredential {
                try? CredentialManager.store(key: credentialKey, value: originalCredential)
            } else {
                CredentialManager.delete(key: credentialKey)
            }
            CoworkNetworkTransport.loader = originalLoader
            CoworkNetworkTransport.streamer = originalStreamer
            try? fileManager.removeItem(at: tempRoot)
        }

        try CredentialManager.store(key: credentialKey, value: "test-openrouter-key")

        let recorder = RequestRecorder()
        CoworkNetworkTransport.loader = { request in
            await recorder.record(request)
            guard let url = request.url else { throw URLError(.badURL) }
            let data = """
            {
              "choices": [
                {
                  "message": {
                    "content": "Remote answer after switch"
                  }
                }
              ]
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
        CoworkNetworkTransport.streamer = { request in
            await recorder.record(request)
            guard let url = request.url else { throw URLError(.badURL) }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let stream = AsyncThrowingStream<String, Error> { continuation in
                continuation.yield("data: {\"choices\":[{\"delta\":{\"content\":\"Remote answer\"}}]}")
                continuation.yield("data: {\"choices\":[{\"delta\":{\"content\":\" after switch\"}}]}")
                continuation.yield("data: [DONE]")
                continuation.finish()
            }
            return (response, stream)
        }

        let remoteAgent = WorkWithFaeAgentProfile(
            id: "agent-openrouter",
            name: "OpenRouter",
            providerKind: .openAICompatibleExternal,
            backendPresetID: "openrouter",
            modelIdentifier: "openai/gpt-4.1-mini",
            baseURL: "https://openrouter.ai/api",
            credentialKey: credentialKey,
            notes: nil,
            createdAt: Date()
        )
        let workspace = WorkWithFaeWorkspaceRecord(
            name: "Workspace",
            agentID: remoteAgent.id,
            state: WorkWithFaeWorkspaceState(
                selectedDirectoryPath: nil,
                indexedFiles: [],
                attachments: [],
                conversationMessages: [
                    WorkWithFaeConversationMessage(role: "user", content: "First question"),
                    WorkWithFaeConversationMessage(role: "assistant", content: "First answer")
                ]
            )
        )
        WorkWithFaeWorkspaceStore.saveRegistry(
            WorkWithFaeWorkspaceRegistry(
                selectedWorkspaceID: workspace.id,
                workspaces: [workspace],
                agents: [.faeLocal, remoteAgent]
            )
        )

        let conversation = ConversationController()
        let core = FaeCore()
        let controller = CoworkWorkspaceController(
            faeCore: core,
            conversation: conversation,
            runtimeDescriptor: nil
        )

        XCTAssertEqual(conversation.messages.map(\.content), ["First question", "First answer"])
        XCTAssertEqual(controller.selectedAgent?.modelIdentifier, "openai/gpt-4.1-mini")

        controller.updateSelectedAgentModel("openai/gpt-5")
        controller.setThinkingLevel(.deep)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(controller.selectedAgent?.modelIdentifier, "openai/gpt-5")
        XCTAssertEqual(core.thinkingLevel, .deep)
        XCTAssertEqual(conversation.messages.map(\.content), ["First question", "First answer"])

        controller.draft = "Continue with the migration plan."
        controller.submitDraft()

        try await waitForReply(in: conversation)

        XCTAssertEqual(
            conversation.messages.map(\.content),
            ["First question", "First answer", "Continue with the migration plan.", "Remote answer after switch"]
        )
        XCTAssertFalse(conversation.isGenerating)
        XCTAssertFalse(conversation.isStreaming)

        let persisted = WorkWithFaeWorkspaceStore.loadRegistry()
        let persistedMessages = WorkWithFaeWorkspaceStore.selectedWorkspace(in: persisted)?.state.conversationMessages.map(\.content)
        XCTAssertEqual(
            persistedMessages,
            ["First question", "First answer", "Continue with the migration plan.", "Remote answer after switch"]
        )

        let requests = await recorder.snapshot()
        let completionRequest = try XCTUnwrap(
            requests.last(where: {
                $0.httpMethod == "POST"
                    && $0.url?.path.contains("/v1/chat/completions") == true
                    && $0.httpBody != nil
            })
        )
        let json = try XCTUnwrap(jsonObject(from: completionRequest))
        XCTAssertEqual(json["model"] as? String, "openai/gpt-5")

        let reasoning = try XCTUnwrap(json["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "high")
        XCTAssertEqual(reasoning["exclude"] as? Bool, true)

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let userMessage = try XCTUnwrap(messages.first(where: { ($0["role"] as? String) == "user" }))
        let promptBody = try XCTUnwrap(userMessage["content"] as? String)
        XCTAssertFalse(promptBody.contains("Recent conversation:"))
        XCTAssertFalse(promptBody.contains("First question"))
        XCTAssertFalse(promptBody.contains("First answer"))
        XCTAssertTrue(promptBody.contains("Context kept on this Mac:"))
        XCTAssertTrue(promptBody.contains("recent conversation history"))
        XCTAssertTrue(promptBody.contains("Continue with the migration plan."))
    }

    private func waitForReply(in conversation: ConversationController, timeout: TimeInterval = 2.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if conversation.messages.count >= 4, conversation.isGenerating == false, conversation.isStreaming == false {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for remote reply")
    }

    private func jsonObject(from request: URLRequest) throws -> [String: Any]? {
        guard let body = request.httpBody else { return nil }
        return try JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}
