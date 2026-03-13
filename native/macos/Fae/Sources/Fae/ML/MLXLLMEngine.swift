import Foundation
import MLX
import MLXLLM
import MLXLMCommon

private final class UnsafeBox<T>: @unchecked Sendable {
    var value: T

    init(_ value: T) {
        self.value = value
    }
}

private func usesQwenCompatibleToolCallFormat(modelID: String) -> Bool {
    let lower = modelID.lowercased()
    return lower.contains("qwen")
        || lower.contains("saorsa1-worker")
        || lower.contains("saorsa1-tiny")
}

/// Large language model engine using mlx-swift-lm.
///
/// Replaces: `src/llm/mod.rs` + `src/fae_llm/providers/local.rs`
actor MLXLLMEngine: LLMEngine {
    private struct SessionState {
        let systemPrompt: String
        let toolSignature: String
        var history: [LLMMessage]
        var kvCache: [KVCache]
        var reusable: Bool
    }

    private struct GenerationSetup: Sendable {
        let stream: AsyncStream<Generation>
        let task: Task<Void, Never>
        let promptTokenCount: Int
        let cachedTokenCount: Int
        let effectiveMaxTokens: Int
    }

    private var container: ModelContainer?
    private(set) var isLoaded: Bool = false
    private(set) var loadState: MLEngineLoadState = .notStarted
    private var sessionState: SessionState?
    private var wiredMemoryTicketProvider: (@Sendable (Int, Int) async -> WiredMemoryTicket?)?
    private(set) var lastCompletionInfo: GenerateCompletionInfo?

    /// Load the LLM model.
    func load(modelID: String) async throws {
        loadState = .loading
        NSLog("MLXLLMEngine: loading model %@", modelID)
        do {
            var config = ModelConfiguration(id: modelID)
            // Qwen3.5-derived models use XML parameter format for tool calls:
            //   <tool_call>{"name":"...","arguments":{...}}</tool_call>
            // The default ToolCallProcessor can't parse XML content and silently
            // discards tool calls. Setting .xmlFunction activates XMLFunctionParser
            // which correctly handles this format.
            if usesQwenCompatibleToolCallFormat(modelID: modelID) {
                config.toolCallFormat = .xmlFunction
                NSLog("MLXLLMEngine: set toolCallFormat=xmlFunction for Qwen-compatible model")
            }
            container = try await LLMModelFactory.shared.loadContainer(configuration: config)
            isLoaded = true
            loadState = .loaded
            sessionState = nil
            NSLog("MLXLLMEngine: model loaded")
        } catch {
            loadState = .failed(error.localizedDescription)
            NSLog("MLXLLMEngine: load failed: %@", error.localizedDescription)
            throw error
        }
    }

    func setWiredMemoryTicketProvider(
        _ provider: (@Sendable (Int, Int) async -> WiredMemoryTicket?)?
    ) {
        wiredMemoryTicketProvider = provider
    }

    func synchronizeSession(history: [LLMMessage]) async {
        guard var sessionState else { return }
        sessionState.history = history
        sessionState.reusable = true
        self.sessionState = sessionState
    }

    func resetSession() async {
        sessionState = nil
    }

    func measureMemory(
        tokenCount: Int,
        parameters: GenerateParameters
    ) async throws -> WiredMemoryMeasurement {
        guard let container else {
            throw MLEngineError.notLoaded("LLM")
        }

        return try await container.perform { context in
            try await WiredMemoryUtils.tune(
                context: context,
                tokenCount: tokenCount,
                parameters: parameters
            )
        }
    }

    /// Run a warmup inference to pre-compile Metal shaders using production-like paths.
    func warmup() async {
        guard let container else { return }
        NSLog("MLXLLMEngine: starting warmup inference...")

        let plainPrompt = "Hello Fae. Give me a short greeting."
        let toolPrompt = "If you needed a tool, you would call it. For now just say hi."
        let dummyTools: [[String: any Sendable]] = [
            [
                "type": "function",
                "function": [
                    "name": "noop",
                    "description": "No-op warmup tool",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "input": ["type": "string"] as [String: String],
                        ] as [String: Any],
                        "required": ["input"],
                    ] as [String: Any],
                ] as [String: Any],
            ],
        ]

        do {
            try await performWarmupPass(
                container: container,
                systemPrompt: "You are Fae.",
                userPrompt: plainPrompt,
                tools: []
            )
            try await performWarmupPass(
                container: container,
                systemPrompt: "You are Fae. Tools may be available.",
                userPrompt: toolPrompt,
                tools: dummyTools
            )
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
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                guard let container = await self.container else {
                    continuation.finish(throwing: MLEngineError.notLoaded("LLM"))
                    return
                }

                let turnContextPrefix = options.turnContextPrefix?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let toolSignature = await self.toolSignature(for: options.tools)
                let priorSession = await self.sessionState
                let canReuseSession = await self.canReuseSession(
                    priorSession,
                    messages: messages,
                    systemPrompt: systemPrompt,
                    toolSignature: toolSignature
                )

                let deltaMessages: [LLMMessage]
                let chatMessages: [Chat.Message]
                let cacheBox: UnsafeBox<[KVCache]>

                if let priorSession, canReuseSession {
                    deltaMessages = Array(messages.dropFirst(priorSession.history.count))
                    chatMessages = await self.makeDeltaChatMessages(
                        from: deltaMessages,
                        turnContextPrefix: turnContextPrefix
                    )
                    cacheBox = UnsafeBox(priorSession.kvCache)
                    NSLog(
                        "MLXLLMEngine: reusing session cache for %d message(s)",
                        deltaMessages.count
                    )
                } else {
                    deltaMessages = messages
                    chatMessages = await self.makeFullChatMessages(
                        from: messages,
                        systemPrompt: systemPrompt,
                        turnContextPrefix: turnContextPrefix
                    )
                    cacheBox = UnsafeBox([])
                    if priorSession != nil {
                        NSLog("MLXLLMEngine: session cache invalidated — rebuilding prompt state")
                    }
                }

                let baseParameters = await self.makeParameters(from: options)
                let ticketProvider = await self.wiredMemoryTicketProvider

                do {
                    let setup = try await container.perform { context in
                        var userInput = UserInput(chat: chatMessages)
                        userInput.additionalContext = ["enable_thinking": !options.suppressThinking]
                        // With toolCallFormat=.xmlFunction, passing tools=nil can cause
                        // 0-token generation. Always provide an array.
                        userInput.tools = options.tools ?? []

                        let input = try await context.processor.prepare(input: userInput)
                        let cachedTokenCount = cacheBox.value.first?.offset ?? 0
                        let totalPromptTokens = cachedTokenCount + input.text.tokens.size

                        var effectiveParameters = baseParameters
                        if let contextLimit = options.contextLimitTokens {
                            let availableForGeneration = max(contextLimit - totalPromptTokens - 32, 1)
                            if let maxTokens = effectiveParameters.maxTokens, maxTokens > availableForGeneration {
                                effectiveParameters.maxTokens = availableForGeneration
                            }
                        }

                        if cacheBox.value.isEmpty {
                            cacheBox.value = context.model.newCache(parameters: effectiveParameters)
                        }

                        let ticket = await ticketProvider?(totalPromptTokens, effectiveParameters.maxTokens ?? 0)
                        let iterator = try TokenIterator(
                            input: input,
                            model: context.model,
                            cache: cacheBox.value,
                            parameters: effectiveParameters
                        )
                        let (stream, task) = generateTask(
                            promptTokenCount: input.text.tokens.size,
                            modelConfiguration: context.configuration,
                            tokenizer: context.tokenizer,
                            iterator: iterator,
                            wiredMemoryTicket: ticket
                        )
                        return GenerationSetup(
                            stream: stream,
                            task: task,
                            promptTokenCount: input.text.tokens.size,
                            cachedTokenCount: cachedTokenCount,
                            effectiveMaxTokens: effectiveParameters.maxTokens ?? 0
                        )
                    }

                    await self.storePreparedSession(
                        history: messages,
                        systemPrompt: systemPrompt,
                        toolSignature: toolSignature,
                        kvCache: cacheBox.value
                    )

                    var completionInfo: GenerateCompletionInfo?
                    for await generation in setup.stream {
                        if Task.isCancelled {
                            break
                        }
                        switch generation {
                        case .chunk(let text):
                            continuation.yield(.text(text))
                        case .toolCall(let call):
                            continuation.yield(.toolCall(call))
                        case .info(let info):
                            completionInfo = info
                            continuation.yield(.info(info))
                        }
                    }

                    await setup.task.value
                    await self.finishGeneration(info: completionInfo, kvCache: cacheBox.value)
                    continuation.finish()
                } catch {
                    await self.invalidatePreparedSession(
                        history: messages,
                        systemPrompt: systemPrompt,
                        toolSignature: toolSignature,
                        kvCache: cacheBox.value
                    )
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }

    private func performWarmupPass(
        container: ModelContainer,
        systemPrompt: String,
        userPrompt: String,
        tools: [[String: any Sendable]]
    ) async throws {
        let chatMessages: [Chat.Message] = [.system(systemPrompt), .user(userPrompt)]
        var userInput = UserInput(chat: chatMessages)
        userInput.additionalContext = ["enable_thinking": false]
        userInput.tools = tools
        let lmInput = try await container.prepare(input: userInput)
        let params = GenerateParameters(
            maxTokens: 8,
            temperature: 0.0,
            topP: 1.0,
            repetitionPenalty: 1.0,
            prefillStepSize: 256
        )
        let stream = try await container.generate(input: lmInput, parameters: params)
        var sawEvent = false
        for await generation in stream {
            switch generation {
            case .chunk, .toolCall, .info:
                sawEvent = true
            }
            if sawEvent {
                break
            }
        }
    }

    private func makeParameters(from options: GenerationOptions) -> GenerateParameters {
        GenerateParameters(
            maxTokens: options.maxTokens,
            maxKVSize: options.maxKVSize,
            kvBits: options.kvBits,
            kvGroupSize: options.kvGroupSize,
            quantizedKVStart: options.quantizedKVStart,
            temperature: options.temperature,
            topP: options.topP,
            repetitionPenalty: options.repetitionPenalty,
            repetitionContextSize: options.repetitionContextSize,
            prefillStepSize: options.prefillStepSize ?? 512
        )
    }

    private func storePreparedSession(
        history: [LLMMessage],
        systemPrompt: String,
        toolSignature: String,
        kvCache: [KVCache]
    ) {
        sessionState = SessionState(
            systemPrompt: systemPrompt,
            toolSignature: toolSignature,
            history: history,
            kvCache: kvCache,
            reusable: false
        )
    }

    private func finishGeneration(
        info: GenerateCompletionInfo?,
        kvCache: [KVCache]
    ) {
        lastCompletionInfo = info
        if var sessionState {
            sessionState.kvCache = kvCache
            self.sessionState = sessionState
        }
    }

    private func invalidatePreparedSession(
        history: [LLMMessage],
        systemPrompt: String,
        toolSignature: String,
        kvCache: [KVCache]
    ) {
        sessionState = SessionState(
            systemPrompt: systemPrompt,
            toolSignature: toolSignature,
            history: history,
            kvCache: kvCache,
            reusable: false
        )
    }

    private func canReuseSession(
        _ session: SessionState?,
        messages: [LLMMessage],
        systemPrompt: String,
        toolSignature: String
    ) -> Bool {
        guard let session else { return false }
        guard session.reusable else { return false }
        guard session.systemPrompt == systemPrompt else { return false }
        guard session.toolSignature == toolSignature else { return false }
        guard messages.count >= session.history.count else { return false }
        return Array(messages.prefix(session.history.count)) == session.history
    }

    private func toolSignature(for tools: [[String: any Sendable]]?) -> String {
        guard let tools else { return "none" }
        let names = tools.compactMap { spec -> String? in
            guard let function = spec["function"] as? [String: any Sendable] else { return nil }
            return function["name"] as? String
        }
        return names.sorted().joined(separator: "|")
    }

    private func makeFullChatMessages(
        from messages: [LLMMessage],
        systemPrompt: String,
        turnContextPrefix: String?
    ) -> [Chat.Message] {
        var chatMessages: [Chat.Message] = [.system(systemPrompt)]
        chatMessages.append(contentsOf: makeChatMessages(from: messages))
        attachTurnContext(turnContextPrefix, to: &chatMessages, mode: .lastMessage)
        return chatMessages
    }

    private func makeDeltaChatMessages(
        from messages: [LLMMessage],
        turnContextPrefix: String?
    ) -> [Chat.Message] {
        var chatMessages = makeChatMessages(from: messages)
        attachTurnContext(turnContextPrefix, to: &chatMessages, mode: .firstMessage)
        return chatMessages
    }

    private enum TurnContextAttachmentMode {
        case firstMessage
        case lastMessage
    }

    private func attachTurnContext(
        _ turnContextPrefix: String?,
        to chatMessages: inout [Chat.Message],
        mode: TurnContextAttachmentMode
    ) {
        guard let turnContextPrefix,
              !turnContextPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        let payload = "<turn_context>\n\(turnContextPrefix)\n</turn_context>"

        let targetIndex: Int?
        switch mode {
        case .firstMessage:
            targetIndex = chatMessages.indices.first
        case .lastMessage:
            targetIndex = chatMessages.indices.last
        }

        guard let index = targetIndex else {
            chatMessages = [.user(payload)]
            return
        }

        let message = chatMessages[index]
        let decoratedContent = payload + "\n\n" + message.content
        chatMessages[index] = Chat.Message(
            role: message.role,
            content: decoratedContent,
            images: message.images,
            videos: message.videos
        )
    }

    private func makeChatMessages(from messages: [LLMMessage]) -> [Chat.Message] {
        messages.map { msg in
            switch msg.role {
            case .user:
                return .user(msg.content)
            case .assistant:
                return .assistant(msg.content)
            case .system:
                return .system(msg.content)
            case .tool:
                return .tool(msg.content)
            }
        }
    }
}
