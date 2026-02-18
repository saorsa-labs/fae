import SwiftUI
import WebKit

/// A SwiftUI view that hosts the onboarding HTML/JS screens.
///
/// `OnboardingWebView` loads `Resources/Onboarding/onboarding.html` into a
/// `WKWebView` and bridges JS message handlers to the `OnboardingController`.
/// It also exposes a JS API so the controller can push permission state and the
/// personalised user name back to the web layer.
struct OnboardingWebView: NSViewRepresentable {

    /// Fired when the web layer reports that it is ready.
    var onLoad: (() -> Void)?

    /// Fired when the user requests a native permission dialog.
    /// Argument: permission name ("microphone" | "contacts")
    var onRequestPermission: ((String) -> Void)?

    /// Fired when the user taps a help "?" button on a permission card.
    var onPermissionHelp: ((String) -> Void)?

    /// Fired when the user taps the final CTA on the Ready screen.
    var onComplete: (() -> Void)?

    /// Fired when the JS layer advances to the next onboarding phase.
    var onAdvance: (() -> Void)?

    /// User's first name to push into the Ready screen greeting (nil = not yet known).
    var userName: String?

    /// Permission states to push into the permission cards as they are resolved.
    /// Format: `["microphone": "granted", "contacts": "denied"]`
    var permissionStates: [String: String] = [:]

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loaded = false
        weak var webView: WKWebView?

        var onLoad: (() -> Void)?
        var onRequestPermission: ((String) -> Void)?
        var onPermissionHelp: ((String) -> Void)?
        var onComplete: (() -> Void)?
        var onAdvance: (() -> Void)?

        /// Tracks the last pushed user name to avoid redundant JS calls.
        var lastUserName: String?
        /// Tracks the last pushed permission states to avoid redundant JS calls.
        var lastPermissionStates: [String: String] = [:]

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            _ = navigation
            self.webView = webView
            loaded = true
            onLoad?()
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            _ = userContentController

            switch message.name {
            case "ready":
                break

            case "onboardingAdvance":
                onAdvance?()

            case "onboardingComplete":
                onComplete?()

            case "requestPermission":
                guard let body = message.body as? [String: Any],
                      let permission = body["permission"] as? String,
                      !permission.isEmpty
                else { return }
                onRequestPermission?(permission)

            case "permissionHelp":
                guard let body = message.body as? [String: Any],
                      let permission = body["permission"] as? String
                else { return }
                onPermissionHelp?(permission)

            case "onboardingPhaseChanged":
                // Phase transitions are handled by the JS state machine;
                // Swift receives this as an informational event.
                break

            default:
                break
            }
        }

        // MARK: - JS → Swift Push APIs

        /// Push a permission state update into the web layer.
        func setPermissionState(_ permission: String, state: String) {
            guard loaded, let webView else { return }
            let safe = permission.replacingOccurrences(of: "'", with: "\\'")
            let safeSt = state.replacingOccurrences(of: "'", with: "\\'")
            let js = "window.setPermissionState && window.setPermissionState('\(safe)', '\(safeSt)');"
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    NSLog("OnboardingWebView setPermissionState failed: %@", error.localizedDescription)
                }
            }
        }

        /// Push the user's first name into the web layer (personalises the Ready screen).
        func setUserName(_ name: String) {
            guard loaded, let webView else { return }
            let safe = name.replacingOccurrences(of: "'", with: "\\'")
            let js = "window.setUserName && window.setUserName('\(safe)');"
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    NSLog("OnboardingWebView setUserName failed: %@", error.localizedDescription)
                }
            }
        }
    }

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.onLoad = onLoad
        coordinator.onRequestPermission = onRequestPermission
        coordinator.onPermissionHelp = onPermissionHelp
        coordinator.onComplete = onComplete
        coordinator.onAdvance = onAdvance
        return coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let contentController = configuration.userContentController
        let handlers = [
            "ready",
            "onboardingAdvance",
            "onboardingComplete",
            "requestPermission",
            "permissionHelp",
            "onboardingPhaseChanged"
        ]
        for handler in handlers {
            contentController.add(context.coordinator, name: handler)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // KNOWN: drawsBackground is private KVC; no public API exists for
        // transparent WKWebView backgrounds on macOS. Tracked for future
        // replacement if Apple adds a public alternative.
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        loadOnboardingHTML(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onLoad = onLoad
        coordinator.onRequestPermission = onRequestPermission
        coordinator.onPermissionHelp = onPermissionHelp
        coordinator.onComplete = onComplete
        coordinator.onAdvance = onAdvance

        // Push user name when it becomes available for the first time.
        if let name = userName, name != coordinator.lastUserName {
            coordinator.lastUserName = name
            coordinator.setUserName(name)
        }

        // Push any changed permission states.
        for (permission, state) in permissionStates
        where coordinator.lastPermissionStates[permission] != state {
            coordinator.lastPermissionStates[permission] = state
            coordinator.setPermissionState(permission, state: state)
        }
    }

    // MARK: - HTML Loading

    private func loadOnboardingHTML(in webView: WKWebView) {
        guard let url = Bundle.faeResources.url(
            forResource: "onboarding",
            withExtension: "html"
        ) else {
            webView.loadHTMLString(
                "<html><body style='background:#0a0b0d;color:#eee;'>Onboarding resource missing.</body></html>",
                baseURL: nil
            )
            return
        }

        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}
