import SwiftUI
import WebKit

struct ConversationWebView: NSViewRepresentable {
    var mode: OrbMode
    var palette: OrbPalette
    var feeling: OrbFeeling
    var isListening: Bool
    var windowMode: String
    var panelSide: String
    var onLoad: (() -> Void)?
    var onUserMessage: ((String) -> Void)?
    var onToggleListening: (() -> Void)?
    var onLinkDetected: ((String) -> Void)?
    var onPanelOpened: ((String) -> Void)?
    var onPanelClosed: ((String) -> Void)?
    var onUserInteraction: (() -> Void)?
    var onOrbClicked: (() -> Void)?
    /// Monotonic counter — when it changes, all `.slide-panel` elements have
    /// their `.open` class removed so panels don't reappear after collapse.
    var panelCloseGeneration: Int = 0

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loaded = false
        var lastMode: OrbMode?
        var lastPalette: OrbPalette?
        var lastFeeling: OrbFeeling?
        var lastListening: Bool?
        var lastWindowMode: String?
        var lastPanelSide: String?
        var onLoad: (() -> Void)?
        var onUserMessage: ((String) -> Void)?
        var onToggleListening: (() -> Void)?
        var onLinkDetected: ((String) -> Void)?
        var onPanelOpened: ((String) -> Void)?
        var onPanelClosed: ((String) -> Void)?
        var onUserInteraction: (() -> Void)?
        var onOrbClicked: (() -> Void)?
        var lastPanelCloseGeneration: Int = 0

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            _ = webView
            _ = navigation
            loaded = true
            onLoad?()
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
            case "panelOpened":
                guard let body = message.body as? [String: Any],
                      let panel = body["panel"] as? String
                else { return }
                onPanelOpened?(panel)
            case "panelClosed":
                guard let body = message.body as? [String: Any],
                      let panel = body["panel"] as? String
                else { return }
                onPanelClosed?(panel)
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
        coordinator.onUserMessage = onUserMessage
        coordinator.onToggleListening = onToggleListening
        coordinator.onLinkDetected = onLinkDetected
        coordinator.onPanelOpened = onPanelOpened
        coordinator.onPanelClosed = onPanelClosed
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
            "panelOpened", "panelClosed", "userInteraction", "orbClicked"
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
        context.coordinator.onUserMessage = onUserMessage
        context.coordinator.onToggleListening = onToggleListening
        context.coordinator.onLinkDetected = onLinkDetected
        context.coordinator.onPanelOpened = onPanelOpened
        context.coordinator.onPanelClosed = onPanelClosed
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

        if context.coordinator.lastPanelSide != panelSide {
            context.coordinator.lastPanelSide = panelSide
            jsStatements.append("window.setPanelSide && window.setPanelSide('\(panelSide)');")
        }

        if context.coordinator.lastPanelCloseGeneration != panelCloseGeneration {
            context.coordinator.lastPanelCloseGeneration = panelCloseGeneration
            jsStatements.append("document.querySelectorAll('.slide-panel').forEach(function(p){p.classList.remove('open')});")
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
