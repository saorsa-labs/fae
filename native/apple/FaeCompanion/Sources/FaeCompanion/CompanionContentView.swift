import SwiftUI
import FaeOrbKit
import FaeRelayKit

/// Main companion view layout:
///
/// ```
/// ┌─────────────────────────┐
/// │      Connection bar     │
/// ├─────────────────────────┤
/// │                         │
/// │     CompanionOrbView    │
/// │      (centered)         │
/// │                         │
/// ├─────────────────────────┤
/// │   Conversation turns    │
/// ├─────────────────────────┤
/// │  ◉ Tap to talk          │
/// └─────────────────────────┘
/// ```
struct CompanionContentView: View {
    @ObservedObject var relay: FaeRelayClient
    @ObservedObject var orbAnimation: OrbAnimationState
    @ObservedObject var conversationStore: ConversationStore

    @State private var showConversation = false

    var body: some View {
        ZStack {
            // Black background
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Connection bar
                connectionBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Spacer()

                // Orb
                CompanionOrbView(
                    orbAnimation: orbAnimation,
                    audioRMS: Double(relay.audioRMS),
                    onOrbTapped: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showConversation.toggle()
                        }
                    }
                )
                .frame(width: orbSize, height: orbSize)
                .padding(.bottom, 20)

                Spacer()

                // Conversation overlay (shown on tap)
                if showConversation {
                    conversationPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Tap to talk / Go home bar
                bottomBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Connection Bar

    private var connectionBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)

            Text(connectionText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if relay.connectionState == .connected {
                Button("Go Home") {
                    relay.goHome()
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var connectionColor: Color {
        switch relay.connectionState {
        case .connected: return .green
        case .connecting: return .yellow
        case .searching: return .orange
        case .disconnected: return .red
        }
    }

    private var connectionText: String {
        switch relay.connectionState {
        case .connected:
            return "Connected to \(relay.macDisplayName ?? "Mac")"
        case .connecting:
            return "Connecting..."
        case .searching:
            return "Searching for Fae..."
        case .disconnected:
            return "Disconnected"
        }
    }

    // MARK: - Conversation Panel

    private var conversationPanel: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(conversationStore.turns) { turn in
                        ConversationBubble(turn: turn)
                            .id(turn.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 200)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 16)
            .onChange(of: conversationStore.turns.count) { _, _ in
                if let last = conversationStore.turns.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            // Tap to talk button
            Button {
                if relay.connectionState == .connected {
                    // Toggle listening mode on Mac
                    relay.sendCommand("conversation.inject_text", payload: [:])
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.title3)
                    Text("Tap to Talk")
                        .font(.callout.weight(.medium))
                }
                .foregroundStyle(relay.connectionState == .connected ? .white : .gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    relay.connectionState == .connected
                        ? Color.orange.opacity(0.3)
                        : Color.gray.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 14)
                )
            }
            .disabled(relay.connectionState != .connected)

            // Reconnect button (when disconnected)
            if relay.connectionState == .disconnected {
                Button {
                    relay.startSearching()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.title3)
                        .foregroundStyle(.orange)
                        .frame(width: 50, height: 50)
                        .background(Color.orange.opacity(0.15), in: Circle())
                }
            }
        }
    }

    // MARK: - Layout

    private var orbSize: CGFloat {
        // Adaptive: larger on iPad
        let screenWidth = UIScreen.main.bounds.width
        if screenWidth > 600 {
            return 280  // iPad
        } else {
            return 200  // iPhone
        }
    }
}

// MARK: - Conversation Bubble

private struct ConversationBubble: View {
    let turn: ConversationTurn

    var body: some View {
        HStack {
            if turn.role == "user" { Spacer(minLength: 40) }

            Text(turn.content)
                .font(.callout)
                .foregroundStyle(turn.role == "assistant" ? .white : .white.opacity(0.9))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    turn.role == "assistant"
                        ? Color.white.opacity(0.1)
                        : Color.orange.opacity(0.2),
                    in: RoundedRectangle(cornerRadius: 12)
                )

            if turn.role == "assistant" { Spacer(minLength: 40) }
        }
    }
}
