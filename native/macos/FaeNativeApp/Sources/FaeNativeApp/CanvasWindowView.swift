import SwiftUI
import WebKit

/// Native SwiftUI view for the canvas content window.
///
/// Renders HTML content from `CanvasController` using a minimal embedded
/// `WKWebView`. Falls back to a placeholder when content is empty.
struct CanvasWindowView: View {
    @ObservedObject var canvasController: CanvasController
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            contentArea
        }
        .background(Color(red: 0.06, green: 0.063, blue: 0.075))
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
            if canvasController.htmlContent.isEmpty {
                emptyPlaceholder
            } else {
                CanvasHTMLView(htmlContent: canvasController.htmlContent)
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

// MARK: - CanvasHTMLView

/// Minimal `WKWebView` wrapper for rendering canvas HTML content.
/// Read-only — no interaction handlers, just HTML rendering with dark theme.
struct CanvasHTMLView: NSViewRepresentable {
    var htmlContent: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false

        let view = WKWebView(frame: .zero, configuration: config)
        view.underPageBackgroundColor = .clear

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
