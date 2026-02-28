import Foundation
import FaeHandoffKit

// MARK: - Chat Types

enum ChatRole: String {
    case user
    case assistant
    case tool
}

struct ChatMessage: Identifiable {
    let id: UUID
    let role: ChatRole
    let content: String
    let timestamp: Date

    init(id: UUID = UUID(), role: ChatRole, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

// MARK: - ConversationController

@MainActor
final class ConversationController: ObservableObject {
    @Published var isListening: Bool = true
    @Published var isConversationPanelOpen: Bool = false
    @Published var isCanvasPanelOpen: Bool = false
    @Published var lastInteractionTimestamp: Date = Date()

    /// Native message store for SwiftUI conversation window.
    @Published var messages: [ChatMessage] = []

    /// Whether the assistant is currently generating a response.
    @Published var isGenerating: Bool = false

    /// Text currently streaming from the assistant (sentence fragments as they arrive).
    @Published var streamingText: String = ""
    /// Whether a streaming response is actively being built.
    @Published var isStreaming: Bool = false

    /// Friendly label for the loaded LLM, e.g. "Qwen3 8B · Q4_K_M".
    /// Set when the LLM finishes loading; empty until then.
    @Published var loadedModelLabel: String = ""

    private let maxMessages = 200

    /// Set when a handoff snapshot is restored. The UI observes this to push
    /// the restored entries into the conversation web view.
    @Published private(set) var restoredSnapshot: ConversationSnapshot?

    /// The device name that sent the restored conversation (for banner display).
    @Published private(set) var restoredFromDevice: String?

    func toggleListening() {
        isListening.toggle()
        lastInteractionTimestamp = Date()
        NotificationCenter.default.post(
            name: .faeConversationGateSet,
            object: nil,
            userInfo: ["active": isListening]
        )
    }

    func handleUserSent(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastInteractionTimestamp = Date()
        // Add to conversation panel immediately — typed messages don't go through
        // STT/pendingUserTranscription, so we add them here directly.
        appendMessage(role: .user, content: trimmed)
        NotificationCenter.default.post(
            name: .faeConversationInjectText,
            object: nil,
            userInfo: ["text": trimmed]
        )
    }

    /// Restore conversation state from a handoff snapshot.
    ///
    /// Stores the snapshot so the UI layer can push entries into the web view.
    /// Handles malformed snapshots gracefully — empty entries are accepted but
    /// a nil snapshot is a no-op.
    func restore(from snapshot: ConversationSnapshot, device: String? = nil) {
        restoredSnapshot = snapshot
        restoredFromDevice = device
        lastInteractionTimestamp = Date()
        NSLog("ConversationController: restored %d entries from handoff%@",
              snapshot.entries.count,
              device.map { " (\($0))" } ?? "")
    }

    /// Clear the restored snapshot after the UI has consumed it.
    func clearRestoredSnapshot() {
        restoredSnapshot = nil
        restoredFromDevice = nil
    }

    // MARK: - Message Store

    func appendMessage(role: ChatRole, content: String) {
        let message = ChatMessage(role: role, content: content)
        messages.append(message)
        // FIFO cap at maxMessages
        if messages.count > maxMessages {
            messages.removeFirst(messages.count - maxMessages)
        }
    }

    func clearMessages() {
        messages.removeAll()
    }

    // MARK: - Streaming

    func startStreaming() {
        streamingText = ""
        isStreaming = true
    }

    func updateStreaming(text: String) {
        streamingText = text
    }

    func finalizeStreaming() {
        if !streamingText.isEmpty {
            appendMessage(role: .assistant, content: streamingText)
        }
        streamingText = ""
        isStreaming = false
    }

    func cancelStreaming() {
        // Commit any partial text as a message (barge-in)
        if !streamingText.isEmpty {
            appendMessage(role: .assistant, content: streamingText)
        }
        streamingText = ""
        isStreaming = false
    }

    // MARK: - Link Detection

    func handleLinkDetected(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Post as a separate link-detected event, NOT as inject_text.
        // The message text (including the URL) is already injected by handleUserSent.
        // This event is for link-specific handling (preview cards, bookmarks, etc.).
        NotificationCenter.default.post(
            name: .faeConversationLinkDetected,
            object: nil,
            userInfo: ["url": trimmed]
        )
    }
}

extension Notification.Name {
    static let faeConversationInjectText = Notification.Name("faeConversationInjectText")
    static let faeConversationGateSet = Notification.Name("faeConversationGateSet")
    static let faeConversationLinkDetected = Notification.Name("faeConversationLinkDetected")
    /// Posted when the user clicks the collapsed orb to expand it.
    /// The HostCommandBridge forwards this as "conversation.engage" to reset
    /// the direct-address follow-up window so the next utterance is accepted.
    static let faeConversationEngage = Notification.Name("faeConversationEngage")
    /// Posted by WindowStateController when it expands from collapsed to compact.
    /// InputBarView listens for this to restore keyboard focus on the text field.
    static let faeWillFocusInputField = Notification.Name("faeWillFocusInputField")
    /// Posted by Help menu items to pre-fill the input bar with a topic question.
    /// userInfo: ["text": String]
    static let faePrefillInput = Notification.Name("faePrefillInput")
    /// Posted by the stop button or Cmd+. menu item to cancel the current generation.
    static let faeCancelGeneration = Notification.Name("faeCancelGeneration")
}
