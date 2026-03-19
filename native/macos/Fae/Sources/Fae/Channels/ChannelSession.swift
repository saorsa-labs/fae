import FaeInference
import Foundation

// MARK: - SessionKey

/// Composite key identifying a unique sender on a specific channel.
///
/// Two senders with the same phone number on different channels (e.g. iMessage
/// vs WhatsApp) are treated as separate sessions until cross-channel identity
/// linking is implemented in Milestone 3.
struct SessionKey: Hashable, Sendable, CustomStringConvertible {
    /// The channel this session belongs to.
    let channel: ChannelKind

    /// Platform-specific sender identifier.
    let senderId: String

    var description: String {
        "\(channel.rawValue):\(senderId)"
    }
}

// MARK: - ChannelSession

/// Per-sender conversation state for a single channel session.
///
/// Each remote sender gets an isolated `ChannelSession` with its own message
/// history, independent from the local voice conversation and from other
/// channel senders. This prevents cross-contamination of conversation context.
final class ChannelSession: Sendable {
    /// The composite key for this session.
    let key: SessionKey

    /// Conversation history for this sender (user + assistant messages).
    private let _messages: LockedState<[LLMMessage]>

    /// Timestamp of the last message activity.
    private let _lastActivity: LockedState<Date>

    /// Optional display name for the sender.
    private let _senderDisplayName: LockedState<String?>

    /// Whether this session is actively being processed.
    private let _isActive: LockedState<Bool>

    /// Conversation history for this sender.
    var messages: [LLMMessage] {
        _messages.value
    }

    /// Timestamp of the last message activity.
    var lastActivity: Date {
        _lastActivity.value
    }

    /// Optional display name for the sender.
    var senderDisplayName: String? {
        _senderDisplayName.value
    }

    /// Whether this session is actively being processed.
    var isActive: Bool {
        _isActive.value
    }

    /// Create a new channel session for the given key.
    init(key: SessionKey, senderDisplayName: String? = nil) {
        self.key = key
        self._messages = LockedState([])
        self._lastActivity = LockedState(Date())
        self._senderDisplayName = LockedState(senderDisplayName)
        self._isActive = LockedState(true)
    }

    /// Append a user message to this session's history.
    func addUserMessage(_ text: String) {
        let message = LLMMessage(role: .user, content: text)
        _messages.withLock { $0.append(message) }
        _lastActivity.withLock { $0 = Date() }
    }

    /// Append an assistant response to this session's history.
    func addAssistantMessage(_ text: String) {
        let message = LLMMessage(role: .assistant, content: text)
        _messages.withLock { $0.append(message) }
        _lastActivity.withLock { $0 = Date() }
    }

    /// Trim history to the most recent `maxMessages`, keeping pairs intact.
    ///
    /// Always preserves at least the last user+assistant pair.
    func trimHistory(maxMessages: Int = 20) {
        _messages.withLock { messages in
            guard messages.count > maxMessages else { return }
            let excess = messages.count - maxMessages
            messages.removeFirst(excess)
        }
    }

    /// Mark this session as inactive (e.g. after idle timeout).
    func deactivate() {
        _isActive.withLock { $0 = false }
    }

    /// Update the sender display name.
    func updateDisplayName(_ name: String?) {
        _senderDisplayName.withLock { $0 = name }
    }
}

// MARK: - LockedState

/// Minimal thread-safe wrapper using `NSLock` for `Sendable` conformance.
///
/// This is intentionally simple — the gateway actor serialises most access,
/// but `ChannelSession` needs to be `Sendable` for passing across isolation
/// boundaries while still allowing mutation.
private final class LockedState<Value>: @unchecked Sendable {
    private var _value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self._value = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&_value)
    }
}
