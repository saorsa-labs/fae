import XCTest
@testable import Fae

// MARK: - Mock providers

private struct MockBatchProvider: CoworkLLMProvider, @unchecked Sendable {
    let kind: CoworkLLMProviderKind = .faeLocalhost
    let responseContent: String
    let delay: Duration
    let shouldFail: Bool

    init(responseContent: String = "batch response", delay: Duration = .zero, shouldFail: Bool = false) {
        self.responseContent = responseContent
        self.delay = delay
        self.shouldFail = shouldFail
    }

    func submit(request: CoworkProviderRequest) async throws -> CoworkProviderResponse {
        if delay > .zero { try await Task.sleep(for: delay) }
        if shouldFail { throw CoworkProviderError.rejected("Mock batch failure") }
        return CoworkProviderResponse(content: responseContent, status: "completed")
    }
}

private struct MockStreamingProvider: CoworkLLMProvider, CoworkStreamingProvider, @unchecked Sendable {
    let kind: CoworkLLMProviderKind = .openAICompatibleExternal
    let chunks: [String]
    let delay: Duration
    let shouldFail: Bool

    init(chunks: [String] = ["Hello", "Hello world"], delay: Duration = .zero, shouldFail: Bool = false) {
        self.chunks = chunks
        self.delay = delay
        self.shouldFail = shouldFail
    }

    func submit(request: CoworkProviderRequest) async throws -> CoworkProviderResponse {
        if shouldFail { throw CoworkProviderError.rejected("Mock stream failure") }
        return CoworkProviderResponse(content: chunks.last ?? "", status: "completed")
    }

    func stream(
        request: CoworkProviderRequest,
        onPartialText: @escaping @Sendable (String) async -> Void
    ) async throws -> CoworkProviderResponse {
        if shouldFail { throw CoworkProviderError.rejected("Mock stream failure") }
        for chunk in chunks {
            if delay > .zero { try await Task.sleep(for: delay) }
            await onPartialText(chunk)
        }
        return CoworkProviderResponse(content: chunks.last ?? "", status: "completed")
    }
}

private func makePassthroughExecutor() -> CoworkToolExecutor {
    CoworkToolExecutor(damageControlPolicy: DamageControlPolicy())
}

// MARK: - Helpers

private func makeAgent(id: String, name: String, providerKind: CoworkLLMProviderKind = .openAICompatibleExternal) -> WorkWithFaeAgentProfile {
    WorkWithFaeAgentProfile(
        id: id,
        name: name,
        providerKind: providerKind,
        backendPresetID: nil,
        modelIdentifier: "test-model",
        baseURL: nil,
        credentialKey: nil,
        notes: nil,
        createdAt: Date()
    )
}

private func makePreparedPrompt() -> WorkWithFaePreparedPrompt {
    WorkWithFaePreparedPrompt(
        userVisiblePrompt: "test prompt",
        faeLocalPrompt: "local test prompt",
        shareablePrompt: "shareable test prompt",
        containsLocalOnlyContext: false
    )
}

// MARK: - Tests

final class StreamingConsensusEngineTests: XCTestCase {

