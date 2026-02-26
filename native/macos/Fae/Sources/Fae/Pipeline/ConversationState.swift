import Foundation

/// Tracks conversation turns and history for the LLM context window.
///
/// Replaces: conversation tracking from `src/pipeline/coordinator.rs`
actor ConversationStateTracker {

    /// Maximum number of history messages to retain.
    var maxHistoryMessages: Int = 10

    /// Conversation history for LLM context.
    private(set) var history: [LLMMessage] = []

    /// The last assistant response text (for context-aware intent classification).
    private(set) var lastAssistantText: String?

    // MARK: - History Management

    /// Add a user message to history.
    func addUserMessage(_ text: String) {
        history.append(LLMMessage(role: .user, content: text))
        trimHistory()
    }

    /// Add an assistant message to history.
    func addAssistantMessage(_ text: String) {
        history.append(LLMMessage(role: .assistant, content: text))
        lastAssistantText = text
        trimHistory()
    }

    /// Add a tool result to history.
    func addToolResult(id: String, name: String, content: String) {
        history.append(LLMMessage(role: .tool, content: content, toolCallID: id, name: name))
        trimHistory()
    }

    /// Truncate history to keep only the last N messages.
    func truncateHistory(keep: Int) {
        if history.count > keep {
            history = Array(history.suffix(keep))
        }
    }

    /// Clear all history.
    func clear() {
        history.removeAll()
        lastAssistantText = nil
    }

    // MARK: - Private

    private func trimHistory() {
        if history.count > maxHistoryMessages {
            history = Array(history.suffix(maxHistoryMessages))
        }
    }
}
