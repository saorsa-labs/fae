import SwiftUI

struct ThinkingCrawlView: View {
    let text: String
    @State private var offset: CGFloat = 0

    private let accent = Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 11, weight: .semibold))
                Text("THINKING")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.8)
                Spacer()
            }
            .foregroundStyle(accent.opacity(0.72))

            GeometryReader { _ in
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(accent.opacity(0.58))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: offset)
                    .onChange(of: text) {
                        // Let crawl continue while new text is appended.
                    }
                    .onAppear {
                        offset = 28
                        withAnimation(.linear(duration: 90).repeatForever(autoreverses: false)) {
                            offset = -2000
                        }
                    }
            }
            .frame(height: 108)
            .mask(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.2),
                        .init(color: .black, location: 0.82),
                        .init(color: .clear, location: 1),
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipped()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(accent.opacity(0.18), lineWidth: 1)
                )
        )
    }
}

struct ThinkIconBubble: View {
    let thinkTrace: String
    @State private var showTrace = false

    private let accent = Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255)

    var body: some View {
        Button {
            showTrace = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.system(size: 10, weight: .medium))
                Text("Reasoning")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(accent.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(accent.opacity(0.08)))
            .overlay(Capsule().stroke(accent.opacity(0.15), lineWidth: 1))
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
