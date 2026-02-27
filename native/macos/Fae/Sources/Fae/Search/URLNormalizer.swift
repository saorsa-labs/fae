import Foundation

/// URL normalization for cross-engine deduplication.
///
/// Strips tracking parameters, removes default ports, normalizes trailing slashes,
/// and sorts query parameters for consistent comparison.
enum URLNormalizer {
    /// Tracking parameters to strip during normalization.
    static let trackingParams: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "fbclid", "gclid", "ref", "si", "feature",
    ]

    /// Normalize a URL for deduplication.
    ///
    /// - Lowercases scheme and host (via URLComponents)
    /// - Removes fragment
    /// - Removes default ports (80 for http, 443 for https)
    /// - Strips tracking query parameters
    /// - Sorts remaining query params alphabetically
    /// - Removes trailing slash from path (unless path is "/")
    static func normalize(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else {
            return raw.lowercased()
        }

        // Remove fragment.
        components.fragment = nil

        // Remove default ports.
        if let scheme = components.scheme?.lowercased(), let port = components.port {
            if (scheme == "http" && port == 80) || (scheme == "https" && port == 443) {
                components.port = nil
            }
        }

        // Filter and sort query parameters.
        if let queryItems = components.queryItems, !queryItems.isEmpty {
            let filtered = queryItems.filter { item in
                !trackingParams.contains(item.name.lowercased())
            }
            if filtered.isEmpty {
                components.queryItems = nil
            } else {
                components.queryItems = filtered.sorted { lhs, rhs in
                    if lhs.name == rhs.name {
                        return (lhs.value ?? "") < (rhs.value ?? "")
                    }
                    return lhs.name < rhs.name
                }
            }
        }

        // Remove trailing slash from path (unless root).
        if components.path.hasSuffix("/") && components.path != "/" {
            components.path = String(components.path.dropLast())
        }

        // Lowercase scheme and host.
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        return components.string ?? raw.lowercased()
    }
}
