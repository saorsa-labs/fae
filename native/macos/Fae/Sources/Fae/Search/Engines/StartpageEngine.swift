import Foundation

/// Startpage HTML search engine.
///
/// GETs startpage.com/do/search and parses .w-gl__result blocks.
/// Privacy-focused Google proxy — good result quality without bot detection.
struct StartpageEngine: SearchEngineProtocol {
    let engineType: SearchEngine = .startpage

    func search(query: String, config: SearchConfig) async throws -> [SearchResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw SearchError.http("Failed to encode query")
        }

        var urlString = "https://www.startpage.com/do/search?q=\(encoded)&cat=web"
        if !config.safeSearch {
            urlString += "&qadf=none"
        }

        guard let url = URL(string: urlString) else {
            throw SearchError.http("Invalid Startpage search URL")
        }

        let request = SearchHTTPClient.getRequest(url: url, config: config)
        let session = URLSession(configuration: SearchHTTPClient.sessionConfiguration(config: config))
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SearchError.http("Startpage returned status \(code)")
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw SearchError.parse("Startpage response not valid UTF-8")
        }

        return parseStartpageResults(html: html, maxResults: config.maxResults)
    }

    /// Parse results from Startpage HTML. Uses .w-gl__result blocks.
    func parseStartpageResults(html: String, maxResults: Int) -> [SearchResult] {
        var results: [SearchResult] = []

        // Startpage uses <div class="w-gl__result"> for each result.
        let blockPattern = "(?s)<div[^>]*class=\"[^\"]*w-gl__result[^\"]*\"[^>]*>(.*?)</div>\\s*(?=<div[^>]*class=\"[^\"]*w-gl__result|$)"
        guard let blockRegex = try? NSRegularExpression(pattern: blockPattern, options: .caseInsensitive) else {
            return results
        }

        let matches = blockRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for match in matches {
            guard results.count < maxResults else { break }
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let block = String(html[range])

            // Extract title from .w-gl__result-title.
            let title = extractByClass(from: block, className: "w-gl__result-title")
            guard !title.isEmpty else { continue }

            // Extract URL from <a> inside the title element.
            guard let href = extractFirstHref(from: block), href.hasPrefix("http") else { continue }

            // Extract description from .w-gl__description.
            let description = extractByClass(from: block, className: "w-gl__description")

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
