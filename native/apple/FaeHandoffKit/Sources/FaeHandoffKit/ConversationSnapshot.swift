import Foundation

// MARK: - Snapshot Entry

/// A single conversation turn for handoff serialisation.
///
/// Only `"user"` and `"assistant"` roles should be present — system prompts,
/// tool results, and memory recall hits must be excluded by the provider before
/// building a snapshot.
public struct SnapshotEntry: Codable, Sendable, Equatable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

// MARK: - Conversation Snapshot

/// Serialisable snapshot of conversation state carried via NSUserActivity handoff
/// and the iCloud key-value store fallback.
///
/// The snapshot is intended to be small: only the most recent
/// `maxEntries` turns are encoded. The provider closure on
/// `DeviceHandoffController` is contractually responsible for filtering
/// entries to `"user"` and `"assistant"` roles before returning a snapshot.
public struct ConversationSnapshot: Codable, Sendable, Equatable {

    /// Maximum number of entries encoded into a handoff payload. Older entries
    /// are dropped to stay within NSUserActivity userInfo size limits.
    public static let maxEntries = 20

    public let entries: [SnapshotEntry]
    public let orbMode: String
    public let orbFeeling: String
    public let timestamp: Date

    public init(
        entries: [SnapshotEntry],
        orbMode: String,
        orbFeeling: String,
        timestamp: Date
    ) {
        self.entries = entries
        self.orbMode = orbMode
        self.orbFeeling = orbFeeling
        self.timestamp = timestamp
    }
}
