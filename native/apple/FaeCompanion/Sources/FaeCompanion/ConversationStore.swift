import Foundation
import Combine
import FaeHandoffKit

/// Observable store for conversation turns displayed in the companion app.
@MainActor
final class ConversationStore: ObservableObject {

    @Published private(set) var turns: [ConversationTurn] = []

    /// Cancellable storage for relay subscriptions (used by FaeCompanionApp).
    var cancellables = Set<AnyCancellable>()

    /// Add a conversation turn from the relay.
    func addTurn(role: String, content: String, isFinal: Bool) {
        // If we have a streaming (non-final) turn from the same role, update it.
        if !isFinal, let lastIndex = turns.indices.last, turns[lastIndex].role == role, !turns[lastIndex].isFinal {
            turns[lastIndex] = ConversationTurn(
                id: turns[lastIndex].id,
                role: role,
                content: content,
                isFinal: false,
                timestamp: Date()
            )
            return
        }

        // Otherwise add a new turn.
        let turn = ConversationTurn(
            role: role,
            content: content,
            isFinal: isFinal,
            timestamp: Date()
        )
        turns.append(turn)

        // Keep only the most recent 20 turns.
        if turns.count > 20 {
            turns.removeFirst(turns.count - 20)
        }
    }

    /// Restore from a handoff ConversationSnapshot.
    func restore(from snapshot: ConversationSnapshot) {
        turns = snapshot.entries.map { entry in
            ConversationTurn(
                role: entry.role,
                content: entry.content,
                isFinal: true,
                timestamp: snapshot.timestamp
            )
        }
    }

    /// Clear all turns.
    func clear() {
        turns.removeAll()
    }
}

// MARK: - Turn Model

struct ConversationTurn: Identifiable {
    let id: UUID
    let role: String
    let content: String
    let isFinal: Bool
    let timestamp: Date

    init(id: UUID = UUID(), role: String, content: String, isFinal: Bool, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.isFinal = isFinal
        self.timestamp = timestamp
    }
}
