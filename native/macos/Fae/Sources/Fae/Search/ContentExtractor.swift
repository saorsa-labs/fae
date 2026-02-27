import Foundation

/// Extracts clean text content from HTML pages.
///
/// Strips boilerplate tags (script, style, nav, footer, header, aside, noscript, svg, iframe),
/// extracts main content from <article>, <main>, or <body> in priority order,
/// and normalizes whitespace.
enum ContentExtractor {
    /// Maximum output characters.
    static let maxChars = 100_000

    /// Extract clean text content from an HTML string.
    static func extract(html: String, url: String) -> PageContent {
        // Extract title from <title> tag.
        let title = extractTagContent(from: html, tag: "title")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Strip boilerplate tags and their contents.
        var cleaned = html
        let boilerplateTags = ["script", "style", "nav", "footer", "header", "aside", "noscript", "svg", "iframe"]
        for tag in boilerplateTags {
            cleaned = stripTag(from: cleaned, tag: tag)
        }

        // Try main content selectors in priority order.
        let text: String
        if let article = extractTagContent(from: cleaned, tag: "article") {
            text = stripAllHTMLTags(article)
        } else if let main = extractTagContent(from: cleaned, tag: "main") {
            text = stripAllHTMLTags(main)
        } else if let body = extractTagContent(from: cleaned, tag: "body") {
            text = stripAllHTMLTags(body)
        } else {
            text = stripAllHTMLTags(cleaned)
        }

        // Normalize whitespace.
        var normalized = normalizeWhitespace(text)

        // Truncate if needed.
        if normalized.count > maxChars {
            let endIndex = normalized.index(normalized.startIndex, offsetBy: maxChars)
            normalized = String(normalized[..<endIndex]) + "\n\n[Content truncated]"
        }

        let wordCount = normalized.split(whereSeparator: { $0.isWhitespace }).count

        return PageContent(url: url, title: title, text: normalized, wordCount: wordCount)
    }

    /// Remove a specific HTML tag and all its contents.
    static func stripTag(from html: String, tag: String) -> String {
        // Handle both <tag ...>...</tag> and self-closing <tag ... />
        let pattern = "(?s)<\(tag)[^>]*>.*?</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return html
        }
        return regex.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "")
    }

    /// Extract content between opening and closing tags of a specific element.
    static func extractTagContent(from html: String, tag: String) -> String? {
        let pattern = "(?s)<\(tag)[^>]*>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html)
        else {
            return nil
        }
        return String(html[range])
    }

    /// Strip all HTML tags, leaving only text content.
    static func stripAllHTMLTags(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else {
            return html
        }
        var result = regex.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: " ")
        // Decode common HTML entities.
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        return result
    }

    /// Collapse multiple spaces to one, 3+ newlines to 2, trim lines.
    static func normalizeWhitespace(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        // Collapse horizontal whitespace within lines.
        lines = lines.map { line in
            line.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }

        // Collapse 3+ consecutive blank lines to 2.
        var result: [String] = []
        var blankCount = 0
        for line in lines {
            if line.isEmpty {
                blankCount += 1
                if blankCount <= 2 {
                    result.append(line)
                }
            } else {
                blankCount = 0
                result.append(line)
            }
        }

        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
