import SwiftUI

/// SwiftUI wrapper for the thought bubble in its own frameless window.
///
/// Reads `thinkingText` and `isThinking` from the injected `SubtitleStateController`
/// environment object so the hosted view updates reactively.
struct ThoughtBubbleWindowContent: View {
    @EnvironmentObject private var subtitles: SubtitleStateController

    var body: some View {
        ThoughtBubbleView(
            text: subtitles.thinkingText,
            isActive: subtitles.isThinking,
            onClose: { subtitles.dismissThinkingUntilNextTurn() }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.bottom, 10)
        .padding(.trailing, 10)
    }
}

/// Comic-book thought bubble that floats near the orb.
///
/// The cloud body is an organic blob built from nine overlapping circles —
/// matching the classic thought-bubble silhouette in the reference image.
/// Three descending circles form the tail pointing toward the orb (bottom-right).
/// All circles pulse gently while Fae is actively thinking.
struct ThoughtBubbleView: View {
    let text: String
    let isActive: Bool
    var onClose: () -> Void = {}

    // Fixed cloud frame so the blob proportions are always correct.
    private let cloudWidth:  CGFloat = 240
    private let cloudHeight: CGFloat = 135

    /// Lavender-indigo accent used for glow and tint.
    private static let bubbleColor = Color(
        red: 140.0 / 255.0,
        green: 130.0 / 255.0,
        blue: 180.0 / 255.0
    )

    var body: some View {
        VStack(alignment: .trailing, spacing: -10) {
            cloudBody
            HStack(spacing: 0) {
                Spacer()
                tailCircles
                    .padding(.trailing, 30)
            }
        }
        .opacity(isActive ? 1.0 : 0.30)
        .animation(.easeInOut(duration: 0.8), value: isActive)
    }

    // MARK: - Cloud Body

    private var cloudBody: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(cleanThinkText(text))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.88))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Padding calibrated so all four text corners stay inside the blob.
                    // The side bulge lobes cover from y≈23 upward with 40 px horizontal margin.
                    .padding(.horizontal, 40)
                    .padding(.top, 28)
                    .padding(.bottom, 26)
                    .id("bottom")
            }
            .onChange(of: text) { _, _ in
                withAnimation(.easeOut(duration: 0.6)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .frame(width: cloudWidth, height: cloudHeight)
        .background {
            // Frosted glass base (matches canvas panel) + lavender tint overlay.
            ZStack {
                ThoughtCloudBlobShape()
                    .fill(.thinMaterial)
                ThoughtCloudBlobShape()
                    .fill(Self.bubbleColor.opacity(0.18))
            }
        }
        // Close button — positioned inside the large central lobe (not topTrailing which is outside the blob).
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .padding(.trailing, 48)
            .help("Hide thinking for this turn")
        }
        .clipShape(ThoughtCloudBlobShape())
        // Glow: lavender halo + dark drop shadow for depth
        .shadow(color: Self.bubbleColor.opacity(0.55), radius: 18, x: 0, y: 4)
        .shadow(color: .black.opacity(0.45), radius:  6, x: 0, y: 2)
    }

    // MARK: - Tail Circles

    /// Three descending circles — large → medium → small — pointing toward
    /// the orb (bottom-right), exactly like the classic comic-book thought tail.
    private var tailCircles: some View {
        ZStack(alignment: .topLeading) {
            tailDot(size: 28, delay: 0.00, x:  0, y:  0)
            tailDot(size: 17, delay: 0.22, x: 25, y: 20)
            tailDot(size: 10, delay: 0.44, x: 43, y: 36)
        }
        .frame(width: 58, height: 52)
    }

    @ViewBuilder
    private func tailDot(size: CGFloat, delay: Double, x: CGFloat, y: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(.thinMaterial)
            Circle()
                .fill(Self.bubbleColor.opacity(0.22))
        }
        .frame(width: size, height: size)
        .shadow(color: Self.bubbleColor.opacity(0.50), radius: size / 3)
        .shadow(color: .black.opacity(0.40), radius: size / 6)
        .scaleEffect(isActive ? 1.07 : 0.85)
        .animation(
            .easeInOut(duration: 1.15).repeatForever(autoreverses: true).delay(delay),
            value: isActive
        )
        .offset(x: x, y: y)
    }

    // MARK: - Helpers

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

// MARK: - ThoughtCloudBlobShape

/// Organic thought-bubble cloud with a text-safe interior.
///
/// Architecture: one large central body + two side bulges guarantee the text
/// area (40 px horizontal, 28 px top, 26 px bottom inset) is *always* inside
/// the filled region.  Four small top/bottom bumps add the cloud silhouette on
/// top of that solid core.
///
/// Verified geometry (240×135 frame, cx/cy as fractions of rect dims, r as
/// fraction of rect.width):
///   • Text corners (40,28) and (200,28) → inside side bulges (r≈44 px) ✓
///   • Text corners (40,109) and (200,109) → inside side bulges ✓
///   • Close button (≈182,22) → inside central lobe (r≈86 px) ✓
///
/// SwiftUI's nonzero winding-fill rule produces a solid union — no holes,
/// no internal artefacts, no stroked circle outlines.
struct ThoughtCloudBlobShape: Shape {

    private static let lobes: [(cx: CGFloat, cy: CGFloat, r: CGFloat)] = [
        // cx, cy as fraction of rect dims; r as fraction of rect.width
        (0.500, 0.480, 0.360),  // LARGE central body — guarantees text-area coverage
        (0.175, 0.500, 0.185),  // left side bulge  (reaches left edge)
        (0.825, 0.500, 0.185),  // right side bulge (reaches right edge)
        (0.370, 0.115, 0.130),  // top-left cloud bump  (reaches top edge)
        (0.630, 0.095, 0.115),  // top-right cloud bump (reaches top edge)
        (0.325, 0.870, 0.095),  // bottom-left cloud bump  (reaches bottom edge)
        (0.675, 0.855, 0.095),  // bottom-right cloud bump (reaches bottom edge)
    ]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for lobe in Self.lobes {
            let cx = rect.minX + lobe.cx * rect.width
            let cy = rect.minY + lobe.cy * rect.height
            let r  = lobe.r  * rect.width
            path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        }
        return path
    }
}
