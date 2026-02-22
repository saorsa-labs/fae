import Foundation

/// Manages the transient subtitle overlay state displayed above the orb.
///
/// Subtitles appear as floating bubbles (user, assistant, tool) and auto-hide
/// after ``displayDuration`` seconds. Partial STT transcription uses a separate
/// faded italic style that persists until a final transcription replaces it.
///
/// Streaming assistant text accumulates sentence fragments at reduced opacity
/// until the final sentence arrives, at which point the full message is shown
/// at full opacity and the auto-hide timer starts.
@MainActor
final class SubtitleStateController: ObservableObject {

    // MARK: - Display Duration

    /// How long a finalized subtitle stays visible before fading out (seconds).
    static let displayDuration: TimeInterval = 5.0

    // MARK: - Published State

    /// The currently visible assistant subtitle text (empty = hidden).
    @Published var assistantText: String = ""

    /// Whether the assistant subtitle is in streaming mode (reduced opacity).
    @Published var isAssistantStreaming: Bool = false

    /// The currently visible user subtitle text (empty = hidden).
    @Published var userText: String = ""

    /// Whether the user subtitle is showing partial STT (italic + faded).
    @Published var isUserPartial: Bool = false

    /// The currently visible tool/status subtitle text (empty = hidden).
    @Published var toolText: String = ""

    /// Progress bar state: percentage (0–100), nil = hidden.
    @Published var progressPercent: Int?

    /// Progress bar label text.
    @Published var progressLabel: String = ""

    // MARK: - Private Timers

    private var assistantHideTask: Task<Void, Never>?
    private var userHideTask: Task<Void, Never>?
    private var toolHideTask: Task<Void, Never>?

    // MARK: - Subtitle Updates

    /// Show a partial STT transcription (faded italic, no auto-hide timer).
    func showPartialTranscription(_ text: String) {
        userHideTask?.cancel()
        userText = text
        isUserPartial = true
    }

    /// Show a finalized user message with auto-hide timer.
    func showUserMessage(_ text: String) {
        userHideTask?.cancel()
        userText = text
        isUserPartial = false
        userHideTask = Task {
            try? await Task.sleep(for: .seconds(Self.displayDuration))
            guard !Task.isCancelled else { return }
            userText = ""
        }
    }

    /// Append a streaming assistant sentence fragment (reduced opacity, no timer).
    func appendStreamingSentence(_ sentence: String) {
        assistantHideTask?.cancel()
        if assistantText.isEmpty {
            assistantText = sentence
        } else {
            assistantText += " " + sentence
        }
        isAssistantStreaming = true
    }

    /// Finalize the streaming assistant message (full opacity + auto-hide timer).
    func finalizeAssistantMessage(_ fullText: String) {
        assistantHideTask?.cancel()
        assistantText = fullText
        isAssistantStreaming = false
        assistantHideTask = Task {
            try? await Task.sleep(for: .seconds(Self.displayDuration))
            guard !Task.isCancelled else { return }
            assistantText = ""
        }
    }

    /// Show a non-streaming assistant message (for addMessage('assistant', ...)).
    func showAssistantMessage(_ text: String) {
        finalizeAssistantMessage(text)
    }

    /// Show a tool/status message with auto-hide timer.
    func showToolMessage(_ text: String) {
        toolHideTask?.cancel()
        toolText = text
        toolHideTask = Task {
            try? await Task.sleep(for: .seconds(Self.displayDuration))
            guard !Task.isCancelled else { return }
            toolText = ""
        }
    }

    /// Clear all subtitles immediately.
    func clearAll() {
        assistantHideTask?.cancel()
        userHideTask?.cancel()
        toolHideTask?.cancel()
        assistantText = ""
        userText = ""
        toolText = ""
        isAssistantStreaming = false
        isUserPartial = false
    }

    // MARK: - Progress Bar

    /// Show the progress bar with label and percentage.
    func showProgress(label: String, percent: Int) {
        progressLabel = label
        progressPercent = min(100, max(0, percent))
    }

    /// Hide the progress bar.
    func hideProgress() {
        // Delay slightly so the bar visually reaches 100% before vanishing.
        Task {
            progressPercent = 100
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            progressPercent = nil
            progressLabel = ""
        }
    }
}
