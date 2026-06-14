import Foundation

/// Tracks in-flight assistant generations separately from the user-visible
/// "assistant is thinking" indicator.
///
/// Silent background generations (for example awareness chores) remain live for
/// stale-token isolation, but they do not light the orb's Thinking state. A
/// stale generation ending can therefore never clear a newer visible turn, while
/// quiescence is still forced back to idle when no visible generation remains.
struct AssistantGenerationTracker {
    enum Visibility: Equatable {
        /// User-visible turn: should drive the orb Thinking indicator.
        case visible
        /// Silent/background turn: should not drive the orb Thinking indicator.
        case silentBackground
    }

    private(set) var activeGenerationID: UUID?

    private var generationVisibility: [UUID: Visibility] = [:]

    var hasActiveGeneration: Bool {
        !generationVisibility.isEmpty
    }

    var hasVisibleGeneration: Bool {
        generationVisibility.values.contains(.visible)
    }

    mutating func begin(_ generationID: UUID, visibility: Visibility) {
        // A newly-started generation owns the token stream. Older generations
        // may still be draining, but they are superseded and must no longer
        // keep the user-visible Thinking indicator alive.
        generationVisibility = generationVisibility.mapValues { _ in .silentBackground }
        generationVisibility[generationID] = visibility
        activeGenerationID = generationID
    }

    mutating func end(_ generationID: UUID?) {
        guard let generationID else {
            reset()
            return
        }

        generationVisibility.removeValue(forKey: generationID)
        if activeGenerationID == generationID {
            activeGenerationID = nil
        }
    }

    mutating func reset() {
        generationVisibility.removeAll()
        activeGenerationID = nil
    }

    func shouldShowAssistantGenerating(awaitingApproval: Bool) -> Bool {
        awaitingApproval || hasVisibleGeneration
    }
}
