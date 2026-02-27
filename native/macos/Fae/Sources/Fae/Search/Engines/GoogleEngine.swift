import Foundation

/// Google HTML search engine.
///
/// GETs google.com/search and parses div.g result blocks.
/// Best result quality but aggressive bot detection — may get blocked.
struct GoogleEngine: SearchEngineProtocol {
    let engineType: SearchEngine = .google

    func search(query: String, config: SearchConfig) async throws -> [SearchResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw SearchError.http("Failed to encode query")
        }

        let safeParam = config.safeSearch ? "active" : "off"
        guard let url = URL(string: "https://www.google.com/search?q=\(encoded)&hl=en&safe=\(safeParam)") else {
            throw SearchError.http("Invalid Google search URL")
        }

        let request = SearchHTTPClient.getRequest(url: url, config: config)
        let session = URLSession(configuration: SearchHTTPClient.sessionConfiguration(config: config))
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SearchError.http("Google returned status \(code)")
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw SearchError.parse("Google response not valid UTF-8")
        }

        return parseGoogleResults(html: html, maxResults: config.maxResults)
    }

    /// Parse results from Google HTML. Uses div.g blocks.
    func parseGoogleResults(html: String, maxResults: Int) -> [SearchResult] {
        var results: [SearchResult] = []

        // Google organic results are in <div class="g"> blocks.
        let blockPattern = "(?s)<div[^>]*class=\"[^\"]*\\bg\\b[^\"]*\"[^>]*>(.*?)</div>\\s*(?=<div[^>]*class=\"[^\"]*\\bg\\b|<div[^>]*id=\"botstuff\"|$)"
        guard let blockRegex = try? NSRegularExpression(pattern: blockPattern, options: .caseInsensitive) else {
            return results
        }

        let matches = blockRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for match in matches {
            guard results.count < maxResults else { break }
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let block = String(html[range])

            // Extract title from <h3>.
            let title = extractH3(from: block)
            guard !title.isEmpty else { continue }

            // Extract URL from first <a href>.
            guard let rawHref = extractFirstHref(from: block) else { continue }
            let resolvedURL = unwrapGoogleRedirect(rawHref)
            guard resolvedURL.hasPrefix("http") else { continue }

            // Extract snippet.
            let snippet = extractSnippet(from: block)

            results.append(SearchResult(
                title: ContentExtractor.stripAllHTMLTags(title).trimmingCharacters(in: .whitespacesAndNewlines),
                url: resolvedURL,
                snippet: ContentExtractor.stripAllHTMLTags(snippet).trimmingCharacters(in: .whitespacesAndNewlines),
                engine: engineType.rawValue
            ))
        }

        return results
    }

    /// Unwrap Google redirect URLs (/url?q=<target>&...).
    func unwrapGoogleRedirect(_ href: String) -> String {
        if href.hasPrefix("/url?") || href.contains("google.com/url?") {
            let fullURL = href.hasPrefix("/") ? "https://www.google.com\(href)" : href
            if let components = URLComponents(string: fullURL),
               let q = components.queryItems?.first(where: { $0.name == "q" })?.value
            {
                return q
            }
        }
        return href
    }

    private func extractH3(from block: String) -> String {
        let pattern = "(?s)<h3[^>]*>(.*?)</h3>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
              let range = Range(match.range(at: 1), in: block)
        else {
            return ""
        }
        return String(block[range])
    }

    private func extractSnippet(from block: String) -> String {
        // Google uses various classes for snippets.
        let patterns = [
            "(?s)<span[^>]*class=\"[^\"]*VwiC3b[^\"]*\"[^>]*>(.*?)</span>",
            "(?s)<div[^>]*data-sncf[^>]*>(.*?)</div>",
            "(?s)<span[^>]*class=\"[^\"]*lEBKkf[^\"]*\"[^>]*>(.*?)</span>",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
               let range = Range(match.range(at: 1), in: block)
            {
                return String(block[range])
            }
        }
        return ""
    }

    private func extractFirstHref(from block: String) -> String? {
        let pattern = "<a[^>]*href=\"([^\"]+)\"[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
              let range = Range(match.range(at: 1), in: block)
        else {
            return nil
        }
        return String(block[range])
    }
}
