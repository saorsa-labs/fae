import Foundation

// MARK: - ChannelKind

/// Identifies which external messaging platform a channel message originates from.
///
/// Raw string values are used for logging, metrics, and persistence keys.
enum ChannelKind: String, Sendable, Codable, CaseIterable {
    case imessage
    case whatsapp
    case discord

    /// Human-readable display name for UI and logs.
    var displayName: String {
        switch self {
        case .imessage: return "iMessage"
        case .whatsapp: return "WhatsApp"
        case .discord: return "Discord"
        }
    }
}

// MARK: - ChannelAttachment

/// Placeholder attachment type for future media support in channel messages.
///
/// Currently unused — all channel messages are text-only. The struct is defined
/// now so that `ChannelMessage` has a stable schema when attachments are added.
struct ChannelAttachment: Sendable, Codable, Equatable {
    /// The kind of attachment content.
    enum AttachmentType: String, Sendable, Codable {
        case image
        case file
        case audio
        case video
    }

    /// The kind of attachment.
    let type: AttachmentType

    /// Remote URL for the attachment, if available.
    let url: URL?

    /// Inline attachment data, if available.
    let data: Data?

    /// MIME type string (e.g. `"image/png"`).
    let mimeType: String?
}

// MARK: - ChannelMessage

/// Normalised message envelope used by all channel adapters.
///
/// Every inbound message from Discord, WhatsApp, or iMessage is converted into
/// a `ChannelMessage` before reaching the gateway. This provides a single type
/// for routing, session resolution, and response dispatch.
struct ChannelMessage: Sendable, Equatable {
    /// Unique message identifier (adapter-generated or UUID).
    let id: String

    /// The channel this message arrived on.
    let channel: ChannelKind

    /// Platform-specific sender identifier (Discord user ID, phone number, etc.).
    let senderId: String

    /// Optional human-readable sender name.
    let senderDisplayName: String?

    /// The text content of the message.
    let text: String

    /// When the message was sent or received.
    let timestamp: Date

    /// Optional thread or group identifier (Discord thread ID, WhatsApp group chat).
    let threadId: String?

    /// Optional ID of the message this is replying to.
    let replyToId: String?

    /// Attachments (currently always empty — placeholder for future media support).
    let attachments: [ChannelAttachment]

    /// Optional cross-channel context injected by the gateway when the sender
    /// has linked identities on other channels.
    let crossChannelContext: String?

    /// Create a new channel message with all fields.
    init(
        id: String = UUID().uuidString,
        channel: ChannelKind,
        senderId: String,
        senderDisplayName: String? = nil,
        text: String,
        timestamp: Date = Date(),
        threadId: String? = nil,
        replyToId: String? = nil,
        attachments: [ChannelAttachment] = [],
        crossChannelContext: String? = nil
    ) {
        self.id = id
        self.channel = channel
        self.senderId = senderId
        self.senderDisplayName = senderDisplayName
        self.text = text
        self.timestamp = timestamp
        self.threadId = threadId
        self.replyToId = replyToId
        self.attachments = attachments
        self.crossChannelContext = crossChannelContext
    }
}
