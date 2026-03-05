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

    /// The currently visible thinking text (empty = hidden).
    @Published var thinkingText: String = ""

    /// Whether the LLM is actively in a thinking block.
    @Published var isThinking: Bool = false

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

    /// Show the most recent streaming assistant sentence fragment (reduced opacity, no timer).
    ///
    /// Replaces the previous fragment so the subtitle shows only the current sentence,
    /// preventing the bubble from growing to cover the orb.
    func appendStreamingSentence(_ sentence: String) {
        assistantHideTask?.cancel()
        assistantText = sentence
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

    /// Show a persistent tool/status message with no auto-hide timer.
    ///
    /// The caller is responsible for clearing it (e.g. via ``clearToolMessage()``).
    func showPersistentToolMessage(_ text: String) {
        toolHideTask?.cancel()
        toolHideTask = nil
        toolText = text
    }

    /// Clear the tool/status message immediately.
    func clearToolMessage() {
        toolHideTask?.cancel()
        toolHideTask = nil
        toolText = ""
    }

    /// Clear all subtitles immediately.
    func clearAll() {
        assistantHideTask?.cancel()
        userHideTask?.cancel()
        toolHideTask?.cancel()
        thinkHideTask?.cancel()
        assistantText = ""
        userText = ""
        toolText = ""
        thinkingText = ""
        isAssistantStreaming = false
        isUserPartial = false
        isThinking = false
    }

    // MARK: - Thinking Bubble

    private var thinkHideTask: Task<Void, Never>?

    /// Append streaming thinking text to the thought bubble.
    func appendThinkingText(_ text: String) {
        thinkHideTask?.cancel()
        isThinking = true
        thinkingText += text
        // Keep only the last ~400 characters for readability.
        if thinkingText.count > 400 {
            let start = thinkingText.index(thinkingText.endIndex, offsetBy: -350)
            thinkingText = "\u{2026}" + String(thinkingText[start...])
        }
    }

    /// Signal that thinking is complete — start fade-out timer.
    func finalizeThinking() {
        isThinking = false
        thinkHideTask?.cancel()
        thinkHideTask = Task {
            try? await Task.sleep(for: .seconds(4.0))
            guard !Task.isCancelled else { return }
            thinkingText = ""
        }
    }

    /// Append tool call activity to the thinking bubble so users see what Fae is doing.
    ///
    /// Resets the 10-second auto-vanish timer on each call so the bubble stays
    /// visible while tools are actively firing and disappears 10s after the last one.
    func appendToolActivity(_ text: String) {
        thinkHideTask?.cancel()
        isThinking = true
        if !thinkingText.isEmpty {
            thinkingText += "\n"
        }
        thinkingText += text
        // Keep only the last ~400 characters for readability.
        if thinkingText.count > 400 {
            let start = thinkingText.index(thinkingText.endIndex, offsetBy: -350)
            thinkingText = "\u{2026}" + String(thinkingText[start...])
        }
        // Auto-vanish 10s after the last tool event (debounced: each tool call resets the timer).
        thinkHideTask = Task {
            try? await Task.sleep(for: .seconds(10.0))
            guard !Task.isCancelled else { return }
            thinkingText = ""
            isThinking = false
        }
    }

    /// Clear thinking text immediately (e.g. on new turn).
    func clearThinking() {
        thinkHideTask?.cancel()
        thinkHideTask = nil
        thinkingText = ""
        isThinking = false
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
