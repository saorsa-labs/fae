import Foundation

@MainActor
final class ConversationController: ObservableObject {
    @Published var isListening: Bool = true
    @Published var isConversationPanelOpen: Bool = false
    @Published var isCanvasPanelOpen: Bool = false
    @Published var lastInteractionTimestamp: Date = Date()

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
