import Combine
import SwiftUI

/// Native input bar with microphone toggle, text field, send button, and thinking pill.
///
/// Positioned at the bottom of the main window in the compact three-zone layout.
/// The text field grows upward within its container, pushing the conversation
/// scroll view up naturally — no window resizing needed.
struct InputBarView: View {
    @EnvironmentObject private var conversation: ConversationController
    @EnvironmentObject private var windowState: WindowStateController
    @EnvironmentObject private var faeCore: FaeCore

    @State private var messageText: String = ""
    @State private var isSendAnimating: Bool = false
    @FocusState private var isTextFieldFocused: Bool

    /// Heather accent colour.
    private static let heather = Color(
        red: 180.0 / 255.0,
        green: 168.0 / 255.0,
        blue: 196.0 / 255.0
    )

    var body: some View {
        VStack(spacing: 10) {
            // Input row: mic + textfield + send/stop
            HStack(spacing: 10) {
                micToggleButton
                messageField
                Group {
                    if conversation.isGenerating {
                        stopButton
                    } else {
                        sendButton
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: conversation.isGenerating)
            }

            // Action pills
            HStack(spacing: 8) {
                thinkingTogglePill
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial.opacity(0.6))
                .overlay(
                    Rectangle()
                        .fill(Color.white.opacity(0.04))
                )
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .faeWillFocusInputField)
        ) { _ in
            isTextFieldFocused = true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .faePrefillInput)
        ) { note in
            if let text = note.userInfo?["text"] as? String {
                messageText = text
            }
        }
    }

    // MARK: - Mic Toggle

    private var micToggleButton: some View {
        Button(action: {
            conversation.toggleListening()
            windowState.noteActivity()
        }) {
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(
                    conversation.isListening
                        ? Color.green
                        : Color.white.opacity(0.4)
                )
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(
                            conversation.isListening
                                ? Color.green.opacity(0.15)
                                : Color.white.opacity(0.06)
                        )
                )
                .overlay(
                    Circle()
                        .stroke(
                            conversation.isListening
                                ? Color.green.opacity(0.3)
                                : Color.white.opacity(0.1),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(conversation.isListening ? "Listening — tap to mute" : "Muted — tap to listen")
        .animation(.easeInOut(duration: 0.2), value: conversation.isListening)
    }

    // MARK: - Message Field

    private var messageField: some View {
        TextField("Message Fae...", text: $messageText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .regular, design: .serif))
            .foregroundColor(.white.opacity(0.92))
            .lineLimit(1...8)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .focused($isTextFieldFocused)
            .onSubmit {
                submitMessage()
            }
            .accessibilityLabel("Message input")
    }

    // MARK: - Send Button

    private var sendButton: some View {
        Button(action: {
            submitMessage()
        }) {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(
                    messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? Color.white.opacity(0.2)
                        : Self.heather
                )
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(
                            messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.white.opacity(0.04)
                                : Self.heather.opacity(0.15)
                        )
                )
                .overlay(
                    Circle()
                        .stroke(
                            messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.white.opacity(0.07)
                                : Self.heather.opacity(0.3),
                            lineWidth: 1
                        )
                )
                .scaleEffect(isSendAnimating ? 0.85 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .animation(.easeInOut(duration: 0.15), value: isSendAnimating)
        .accessibilityLabel("Send message")
    }

    // MARK: - Stop Button

    private var stopButton: some View {
        Button(action: {
            NotificationCenter.default.post(name: .faeCancelGeneration, object: nil)
            windowState.noteActivity()
        }) {
            Image(systemName: "stop.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Color.red.opacity(0.8))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color.red.opacity(0.1))
                )
                .overlay(
                    Circle()
                        .stroke(Color.red.opacity(0.25), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop generation")
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    // MARK: - Thinking Toggle Pill

    private var thinkingTogglePill: some View {
        Button(action: {
            faeCore.setThinkingEnabled(!faeCore.thinkingEnabled)
        }) {
            HStack(spacing: 5) {
                Circle()
                    .fill(faeCore.thinkingEnabled ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text("Thinking")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.45))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: faeCore.thinkingEnabled)
    }

    // MARK: - Submit

    private func submitMessage() {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        detectAndReportLinks(in: trimmed)

        conversation.handleUserSent(trimmed)
        windowState.noteActivity()

        // Animate send button
        isSendAnimating = true
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            isSendAnimating = false
        }

        messageText = ""
    }

    /// Detect URLs in the message and report them to the conversation controller.
    private func detectAndReportLinks(in text: String) {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        detector?.enumerateMatches(in: text, range: range) { result, _, _ in
            if let url = result?.url {
                conversation.handleLinkDetected(url.absoluteString)
            }
        }
    }
}
