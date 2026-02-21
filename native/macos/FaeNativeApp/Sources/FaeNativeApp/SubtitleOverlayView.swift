import SwiftUI

/// Floating subtitle bubbles displayed above the orb.
///
/// Renders up to three subtitle lanes (assistant, user, tool) as glassmorphic
/// bubbles that fade in/out based on ``SubtitleStateController`` state. The
/// styling mirrors the `MessageBubble` pattern from `ConversationWindowView`.
struct SubtitleOverlayView: View {
    @EnvironmentObject private var subtitles: SubtitleStateController

    /// Heather accent colour used for assistant bubbles.
    private static let heather = Color(
        red: 180.0 / 255.0,
        green: 168.0 / 255.0,
        blue: 196.0 / 255.0
    )

    var body: some View {
        VStack(spacing: 8) {
            Spacer()

            // Tool / status message
            if !subtitles.toolText.isEmpty {
                subtitleBubble(
                    text: subtitles.toolText,
                    textColor: .white.opacity(0.6),
                    backgroundColor: .white.opacity(0.04),
                    borderColor: .white.opacity(0.07),
                    alignment: .center
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // Assistant message
            if !subtitles.assistantText.isEmpty {
                subtitleBubble(
                    text: subtitles.assistantText,
                    textColor: .white.opacity(0.92),
                    backgroundColor: Self.heather.opacity(0.1),
                    borderColor: Self.heather.opacity(0.18),
                    alignment: .leading
                )
                .opacity(subtitles.isAssistantStreaming ? 0.7 : 1.0)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // User message / partial STT
            if !subtitles.userText.isEmpty {
                subtitleBubble(
                    text: subtitles.userText,
                    textColor: .white.opacity(subtitles.isUserPartial ? 0.5 : 0.92),
                    backgroundColor: .white.opacity(subtitles.isUserPartial ? 0.04 : 0.1),
                    borderColor: .white.opacity(subtitles.isUserPartial ? 0.07 : 0.14),
                    alignment: .trailing,
                    isItalic: subtitles.isUserPartial
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.25), value: subtitles.assistantText)
        .animation(.easeInOut(duration: 0.25), value: subtitles.userText)
        .animation(.easeInOut(duration: 0.25), value: subtitles.toolText)
        .animation(.easeInOut(duration: 0.15), value: subtitles.isAssistantStreaming)
        .allowsHitTesting(false)
    }

    // MARK: - Bubble Component

    @ViewBuilder
    private func subtitleBubble(
        text: String,
        textColor: Color,
        backgroundColor: Color,
        borderColor: Color,
        alignment: HorizontalAlignment,
        isItalic: Bool = false
    ) -> some View {
        HStack {
            if alignment == .trailing || alignment == .center {
                Spacer(minLength: alignment == .center ? 0 : 40)
            }

            Text(text)
                .font(.system(size: 13, weight: .regular, design: .serif))
                .italic(isItalic)
                .foregroundColor(textColor)
                .lineSpacing(4)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(backgroundColor)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.ultraThinMaterial.opacity(0.3))
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(borderColor, lineWidth: 1)
                )

            if alignment == .leading || alignment == .center {
                Spacer(minLength: alignment == .center ? 0 : 40)
            }
        }
    }
}
