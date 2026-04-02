import Foundation

/// A single chunk of output from one agent during streaming consensus.
///
/// Each chunk carries the agent's identity and either a text delta (partial
/// response) or a completion/error marker. Consumers accumulate `delta` values
/// per `agentID` to build the full response text.
struct TaggedChunk: Sendable, Equatable {
    /// Unique identifier of the agent that produced this chunk.
    let agentID: String

    /// Human-readable agent name (for UI display).
    let agentName: String

    /// Accumulated response text so far. For streaming providers, each successive
    /// chunk replaces the previous value. Empty when the chunk is an error marker.
    let text: String

    /// `true` when this is the final chunk for this agent (success or error).
    let isComplete: Bool

    /// Non-nil when the agent encountered an error. Always paired with `isComplete == true`.
    let errorText: String?
}

/// Streams consensus results from multiple agents concurrently.
///
/// Each agent runs independently inside a `TaskGroup`. Streaming providers
/// emit `TaggedChunk` values as tokens arrive; non-streaming (batch) providers
/// emit a single chunk when complete. One agent failing does not cancel others.
///
/// Cancel the consuming `Task` to propagate cancellation to all in-flight agents.
actor StreamingConsensusEngine {

    /// A resolved participant ready for execution.
    struct Participant: Sendable {
        let agent: WorkWithFaeAgentProfile
        let provider: (any CoworkLLMProvider)?
        let useChatProvider: Bool
    }

    /// Streams consensus across all `participants`, yielding `TaggedChunk` values
    /// as tokens arrive from each agent.
    ///
    /// - Parameters:
    ///   - participants: Resolved agent/provider pairs to query.
    ///   - request: The CoWork provider request (same for every agent, with per-agent model overridden).
    ///   - chatProvider: Local Fae provider for `faeLocalhost` agents.
    ///   - securityExecutor: Security gate for external providers.
    /// - Returns: An `AsyncStream` of tagged chunks. The stream finishes when all
    ///   agents have completed (successfully or with errors).
    func streamConsensus(
        participants: [Participant],
        preparedPrompt: WorkWithFaePreparedPrompt,
        thinkingLevel: FaeThinkingLevel,
        chatProvider: (any CoworkLLMProvider)?,
        securityExecutor: CoworkToolExecutor?
    ) -> AsyncStream<TaggedChunk> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for participant in participants {
                        group.addTask {
                            await Self.runAgent(
                                participant: participant,
                                preparedPrompt: preparedPrompt,
                                thinkingLevel: thinkingLevel,
                                chatProvider: chatProvider,
                                securityExecutor: securityExecutor,
                                continuation: continuation
                            )
                        }
                    }
                    // Wait for all agents to finish before closing the stream.
                    await group.waitForAll()
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Private

    private static func runAgent(
        participant: Participant,
        preparedPrompt: WorkWithFaePreparedPrompt,
        thinkingLevel: FaeThinkingLevel,
        chatProvider: (any CoworkLLMProvider)?,
        securityExecutor: CoworkToolExecutor?,
        continuation: AsyncStream<TaggedChunk>.Continuation
    ) async {
        let agent = participant.agent
        let request = CoworkProviderRequest(
            model: agent.modelIdentifier,
            preparedPrompt: preparedPrompt,
            thinkingLevel: thinkingLevel
        )

        do {
            let response: CoworkProviderResponse

            if participant.useChatProvider {
                // Local Fae provider — batch only.
                guard let chatProvider else {
                    throw CoworkProviderError.rejected("Fae localhost runtime is unavailable.")
                }
                response = try await chatProvider.submit(request: request)
            } else {
                guard let provider = participant.provider else {
                    throw CoworkProviderError.rejected("No provider resolved for \(agent.name).")
                }
                guard let securityExecutor else {
                    throw CoworkToolExecutorError.pipelineNotReady
                }

                // Prefer streaming when the provider supports it.
                if let streamingProvider = provider as? any CoworkStreamingProvider {
                    response = try await securityExecutor.submitStreaming(
                        request: request,
                        provider: streamingProvider
                    ) { partialText in
                        continuation.yield(TaggedChunk(
                            agentID: agent.id,
                            agentName: agent.name,
                            text: partialText,
                            isComplete: false,
                            errorText: nil
                        ))
                    }
                } else {
                    response = try await securityExecutor.submit(
                        request: request,
                        provider: provider
                    )
                }
            }

            // Emit the final chunk with the full response text.
            continuation.yield(TaggedChunk(
                agentID: agent.id,
                agentName: agent.name,
                text: response.content,
                isComplete: true,
                errorText: nil
            ))
        } catch {
            // Emit an error chunk — does NOT cancel other agents.
            continuation.yield(TaggedChunk(
                agentID: agent.id,
                agentName: agent.name,
                text: "",
                isComplete: true,
                errorText: error.localizedDescription
            ))
        }
    }
}
