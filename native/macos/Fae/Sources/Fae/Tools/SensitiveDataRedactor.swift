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

    static func redactLongOpaqueTokens(_ input: String) -> String {
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

    /// Returns true if `value` looks like a raw credential that should not be
    /// returned to the LLM in plaintext.
    ///
    /// Checks three signal classes:
    ///  1. Known provider prefixes — sk-, ghp_, AIza, xox[baprs]-
    ///  2. High-entropy no-whitespace token ≥ 20 compact alphanumeric chars
    ///  3. Request-context hint: prompt/title contains a credential keyword
    ///     AND the value has no whitespace and is ≥ 8 chars
    ///
    /// False positives are acceptable: the withholding error message tells the
    /// user how to re-provide the value via the safe secure+store_key path.
    static func looksLikeCredential(_ value: String, hint: String = "") -> Bool {
        guard !value.isEmpty else { return false }

        // 1. Known provider token prefixes.
        let prefixPatterns: [String] = [
            #"(?i)sk-[A-Za-z0-9]{12,}"#,
            #"(?i)xox[baprs]-[A-Za-z0-9\-]{10,}"#,
            #"(?i)ghp_[A-Za-z0-9]{20,}"#,
            #"(?i)AIza[0-9A-Za-z\-_]{20,}"#,
        ]
        for pattern in prefixPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(value.startIndex..., in: value)
                if regex.firstMatch(in: value, options: [], range: range) != nil {
                    return true
                }
            }
        }

        // Email- and URL-shaped values are exempt from the heuristics below —
        // Fae legitimately asks for both via input_request (mail/channel setup,
        // "paste the link"), and neither is a credential per se. A credential
        // EMBEDDED in a URL is still caught by the explicit provider-prefix
        // patterns above (checked first).
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if isEmailOrUrlShaped(trimmed) {
            return false
        }

        // 2. High-entropy heuristic: no whitespace and ≥ 20 compact alphanumeric chars.
        if !trimmed.contains(" ") && !trimmed.contains("\n") {
            let compact = trimmed.replacingOccurrences(
                of: #"[^A-Za-z0-9]"#, with: "", options: .regularExpression
            )
            if compact.count >= 20 {
                return true
            }
        }

        // 3. Context hint: prompt or title signals a credential request,
        //    and the value is a no-whitespace token of ≥ 8 chars.
        if !hint.isEmpty {
            let hintLower = hint.lowercased()
            let credentialKeywords = ["key", "token", "secret", "password", "credential", "api", "auth"]
            let hintIndicatesCredential = credentialKeywords.contains(where: { hintLower.contains($0) })
            if hintIndicatesCredential, !trimmed.contains(" "), trimmed.count >= 8 {
                return true
            }
        }

        return false
    }

    /// True when the value reads as an email address or a URL — inputs Fae
    /// legitimately requests in the clear (mail setup, "paste the link").
    /// These are exempt from the entropy/hint heuristics; only the explicit
    /// provider-token patterns may flag them.
    private static func isEmailOrUrlShaped(_ value: String) -> Bool {
        if value.range(
            of: #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        let lower = value.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }
}
