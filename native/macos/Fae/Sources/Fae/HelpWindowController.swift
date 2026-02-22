import AppKit
import SwiftUI
import WebKit

/// Manages a lightweight help window that displays HTML content from the
/// resource bundle using a WKWebView.
@MainActor
final class HelpWindowController {

    private var window: NSWindow?

    /// Show a help page by name (e.g. "getting-started"). Looks for
    /// `Help/{name}.html` in the Fae resource bundle.
    func showPage(_ name: String) {
        let webView = WKWebView(frame: .zero)
        webView.setValue(false, forKey: "drawsBackground")

        if let url = Bundle.faeResources.url(forResource: name, withExtension: "html", subdirectory: "Help") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            let fallbackHTML = """
            <html><body style="background:#1a1a2e;color:#ccc;font-family:system-ui;padding:40px;">
            <h1>Page Not Found</h1>
            <p>The help page "\(name)" could not be loaded.</p>
            </body></html>
            """
            webView.loadHTMLString(fallbackHTML, baseURL: nil)
        }

        let title: String
        switch name {
        case "getting-started": title = "Getting Started"
        case "shortcuts": title = "Keyboard Shortcuts"
        case "privacy": title = "Privacy & Security"
        default: title = "Fae Help"
        }

        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.contentView = webView
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        window = panel
    }
}
