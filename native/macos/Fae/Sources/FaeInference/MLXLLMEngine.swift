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
    private var loadedModelId: String?
    public private(set) var isLoaded: Bool = false
    public private(set) var loadState: MLEngineLoadState = .notStarted
    private var sessionState: SessionState?
    private var wiredMemoryTicketProvider: (@Sendable (Int, Int) async -> WiredMemoryTicket?)?
    public private(set) var lastCompletionInfo: GenerateCompletionInfo?

    public init() {}

    public func load(modelID: String) async throws {
        try await load(modelID: modelID, progressHandler: { _ in })
    }

    /// Load a model with download progress reporting.
    ///
    /// When the model is not locally cached, MLX's `LLMModelFactory` downloads it
    /// from HuggingFace Hub. The `progressHandler` receives `Progress` updates during
    /// that download, allowing the UI to show a progress bar instead of freezing.
    public func load(
        modelID: String,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws {
        loadState = .loading
        NSLog("MLXLLMEngine: loading model %@", modelID)
        do {
            var config: ModelConfiguration
            if let localDirectory = localModelDirectoryURL(from: modelID) {
                config = ModelConfiguration(directory: localDirectory)
                NSLog("MLXLLMEngine: resolved local model directory %@", localDirectory.path)
            } else {
                config = ModelConfiguration(id: modelID)
                NSLog("MLXLLMEngine: model not cached locally — download will begin")
            }
            if usesQwenCompatibleToolCallFormat(modelID: modelID) {
                config.toolCallFormat = .xmlFunction
                NSLog("MLXLLMEngine: set toolCallFormat=xmlFunction for Qwen-compatible model")
            }
            container = try await LLMModelFactory.shared.loadContainer(
                configuration: config,
                progressHandler: progressHandler
            )
            isLoaded = true
            loadState = .loaded
            loadedModelId = modelID
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

    /// Warm the KV cache by running a minimal generation (1 token) with the
    /// given system prompt and history.  The resulting session state is stored
    /// so that the next `generate()` call with a matching prefix reuses the
    /// cache via `canReuseSession()`, skipping the expensive prompt prefill.
    ///
    /// Called speculatively at speech-end to overlap LLM prefill with final STT.
    public func prefillSession(
        messages: [LLMMessage],
        systemPrompt: String,
        options: GenerationOptions
    ) async throws {
        guard container != nil else { return }
        // Check if the session is already warm for this prompt/history.
        if let session = sessionState,
           session.systemPrompt == systemPrompt,
           session.history.count <= messages.count,
           session.history == Array(messages.prefix(session.history.count)),
           session.reusable
        {
            return  // Already warm — nothing to do.
        }

        // Run a 1-token generation to fill the KV cache.
        // The session state is persisted by generate()'s internal storePreparedSession().
        var prefillOptions = options
        prefillOptions.maxTokens = 1
        prefillOptions.suppressThinking = true
        let stream = generate(
            messages: messages,
            systemPrompt: systemPrompt,
            options: prefillOptions
        )
        // Drain the stream — we don't care about the output.
        do {
            for try await _ in stream {
                break  // One token is enough to warm the cache.
            }
        } catch {
            // Non-fatal — the cache may still be partially warm.
            NSLog("MLXLLMEngine: prefillSession error (non-fatal): %@", error.localizedDescription)
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

                NSLog("MLXLLMEngine: generate() starting — messages=%d", messages.count)

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

                // Debug: dump chat messages for tool follow-up diagnosis.
                // Check original messages (before tool→user conversion) since
                // makeChatMessages converts tool messages to user messages.
                let hasToolMessages = messages.contains { $0.role == .tool }
                if hasToolMessages {
                    NSLog("MLXLLMEngine: ⚠️ TOOL FOLLOW-UP — dumping %d chat messages:", chatMessages.count)
                    for (i, msg) in chatMessages.enumerated() {
                        let preview = String(msg.content.prefix(300)).replacingOccurrences(of: "\n", with: "\\n")
                        NSLog("  [%d] role=%@ content(%d chars)=%@", i, msg.role.rawValue, msg.content.count, preview)
                    }
                    NSLog("  tools=%d, suppressThinking=%@, shouldParseToolCalls=%@",
                          options.tools?.count ?? 0,
                          options.suppressThinking ? "true" : "false",
                          shouldParseToolCalls ? "true" : "false")
                }

                do {
                    NSLog("MLXLLMEngine: about to acquire container lock (parseTools=%@)", shouldParseToolCalls ? "true" : "false")
                    if shouldParseToolCalls {
                        let setup = try await container.perform { context in
                            NSLog("MLXLLMEngine: lock acquired — preparing input")
                            var userInput = UserInput(chat: chatMessages)
                            userInput.additionalContext = ["enable_thinking": !options.suppressThinking]
                            userInput.tools = options.tools ?? []

                            let input = try await context.processor.prepare(input: userInput)
                            let cachedTokenCount = cacheBox.value.first?.offset ?? 0
                            let totalPromptTokens = cachedTokenCount + input.text.tokens.size

                            // Debug: log prompt token count for tool follow-up diagnosis.
                            if hasToolMessages {
                                let tokenCount = input.text.tokens.size
                                NSLog("MLXLLMEngine: TOOL FOLLOW-UP prompt: %d tokens total", tokenCount)
                            }

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
                            // Pass the SAME tools as the cached session to keep tokenization
                            // consistent with the KV cache. We just won't parse the output
                            // for tool calls (text-only generation path).
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

        // Qwen3.5 is a hybrid Attention+Mamba architecture. KV cache reuse was
        // broken for hybrid models (QwenLM/Qwen3.5#37, ml-explore/mlx-lm#980).
        // PR #155 (cherry-picked into vendored mlx-swift-lm) adds CacheList
        // serialization/deserialization, enabling cache round-trip for hybrids.
        // Session reuse is now re-enabled for Qwen3.5.

        guard session.systemPrompt == systemPrompt else { return false }
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
        attachTurnContext(turnContextPrefix, to: &chatMessages, mode: .firstUserMessage)
        return chatMessages
    }

    private func makeDeltaChatMessages(
        from messages: [LLMMessage],
        turnContextPrefix: String?
    ) -> [Chat.Message] {
        var chatMessages = makeChatMessages(from: messages)
        attachTurnContext(turnContextPrefix, to: &chatMessages, mode: .firstUserMessage)
        return chatMessages
    }

    private enum TurnContextAttachmentMode {
        case firstUserMessage
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

        guard let index = chatMessages.firstIndex(where: { $0.role == .user }) else {
            chatMessages = [.user(payload)]
            return
        }

        let message = chatMessages[index]

        // Never inject turn context into tool result messages — the model
        // was trained to see clean tool responses. Mixing system context into
        // tool_response tags causes Qwen3.5 to produce 0 tokens on follow-ups.
        // When the target message is a tool response, find the nearest user
        // message instead so the context is available to the LLM.
        if message.role == .tool {
            let nearestUserIndex = chatMessages.firstIndex { $0.role == .user }
            if let userIdx = nearestUserIndex {
                let userMsg = chatMessages[userIdx]
                chatMessages[userIdx] = Chat.Message(
                    role: userMsg.role,
                    content: payload + "\n\n" + userMsg.content,
                    images: userMsg.images,
                    videos: userMsg.videos
                )
            }
            return
        }

        let decoratedContent = payload + "\n\n" + message.content
        chatMessages[index] = Chat.Message(
            role: message.role,
            content: decoratedContent,
            images: message.images,
            videos: message.videos
        )
    }

    private func makeChatMessages(from messages: [LLMMessage]) -> [Chat.Message] {
        // Group consecutive tool messages and merge them into a single user message
        // with <tool_response> wrapping. This matches the exact token sequence that
        // the Qwen3.5 Jinja template produces for role=tool, bypassing template
        // processing that can cause 0-token generation on tool follow-up turns.
        var result: [Chat.Message] = []
        var pendingToolResponses: [String] = []

        func flushToolResponses() {
            guard !pendingToolResponses.isEmpty else { return }
            // Format must match what the Jinja template's multi_step_tool
            // detection expects: content.startswith('<tool_response>') and
            // content.endswith('</tool_response>') — no leading/trailing newlines.
            let combined = pendingToolResponses
                .map { "<tool_response>\n\($0)\n</tool_response>" }
                .joined(separator: "\n")
            result.append(.user(combined))
            pendingToolResponses.removeAll()
        }

        for (idx, msg) in messages.enumerated() {
            switch msg.role {
            case .user:
                flushToolResponses()
                result.append(.user(msg.content))
            case .assistant:
                flushToolResponses()
                var content = msg.content
                // Qwen3.5 template bug: when the assistant emits thinking + tool call
                // with no visible text, the template leaves <think> unclosed. The model
                // then sees corrupted context on the follow-up turn and produces 0 tokens.
                //
                // Fix: if this assistant message contains <tool_call> but no </think>
                // marker, and the next message is a tool response, prepend </think>\n\n
                // so the template properly closes its think block. This is model-agnostic:
                // models without thinking have no <think> prefix in the template rendering.
                let hasToolCall = content.contains("<tool_call>")
                let hasThinkClose = content.contains("</think>")
                let nextIsTool = idx + 1 < messages.count && messages[idx + 1].role == .tool
                if hasToolCall && !hasThinkClose && nextIsTool {
                    content = "</think>\n\n" + content.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                result.append(.assistant(content))
            case .system:
                flushToolResponses()
                result.append(.system(msg.content))
            case .tool:
                pendingToolResponses.append(msg.content)
            }
        }
        flushToolResponses()
        return result
    }
}
