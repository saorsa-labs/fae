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

    /// Run a minimal warmup inference to pre-compile Metal shaders.
    ///
    /// The first MLX inference on Apple Silicon compiles Metal shader kernels,
    /// which can take 30–60 seconds on a cold GPU cache. Calling this after
    /// model load but before the first user interaction ensures Fae is actually
    /// responsive when she announces ready.
    func warmup() async {
        guard let container else { return }
        NSLog("MLXLLMEngine: starting warmup inference...")
        do {
            let chatMessages: [Chat.Message] = [.system(""), .user("Hi")]
            var userInput = UserInput(chat: chatMessages)
            userInput.additionalContext = ["enable_thinking": false]
            let lmInput = try await container.prepare(input: userInput)
            let params = GenerateParameters(
                maxTokens: 1,
                temperature: 0.0,
                topP: 1.0,
                repetitionPenalty: 1.0
            )
            let stream = try await container.generate(input: lmInput, parameters: params)
            for await _ in stream { break }
            NSLog("MLXLLMEngine: warmup complete")
        } catch {
            NSLog("MLXLLMEngine: warmup failed (non-fatal): %@", error.localizedDescription)
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
                    // Thinking suppression is handled at the system-prompt level
                    // (PersonalityManager injects the directive there) rather than
                    // by appending "/no_think" to user messages.  Appending "/no_think"
                    // as literal text causes mlx-swift-lm to pass it through to the
                    // model as user content — Qwen3 then reasons *about* the string
                    // instead of treating it as a control directive, producing visible
                    // thinking text and breaking tool calls.
                    var chatMessages: [Chat.Message] = [
                        .system(systemPrompt),
                    ]
                    for (_, msg) in messages.enumerated() {
                        switch msg.role {
                        case .user:
                            chatMessages.append(.user(msg.content))
                        case .assistant:
                            chatMessages.append(.assistant(msg.content))
                        case .system:
                            chatMessages.append(.system(msg.content))
                        case .tool:
                            chatMessages.append(.tool(msg.content))
                        }
                    }

                    // Pass enable_thinking to the model's Jinja2 chat template.
                    // Qwen3.5-35B-A3B does NOT support the /no_think per-turn suffix
                    // (removed from Qwen3.5). The correct way to suppress thinking is
                    // via chat_template_kwargs — Swift equivalent is additionalContext.
                    var userInput = UserInput(chat: chatMessages)
                    userInput.additionalContext = ["enable_thinking": !options.suppressThinking]

                    // Pass native tool specs so the chat template enables tool calling mode.
                    // Without this, Qwen3.5 thinks about tools in <think> but never emits
                    // actual tool calls — the template needs `tools` to activate that behavior.
                    if let toolSpecs = options.tools {
                        userInput.tools = toolSpecs
                    }

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
                        case .toolCall(let call):
                            // Serialize native ToolCall back to text so the existing
                            // parseToolCalls() parser in PipelineCoordinator picks it up.
                            let jsonObj: [String: Any] = [
                                "name": call.function.name,
                                "arguments": call.function.arguments.mapValues { $0.anyValue },
                            ]
                            if let data = try? JSONSerialization.data(
                                withJSONObject: jsonObj, options: [.sortedKeys]),
                                let jsonStr = String(data: data, encoding: .utf8)
                            {
                                NSLog(
                                    "MLXLLMEngine: native .toolCall → %@", call.function.name)
                                continuation.yield("<tool_call>\(jsonStr)</tool_call>")
                            }
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
