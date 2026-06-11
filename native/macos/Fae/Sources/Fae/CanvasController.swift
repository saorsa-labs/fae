import Foundation

// MARK: - Activity Card Types

enum ActivityCardStatus {
    case running
    case done
    case error
}

enum ActivityCardKind {
    case toolCall(name: String)
    case toolResult(name: String, isError: Bool)
    case thinking
    case webResult(title: String, url: String, snippet: String)
    case codeBlock(language: String, code: String)
}

struct ActivityCard: Identifiable {
    let id: String
    var kind: ActivityCardKind
    var status: ActivityCardStatus
    var detail: String
    let timestamp: Date

    init(
        id: String = UUID().uuidString,
        kind: ActivityCardKind,
        status: ActivityCardStatus = .running,
        detail: String = "",
        timestamp: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.detail = detail
        self.timestamp = timestamp
    }
}

// MARK: - CanvasController

/// Observable store for the live tool-activity feed shown inline in the
/// conversation scroll (tool calls, results, web searches).
///
/// The legacy static-HTML canvas window was removed in the 2026-06-11
/// cleanup; the Rust orb host's panels own rich content surfaces now.
@MainActor
final class CanvasController: ObservableObject {
    /// Live activity cards for the current turn.
    @Published var activityCards: [ActivityCard] = []

    /// Archived turns: each entry is (timestamp, cards) for a completed turn.
    @Published var archivedTurns: [(timestamp: Date, cards: [ActivityCard])] = []

    func clear() {
        activityCards = []
        archivedTurns = []
    }

    // MARK: - Activity Feed API

    func addCard(_ card: ActivityCard) {
        activityCards.append(card)
    }

    func updateCard(id: String, status: ActivityCardStatus, detail: String? = nil) {
        if let idx = activityCards.firstIndex(where: { $0.id == id }) {
            activityCards[idx].status = status
            if let detail {
                activityCards[idx].detail = detail
            }
        }
    }

    /// Archive the current turn's cards and start fresh for the next turn.
    func archiveCurrentTurn() {
        guard !activityCards.isEmpty else { return }
        archivedTurns.append((timestamp: Date(), cards: activityCards))
        // Keep max 10 archived turns
        if archivedTurns.count > 10 {
            archivedTurns.removeFirst(archivedTurns.count - 10)
        }
        activityCards = []
    }
}
