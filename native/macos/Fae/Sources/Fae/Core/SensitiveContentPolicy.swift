import Foundation

/// Runtime policy for detecting and handling sensitive user content.
///
/// This is a guardrail for local privacy: secrets should not silently flow into
/// durable memory, logs, or delegated prompts even when the user shares them in
/// normal conversation.
enum SensitiveContentPolicy {
    enum SensitivityLevel: Int, Sendable {
        case normal = 0
        case sensitiveInline = 1
        case likelyCredential = 2
        case highlySensitive = 3
    }

    struct ScanResult: Sendable {
        let level: SensitivityLevel
        let matchedLabels: [String]

        var containsSensitiveContent: Bool { level != .normal }
        var shouldSuppressStructuredExtraction: Bool { level.rawValue >= SensitivityLevel.likelyCredential.rawValue }
        var shouldBlockDelegation: Bool { level.rawValue >= SensitivityLevel.sensitiveInline.rawValue }
    }

    private struct Rule {
        let label: String
        let level: SensitivityLevel
        let pattern: String
    }

    private static let rules: [Rule] = [
        Rule(label: "private_key_block", level: .highlySensitive, pattern: "-----BEGIN (?:RSA |EC |OPENSSH |PGP |PRIVATE)KEY-----"),
        Rule(label: "seed_phrase", level: .highlySensitive, pattern: "(?i)\\b(?:seed phrase|recovery phrase|mnemonic phrase|wallet seed)\\b"),
        Rule(label: "password_assignment", level: .highlySensitive, pattern: "(?i)\\b(?:my |the )?(?:password|passphrase|pin)\\b\\s*(?:is|=|:)\\s*[^\\s,;]+"),
        Rule(label: "api_key_assignment", level: .likelyCredential, pattern: "(?i)\\b(?:api[_ -]?key|access[_ -]?token|auth[_ -]?token|bearer token|secret key|client secret)\\b\\s*(?:is|=|:)\\s*[^\\s,;]+"),
        Rule(label: "openai_key", level: .likelyCredential, pattern: "(?i)\\bsk-[A-Za-z0-9]{12,}\\b"),
        Rule(label: "github_token", level: .likelyCredential, pattern: "(?i)\\bgh[pousr]_[A-Za-z0-9]{16,}\\b"),
        Rule(label: "slack_token", level: .likelyCredential, pattern: "(?i)\\bxox[baprs]-[A-Za-z0-9-]{10,}\\b"),
        Rule(label: "google_key", level: .likelyCredential, pattern: "(?i)\\bAIza[0-9A-Za-z\\-_]{20,}\\b"),
        Rule(label: "ssh_key", level: .highlySensitive, pattern: "(?i)\\bssh-(?:rsa|ed25519|ecdsa)\\s+[A-Za-z0-9+/=]{20,}"),
        Rule(label: "one_time_code", level: .sensitiveInline, pattern: "(?i)\\b(?:one[- ]time code|verification code|otp|2fa code|totp|mfa code)\\b"),
        Rule(label: "credential_phrase", level: .sensitiveInline, pattern: "(?i)\\b(?:login token|session token|cookie value|backup code|recovery code)\\b"),
        Rule(label: "long_opaque_token", level: .likelyCredential, pattern: "\\b[A-Za-z0-9+/=_-]{40,}\\b"),
    ]

    static func scan(_ text: String) -> ScanResult {
        guard !text.isEmpty else {
            return ScanResult(level: .normal, matchedLabels: [])
        }

        var maxLevel: SensitivityLevel = .normal
        var labels: [String] = []

        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if regex.firstMatch(in: text, options: [], range: range) != nil {
                labels.append(rule.label)
                if rule.level.rawValue > maxLevel.rawValue {
                    maxLevel = rule.level
                }
            }
        }

        return ScanResult(level: maxLevel, matchedLabels: labels)
    }

    static func redactForStorage(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var output = text
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let range = NSRange(output.startIndex..., in: output)
            output = regex.stringByReplacingMatches(
                in: output,
                options: [],
                range: range,
                withTemplate: "[REDACTED_SENSITIVE]"
            )
        }
        return output
    }

    static func shouldPersistProactiveObservation(taskId: String, text: String) -> Bool {
        let lower = text.lowercased()
        let observationTasks: Set<String> = ["camera_presence_check", "screen_activity_check"]
        guard observationTasks.contains(taskId) else { return true }

        if scan(text).containsSensitiveContent {
            return false
        }

        let protectedKeywords = [
            "1password", "lastpass", "bitwarden", "password manager", "passkey",
            "bank", "banking", "account balance", "credit card", "card number", "routing number",
            "inbox", "private message", "text thread", "imessage", "whatsapp", "signal",
            "medical", "diagnosis", "prescription", "patient", "lab result", "social security"
        ]
        return !protectedKeywords.contains(where: { lower.contains($0) })
    }
}
