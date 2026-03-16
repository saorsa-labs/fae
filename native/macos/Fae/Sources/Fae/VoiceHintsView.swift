import SwiftUI

/// Collapsible cheat sheet showing how to wake and silence Fae.
/// Persists collapsed state so returning users aren't bothered.
struct VoiceHintsView: View {
    @AppStorage("voiceHintsCollapsed") private var isCollapsed: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header — always visible, tap to toggle.
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isCollapsed.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Voice commands")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 8) {
                    hintRow(
                        icon: "mic.fill",
                        color: .green,
                        label: "Wake",
                        phrases: "\"Hey Fae\" or \"Hi Fae\""
                    )
                    hintRow(
                        icon: "hand.raised.fill",
                        color: .orange,
                        label: "Silence",
                        phrases: "\"Stop\" \u{2022} \"Be quiet\" \u{2022} \"That\u{2019}s enough\""
                    )
                    hintRow(
                        icon: "moon.fill",
                        color: .indigo,
                        label: "Sleep",
                        phrases: "\"Go to sleep\" \u{2022} \"Goodbye Fae\""
                    )
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
        }
    }

    private func hintRow(icon: String, color: Color, label: String, phrases: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(color)
                .frame(width: 14)
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.7))
                .frame(width: 48, alignment: .leading)
            Text(phrases)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
