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
    /// Applies profile and risk-aware adjustments on top of per-tool defaults.
    /// - Returns `nil` if allowed, or an error message if rate-limited.
    func checkLimit(tool: String, riskLevel: ToolRiskLevel, profile: PolicyProfile) -> String? {
        let now = Date()
        let windowStart = now.addingTimeInterval(-60)
        let baseLimit = Self.limits[tool] ?? Self.defaultLimit
        let maxPerMinute = adjustedLimit(
            base: baseLimit,
            riskLevel: riskLevel,
            profile: profile
        )

        // Prune entries older than 60 seconds.
        var entries = windowByTool[tool, default: []]
        entries.removeAll { $0 < windowStart }

        if entries.count >= maxPerMinute {
            return "Rate limit exceeded for '\(tool)': max \(maxPerMinute) calls/min (\(riskLevel.rawValue), \(profile.rawValue))"
        }

        entries.append(now)
        windowByTool[tool] = entries
        return nil
    }

    private func adjustedLimit(base: Int, riskLevel: ToolRiskLevel, profile: PolicyProfile) -> Int {
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

        // Profile tuning.
        switch profile {
        case .moreCautious:
            limit = max(1, limit / 2)
        case .balanced:
            break
        case .moreAutonomous:
            if riskLevel == .low {
                limit = min(60, limit + 5)
            } else if riskLevel == .high {
                limit = min(limit, 2)
            }
        }

        return max(limit, 1)
    }

    /// Backward-compatible call path used by older tests/callers.
    func checkLimit(tool: String) -> String? {
        checkLimit(tool: tool, riskLevel: .medium, profile: .balanced)
    }

    /// Reset all rate limit state (for testing).
    func reset() {
        windowByTool.removeAll()
    }
}
