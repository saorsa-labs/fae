import Foundation

/// Best-effort redaction for secrets before persistence in logs/analytics.
enum SensitiveDataRedactor {
    private static let patterns: [String] = [
        #"(?i)(api[_-]?key\s*[:=]\s*)([A-Za-z0-9_\-]{8,})"#,
        #"(?i)(token\s*[:=]\s*)([A-Za-z0-9_\-]{8,})"#,
        #"(?i)(password\s*[:=]\s*)([^\s,;]{4,})"#,
        #"(?i)sk-[A-Za-z0-9]{12,}"#,
        #"(?i)xox[baprs]-[A-Za-z0-9\-]{10,}"#,
        #"(?i)ghp_[A-Za-z0-9]{20,}"#,
        #"(?i)AIza[0-9A-Za-z\-_]{20,}"#,
    ]

    static func redact(_ text: String?) -> String? {
        guard var output = text, !output.isEmpty else { return text }

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..., in: output)
            output = regex.stringByReplacingMatches(
                in: output,
                options: [],
                range: range,
                withTemplate: "[REDACTED]"
            )
        }

        // High-entropy long token heuristic.
        output = redactLongOpaqueTokens(output)
        return output
    }

    private static func redactLongOpaqueTokens(_ input: String) -> String {
        let parts = input.split(separator: " ", omittingEmptySubsequences: false)
        let redacted = parts.map { part -> String in
            let token = String(part)
            let compact = token.replacingOccurrences(of: #"[^A-Za-z0-9]"#, with: "", options: .regularExpression)
            if compact.count >= 32, compact.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil {
                return "[REDACTED_TOKEN]"
            }
            return token
        }
        return redacted.joined(separator: " ")
    }
}
