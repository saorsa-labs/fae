import Foundation

/// Consolidated TTS orchestration state for the voice pipeline.
///
/// Manages the chained TTS task (`pendingTTSTask`) and time-to-first-audio
/// (TTFA) telemetry. Extracted from PipelineCoordinator to reduce its state
/// variable count and group TTS-specific bookkeeping.
///
/// **Note**: `assistantSpeaking` and `lastAssistantStart` remain in the
/// coordinator because they serve as cross-cutting pipeline signals used by
/// barge-in, echo suppression, and gate logic — not just TTS.
final class TTSState {

    /// Chained TTS task — each sentence enqueues onto this so TTS runs in
    /// order without blocking the LLM token stream.
    var pendingTask: Task<Void, Never>?

    /// Timestamp captured when the user turn ended (post-VAD segment close).
    /// Used for TTFA (time-to-first-audio) telemetry.
    var lastUserTurnEndedAt: Date?

    /// Whether TTFA has been emitted for the current turn (prevents duplicates).
    var ttfaEmittedForCurrentTurn: Bool = false

    /// Maximum time a single TTS synthesis call can take before force-cancel.
    /// Prevents `assistantSpeaking` from getting stuck if the TTS model hangs.
    static let synthesisTimeoutSeconds: UInt64 = 30

    /// Cancel any pending TTS work and nil the task reference.
    func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
    }

    /// Wait for all pending TTS work to complete, then nil the reference.
    func awaitPending() async {
        await pendingTask?.value
        pendingTask = nil
    }

    /// Reset TTFA tracking for a new user turn.
    func resetForNewTurn() {
        ttfaEmittedForCurrentTurn = false
    }
}
