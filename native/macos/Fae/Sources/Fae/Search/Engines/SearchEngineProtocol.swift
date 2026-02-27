import Foundation

/// Protocol for search engine implementations.
protocol SearchEngineProtocol: Sendable {
    /// The engine type.
    var engineType: SearchEngine { get }

    /// Execute a search query and return results.
    func search(query: String, config: SearchConfig) async throws -> [SearchResult]
}
