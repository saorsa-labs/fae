import Foundation

/// Brave Search HTML engine.
///
/// GETs search.brave.com/search and parses result snippets.
/// Independent search index — good complement to DuckDuckGo.
struct BraveEngine: SearchEngineProtocol {
    let engineType: SearchEngine = .brave

    func search(query: String, config: SearchConfig) async throws -> [SearchResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw SearchError.http("Failed to encode query")
        }

        let safeParam = config.safeSearch ? "strict" : "off"
        guard let url = URL(string: "https://search.brave.com/search?q=\(encoded)&safesearch=\(safeParam)") else {
            throw SearchError.http("Invalid Brave search URL")
        }

        let request = SearchHTTPClient.getRequest(url: url, config: config)
        let session = URLSession(configuration: SearchHTTPClient.sessionConfiguration(config: config))
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SearchError.http("Brave returned status \(code)")
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw SearchError.parse("Brave response not valid UTF-8")
        }

        return parseBraveResults(html: html, maxResults: config.maxResults)
    }

    /// Parse results from Brave HTML. Uses .snippet[data-pos] blocks.
    func parseBraveResults(html: String, maxResults: Int) -> [SearchResult] {
        var results: [SearchResult] = []

        // Brave uses <div class="snippet" data-pos="N"> for organic results.
        let blockPattern = "(?s)<div[^>]*class=\"[^\"]*snippet[^\"]*\"[^>]*data-pos=\"\\d+\"[^>]*>(.*?)</div>\\s*(?=<div[^>]*class=\"[^\"]*snippet|<div[^>]*class=\"[^\"]*fdb|$)"
        guard let blockRegex = try? NSRegularExpression(pattern: blockPattern, options: .caseInsensitive) else {
            return results
        }

        let matches = blockRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for match in matches {
            guard results.count < maxResults else { break }
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let block = String(html[range])

            // Skip standalone/featured snippets.
            if block.contains("standalone") { continue }

            // Extract title from .snippet-title.
            let title = extractByClass(from: block, className: "snippet-title")
            guard !title.isEmpty else { continue }

            // Extract URL from the first <a> in the block.
            let href = extractFirstHref(from: block)
            guard let href, href.hasPrefix("http") else { continue }

            // Extract description from .snippet-description.
            let description = extractByClass(from: block, className: "snippet-description")

            results.append(SearchResult(
                title: ContentExtractor.stripAllHTMLTags(title).trimmingCharacters(in: .whitespacesAndNewlines),
                url: href,
                snippet: ContentExtractor.stripAllHTMLTags(description).trimmingCharacters(in: .whitespacesAndNewlines),
                engine: engineType.rawValue
            ))
        }

        return results
    }

    private func extractByClass(from block: String, className: String) -> String {
        let pattern = "(?s)<[^>]*class=\"[^\"]*\(className)[^\"]*\"[^>]*>(.*?)</[^>]+>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
              let range = Range(match.range(at: 1), in: block)
        else {
            return ""
        }
        return String(block[range])
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
