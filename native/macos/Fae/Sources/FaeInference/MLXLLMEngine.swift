import Foundation
import MLX
import MLXLLM
@preconcurrency import MLXLMCommon

private final class UnsafeBox<T>: @unchecked Sendable {
    var value: T

    init(_ value: T) {
        self.value = value
    }
}

/// Large language model engine using mlx-swift-lm.
public actor MLXLLMEngine: LLMEngine {
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

    private struct RawTokenGenerationSetup: @unchecked Sendable {
        let stream: AsyncStream<TokenGeneration>
        let task: Task<Void, Never>
        let detokenizer: NaiveStreamingDetokenizer
        let promptTokenCount: Int
        let cachedTokenCount: Int
        let effectiveMaxTokens: Int
    }

    private var container: ModelContainer?
    public private(set) var isLoaded: Bool = false
    public private(set) var loadState: MLEngineLoadState = .notStarted
    private var sessionState: SessionState?
    private var wiredMemoryTicketProvider: (@Sendable (Int, Int) async -> WiredMemoryTicket?)?
    public private(set) var lastCompletionInfo: GenerateCompletionInfo?

    public init() {}

    public func load(modelID: String) async throws {
        loadState = .loading
        NSLog("MLXLLMEngine: loading model %@", modelID)
        do {
            var config: ModelConfiguration
            if let localDirectory = localModelDirectoryURL(from: modelID) {
                config = ModelConfiguration(directory: localDirectory)
                NSLog("MLXLLMEngine: resolved local model directory %@", localDirectory.path)
            } else {
                config = ModelConfiguration(id: modelID)
            }
            if usesQwenCompatibleToolCallFormat(modelID: modelID) {
                config.toolCallFormat = .xmlFunction
                NSLog("MLXLLMEngine: set toolCallFormat=xmlFunction for Qwen-compatible model")
            }
            container = try await LLMModelFactory.shared.loadContainer(configuration: config)
            isLoaded = true
            loadState = .loaded
            sessionState = nil
            lastCompletionInfo = nil
            NSLog("MLXLLMEngine: model loaded")
        } catch {
            loadState = .failed(error.localizedDescription)
            NSLog("MLXLLMEngine: load failed: %@", error.localizedDescription)
            throw error
        }
    }

    /// Attach a pre-loaded ModelContainer (e.g. from VLMModelFactory for multimodal models).
    ///
    /// Used when the LLM model is natively multimodal (e.g. Qwen3.5-35B-A3B) and was loaded
    /// via VLMModelFactory to enable sharing between text and vision pipelines.
    public func attachContainer(_ sharedContainer: ModelContainer) {
        container = sharedContainer
        isLoaded = true
        loadState = .loaded
        sessionState = nil
        lastCompletionInfo = nil
        NSLog("MLXLLMEngine: attached shared container")
    }

    public func setWiredMemoryTicketProvider(
        _ provider: (@Sendable (Int, Int) async -> WiredMemoryTicket?)?
    ) {
        wiredMemoryTicketProvider = provider
    }

    public func synchronizeSession(history: [LLMMessage]) async {
        guard var sessionState else { return }
        sessionState.history = history
        sessionState.reusable = true
        self.sessionState = sessionState
    }

    public func resetSession() async {
        sessionState = nil
    }

    public func shutdown() async {
        sessionState = nil
        container = nil
        wiredMemoryTicketProvider = nil
        lastCompletionInfo = nil
        isLoaded = false
        loadState = .notStarted
    }

    public func measureMemory(
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

    public func warmup() async {
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

    public func generate(
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

                let chatMessages: [Chat.Message]
                let cacheBox: UnsafeBox<[KVCache]>

                if let priorSession, canReuseSession {
                    let deltaMessages = Array(messages.dropFirst(priorSession.history.count))
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
                // MLX tool-call parsing can corrupt plain XML text when no tools are active,
                // so only enable parsed generation on turns that actually expose tools.
                let shouldParseToolCalls = !(options.tools?.isEmpty ?? true)

                do {
                    if shouldParseToolCalls {
                        let setup = try await container.perform { context in
                            var userInput = UserInput(chat: chatMessages)
                            userInput.additionalContext = ["enable_thinking": !options.suppressThinking]
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
                    } else {
                        let setup = try await container.perform { context in
                            var userInput = UserInput(chat: chatMessages)
                            userInput.additionalContext = ["enable_thinking": !options.suppressThinking]
                            userInput.tools = []

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
                            let (stream, task) = generateTokenTask(
                                promptTokenCount: input.text.tokens.size,
                                modelConfiguration: context.configuration,
                                tokenizer: context.tokenizer,
                                iterator: iterator,
                                wiredMemoryTicket: ticket
                            )
                            return RawTokenGenerationSetup(
                                stream: stream,
                                task: task,
                                detokenizer: NaiveStreamingDetokenizer(tokenizer: context.tokenizer),
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
                        var detokenizer = setup.detokenizer
                        for await generation in setup.stream {
                            if Task.isCancelled {
                                break
                            }
                            switch generation {
                            case .token(let token):
                                detokenizer.append(token: token)
                                if let text = detokenizer.next(), !text.isEmpty {
                                    continuation.yield(.text(text))
                                }
                            case .info(let info):
                                completionInfo = info
                                continuation.yield(.info(info))
                            }
                        }

                        await setup.task.value
                        await self.finishGeneration(info: completionInfo, kvCache: cacheBox.value)
                    }
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
