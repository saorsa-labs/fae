import Foundation

/// Show rich content (charts, tables, documents, formatted reports, embedded
/// media) by rendering a self-contained HTML page in the user's *own* default
/// web browser. The orb + pill are Fae's only in-app UI, so anything richer
/// than conversational text is handed off to the browser rather than drawn in a
/// Fae panel.
///
/// The HTML is written to a uniquely-named file under the render cache and
/// opened with the OS default opener (`open` on macOS, `xdg-open` on Linux,
/// `start` on Windows). The tool itself makes no network calls; whatever the
/// page loads when the browser renders it is the page's own business.
struct ShowHtmlTool: Tool {
    let name = "show_html"
    let description = "Display rich content in the user's web browser. Provide a complete, self-contained HTML document in `html` (charts, tables, documents, formatted reports, embedded video — anything richer than plain text). It is written to a temp file and opened in a new browser tab. Prefer this over describing complex data in prose."
    let parametersSchema = #"{"html": "string (required: a complete self-contained HTML document)", "title": "string (optional: a short title used for the file name)"}"#
    let requiresApproval = false
    let riskLevel: ToolRiskLevel = .low
    let example = #"<tool_call>{"name":"show_html","arguments":{"html":"<!doctype html><html><body><h1>Weekly hours</h1><table><tr><td>Mon</td><td>6h</td></tr></table></body></html>","title":"Weekly hours"}}</tool_call>"#

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let html = input["html"] as? String,
              !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .error("Missing required parameter: html (a complete HTML document)")
        }
        let title = (input["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let fileURL = try Self.writeRenderFile(html: html, title: title)
            try Self.openInBrowser(fileURL)
            let label = (title?.isEmpty == false) ? "“\(title!)” " : ""
            return .success(
                "Opened \(label)in your browser.",
                structuredData: ["file": fileURL.path, "url": fileURL.absoluteString]
            )
        } catch {
            return .error("Failed to show HTML: \(error.localizedDescription)")
        }
    }

    // MARK: - Render file

    /// Write `html` to a uniquely-named file under `<cache>/render/` and return
    /// its URL. The directory is created on demand.
    static func writeRenderFile(html: String, title: String?) throws -> URL {
        let dir = FaeDirectories.cache.appendingPathComponent("render", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileName = "\(slug(title))-\(UUID().uuidString.prefix(8)).html"
        let url = dir.appendingPathComponent(fileName)
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A filesystem-safe slug from an optional title (defaults to "render").
    static func slug(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "render" }
        var out = ""
        for ch in title.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if let last = out.last, last != "-" {
                out.append("-")
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "render" : String(trimmed.prefix(40))
    }

    // MARK: - Browser open (portable)

    /// The OS command + arguments that open `url` in the default browser, per
    /// platform. Pure and side-effect-free so it can be unit-tested without
    /// actually launching anything.
    static func openCommand(for url: URL) -> (launchPath: String, arguments: [String]) {
        #if os(macOS)
        return ("/usr/bin/open", [url.path])
        #elseif os(Linux)
        return ("/usr/bin/env", ["xdg-open", url.path])
        #else
        return ("/usr/bin/env", ["xdg-open", url.path])
        #endif
    }

    /// Launch the OS opener for `url`. Does not wait for the browser.
    static func openInBrowser(_ url: URL) throws {
        let command = openCommand(for: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.launchPath)
        process.arguments = command.arguments
        try process.run()
    }
}
