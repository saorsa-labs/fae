import Foundation

/// Per-tool sliding-window rate limiter.
///
/// Prevents runaway tool use and resource exhaustion by limiting
/// how many times each tool can execute per minute.
actor ToolRateLimiter {

    /// Timestamps of recent invocations, keyed by tool name.
    private var windowByTool: [String: [Date]] = [:]

    /// Per-tool limits (calls per minute).
    private static let limits: [String: Int] = [
        "bash": 5,
        "write": 10,
        "edit": 10,
        "web_search": 15,
        "fetch_url": 15,
        "self_config": 3,
    ]

    /// Default limit for tools not in the explicit map.
    private static let defaultLimit = 20

    /// Check whether a tool invocation is within its rate limit.
    ///
    /// - Returns `nil` if allowed, or an error message if rate-limited.
    func checkLimit(tool: String) -> String? {
        let now = Date()
        let windowStart = now.addingTimeInterval(-60)
        let maxPerMinute = Self.limits[tool] ?? Self.defaultLimit

        // Prune entries older than 60 seconds.
        var entries = windowByTool[tool, default: []]
        entries.removeAll { $0 < windowStart }

        if entries.count >= maxPerMinute {
            return "Rate limit exceeded for '\(tool)': max \(maxPerMinute) calls per minute"
        }

        entries.append(now)
        windowByTool[tool] = entries
        return nil
    }

    /// Reset all rate limit state (for testing).
    func reset() {
        windowByTool.removeAll()
    }
}
