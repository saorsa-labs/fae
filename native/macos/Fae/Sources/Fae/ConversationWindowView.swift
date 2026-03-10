import SwiftUI

/// Native SwiftUI view for the conversation message history window.
///
/// Displays messages from `ConversationController.messages` as chat bubbles,
/// with auto-scroll and a typing indicator.
struct ConversationWindowView: View {
    @ObservedObject var conversationController: ConversationController
    var onClose: () -> Void

    @State private var bubblesOpacity: Double = 1.0

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            messageList
        }
        .background(Color(red: 0.06, green: 0.063, blue: 0.075))
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            Text("CONVERSATION")
                .font(.system(size: 11, weight: .medium, design: .default))
                .tracking(2)
                .foregroundStyle(.primary.opacity(0.45))

            if conversationController.isBackgroundLookupActive {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255).opacity(0.55))
                        .frame(width: 5, height: 5)
                    Text("background lookup")
                        .font(.system(size: 10, weight: .regular, design: .default))
                        .foregroundStyle(.primary.opacity(0.35))
                }
                .padding(.leading, 8)
                .transition(.opacity)
            }

            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.primary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Close conversation")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .animation(.easeInOut(duration: 0.2), value: conversationController.isBackgroundLookupActive)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(conversationController.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    .opacity(bubblesOpacity)
                    .animation(.easeInOut(duration: 0.3), value: bubblesOpacity)

                    // Thinking crawl — scrolling text during think phase
                    if conversationController.isGenerating
                        && !conversationController.isStreaming
                        && !conversationController.streamingThinkText.isEmpty
                    {
                        ThinkingCrawlView(text: conversationController.streamingThinkText)
                            .id("think-crawl")
                            .transition(.opacity)
                    }

                    // Completed think trace icon — shown when reasoning finished
                    if let trace = conversationController.completedThinkTrace,
                       !conversationController.isGenerating
                    {
                        ThinkIconBubble(thinkTrace: trace)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("think-icon")
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }

                    // Live streaming bubble — shows tokens as they arrive
                    if conversationController.isStreaming
                        && !conversationController.streamingText.isEmpty
                    {
                        StreamingBubble(text: conversationController.streamingText)
                            .id("streaming")
                    }

                    // Typing indicator — only when generating but no text yet
                    if conversationController.isGenerating
                        && !conversationController.isStreaming
                        && conversationController.streamingThinkText.isEmpty
                    {
                        TypingIndicator()
                            .id("typing")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .onChange(of: conversationController.messages.count) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: conversationController.isGenerating) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    bubblesOpacity = conversationController.isGenerating ? 0.35 : 1.0
                }
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: conversationController.streamingText) {
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }
            .onChange(of: conversationController.streamingThinkText) {
                proxy.scrollTo("think-crawl", anchor: .bottom)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if conversationController.isStreaming
            && !conversationController.streamingText.isEmpty
        {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("streaming", anchor: .bottom)
            }
        } else if conversationController.isGenerating {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("typing", anchor: .bottom)
            }
        } else if let last = conversationController.messages.last {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

// MARK: - MessageBubble

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        let rendered = (try? AttributedString(
            markdown: message.content,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(message.content)

        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            Text(rendered)
                .font(.system(size: 13, weight: .regular, design: .serif))
                .lineSpacing(4)
                .foregroundStyle(textColor)
                .textSelection(.enabled)
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
            // iMessage blue-grey — clearly the "sent" bubble
            return Color(red: 0.22, green: 0.28, blue: 0.42)
        case .assistant:
            // Fae's lavender-grey — distinct from user
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
            return Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255).opacity(0.25)
        case .tool:
            return Color.primary.opacity(0.07)
        }
    }
}

// MARK: - StreamingBubble

private struct StreamingBubble: View {
    let text: String
    @State private var cursorVisible: Bool = true

    var body: some View {
        HStack {
            HStack(spacing: 0) {
                Text(text)
                    .font(.system(size: 13, weight: .regular, design: .serif))
                    .lineSpacing(4)
                    .foregroundStyle(Color(white: 0.92))
                    .animation(.easeOut(duration: 0.15), value: text)

                // Blinking cursor
                Rectangle()
                    .fill(
                        Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255)
                            .opacity(cursorVisible ? 0.8 : 0)
                    )
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
                    .stroke(
                        Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255).opacity(0.25),
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { cursorVisible = false }
    }
}

// MARK: - TypingIndicator

private struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255).opacity(0.65))
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
        .background(Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255).opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255).opacity(0.14), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { animating = true }
    }
}

// MARK: - ThinkingCrawlView

struct ThinkingCrawlView: View {
    let text: String
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { _ in
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255).opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: offset)
                .onChange(of: text) {
                    // Let crawl continue — text grows naturally
                }
                .onAppear {
                    withAnimation(.linear(duration: 90).repeatForever(autoreverses: false)) {
                        offset = -2000
                    }
                }
        }
        .frame(height: 72)
        .mask(
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.3),
                    .init(color: .black, location: 1)
                ]),
                startPoint: .top, endPoint: .bottom
            )
        )
        .clipped()
        .padding(.horizontal, 14)
    }
}

// MARK: - ThinkIconBubble

struct ThinkIconBubble: View {
    let thinkTrace: String
    @State private var showTrace = false

    var body: some View {
        Button { showTrace = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.system(size: 10, weight: .medium))
                Text("Reasoning")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255).opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255).opacity(0.08)))
            .overlay(Capsule().stroke(Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255).opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showTrace) {
            ScrollView {
                Text(thinkTrace)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(width: 380, height: 300)
        }
    }
}
