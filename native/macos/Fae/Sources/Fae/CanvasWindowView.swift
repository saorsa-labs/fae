import SwiftUI
import WebKit

/// Native SwiftUI view for the canvas content window.
///
/// Shows either:
/// - Live activity feed (tool calls, results, web searches) as glassmorphic cards
/// - Static HTML content for legacy setContent() callers
struct CanvasWindowView: View {
    @ObservedObject var canvasController: CanvasController
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            contentArea
        }
        .background(Color.clear)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            Text("CANVAS")
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
            .help("Close canvas")
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

    // MARK: - Content

    private var contentArea: some View {
        Group {
            if canvasController.isActivityMode {
                activityFeed
            } else if canvasController.htmlContent.isEmpty {
                emptyPlaceholder
            } else {
                CanvasHTMLView(htmlContent: canvasController.htmlContent)
            }
        }
    }

    // MARK: - Activity Feed

    private var activityFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    // Archived turns (collapsed summaries)
                    ForEach(
                        Array(canvasController.archivedTurns.enumerated()),
                        id: \.offset
                    ) { idx, turn in
                        ArchivedTurnRow(cards: turn.cards, timestamp: turn.timestamp)
                            .id("archived-\(idx)")
                    }

                    // Divider between archived and current
                    if !canvasController.archivedTurns.isEmpty
                        && !canvasController.activityCards.isEmpty
                    {
                        HStack {
                            Rectangle()
                                .fill(Color.white.opacity(0.07))
                                .frame(height: 1)
                        }
                        .padding(.vertical, 4)
                    }

                    // Current turn cards
                    ForEach(canvasController.activityCards) { card in
                        ActivityCardView(card: card)
                            .id(card.id)
                            .transition(
                                .asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                    }

                    // Scroll anchor
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .animation(.easeOut(duration: 0.25), value: canvasController.activityCards.count)
            }
            .onChange(of: canvasController.activityCards.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 32))
                .foregroundStyle(Color.white.opacity(0.15))
            Text("No content")
                .font(.system(size: 13, design: .serif))
                .foregroundStyle(Color.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ActivityCardView

private struct ActivityCardView: View {
    let card: ActivityCard

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            statusIndicator
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .font(.system(size: 11))
                        .foregroundStyle(iconColor)
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                    Spacer()
                    Text(timeLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.3))
                }

                if !card.detail.isEmpty {
                    Text(card.detail)
                        .font(.system(size: 11, design: isCodeCard ? .monospaced : .default))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(4)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(cardOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(borderColor, lineWidth: 1)
                )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch card.status {
        case .running:
            ProgressView()
                .scaleEffect(0.6)
                .progressViewStyle(.circular)
                .tint(Color.white.opacity(0.5))
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.green.opacity(0.7))
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.red.opacity(0.7))
        }
    }

    private var title: String {
        switch card.kind {
        case .toolCall(let name):
            return name.replacingOccurrences(of: "_", with: " ").capitalized
        case .toolResult(let name, _):
            return name.replacingOccurrences(of: "_", with: " ").capitalized
        case .thinking:
            return "Thinking"
        case .webResult(let title, _, _):
            return title.isEmpty ? "Web result" : title
        case .codeBlock(let lang, _):
            return lang.isEmpty ? "Code" : lang.uppercased()
        }
    }

    private var iconName: String {
        switch card.kind {
        case .toolCall(let name):
            if name.contains("search") { return "magnifyingglass" }
            if name.contains("read") || name.contains("fetch") { return "doc.text" }
            if name.contains("write") || name.contains("edit") { return "pencil" }
            if name.contains("bash") { return "terminal" }
            if name.contains("calendar") { return "calendar" }
            if name.contains("mail") { return "envelope" }
            if name.contains("reminder") { return "checklist" }
            if name.contains("contact") { return "person.crop.circle" }
            if name.contains("note") { return "note.text" }
            if name.contains("scheduler") { return "clock" }
            if name.contains("roleplay") { return "theatermasks" }
            if name.contains("skill") { return "hammer" }
            return "gearshape"
        case .toolResult(_, let isError):
            return isError ? "xmark.circle" : "checkmark"
        case .thinking:
            return "brain"
        case .webResult:
            return "globe"
        case .codeBlock:
            return "chevron.left.forwardslash.chevron.right"
        }
    }

    private var iconColor: Color {
        switch card.kind {
        case .toolCall:
            return Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255).opacity(0.8)
        case .toolResult(_, let isError):
            return isError ? Color.red.opacity(0.7) : Color.green.opacity(0.7)
        case .thinking:
            return Color.yellow.opacity(0.6)
        case .webResult:
            return Color.blue.opacity(0.7)
        case .codeBlock:
            return Color.orange.opacity(0.7)
        }
    }

    private var cardOpacity: Double {
        switch card.status {
        case .running: return 0.08
        case .done: return 0.05
        case .error: return 0.06
        }
    }

    private var borderColor: Color {
        switch card.status {
        case .running:
            return Color(red: 180 / 255, green: 168 / 255, blue: 196 / 255).opacity(0.25)
        case .done:
            return Color.green.opacity(0.15)
        case .error:
            return Color.red.opacity(0.2)
        }
    }

    private var isCodeCard: Bool {
        if case .codeBlock = card.kind { return true }
        return false
    }

    private var timeLabel: String {
        Self.timeFormatter.string(from: card.timestamp)
    }
}

