import SwiftUI
import WebKit

enum OrbMode: String, CaseIterable, Identifiable {
    case idle
    case listening
    case thinking
    case speaking

    var id: String { rawValue }

    var label: String {
        switch self {
        case .idle:
            return "Idle"
        case .listening:
            return "Listening"
        case .thinking:
            return "Thinking"
        case .speaking:
            return "Speaking"
        }
    }

    static func commandOverride(in text: String) -> OrbMode? {
        let normalized = text.lowercased()
        if normalized.contains("orb mode idle") || normalized.contains("set orb idle") {
            return .idle
        }
        if normalized.contains("orb mode listening")
            || normalized.contains("set orb listening")
            || normalized.contains("set listening mode")
        {
            return .listening
        }
        if normalized.contains("orb mode thinking")
            || normalized.contains("set orb thinking")
            || normalized.contains("set thinking mode")
        {
            return .thinking
        }
        if normalized.contains("orb mode speaking")
            || normalized.contains("set orb speaking")
            || normalized.contains("set speaking mode")
        {
            return .speaking
        }
        return nil
    }
}

enum OrbFeeling: String, CaseIterable, Identifiable {
    case neutral
    case calm
    case curiosity
    case warmth
    case concern
    case delight
    case focus
    case playful

    var id: String { rawValue }

    var label: String {
        switch self {
        case .neutral: return "Neutral"
        case .calm: return "Calm"
        case .curiosity: return "Curiosity"
        case .warmth: return "Warmth"
        case .concern: return "Concern"
        case .delight: return "Delight"
        case .focus: return "Focus"
        case .playful: return "Playful"
        }
    }

    static func commandOverride(in text: String) -> OrbFeeling? {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        if normalized.contains("set feeling neutral")
            || normalized.contains("feel neutral")
        {
            return .neutral
        }
        if normalized.contains("set feeling calm")
            || normalized.contains("feel calm")
        {
            return .calm
        }
        if normalized.contains("set feeling curiosity")
            || normalized.contains("feel curious")
            || normalized.contains("feel curiosity")
        {
            return .curiosity
        }
        if normalized.contains("set feeling warmth")
            || normalized.contains("feel warm")
            || normalized.contains("feel warmth")
        {
            return .warmth
        }
        if normalized.contains("set feeling concern")
            || normalized.contains("feel concern")
            || normalized.contains("feel concerned")
        {
            return .concern
        }
        if normalized.contains("set feeling delight")
            || normalized.contains("feel delight")
            || normalized.contains("feel delighted")
        {
            return .delight
        }
        if normalized.contains("set feeling focus")
            || normalized.contains("feel focused")
            || normalized.contains("feel focus")
        {
            return .focus
        }
        if normalized.contains("set feeling playful")
            || normalized.contains("feel playful")
        {
            return .playful
        }
        return nil
    }
}

enum OrbPalette: String, CaseIterable, Identifiable {
    case modeDefault = "mode-default"
    case heatherMist = "heather-mist"
    case glenGreen = "glen-green"
    case lochGreyGreen = "loch-grey-green"
    case autumnBracken = "autumn-bracken"
    case silverMist = "silver-mist"
    case rowanBerry = "rowan-berry"
    case mossStone = "moss-stone"
    case dawnLight = "dawn-light"
    case peatEarth = "peat-earth"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .modeDefault:
            return "Mode Default"
        case .heatherMist:
            return "Heather Mist"
        case .glenGreen:
            return "Glen Green"
        case .lochGreyGreen:
            return "Loch Grey-Green"
        case .autumnBracken:
            return "Autumn Bracken"
        case .silverMist:
            return "Silver Mist"
        case .rowanBerry:
            return "Rowan Berry"
        case .mossStone:
            return "Moss Stone"
        case .dawnLight:
            return "Dawn Light"
        case .peatEarth:
            return "Peat Earth"
        }
    }

    static func commandOverride(in text: String) -> OrbPalette? {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        if normalized.contains("reset orb color")
            || normalized.contains("reset orb palette")
            || normalized.contains("use mode colors")
            || normalized.contains("mode default")
        {
            return .modeDefault
        }

        if normalized.contains("heather mist") { return .heatherMist }
        if normalized.contains("glen green") { return .glenGreen }
        if normalized.contains("loch grey green") || normalized.contains("loch green") {
            return .lochGreyGreen
        }
        if normalized.contains("autumn bracken") { return .autumnBracken }
        if normalized.contains("silver mist") { return .silverMist }
        if normalized.contains("rowan berry") { return .rowanBerry }
        if normalized.contains("moss stone") { return .mossStone }
        if normalized.contains("dawn light") { return .dawnLight }
        if normalized.contains("peat earth") { return .peatEarth }

        return nil
    }
}

struct OrbWebView: NSViewRepresentable {
    var mode: OrbMode
    var palette: OrbPalette
    var feeling: OrbFeeling
    var onLoad: (() -> Void)?

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded = false
        var lastMode: OrbMode?
        var lastPalette: OrbPalette?
        var lastFeeling: OrbFeeling?
        var onLoad: (() -> Void)?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            _ = webView
            _ = navigation
            onLoad?()
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.onLoad = onLoad
        return coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

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
        loadOrbHTML(in: view)
        context.coordinator.lastMode = mode
        context.coordinator.lastPalette = palette
        context.coordinator.lastFeeling = feeling
        return view
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLoad = onLoad

        if context.coordinator.lastMode == mode
            && context.coordinator.lastPalette == palette
            && context.coordinator.lastFeeling == feeling
        {
            return
        }
        context.coordinator.lastMode = mode
        context.coordinator.lastPalette = palette
        context.coordinator.lastFeeling = feeling
        let js = """
        window.setOrbMode && window.setOrbMode('\(mode.rawValue)');
        window.setOrbPalette && window.setOrbPalette('\(palette.rawValue)');
        window.setOrbFeeling && window.setOrbFeeling('\(feeling.rawValue)');
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                NSLog("Orb update failed: %@", error.localizedDescription)
            }
        }
    }

    private func loadOrbHTML(in webView: WKWebView) {
        guard let url = Bundle.faeResources.url(
            forResource: "index",
            withExtension: "html"
        ) else {
            webView.loadHTMLString("<html><body style='background:#0a0b0d;color:#eee;'>Orb resource missing.</body></html>", baseURL: nil)
            return
        }

        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}
