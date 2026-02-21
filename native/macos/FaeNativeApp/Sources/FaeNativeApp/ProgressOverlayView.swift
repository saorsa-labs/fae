import SwiftUI

/// Native progress bar overlay for model download/load progress.
///
/// Renders a thin horizontal bar with a fill indicator and label text,
/// positioned at the top of the orb area. Driven by
/// ``SubtitleStateController/progressPercent`` and
/// ``SubtitleStateController/progressLabel``.
struct ProgressOverlayView: View {
    @EnvironmentObject private var subtitles: SubtitleStateController

    /// Heather accent for the progress fill.
    private static let heather = Color(
        red: 180.0 / 255.0,
        green: 168.0 / 255.0,
        blue: 196.0 / 255.0
    )

    var body: some View {
        VStack {
            if let percent = subtitles.progressPercent {
                VStack(spacing: 6) {
                    // Track + fill
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // Track background
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(0.08))

                            // Fill bar
                            RoundedRectangle(cornerRadius: 3)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Self.heather.opacity(0.6),
                                            Self.heather.opacity(0.4)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geometry.size.width * CGFloat(percent) / 100.0)
                        }
                    }
                    .frame(height: 6)
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                    // Label
                    if !subtitles.progressLabel.isEmpty {
                        Text(subtitles.progressLabel)
                            .font(.system(size: 11, weight: .medium, design: .default))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 16)
                .transition(.opacity)
            }

            Spacer()
        }
        .animation(.easeInOut(duration: 0.3), value: subtitles.progressPercent)
        .allowsHitTesting(false)
    }
}
