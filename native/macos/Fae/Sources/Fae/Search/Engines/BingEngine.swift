import Foundation

/// Bing HTML search engine.
///
/// GETs bing.com/search and parses li.b_algo result blocks.
struct BingEngine: SearchEngineProtocol {
    let engineType: SearchEngine = .bing

    func search(query: String, config: SearchConfig) async throws -> [SearchResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw SearchError.http("Failed to encode query")
        }

        let safeParam = config.safeSearch ? "Strict" : "Off"
        guard let url = URL(string: "https://www.bing.com/search?q=\(encoded)&setlang=en&safeSearch=\(safeParam)") else {
            throw SearchError.http("Invalid Bing search URL")
        }

        let request = SearchHTTPClient.getRequest(url: url, config: config)
        let session = URLSession(configuration: SearchHTTPClient.sessionConfiguration(config: config))
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SearchError.http("Bing returned status \(code)")
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw SearchError.parse("Bing response not valid UTF-8")
        }

        return parseBingResults(html: html, maxResults: config.maxResults)
    }

    /// Parse results from Bing HTML. Uses li.b_algo blocks.
    func parseBingResults(html: String, maxResults: Int) -> [SearchResult] {
        var results: [SearchResult] = []

        // Bing uses <li class="b_algo"> for organic results.
        let blockPattern = "(?s)<li[^>]*class=\"[^\"]*b_algo[^\"]*\"[^>]*>(.*?)</li>"
        guard let blockRegex = try? NSRegularExpression(pattern: blockPattern, options: .caseInsensitive) else {
            return results
        }

        let matches = blockRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for match in matches {
            guard results.count < maxResults else { break }
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let block = String(html[range])

            // Extract title from <h2>.
            let title = extractH2(from: block)
            guard !title.isEmpty else { continue }

            // Extract URL from <h2><a href="...">
            guard let href = extractH2Href(from: block), href.hasPrefix("http") else { continue }

            // Extract snippet from .b_caption p or .b_lineclamp2.
            let snippet = extractSnippet(from: block)

            results.append(SearchResult(
                title: ContentExtractor.stripAllHTMLTags(title).trimmingCharacters(in: .whitespacesAndNewlines),
                url: href,
                snippet: ContentExtractor.stripAllHTMLTags(snippet).trimmingCharacters(in: .whitespacesAndNewlines),
                engine: engineType.rawValue
            ))
        }

        return results
    }

    private func extractH2(from block: String) -> String {
        let pattern = "(?s)<h2[^>]*>(.*?)</h2>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
              let range = Range(match.range(at: 1), in: block)
        else {
            return ""
        }
        return String(block[range])
    }

    private func extractH2Href(from block: String) -> String? {
        // <h2><a href="...">
        let pattern = "(?s)<h2[^>]*>\\s*<a[^>]*href=\"([^\"]+)\"[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
              let range = Range(match.range(at: 1), in: block)
        else {
            return nil
        }
        return String(block[range])
    }

    private func extractSnippet(from block: String) -> String {
        let patterns = [
            "(?s)<div[^>]*class=\"[^\"]*b_caption[^\"]*\"[^>]*>.*?<p[^>]*>(.*?)</p>",
            "(?s)<p[^>]*class=\"[^\"]*b_lineclamp2[^\"]*\"[^>]*>(.*?)</p>",
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
}
