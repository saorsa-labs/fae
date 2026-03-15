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
        "activate_skill": 20,
        "manage_skill": 5,
    ]

    /// Default limit for tools not in the explicit map.
    private static let defaultLimit = 20

    /// Check whether a tool invocation is within its rate limit.
    ///
    /// - Returns `nil` if allowed, or an error message if rate-limited.
    func checkLimit(tool: String, riskLevel: ToolRiskLevel) -> String? {
        let now = Date()
        let windowStart = now.addingTimeInterval(-60)
        let baseLimit = Self.limits[tool] ?? Self.defaultLimit
        let maxPerMinute = adjustedLimit(base: baseLimit, riskLevel: riskLevel)

        // Prune entries older than 60 seconds.
        var entries = windowByTool[tool, default: []]
        entries.removeAll { $0 < windowStart }

        if entries.count >= maxPerMinute {
            return "Rate limit exceeded for '\(tool)': max \(maxPerMinute) calls/min (\(riskLevel.rawValue))"
        }

        entries.append(now)
        windowByTool[tool] = entries
        return nil
    }

    private func adjustedLimit(base: Int, riskLevel: ToolRiskLevel) -> Int {
        var limit = base

        // Risk-tier guardrails.
        switch riskLevel {
        case .high:
            limit = min(limit, 3)
        case .medium:
            limit = min(limit, 10)
        case .low:
            break
        }

        return max(limit, 1)
    }

    /// Backward-compatible call path used by older tests/callers.
    func checkLimit(tool: String) -> String? {
        checkLimit(tool: tool, riskLevel: .medium)
    }

    /// Reset all rate limit state (for testing).
    func reset() {
        windowByTool.removeAll()
    }
}