    func testAllAgentsCompleteSuccessfully() async throws {
        let engine = StreamingConsensusEngine()
        let executor = makePassthroughExecutor()
        let providerA = MockBatchProvider(responseContent: "Answer A")
        let providerB = MockBatchProvider(responseContent: "Answer B")

        let participants: [StreamingConsensusEngine.Participant] = [
            .init(agent: makeAgent(id: "a", name: "Agent A"), provider: providerA, useChatProvider: false),
            .init(agent: makeAgent(id: "b", name: "Agent B"), provider: providerB, useChatProvider: false),
        ]

        let stream = await engine.streamConsensus(
            participants: participants,
            preparedPrompt: makePreparedPrompt(),
            thinkingLevel: .fast,
            chatProvider: nil,
            securityExecutor: executor
        )

        var chunks: [TaggedChunk] = []
        for await chunk in stream {
            chunks.append(chunk)
        }

        // Each batch provider emits exactly one completion chunk.
        XCTAssertEqual(chunks.count, 2)
        let completedIDs = Set(chunks.filter(\.isComplete).map(\.agentID))
        XCTAssertEqual(completedIDs, ["a", "b"])

        let aChunk = try XCTUnwrap(chunks.first(where: { $0.agentID == "a" }))
        XCTAssertEqual(aChunk.text, "Answer A")
        XCTAssertNil(aChunk.errorText)

        let bChunk = try XCTUnwrap(chunks.first(where: { $0.agentID == "b" }))
        XCTAssertEqual(bChunk.text, "Answer B")
        XCTAssertNil(bChunk.errorText)
    }

    func testOneAgentFailsOthersSucceed() async throws {
        let engine = StreamingConsensusEngine()
        let executor = makePassthroughExecutor()
        let goodProvider = MockBatchProvider(responseContent: "Good answer")
        let badProvider = MockBatchProvider(shouldFail: true)

        let participants: [StreamingConsensusEngine.Participant] = [
            .init(agent: makeAgent(id: "good", name: "Good"), provider: goodProvider, useChatProvider: false),
            .init(agent: makeAgent(id: "bad", name: "Bad"), provider: badProvider, useChatProvider: false),
        ]

        let stream = await engine.streamConsensus(
            participants: participants,
            preparedPrompt: makePreparedPrompt(),
            thinkingLevel: .fast,
            chatProvider: nil,
            securityExecutor: executor
        )

        var chunks: [TaggedChunk] = []
        for await chunk in stream {
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks.count, 2)

        let goodChunk = try XCTUnwrap(chunks.first(where: { $0.agentID == "good" }))
        XCTAssertEqual(goodChunk.text, "Good answer")
        XCTAssertTrue(goodChunk.isComplete)
        XCTAssertNil(goodChunk.errorText)

        let badChunk = try XCTUnwrap(chunks.first(where: { $0.agentID == "bad" }))
        XCTAssertTrue(badChunk.isComplete)
        XCTAssertNotNil(badChunk.errorText)
        XCTAssertEqual(badChunk.text, "")
    }

    func testStreamingProviderEmitsIntermediateChunks() async throws {
        let engine = StreamingConsensusEngine()
        let executor = makePassthroughExecutor()
        let streamingProvider = MockStreamingProvider(chunks: ["Hel", "Hello", "Hello world"])

        let participants: [StreamingConsensusEngine.Participant] = [
            .init(agent: makeAgent(id: "s", name: "Streamer"), provider: streamingProvider, useChatProvider: false),
        ]

        let stream = await engine.streamConsensus(
            participants: participants,
            preparedPrompt: makePreparedPrompt(),
            thinkingLevel: .fast,
            chatProvider: nil,
            securityExecutor: executor
        )

        var chunks: [TaggedChunk] = []
        for await chunk in stream {
            chunks.append(chunk)
        }

        // 3 intermediate streaming chunks + 1 final completion chunk = 4.
        XCTAssertEqual(chunks.count, 4)

        let intermediates = chunks.filter { !$0.isComplete }
        XCTAssertEqual(intermediates.count, 3)
        XCTAssertEqual(intermediates.map(\.text), ["Hel", "Hello", "Hello world"])

        let final = try XCTUnwrap(chunks.last)
        XCTAssertTrue(final.isComplete)
        XCTAssertEqual(final.text, "Hello world")
    }

