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
}
