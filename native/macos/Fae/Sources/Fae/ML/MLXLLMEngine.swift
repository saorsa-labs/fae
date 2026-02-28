import Foundation
import MLXLLM
import MLXLMCommon

/// Large language model engine using mlx-swift-lm.
///
/// Replaces: `src/llm/mod.rs` + `src/fae_llm/providers/local.rs`
actor MLXLLMEngine: LLMEngine {
    private var container: ModelContainer?
    private(set) var isLoaded: Bool = false
    private(set) var loadState: MLEngineLoadState = .notStarted

    /// Load the LLM model.
    func load(modelID: String) async throws {
        loadState = .loading
        NSLog("MLXLLMEngine: loading model %@", modelID)
        do {
            let config = ModelConfiguration(id: modelID)
            container = try await LLMModelFactory.shared.loadContainer(configuration: config)
            isLoaded = true
            loadState = .loaded
            NSLog("MLXLLMEngine: model loaded")
        } catch {
            loadState = .failed(error.localizedDescription)
            NSLog("MLXLLMEngine: load failed: %@", error.localizedDescription)
            throw error
        }
    }

    /// Generate a streaming response.
    func generate(
        messages: [LLMMessage],
        systemPrompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                guard let container = await self.container else {
                    continuation.finish(throwing: MLEngineError.notLoaded("LLM"))
                    return
                }

                do {
                    // Build chat messages with system prompt.
                    // NOTE: Qwen3's /no_think token only works when placed at the
                    // START of the final user message (not in the system message).
                    // We inject it in the loop below when appending the last user turn.
                    var chatMessages: [Chat.Message] = [
                        .system(systemPrompt),
                    ]
                    let lastUserIndex = messages.indices.last(where: { messages[$0].role == .user })
                    for (i, msg) in messages.enumerated() {
                        switch msg.role {
                        case .user:
                            let content = (i == lastUserIndex) ? "/no_think\n" + msg.content : msg.content
                            chatMessages.append(.user(content))
                        case .assistant:
                            chatMessages.append(.assistant(msg.content))
                        case .system:
                            chatMessages.append(.system(msg.content))
                        case .tool:
                            chatMessages.append(.tool(msg.content))
                        }
                    }

                    let userInput = UserInput(chat: chatMessages)
                    let lmInput = try await container.prepare(input: userInput)

                    let params = GenerateParameters(
                        maxTokens: options.maxTokens,
                        temperature: options.temperature,
                        topP: options.topP,
                        repetitionPenalty: options.repetitionPenalty
                    )

                    let stream = try await container.generate(
                        input: lmInput,
                        parameters: params
                    )

                    for await generation in stream {
                        switch generation {
                        case .chunk(let text):
                            continuation.yield(text)
                        case .info:
                            break
                        case .toolCall:
                            break
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
