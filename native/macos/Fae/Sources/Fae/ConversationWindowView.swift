import SwiftUI

/// Native SwiftUI view for the conversation message history window.
///
/// Displays messages from `ConversationController.messages` as chat bubbles,
/// with auto-scroll and a typing indicator.
struct ConversationWindowView: View {
    @ObservedObject var conversationController: ConversationController
    var onClose: () -> Void

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
                .foregroundStyle(Color.white.opacity(0.45))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Close conversation")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.07))
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

                    if conversationController.isGenerating {
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
                if conversationController.isGenerating {
                    scrollToBottom(proxy: proxy)
                }
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if conversationController.isGenerating {
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
        case .tool: return Color.white.opacity(0.6)
        default: return Color.white.opacity(0.92)
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user:
            return Color.white.opacity(0.1)
        case .assistant:
            return Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255).opacity(0.1)
        case .tool:
            return Color.white.opacity(0.04)
        }
    }

    private var borderColor: Color {
        switch message.role {
        case .user:
            return Color.white.opacity(0.14)
        case .assistant:
            return Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255).opacity(0.18)
        case .tool:
            return Color.white.opacity(0.07)
        }
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
