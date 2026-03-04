import Foundation

/// Tracks conversation turns and history for the LLM context window.
///
/// Replaces: conversation tracking from `src/pipeline/coordinator.rs`
actor ConversationStateTracker {

    /// Maximum number of history messages to retain.
    private(set) var maxHistoryMessages: Int = 10

    /// Context budget in tokens (set from model selection). Used for token-aware truncation.
    private var contextBudget: Int = 0

    /// Reserved tokens for system prompt + generation. Conversation must fit in the remainder.
    private var reservedTokens: Int = 0

    /// Conversation history for LLM context.
    private(set) var history: [LLMMessage] = []

    /// The last assistant response text (for context-aware intent classification).
    private(set) var lastAssistantText: String?

    // MARK: - Configuration

    /// Set the maximum history message count (called by FaeCore after pipeline setup).
    func setMaxHistory(_ count: Int) {
        maxHistoryMessages = max(count, 4)
        trimHistory()
    }

    /// Set the context budget for token-aware truncation.
    ///
    /// - Parameters:
    ///   - contextSize: Total context window in tokens.
    ///   - reservedTokens: Tokens reserved for system prompt + generation output.
    func setContextBudget(contextSize: Int, reservedTokens: Int) {
        self.contextBudget = contextSize
        self.reservedTokens = reservedTokens
    }

    /// Update only the reserved-token portion of the budget.
    ///
    /// Useful when the dynamic system prompt size changes turn-to-turn
    /// (memory context, activated skills, tool schemas).
    func setReservedTokens(_ reservedTokens: Int) {
        self.reservedTokens = max(reservedTokens, 0)
        trimHistory()
    }

    // MARK: - History Management

    /// Add a user message to history, optionally annotated with speaker name and ID.
    func addUserMessage(_ text: String, speakerDisplayName: String? = nil, speakerId: String? = nil, tag: String? = nil) {
        let content: String
        if let name = speakerDisplayName, let speakerId, !speakerId.isEmpty {
            content = "[\(name) | id:\(speakerId)]: \(text)"
        } else if let name = speakerDisplayName {
            content = "[\(name)]: \(text)"
        } else if let speakerId, !speakerId.isEmpty {
            content = "[speaker id:\(speakerId)]: \(text)"
        } else {
            content = text
        }
        history.append(LLMMessage(role: .user, content: content, tag: tag))
        trimHistory()
    }

    /// Add an assistant message to history.
    func addAssistantMessage(_ text: String, tag: String? = nil) {
        history.append(LLMMessage(role: .assistant, content: text, tag: tag))
        lastAssistantText = text
        trimHistory()
    }

    /// Add a tool result to history.
    func addToolResult(id: String, name: String, content: String, tag: String? = nil) {
        let maxToolResultChars = 2_000
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = normalized.count > maxToolResultChars
            ? String(normalized.prefix(maxToolResultChars)) + "\n[truncated]"
            : normalized
        history.append(LLMMessage(role: .tool, content: bounded, toolCallID: id, name: name, tag: tag))
        trimHistory()
    }

    /// Truncate history to keep only the last N messages.
    func truncateHistory(keep: Int) {
        if history.count > keep {
            history = Array(history.suffix(keep))
        }
    }

    /// Remove history entries with a specific tag.
    func removeMessages(taggedWith tag: String) {
        history.removeAll { $0.tag == tag }
        lastAssistantText = history.last(where: { $0.role == .assistant })?.content
    }

    /// Clear all history.
    func clear() {
        history.removeAll()
        lastAssistantText = nil
    }

    // MARK: - Private

    private func trimHistory() {
        // First pass: message-count cap.
        if history.count > maxHistoryMessages {
            history = Array(history.suffix(maxHistoryMessages))
        }

        // Second pass: token-aware truncation (if budget is configured).
        guard contextBudget > 0 else { return }
        let available = contextBudget - reservedTokens
        guard available > 0 else { return }

        while history.count > 2, estimateTokenCount() > available {
            history.removeFirst()
        }
    }

    /// Lightweight token estimate: characters / 3.5 for English text.
    private func estimateTokenCount() -> Int {
        var totalChars = 0
        for message in history {
            totalChars += message.content.count
            // Role/framing overhead: ~4 tokens per message.
            totalChars += 14
        }
        return Int(Double(totalChars) / 3.5)
    }
}