// MARK: - ArchivedTurnRow

private struct ArchivedTurnRow: View {
    let cards: [ActivityCard]
    let timestamp: Date

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.3))
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.4))
                    Spacer()
                    Text(timeLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.25))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(cards) { card in
                    ActivityCardView(card: card)
                }
            }
        }
    }

    private var summary: String {
        let toolNames = cards.compactMap { card -> String? in
            if case .toolCall(let name) = card.kind { return name }
            return nil
        }
        if toolNames.isEmpty { return "Turn" }
        let unique = NSOrderedSet(array: toolNames).array as? [String] ?? toolNames
        return unique.prefix(3).joined(separator: " \u{00B7} ")
    }

    private var timeLabel: String {
        Self.timeFormatter.string(from: timestamp)
    }
}

// MARK: - CanvasHTMLView

/// Minimal `WKWebView` wrapper for rendering canvas HTML content.
/// Read-only — no interaction handlers, just HTML rendering with dark theme.
struct CanvasHTMLView: NSViewRepresentable {
    var htmlContent: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let view = WKWebView(frame: .zero, configuration: config)
        view.underPageBackgroundColor = .clear
        // Make WebView fully transparent so glassmorphic panel background shows through
        view.setValue(false, forKey: "drawsBackground")

        loadHTML(in: view)
        return view
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        loadHTML(in: webView)
    }

    private func loadHTML(in webView: WKWebView) {
        let wrapped = """
            <!DOCTYPE html>
            <html><head>
            <meta charset="UTF-8">
            <style>
              * { margin: 0; padding: 0; box-sizing: border-box; }
              body {
                background: transparent;
                color: rgba(255,255,255,0.92);
                font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif;
                font-size: 13px;
                line-height: 1.6;
                padding: 16px;
              }
              a { color: #B4A8C4; text-decoration: underline; text-underline-offset: 2px; }
              img { max-width: 100%; border-radius: 8px; display: block; margin: 8px 0; }
              p { margin: 0 0 10px; }
              p:last-child { margin-bottom: 0; }
              h1, h2, h3 { margin: 12px 0 6px; color: rgba(255,255,255,0.92); font-weight: normal; }
              code {
                font-family: 'SF Mono', Monaco, monospace;
                font-size: 0.82em;
                background: rgba(255,255,255,0.07);
                border-radius: 4px;
                padding: 1px 5px;
              }
              pre {
                background: rgba(255,255,255,0.05);
                border: 1px solid rgba(255,255,255,0.08);
                border-radius: 8px;
                padding: 12px;
                overflow-x: auto;
                margin: 8px 0;
              }
              pre code { background: none; padding: 0; font-size: 0.8em; }
              ul, ol { padding-left: 18px; margin: 6px 0; }
              li { margin: 3px 0; }
            </style>
            </head><body>\(htmlContent)</body></html>
            """
        webView.loadHTMLString(wrapped, baseURL: nil)
    }
}
