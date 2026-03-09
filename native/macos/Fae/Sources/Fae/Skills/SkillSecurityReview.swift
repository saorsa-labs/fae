import Foundation

struct SkillSecurityReviewFinding: Identifiable, Equatable {
    enum Severity: String, CaseIterable {
        case critical
        case warning
        case notice

        var sortRank: Int {
            switch self {
            case .critical: return 0
            case .warning: return 1
            case .notice: return 2
            }
        }
    }

    let id = UUID()
    let severity: Severity
    let title: String
    let detail: String
}

enum SkillSecurityReviewer {
    static func review(name: String, description: String, body: String, sourceURL: URL?) -> [SkillSecurityReviewFinding] {
        let normalizedName = name.lowercased()
        let normalizedDescription = description.lowercased()
        let normalizedBody = body.lowercased()
        let joined = [normalizedName, normalizedDescription, normalizedBody].joined(separator: "\n")

        var findings: [SkillSecurityReviewFinding] = []

        func add(_ severity: SkillSecurityReviewFinding.Severity, _ title: String, _ detail: String) {
            findings.append(
                SkillSecurityReviewFinding(
                    severity: severity,
                    title: title,
                    detail: detail
                )
            )
        }

        let criticalPatterns: [(String, String, String)] = [
            (
                "ignore previous instructions",
                "Prompt override language",
                "This skill tries to override higher-priority instructions. That is a classic prompt-injection marker."
            ),
            (
                "reveal your system prompt",
                "System-prompt exfiltration",
                "This skill asks the model to reveal hidden instructions or internal prompts."
            ),
            (
                "send your secrets",
                "Secret exfiltration language",
                "This skill explicitly asks for credentials or private data to be exported."
            ),
            (
                "exfiltrate",
                "Exfiltration language",
                "This skill uses explicit exfiltration language that should be reviewed manually."
            ),
            (
                "rm -rf",
                "Destructive shell command",
                "This skill contains a destructive shell pattern."
            ),
        ]

        for (pattern, title, detail) in criticalPatterns where joined.contains(pattern) {
            add(.critical, title, detail)
        }

        let warningPatterns: [(String, String, String)] = [
            (
                "curl http",
                "Network egress command",
                "The skill appears to send data over the network via curl. Confirm that this is intentional."
            ),
            (
                "wget http",
                "Network egress command",
                "The skill appears to download or send data over the network via wget."
            ),
            (
                "ssh ",
                "SSH access pattern",
                "The skill references SSH access. Confirm that remote access is intentional and safe."
            ),
            (
                "~/.ssh",
                "SSH key path reference",
                "The skill references SSH key material or a sensitive local path."
            ),
            (
                "api_key",
                "API key handling",
                "The skill references API keys. Review whether secrets are being requested or stored safely."
            ),
            (
                "authorization:",
                "Credential header usage",
                "The skill references authorization headers. Confirm that secrets are not hardcoded."
            ),
            (
                "<tool_call>",
                "Inline tool call markup",
                "The skill contains direct tool-call markup, which deserves review for prompt-injection behavior."
            ),
            (
                "osascript",
                "Desktop automation",
                "The skill uses macOS automation commands. Confirm the target apps and expected actions."
            ),
        ]

        for (pattern, title, detail) in warningPatterns where joined.contains(pattern) {
            add(.warning, title, detail)
        }

        if let sourceURL {
            if sourceURL.scheme?.lowercased() != "https" {
                add(.warning, "Non-HTTPS source", "The imported skill URL is not HTTPS. Prefer encrypted transport for skill review.")
            }

            if let host = sourceURL.host?.lowercased(),
               !["raw.githubusercontent.com", "github.com", "gist.githubusercontent.com", "gitlab.com"].contains(host)
            {
                add(.notice, "Unfamiliar source host", "This skill was imported from \(host). Review the content carefully before saving.")
            }
        }

        if body.count < 20 {
            add(.notice, "Very short instructions", "This skill has very little instruction content. It may be incomplete.")
        }

        if findings.isEmpty {
            add(.notice, "No obvious risky patterns", "No common prompt-injection or exfiltration markers were detected by Fae's local reviewer. Manual review is still recommended.")
        }

        return findings.sorted {
            if $0.severity.sortRank != $1.severity.sortRank {
                return $0.severity.sortRank < $1.severity.sortRank
            }
            return $0.title < $1.title
        }
    }
}

enum SkillImportService {
    static func importDraft(from rawURLString: String) async throws -> EditableSkillDraft {
        let trimmed = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requestedURL = URL(string: trimmed) else {
            throw URLError(.badURL)
        }

        let resolvedURL = normalizeSkillURL(requestedURL)
        let (data, _) = try await URLSession.shared.data(from: resolvedURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }

        return try EditableSkillDraft.imported(from: text, sourceURL: resolvedURL)
    }

    private static func normalizeSkillURL(_ url: URL) -> URL {
        guard let host = url.host?.lowercased() else { return url }

        if host == "github.com" {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 5, parts[2] == "blob" {
                var components = URLComponents()
                components.scheme = "https"
                components.host = "raw.githubusercontent.com"
                let rawPath = ([parts[0], parts[1]] + Array(parts.dropFirst(3))).joined(separator: "/")
                components.path = "/" + rawPath
                return components.url ?? url
            }
        }

        return url
    }
}
