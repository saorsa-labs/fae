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

    /// Wall-clock timestamp of the last assistant message, used for
    /// conversation-continuation tool visibility gating.
    private(set) var lastAssistantMessageAt: Date?

    /// Tools whose full schema the model actually used in recent turns, with
    /// the time of the last use. On a follow-up turn these are kept full-schema
    /// (a "sticky" working set) so a bare "yes, do that" can still call the tool
    /// the prior turn relied on — without inflating every continuation to the
    /// whole 36-tool surface. Self-decays via `recentToolNames(within:)`.
    private var recentTools: Set<String> = []
    private var recentToolsAt: Date?

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

    func currentContextBudget() -> Int {
        contextBudget
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

    /// Replace the content of the most recent user message, preserving its tag
    /// and applying the same speaker annotation as `addUserMessage`. Used by
    /// the S18 push-to-talk path: the turn starts with a placeholder user
    /// message (the audio rides the request) and is corrected once the model's
    /// `[heard]:` transcription arrives.
    func updateLastUserMessage(_ text: String, speakerDisplayName: String? = nil, speakerId: String? = nil) {
        guard let index = history.lastIndex(where: { $0.role == .user }) else { return }
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
        history[index] = LLMMessage(role: .user, content: content, tag: history[index].tag)
    }

    /// Add an assistant message to history.
    func addAssistantMessage(_ text: String, tag: String? = nil) {
        history.append(LLMMessage(role: .assistant, content: text, tag: tag))
        lastAssistantText = text
        lastAssistantMessageAt = Date()
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
        recordToolUse(name)
        trimHistory()
    }

    // MARK: - Sticky tool working set

    /// Record that a tool was just used, so it stays full-schema on follow-ups.
    func recordToolUse(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentTools.insert(trimmed)
        recentToolsAt = Date()
    }

    /// Tools used within the last `seconds`. Returns empty once stale so a new
    /// topic after a pause starts from the conservative working set again.
    func recentToolNames(within seconds: TimeInterval) -> Set<String> {
        guard let at = recentToolsAt, Date().timeIntervalSince(at) <= seconds else {
            return []
        }
        return recentTools
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
        // If the last assistant message was removed, clear the timestamp so the
        // continuation window doesn't stay stale.
        if lastAssistantText == nil {
            lastAssistantMessageAt = nil
        }
    }

    /// Clear all history.
    func clear() {
        history.removeAll()
        lastAssistantText = nil
        lastAssistantMessageAt = nil
        recentTools.removeAll()
        recentToolsAt = nil
    }

    /// Replace the current history with external messages and return the old history.
    ///
    /// Used by channel message processing to temporarily swap in a per-sender
    /// session's history, run the LLM turn, then restore the original history.
    @discardableResult
    func swapHistory(_ newHistory: [LLMMessage]) -> [LLMMessage] {
        let old = history
        history = newHistory
        lastAssistantText = newHistory.last(where: { $0.role == .assistant })?.content
        lastAssistantMessageAt = nil
        recentTools.removeAll()
        recentToolsAt = nil
        return old
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
        if available <= 0 {
            // Budget exhausted by system prompt — keep only the most recent pair.
            while history.count > 2 {
                history.removeFirst()
            }
            return
        }

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
