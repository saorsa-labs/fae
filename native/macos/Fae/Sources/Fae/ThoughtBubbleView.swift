import SwiftUI

/// SwiftUI wrapper for the thought bubble in its own frameless window.
///
/// Reads `thinkingText` and `isThinking` from the injected `SubtitleStateController`
/// environment object so the hosted view updates reactively.
struct ThoughtBubbleWindowContent: View {
    @EnvironmentObject private var subtitles: SubtitleStateController

    var body: some View {
        ThoughtBubbleView(text: subtitles.thinkingText, isActive: subtitles.isThinking)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.bottom, 8)
            .padding(.trailing, 8)
    }
}

/// Comic-book thought bubble that floats in its own frameless window near the orb.
///
/// Shows streaming think text and tool activity in a cloud-shaped bubble with
/// trailing thought circles that point toward the orb (bottom-right).
struct ThoughtBubbleView: View {
    let text: String
    let isActive: Bool

    /// Indigo-ish accent for the thought bubble.
    private static let bubbleColor = Color(
        red: 140.0 / 255.0,
        green: 130.0 / 255.0,
        blue: 180.0 / 255.0
    )

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            // Main thought cloud
            thoughtCloud

            // Trailing thought circles — descend toward bottom-right (orb direction)
            HStack(spacing: 0) {
                Spacer()
                trailingCircles
                    .padding(.trailing, 20)
            }
        }
        .opacity(isActive ? 1.0 : 0.35)
        .animation(.easeInOut(duration: 0.8), value: isActive)
    }

    // MARK: - Thought Cloud

    private var thoughtCloud: some View {
        let displayText = cleanThinkText(text)

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(displayText)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .id("bottom")
            }
            .onChange(of: text) { _, _ in
                withAnimation(.easeOut(duration: 0.6)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: 270, maxHeight: 150)
        .background(
            ThoughtBubbleShape(cornerRadius: 20, tailSize: 0)
                .fill(Self.bubbleColor.opacity(0.10))
                .background(
                    ThoughtBubbleShape(cornerRadius: 20, tailSize: 0)
                        .fill(.ultraThinMaterial.opacity(0.6))
                )
        )
        .overlay(
            ThoughtBubbleShape(cornerRadius: 20, tailSize: 0)
                .stroke(Self.bubbleColor.opacity(0.3), lineWidth: 1)
        )
        .clipShape(ThoughtBubbleShape(cornerRadius: 20, tailSize: 0))
        .shadow(color: Self.bubbleColor.opacity(0.2), radius: 12, x: 0, y: 4)
    }

    // MARK: - Trailing Circles

    /// Three descending circles like a cartoon thought trail, pointing toward the orb.
    private var trailingCircles: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Self.bubbleColor.opacity(0.10))
                .overlay(Circle().stroke(Self.bubbleColor.opacity(0.15), lineWidth: 0.5))
                .frame(width: 12, height: 12)
                .shadow(color: Self.bubbleColor.opacity(0.1), radius: 3)

            Circle()
                .fill(Self.bubbleColor.opacity(0.08))
                .overlay(Circle().stroke(Self.bubbleColor.opacity(0.12), lineWidth: 0.5))
                .frame(width: 8, height: 8)
                .shadow(color: Self.bubbleColor.opacity(0.08), radius: 2)
                .offset(y: 4)

            Circle()
                .fill(Self.bubbleColor.opacity(0.06))
                .overlay(Circle().stroke(Self.bubbleColor.opacity(0.10), lineWidth: 0.5))
                .frame(width: 5, height: 5)
                .shadow(color: Self.bubbleColor.opacity(0.06), radius: 1)
                .offset(y: 8)
        }
    }

    // MARK: - Helpers

    /// Strip think tags and normalize whitespace for display.
    private func cleanThinkText(_ raw: String) -> String {
        var cleaned = raw
            .replacingOccurrences(of: "<think>", with: "")
            .replacingOccurrences(of: "</think>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.contains("\n\n\n") {
            cleaned = cleaned.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return cleaned
    }
}

// MARK: - Thought Bubble Shape

/// Rounded rectangle shape for the thought cloud.
struct ThoughtBubbleShape: Shape {
    let cornerRadius: CGFloat
    let tailSize: CGFloat

    func path(in rect: CGRect) -> Path {
        // Simple rounded rectangle — the "thought" feel comes from the
        // trailing circles rather than a pointed tail.
        Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
    }
}
