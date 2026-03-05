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
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
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
            ThoughtCloudShape()
                .fill(Self.bubbleColor.opacity(0.15))
                .background(
                    ThoughtCloudShape()
                        .fill(.ultraThinMaterial.opacity(0.65))
                )
        )
        .overlay(
            ThoughtCloudShape()
                .stroke(Self.bubbleColor.opacity(0.45), lineWidth: 1.5)
        )
        .clipShape(ThoughtCloudShape())
        .shadow(color: Self.bubbleColor.opacity(0.3), radius: 14, x: 0, y: 6)
    }

    // MARK: - Trailing Circles

    /// Three descending circles like a cartoon thought trail, pointing toward the orb.
    private var trailingCircles: some View {
        HStack(alignment: .bottom, spacing: 5) {
            Circle()
                .fill(Self.bubbleColor.opacity(0.30))
                .overlay(Circle().stroke(Self.bubbleColor.opacity(0.45), lineWidth: 1))
                .frame(width: 13, height: 13)
                .shadow(color: Self.bubbleColor.opacity(0.2), radius: 4)
                .scaleEffect(isActive ? 1.05 : 0.9)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: isActive)

            Circle()
                .fill(Self.bubbleColor.opacity(0.22))
                .overlay(Circle().stroke(Self.bubbleColor.opacity(0.35), lineWidth: 0.8))
                .frame(width: 9, height: 9)
                .shadow(color: Self.bubbleColor.opacity(0.15), radius: 3)
                .scaleEffect(isActive ? 1.05 : 0.9)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true).delay(0.2), value: isActive)
                .offset(y: 3)

            Circle()
                .fill(Self.bubbleColor.opacity(0.15))
                .overlay(Circle().stroke(Self.bubbleColor.opacity(0.25), lineWidth: 0.6))
                .frame(width: 6, height: 6)
                .shadow(color: Self.bubbleColor.opacity(0.1), radius: 2)
                .scaleEffect(isActive ? 1.05 : 0.9)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true).delay(0.4), value: isActive)
                .offset(y: 6)
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

// MARK: - Thought Cloud Shape

/// Comic-book cloud shape: convex bumps along every edge like a cartoon thought bubble.
///
/// Each edge is divided into equal-width arcs that protrude outward, creating the
/// classic bumpy cloud silhouette. Adjacent arcs share tangent endpoints so the
/// path is continuous with no gaps or connector lines on each individual edge.
/// Small implicit line segments appear only at the four corners between edges,
/// which is imperceptible at normal sizes.
struct ThoughtCloudShape: Shape {
    /// Radius of each individual bump arc. Smaller values → more, tighter bumps.
    var bumpRadius: CGFloat = 15

    func path(in rect: CGRect) -> Path {
        let r = bumpRadius

        // Compute the number of bumps per edge so each arc exactly fills its slot
        // (arc diameter = step width/height, ensuring tangent joins between bumps).
        let nTop = max(3, Int((rect.width / (r * 2)).rounded()))
        let nBottom = max(3, nTop - 1)  // slightly different count breaks the uniform grid
        let nSide = max(2, Int((rect.height / (r * 2)).rounded()))

        let hStep = rect.width / CGFloat(nTop)
        let bStep = rect.width / CGFloat(nBottom)
        let vStep = rect.height / CGFloat(nSide)

        var path = Path()

        // Clockwise in SwiftUI (y-down): bumps go outward on each edge.

        // Top edge → left to right, bumps protrude upward (toward minY).
        path.move(to: CGPoint(x: rect.minX + hStep * 0.5 - r, y: rect.minY + r))
        for i in 0..<nTop {
            path.addArc(
                center: CGPoint(x: rect.minX + hStep * (CGFloat(i) + 0.5), y: rect.minY + r),
                radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        }

        // Right edge ↓, bumps protrude rightward (toward maxX).
        for i in 0..<nSide {
            path.addArc(
                center: CGPoint(x: rect.maxX - r, y: rect.minY + vStep * (CGFloat(i) + 0.5)),
                radius: r, startAngle: .degrees(270), endAngle: .degrees(90), clockwise: true)
        }

        // Bottom edge ← right to left, bumps protrude downward (toward maxY).
        for i in 0..<nBottom {
            path.addArc(
                center: CGPoint(x: rect.maxX - bStep * (CGFloat(i) + 0.5), y: rect.maxY - r),
                radius: r, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
        }

        // Left edge ↑ bottom to top, bumps protrude leftward (toward minX).
        for i in 0..<nSide {
            path.addArc(
                center: CGPoint(x: rect.minX + r, y: rect.maxY - vStep * (CGFloat(i) + 0.5)),
                radius: r, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: true)
        }

        path.closeSubpath()
        return path
    }
}
