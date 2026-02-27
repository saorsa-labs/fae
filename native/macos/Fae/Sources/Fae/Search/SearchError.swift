import Foundation

/// Errors from the search system.
enum SearchError: Error, LocalizedError {
    case allEnginesFailed(String)
    case timeout(String)
    case http(String)
    case parse(String)
    case config(String)

    var errorDescription: String? {
        switch self {
        case .allEnginesFailed(let msg): "All engines failed: \(msg)"
        case .timeout(let msg): "Timeout: \(msg)"
        case .http(let msg): "HTTP error: \(msg)"
        case .parse(let msg): "Parse error: \(msg)"
        case .config(let msg): "Config error: \(msg)"
        }
    }
}
