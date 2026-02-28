import Foundation

/// DuckDuckGo HTML search engine.
///
/// POSTs to html.duckduckgo.com/html/ and parses result blocks.
/// Most reliable engine — no API key, no aggressive bot detection.
struct DuckDuckGoEngine: SearchEngineProtocol {
    let engineType: SearchEngine = .duckDuckGo

    func search(query: String, config: SearchConfig) async throws -> [SearchResult] {
        guard let url = URL(string: "https://html.duckduckgo.com/html/") else {
            throw SearchError.http("Invalid DuckDuckGo URL")
        }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let safeParam = config.safeSearch ? "1" : "-2"
        let body = "q=\(encoded)&kp=\(safeParam)"

        let request = SearchHTTPClient.postRequest(url: url, body: body, config: config)
        let session = URLSession(configuration: SearchHTTPClient.sessionConfiguration(config: config))
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw SearchError.http("DuckDuckGo returned non-200 status")
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw SearchError.parse("DuckDuckGo response not valid UTF-8")
        }

        return parseDDGResults(html: html, maxResults: config.maxResults)
    }

    /// Parse search results from DuckDuckGo HTML response.
    func parseDDGResults(html: String, maxResults: Int) -> [SearchResult] {
        var results: [SearchResult] = []

        // Split on result blocks. DDG uses <div class="result results_links results_links_deep">
        // or <div class="result results_links"> for each result.
        let resultPattern = "(?s)<div[^>]*class=\"[^\"]*result[^\"]*results_links[^\"]*\"[^>]*>(.*?)</div>\\s*(?=<div[^>]*class=\"[^\"]*result|$)"
        guard let resultRegex = try? NSRegularExpression(pattern: resultPattern, options: .caseInsensitive) else {
            return results
        }

        let matches = resultRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for match in matches {
            guard results.count < maxResults else { break }
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let block = String(html[range])

            // Skip ads — check the full match (including the opening div tag)
            // because result--ad is in the class attribute, not the inner content.
            if let fullRange = Range(match.range(at: 0), in: html) {
                let fullMatch = String(html[fullRange])
                if fullMatch.contains("result--ad") { continue }
            }

            // Extract title and URL from result__a link.
            guard let (title, href) = extractResultLink(from: block) else { continue }
            guard let resolvedURL = extractURL(from: href), !resolvedURL.isEmpty else { continue }

            // Extract snippet.
            let snippet = extractSnippet(from: block)

            results.append(SearchResult(
                title: ContentExtractor.stripAllHTMLTags(title).trimmingCharacters(in: .whitespacesAndNewlines),
                url: resolvedURL,
                snippet: ContentExtractor.stripAllHTMLTags(snippet).trimmingCharacters(in: .whitespacesAndNewlines),
                engine: engineType.rawValue
            ))
        }

        // Fallback: try simpler link-based extraction if regex didn't match.
        if results.isEmpty {
            results = fallbackParse(html: html, maxResults: maxResults)
        }

        return results
    }

    /// Extract the result link (title text + href) from a result block.
    private func extractResultLink(from block: String) -> (title: String, href: String)? {
        let pattern = "(?s)<a[^>]*class=\"[^\"]*result__a[^\"]*\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
              let hrefRange = Range(match.range(at: 1), in: block),
              let titleRange = Range(match.range(at: 2), in: block)
        else {
            return nil
        }
        return (String(block[titleRange]), String(block[hrefRange]))
    }

    /// Extract snippet from a result block.
    private func extractSnippet(from block: String) -> String {
        let pattern = "(?s)<a[^>]*class=\"[^\"]*result__snippet[^\"]*\"[^>]*>(.*?)</a>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
              let range = Range(match.range(at: 1), in: block)
        else {
            return ""
        }
        return String(block[range])
    }

    /// Unwrap DDG redirect URLs (//duckduckgo.com/l/?uddg=<encoded-url>).
    func extractURL(from href: String) -> String? {
        // Protocol-relative redirect.
        if href.contains("duckduckgo.com/l/") {
            let fullURL = href.hasPrefix("//") ? "https:\(href)" : href
            guard let components = URLComponents(string: fullURL),
                  let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value
            else {
                return nil
            }
            return uddg
        }

        // Direct URL.
        if href.hasPrefix("http://") || href.hasPrefix("https://") {
            return href
        }

        // Protocol-relative.
        if href.hasPrefix("//") {
            return "https:\(href)"
        }

        return nil
    }

    /// Fallback parser: extract any <a> links that look like search results.
    private func fallbackParse(html: String, maxResults: Int) -> [SearchResult] {
        var results: [SearchResult] = []
        let pattern = "(?s)<a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return results
        }

        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in matches {
            guard results.count < maxResults else { break }
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html)
            else { continue }

            let href = String(html[hrefRange])
            guard let resolvedURL = extractURL(from: href) else { continue }

            // Skip DDG internal links.
            if resolvedURL.contains("duckduckgo.com") { continue }

            let title = ContentExtractor.stripAllHTMLTags(String(html[textRange]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count > 3 else { continue }

            results.append(SearchResult(
                title: title,
                url: resolvedURL,
                snippet: "",
                engine: engineType.rawValue
            ))
        }
        return results
    }
}