    func testCancellationStopsStream() async throws {
        let engine = StreamingConsensusEngine()
        let executor = makePassthroughExecutor()
        // Use a slow provider so we can cancel mid-flight.
        let slowProvider = MockBatchProvider(responseContent: "Slow answer", delay: .seconds(5))
        let fastProvider = MockBatchProvider(responseContent: "Fast answer")

        let participants: [StreamingConsensusEngine.Participant] = [
            .init(agent: makeAgent(id: "fast", name: "Fast"), provider: fastProvider, useChatProvider: false),
            .init(agent: makeAgent(id: "slow", name: "Slow"), provider: slowProvider, useChatProvider: false),
        ]

        let stream = await engine.streamConsensus(
            participants: participants,
            preparedPrompt: makePreparedPrompt(),
            thinkingLevel: .fast,
            chatProvider: nil,
            securityExecutor: executor
        )

        var chunks: [TaggedChunk] = []
        let consumeTask = Task {
            for await chunk in stream {
                chunks.append(chunk)
                // Cancel after the fast agent completes.
                if chunk.agentID == "fast" && chunk.isComplete {
                    return
                }
            }
        }

        await consumeTask.value

        // We should have at least the fast agent's result.
        let fastChunks = chunks.filter { $0.agentID == "fast" }
        XCTAssertFalse(fastChunks.isEmpty)
        XCTAssertTrue(fastChunks.contains(where: { $0.isComplete && $0.text == "Fast answer" }))
    }

    func testChatProviderUsedForLocalAgent() async throws {
        let engine = StreamingConsensusEngine()
        let localProvider = MockBatchProvider(responseContent: "Local answer")

        let participants: [StreamingConsensusEngine.Participant] = [
            .init(
                agent: makeAgent(id: "local", name: "Fae Local", providerKind: .faeLocalhost),
                provider: nil,
                useChatProvider: true
            ),
        ]

        let stream = await engine.streamConsensus(
            participants: participants,
            preparedPrompt: makePreparedPrompt(),
            thinkingLevel: .fast,
            chatProvider: localProvider,
            securityExecutor: nil
        )

        var chunks: [TaggedChunk] = []
        for await chunk in stream {
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks.count, 1)
        let chunk = try XCTUnwrap(chunks.first)
        XCTAssertEqual(chunk.agentID, "local")
        XCTAssertEqual(chunk.text, "Local answer")
        XCTAssertTrue(chunk.isComplete)
        XCTAssertNil(chunk.errorText)
    }

    func testNoSecurityExecutorFailsGracefully() async throws {
        let engine = StreamingConsensusEngine()
        let provider = MockBatchProvider(responseContent: "answer")

        let participants: [StreamingConsensusEngine.Participant] = [
            .init(agent: makeAgent(id: "ext", name: "External"), provider: provider, useChatProvider: false),
        ]

        let stream = await engine.streamConsensus(
            participants: participants,
            preparedPrompt: makePreparedPrompt(),
            thinkingLevel: .fast,
            chatProvider: nil,
            securityExecutor: nil
        )

        var chunks: [TaggedChunk] = []
        for await chunk in stream {
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks.count, 1)
        let chunk = try XCTUnwrap(chunks.first)
        XCTAssertTrue(chunk.isComplete)
        XCTAssertNotNil(chunk.errorText)
    }

    func testTaggedChunkEquatable() {
        let a = TaggedChunk(agentID: "a", agentName: "A", text: "hello", isComplete: false, errorText: nil)
        let b = TaggedChunk(agentID: "a", agentName: "A", text: "hello", isComplete: false, errorText: nil)
        let c = TaggedChunk(agentID: "a", agentName: "A", text: "world", isComplete: false, errorText: nil)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testEmptyParticipantsProducesEmptyStream() async {
        let engine = StreamingConsensusEngine()

        let stream = await engine.streamConsensus(
            participants: [],
            preparedPrompt: makePreparedPrompt(),
            thinkingLevel: .fast,
            chatProvider: nil,
            securityExecutor: nil
        )

        var chunks: [TaggedChunk] = []
        for await chunk in stream {
            chunks.append(chunk)
        }

        XCTAssertTrue(chunks.isEmpty)
    }
}
