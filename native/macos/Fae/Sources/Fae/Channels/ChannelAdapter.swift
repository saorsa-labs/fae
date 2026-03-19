import Foundation

/// Protocol that all channel adapters must conform to.
///
/// Each adapter (Discord, WhatsApp, iMessage) implements this protocol so the
/// `ChannelGateway` can manage them uniformly. The gateway calls `start()` and
/// `stop()` for lifecycle, sets `onMessage` to receive inbound messages, and
/// calls `send(response:to:)` to deliver replies.
protocol ChannelAdapter: AnyObject, Sendable {
    /// The kind of channel this adapter handles.
    var kind: ChannelKind { get }

    /// Start the adapter (connect to platform, begin listening).
    func start() async throws

    /// Stop the adapter (disconnect, release resources).
    func stop() async

    /// Send a text response back to the platform for a given inbound message.
    ///
    /// - Parameters:
    ///   - response: The text to send.
    ///   - message: The original inbound message being replied to.
    func send(response: String, to message: ChannelMessage) async throws

    /// Callback invoked when the adapter receives an inbound message.
    ///
    /// The gateway sets this closure after creating the adapter. The adapter
    /// calls it for every validated inbound message. The return value is the
    /// assistant's response text (nil means no reply).
    var onMessage: (@Sendable (ChannelMessage) async -> String?)? { get set }
}
