import Foundation
import os.log

// MARK: - Compression Configuration

struct CompressionConfig: Sendable {
    /// Threshold ratio to trigger compression (0.75 = compress at 75% of context window)
    let compressionTriggerRatio: Double
    /// Ratio of recent messages to always preserve (0.20 = keep last 20%)
    let recentMessagesRatio: Double
    /// Inverse of tokens per character (0.25 = 4 characters per token)
    let tokensPerChar: Double

    static let `default` = CompressionConfig(
        compressionTriggerRatio: 0.75,
        recentMessagesRatio: 0.20,
        tokensPerChar: 0.25  // 1 token ≈ 4 characters
    )
}

// MARK: - ConversationCompressor Actor

actor ConversationCompressor: Sendable {
    private let config: CompressionConfig
    private let logger = Logger(subsystem: "com.anthropic.fae", category: "ConversationCompressor")

    init(config: CompressionConfig = .default) {
        self.config = config
    }

    // MARK: - Token Estimation

    /// Estimates token count based on character count using the heuristic: ~4 chars per token
    private func estimateTokens(_ text: String) -> Int {
        Int(Double(text.count) * config.tokensPerChar)
    }

    /// Calculates total tokens in a message
    private func messageTokens(_ message: WorkWithFaeConversationMessage) -> Int {
        estimateTokens(message.content)
    }

    /// Calculates total tokens across all messages
    private func totalTokens(in messages: [WorkWithFaeConversationMessage]) -> Int {
        messages.reduce(0) { $0 + messageTokens($1) }
    }

    // MARK: - Compression Logic

    /// Compresses conversation messages if they exceed the configured threshold.
    /// Calls the local LLM to generate a summary when compression is needed.
    /// On failure, returns the original messages for graceful degradation.
    func compressIfNeeded(
        messages: [WorkWithFaeConversationMessage],
        contextWindowTokens: Int,
        modelID: String,
        provider: FaeLocalhostCoworkProvider,
        runtimeDescriptor: FaeLocalRuntimeDescriptor
    ) async -> [WorkWithFaeConversationMessage] {
        // Guard against edge cases
        guard messages.count > 10 else { return messages }

        // Check if compression is needed
        let currentTokens = totalTokens(in: messages)
        let compressionThreshold = Int(Double(contextWindowTokens) * config.compressionTriggerRatio)

        guard currentTokens > compressionThreshold else {
            // Under threshold, no compression needed
            return messages
        }

        // Compression is needed
        logger.info("Compression triggered: \(currentTokens) tokens > \(compressionThreshold) threshold (\(messages.count) messages)")

        let recentCount = max(1, Int(Double(messages.count) * config.recentMessagesRatio))
        let recentMessages = Array(messages.suffix(recentCount))
        let messagesToCompress = Array(messages.dropLast(recentCount))

        // Look for existing summary in the conversation to include in prompt
        let existingSummary = messagesToCompress.first { $0.role == "summary" }

        // Try to generate an LLM summary; fall back to original messages on error
        do {
            let summaryMessage = try await generateSummary(
                messages: messagesToCompress,
                previousSummary: existingSummary,
                modelID: modelID,
                provider: provider,
                runtimeDescriptor: runtimeDescriptor
            )

            logger.info("Compression complete: \(messagesToCompress.count) messages → 1 summary + \(recentMessages.count) recent")

            // Return: summary + recent messages (drop old messages entirely)
            return [summaryMessage] + recentMessages
        } catch {
            logger.error("Compression failed, keeping original messages: \(error.localizedDescription)")
            // Graceful degradation: return original messages unchanged
            return messages
        }
    }

    /// Synchronous compression check without LLM — returns original messages or hard-truncated.
    /// Used as a fallback when no provider is available.
    func compressIfNeeded(
        messages: [WorkWithFaeConversationMessage],
        contextWindowTokens: Int,
        modelID: String
    ) -> [WorkWithFaeConversationMessage] {
        // Guard against edge cases
        guard messages.count > 10 else { return messages }

        // Check if compression is needed
        let currentTokens = totalTokens(in: messages)
        let compressionThreshold = Int(Double(contextWindowTokens) * config.compressionTriggerRatio)

        guard currentTokens > compressionThreshold else {
            return messages
        }

        // No provider available — fall back to keeping recent messages only
        let recentCount = max(1, Int(Double(messages.count) * config.recentMessagesRatio))
        return Array(messages.suffix(recentCount))
    }

    // MARK: - Summary Generation

    /// Builds a prompt for summarizing conversation messages.
    /// Includes previous summary if it exists for progressive compression.
    private func buildSummaryPrompt(
        messages: [WorkWithFaeConversationMessage],
        previousSummary: WorkWithFaeConversationMessage?
    ) -> String {
        var prompt = """
        You are a conversation summarizer. Compress the following messages into a brief summary \
        that preserves key decisions, context, and action items. Keep the summary concise (max 300 tokens).

        """

        // Include previous summary for progressive compression
        if let previous = previousSummary {
            prompt += """
            Previous summary (for context):
            \(previous.content)

            """
        }

        // Add messages to compress
        prompt += "Messages to compress:\n"
        for (index, message) in messages.enumerated() {
            let role = message.role.uppercased()
            prompt += "[\(index + 1)] \(role): \(message.content)\n"
        }

        prompt += "\nProvide a concise summary."
        return prompt
    }

    /// Generates a summary of messages using the local LLM.
    /// Creates a prepared prompt, submits to the local provider, and returns summary message.
    func generateSummary(
        messages: [WorkWithFaeConversationMessage],
        previousSummary: WorkWithFaeConversationMessage?,
        modelID: String,
        provider: FaeLocalhostCoworkProvider,
        runtimeDescriptor: FaeLocalRuntimeDescriptor
    ) async throws -> WorkWithFaeConversationMessage {
        // Build summary prompt
        let summaryPrompt = buildSummaryPrompt(
            messages: messages,
            previousSummary: previousSummary
        )

        // Create prepared prompt for LLM
        let preparedPrompt = WorkWithFaePreparedPrompt(
            userVisiblePrompt: summaryPrompt,
            faeLocalPrompt: summaryPrompt,
            shareablePrompt: summaryPrompt,
            containsLocalOnlyContext: false,
            shareableExport: nil
        )

        // Create provider request
        let request = CoworkProviderRequest(
            model: modelID,
            preparedPrompt: preparedPrompt,
            thinkingLevel: .fast,
            systemPrompt: nil
        )

        // Submit to local LLM
        do {
            let response = try await provider.submit(request: request)

            // Log successful compression
            logger.debug("Compression summary generated for \(messages.count) messages")

            // Wrap response in conversation message
            return WorkWithFaeConversationMessage(
                id: UUID(),
                role: "summary",
                content: response.content,
                timestamp: Date(),
                modelID: modelID,
                providerKind: "fae-localhost"
            )
        } catch {
            // Log error and re-throw so caller can handle gracefully
            logger.error("Failed to generate summary: \(error.localizedDescription)")
            throw error
        }
    }
}
