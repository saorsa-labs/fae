import SwiftUI

/// Scrolling conversation area for Zone 2 of the main window.
///
/// Displays chat messages from `ConversationController` with inline tool
/// activity cards from `CanvasController`. Auto-scrolls to the latest content.
struct ConversationScrollView: View {
    @EnvironmentObject private var conversation: ConversationController
    @EnvironmentObject private var canvas: CanvasController

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(conversation.messages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }

                    // Inline tool activity cards (from canvas controller).
                    ForEach(canvas.activityCards) { card in
                        InlineToolCardView(card: card)
                            .id("tool-\(card.id)")
                    }

                    // Live streaming bubble — shows tokens as they arrive.
                    if conversation.isStreaming,
                       !conversation.streamingText.isEmpty
                    {
                        StreamingBubbleView(text: conversation.streamingText)
                            .id("streaming")
                    }

                    // Typing indicator — only when generating but no text yet.
                    if conversation.isGenerating,
                       !conversation.isStreaming
                    {
                        TypingIndicatorView()
                            .id("typing")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: conversation.messages.count) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: conversation.isGenerating) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: conversation.streamingText) {
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if conversation.isStreaming,
           !conversation.streamingText.isEmpty
        {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("streaming", anchor: .bottom)
            }
        } else if conversation.isGenerating {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("typing", anchor: .bottom)
            }
        } else if let last = conversation.messages.last {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

// MARK: - MessageBubbleView

struct MessageBubbleView: View {
    let message: ChatMessage

    /// Heather accent colour.
    private static let heather = Color(
        red: 180.0 / 255.0,
        green: 168.0 / 255.0,
        blue: 196.0 / 255.0
    )

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            Text(message.content)
                .font(.system(size: 13, weight: .regular, design: .serif))
                .lineSpacing(4)
                .foregroundStyle(textColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(borderColor, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))

            if message.role == .assistant || message.role == .tool { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var alignment: Alignment {
        switch message.role {
        case .user: return .trailing
        case .assistant: return .leading
        case .tool: return .center
        }
    }

    private var textColor: Color {
        switch message.role {
        case .user: return Color(white: 0.95)
        case .assistant: return Color(white: 0.92)
        case .tool: return Color.primary.opacity(0.55)
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user:
            return Color(red: 0.22, green: 0.28, blue: 0.42)
        case .assistant:
            return Color(red: 0.24, green: 0.20, blue: 0.30)
        case .tool:
            return Color.primary.opacity(0.05)
        }
    }

    private var borderColor: Color {
        switch message.role {
        case .user:
            return Color(red: 0.35, green: 0.45, blue: 0.65).opacity(0.5)
        case .assistant:
            return Self.heather.opacity(0.25)
        case .tool:
            return Color.primary.opacity(0.07)
        }
    }
}

// MARK: - StreamingBubbleView

struct StreamingBubbleView: View {
    let text: String
    @State private var cursorVisible: Bool = true

    /// Heather accent colour.
    private static let heather = Color(
        red: 180.0 / 255.0,
        green: 168.0 / 255.0,
        blue: 196.0 / 255.0
    )

    var body: some View {
        HStack {
            HStack(spacing: 0) {
                Text(text)
                    .font(.system(size: 13, weight: .regular, design: .serif))
                    .lineSpacing(4)
                    .foregroundStyle(Color(white: 0.92))
                    .animation(.easeOut(duration: 0.15), value: text)

                Rectangle()
                    .fill(Self.heather.opacity(cursorVisible ? 0.8 : 0))
                    .frame(width: 2, height: 13)
                    .padding(.leading, 1)
                    .animation(
                        .linear(duration: 0.5).repeatForever(autoreverses: true),
                        value: cursorVisible
                    )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(red: 0.24, green: 0.20, blue: 0.30))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Self.heather.opacity(0.25), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { cursorVisible = false }
    }
}

// MARK: - TypingIndicatorView

struct TypingIndicatorView: View {
    @State private var animating = false

    /// Heather accent colour.
    private static let heather = Color(
        red: 180.0 / 255.0,
        green: 168.0 / 255.0,
        blue: 196.0 / 255.0
    )

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Self.heather.opacity(0.65))
                    .frame(width: 6, height: 6)
                    .offset(y: animating ? -5 : 0)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Self.heather.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Self.heather.opacity(0.14), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { animating = true }
    }
}

// MARK: - InlineToolCardView

/// Compact inline tool activity card for the conversation scroll.
struct InlineToolCardView: View {
    let card: ActivityCard

    /// Heather accent colour.
    private static let heather = Color(
        red: 180.0 / 255.0,
        green: 168.0 / 255.0,
        blue: 196.0 / 255.0
    )

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(toolName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.65))
                if !card.detail.isEmpty {
                    Text(card.detail)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.primary.opacity(0.4))
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toolName: String {
        switch card.kind {
        case .toolCall(let name): return name
        case .toolResult(let name, _): return name
        case .thinking: return "thinking"
        case .webResult(let title, _, _): return title
        case .codeBlock(let language, _): return language
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch card.status {
        case .running:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
        case .done:
            Image(systemName: sfSymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.green.opacity(0.7))
                .frame(width: 16, height: 16)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.red.opacity(0.7))
                .frame(width: 16, height: 16)
        }
    }

    private var sfSymbol: String {
        switch card.kind {
        case .toolCall(let name), .toolResult(let name, _):
            switch name {
            case "web_search": return "magnifyingglass"
            case "fetch_url": return "globe"
            case "read": return "doc.text"
            case "write": return "square.and.pencil"
            case "edit": return "pencil"
            case "bash": return "terminal"
            case "calendar": return "calendar"
            case "contacts": return "person.2"
            case "reminders": return "checklist"
            case "mail": return "envelope"
            case "notes": return "note.text"
            case "screenshot", "read_screen": return "camera.viewfinder"
            case "camera": return "camera"
            case "click", "type_text": return "cursorarrow.click"
            case "voice_identity": return "waveform"
            default: return "checkmark.circle.fill"
            }
        case .thinking: return "brain"
        case .webResult: return "globe"
        case .codeBlock: return "chevron.left.forwardslash.chevron.right"
        }
    }
}
