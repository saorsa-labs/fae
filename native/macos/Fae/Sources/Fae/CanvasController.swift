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

/// Observable store for canvas content and live activity feed.
///
/// Supports two display modes:
/// - **Activity feed mode**: live tool cards showing tool calls, results, and web searches
/// - **Static HTML mode**: legacy HTML rendering via `setContent(_:)`
///
/// `PipelineAuxBridgeController` pushes content and visibility updates here.
/// `CanvasWindowView` observes the published properties to render content.
@MainActor
final class CanvasController: ObservableObject {
    /// Legacy HTML content (for backward compat with setContent callers).
    @Published var htmlContent: String = ""

    /// Whether the canvas window should be visible.
    @Published var isVisible: Bool = false

    /// Live activity cards for the current turn.
    @Published var activityCards: [ActivityCard] = []

    /// Archived turns: each entry is (timestamp, cards) for a completed turn.
    @Published var archivedTurns: [(timestamp: Date, cards: [ActivityCard])] = []

    /// Whether we're in activity feed mode (vs static HTML mode).
    @Published var isActivityMode: Bool = false

    /// Whether the canvas currently has anything meaningful to display.
    var hasDisplayableContent: Bool {
        if isActivityMode {
            return !activityCards.isEmpty || !archivedTurns.isEmpty
        }

        return !htmlContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Legacy HTML API (kept for backward compat)

    func setContent(_ html: String) {
        isActivityMode = false
        htmlContent = html
    }

    func appendContent(_ html: String) {
        htmlContent += html
    }

    func clear() {
        htmlContent = ""
        activityCards = []
        archivedTurns = []
        isActivityMode = false
        isVisible = false
    }

    // MARK: - Activity Feed API

    func addCard(_ card: ActivityCard) {
        isActivityMode = true
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

    func clearActivity() {
        activityCards = []
        archivedTurns = []
        isActivityMode = false
    }
}
