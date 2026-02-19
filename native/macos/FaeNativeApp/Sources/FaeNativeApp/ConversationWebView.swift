import SwiftUI
import WebKit

struct ConversationWebView: NSViewRepresentable {
    var mode: OrbMode
    var palette: OrbPalette
    var feeling: OrbFeeling
    var isListening: Bool
    var windowMode: String
    var onLoad: (() -> Void)?
    /// Called after the WebView finishes loading, providing the `WKWebView` instance
    /// so controllers (e.g. `ConversationBridgeController`) can inject JavaScript.
    var onWebViewReady: ((WKWebView) -> Void)?
    var onUserMessage: ((String) -> Void)?
    var onToggleListening: (() -> Void)?
    var onLinkDetected: ((String) -> Void)?
    var onOpenConversationWindow: (() -> Void)?
    var onOpenCanvasWindow: (() -> Void)?
    var onUserInteraction: (() -> Void)?
    var onOrbClicked: (() -> Void)?

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loaded = false
        var lastMode: OrbMode?
        var lastPalette: OrbPalette?
        var lastFeeling: OrbFeeling?
        var lastListening: Bool?
        var lastWindowMode: String?
        var onLoad: (() -> Void)?
        var onWebViewReady: ((WKWebView) -> Void)?
        var onUserMessage: ((String) -> Void)?
        var onToggleListening: (() -> Void)?
        var onLinkDetected: ((String) -> Void)?
        var onOpenConversationWindow: (() -> Void)?
        var onOpenCanvasWindow: (() -> Void)?
        var onUserInteraction: (() -> Void)?
        var onOrbClicked: (() -> Void)?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            _ = navigation
            loaded = true
            onLoad?()
            onWebViewReady?(webView)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            _ = userContentController

            switch message.name {
            case "sendMessage":
                guard let body = message.body as? [String: Any],
                      let text = body["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return }
                onUserMessage?(text)
            case "toggleListening":
                onToggleListening?()
            case "linkDetected":
                guard let body = message.body as? [String: Any],
                      let url = body["url"] as? String
                else { return }
                onLinkDetected?(url)
            case "openConversationWindow":
                onOpenConversationWindow?()
            case "openCanvasWindow":
                onOpenCanvasWindow?()
            case "userInteraction":
                onUserInteraction?()
            case "orbClicked":
                onOrbClicked?()
            case "ready":
                break
            default:
                break
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.onLoad = onLoad
        coordinator.onWebViewReady = onWebViewReady
        coordinator.onUserMessage = onUserMessage
        coordinator.onToggleListening = onToggleListening
        coordinator.onLinkDetected = onLinkDetected
        coordinator.onOpenConversationWindow = onOpenConversationWindow
        coordinator.onOpenCanvasWindow = onOpenCanvasWindow
        coordinator.onUserInteraction = onUserInteraction
        coordinator.onOrbClicked = onOrbClicked
        return coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let contentController = config.userContentController
        let handlers = [
            "sendMessage", "toggleListening", "linkDetected", "ready",
            "openConversationWindow", "openCanvasWindow", "userInteraction", "orbClicked"
        ]
        for handler in handlers {
            contentController.add(context.coordinator, name: handler)
        }

        // Inject transparent background CSS so native views behind the
        // WKWebView show through. The HTML content renders its own background.
        let transparentCSS = "html, body { background: transparent !important; }"
        let cssScript = WKUserScript(
            source: "const s=document.createElement('style');s.textContent=`\(transparentCSS)`;document.documentElement.appendChild(s);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(cssScript)

        let view = WKWebView(frame: .zero, configuration: config)
        view.underPageBackgroundColor = .clear
        view.navigationDelegate = context.coordinator
        loadConversationHTML(in: view)
        context.coordinator.lastMode = mode
        context.coordinator.lastPalette = palette
        context.coordinator.lastFeeling = feeling
        // NOTE: lastListening intentionally NOT pre-set here so the first
        // updateNSView after webView load pushes the correct initial state
        // to the JS layer via setListening().
        return view
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLoad = onLoad
        context.coordinator.onWebViewReady = onWebViewReady
        context.coordinator.onUserMessage = onUserMessage
        context.coordinator.onToggleListening = onToggleListening
        context.coordinator.onLinkDetected = onLinkDetected
        context.coordinator.onOpenConversationWindow = onOpenConversationWindow
        context.coordinator.onOpenCanvasWindow = onOpenCanvasWindow
        context.coordinator.onUserInteraction = onUserInteraction
        context.coordinator.onOrbClicked = onOrbClicked

        guard context.coordinator.loaded else { return }

        var jsStatements: [String] = []

        if context.coordinator.lastMode != mode {
            context.coordinator.lastMode = mode
            jsStatements.append("window.setOrbMode && window.setOrbMode('\(mode.rawValue)');")
        }

        if context.coordinator.lastPalette != palette {
            context.coordinator.lastPalette = palette
            jsStatements.append("window.setOrbPalette && window.setOrbPalette('\(palette.rawValue)');")
        }

        if context.coordinator.lastFeeling != feeling {
            context.coordinator.lastFeeling = feeling
            jsStatements.append("window.setOrbFeeling && window.setOrbFeeling('\(feeling.rawValue)');")
        }

        if context.coordinator.lastListening != isListening {
            context.coordinator.lastListening = isListening
            jsStatements.append("window.setListening && window.setListening(\(isListening));")
        }

        if context.coordinator.lastWindowMode != windowMode {
            context.coordinator.lastWindowMode = windowMode
            jsStatements.append("window.setWindowMode && window.setWindowMode('\(windowMode)');")
        }

        guard !jsStatements.isEmpty else { return }

        let js = jsStatements.joined(separator: "\n")
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                NSLog("ConversationWebView update failed: %@", error.localizedDescription)
            }
        }
    }

    private func loadConversationHTML(in webView: WKWebView) {
        guard let url = Bundle.faeResources.url(
            forResource: "conversation",
            withExtension: "html"
        ) else {
            webView.loadHTMLString(
                "<html><body style='background:#0a0b0d;color:#eee;'>Conversation resource missing.</body></html>",
                baseURL: nil
            )
            return
        }

        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}
