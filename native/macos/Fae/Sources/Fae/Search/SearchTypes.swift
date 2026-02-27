import Foundation

/// A single search result from any engine.
struct SearchResult: Sendable {
    var title: String
    var url: String
    var snippet: String
    var engine: String
    var score: Double

    init(title: String, url: String, snippet: String, engine: String, score: Double = 0.0) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.engine = engine
        self.score = score
    }
}

/// Supported search engines.
enum SearchEngine: String, CaseIterable, Sendable {
    case duckDuckGo = "DuckDuckGo"
    case brave = "Brave"
    case google = "Google"
    case bing = "Bing"
    case startpage = "Startpage"

    /// Reliability weight used in cross-engine scoring.
    var weight: Double {
        switch self {
        case .google: 1.2
        case .duckDuckGo: 1.0
        case .brave: 1.0
        case .startpage: 0.9
        case .bing: 0.8
        }
    }
}

/// Extracted page content from a URL.
struct PageContent: Sendable {
    let url: String
    let title: String
    let text: String
    let wordCount: Int
}

/// Configuration for the search system.
struct SearchConfig: Sendable {
    /// Which engines to query (queried concurrently).
    var engines: [SearchEngine]
    /// Maximum results to return after dedup + ranking.
    var maxResults: Int
    /// Per-engine HTTP timeout in seconds.
    var timeoutSeconds: TimeInterval
    /// Request safe-search filtering from engines.
    var safeSearch: Bool
    /// In-memory cache TTL in seconds. Set to 0 to disable.
    var cacheTTLSeconds: TimeInterval
    /// Random jitter range (ms) between engine requests to avoid rate-limiting.
    var requestDelayMs: (UInt64, UInt64)
    /// Custom User-Agent string. nil = rotate through realistic browser UAs.
    var userAgent: String?

    static let `default` = SearchConfig(
        engines: [.duckDuckGo, .brave, .google, .bing],
        maxResults: 10,
        timeoutSeconds: 8,
        safeSearch: true,
        cacheTTLSeconds: 600,
        requestDelayMs: (100, 500),
        userAgent: nil
    )

    func validate() throws {
        guard maxResults > 0 else {
            throw SearchError.config("maxResults must be > 0")
        }
        guard timeoutSeconds > 0 else {
            throw SearchError.config("timeoutSeconds must be > 0")
        }
        guard !engines.isEmpty else {
            throw SearchError.config("engines must not be empty")
        }
        guard requestDelayMs.0 <= requestDelayMs.1 else {
            throw SearchError.config("requestDelayMs min must be <= max")
        }
    }
}
