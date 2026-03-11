import Foundation

/// Detects person-centric queries that should trigger entity-enriched recall.
/// Pure stateless utility — no actor, no stored state.
enum PersonQueryDetector {

    struct PersonQueryMatch: Sendable {
        var targetName: String?
        var targetRelationLabel: String?
        var targetOrganisation: String?
        var targetLocation: String?
        var isExplicitQuery: Bool
    }

    /// Detect if `text` is a person-centric query.
    /// Returns nil if the query is not about a specific person.
    static func detectPersonQuery(in text: String) -> PersonQueryMatch? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)

        // Organisation queries — "who works at X", "who do I know at X".
        let orgPrefixes = [
            "who works at ",
            "who do i know at ",
            "who do you know at ",
            "do you know anyone who works at ",
            "tell me about people who work at ",
            "tell me about anyone who works at ",
            "anyone who works at ",
            "people who work at ",
        ]
        for prefix in orgPrefixes where lower.hasPrefix(prefix) {
            let candidate = String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))
                .trimmingCharacters(in: .whitespaces)
            if !candidate.isEmpty, candidate.count < 80 {
                return PersonQueryMatch(
                    targetOrganisation: candidate,
                    isExplicitQuery: true
                )
            }
        }

        // Location queries — "who lives in X", "who is based in X".
        let locPrefixes = ["who lives in ", "who is based in ", "who's in ", "who is in "]
        for prefix in locPrefixes where lower.hasPrefix(prefix) {
            let candidate = String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))
                .trimmingCharacters(in: .whitespaces)
            if !candidate.isEmpty, candidate.count < 80 {
                return PersonQueryMatch(
                    targetLocation: candidate,
                    isExplicitQuery: true
                )
            }
        }

        let explicitPatterns: [String] = [
            "what do you know about ",
            "tell me about ",
            "who is ",
            "who's ",
            "how is ",
            "how's ",
            "anything about ",
            "remind me about ",
            "what about ",
            "remember anything about ",
        ]

        for pattern in explicitPatterns where lower.hasPrefix(pattern) {
            let nameCandidate = String(text.dropFirst(pattern.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))
                .trimmingCharacters(in: .whitespaces)
            if !nameCandidate.isEmpty, nameCandidate.count < 60 {
                let (name, label) = extractNameAndLabel(from: nameCandidate)
                return PersonQueryMatch(
                    targetName: name,
                    targetRelationLabel: label,
                    isExplicitQuery: true
                )
            }
        }

        // Mid-sentence patterns.
        let midPatterns = ["about my ", "about your ", "know about "]
        for pattern in midPatterns where lower.contains(pattern) {
            if let range = lower.range(of: pattern) {
                let after = String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let nameCandidate = String(after.prefix(60))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))
                    .trimmingCharacters(in: .whitespaces)
                if !nameCandidate.isEmpty {
                    let (name, label) = extractNameAndLabel(from: nameCandidate)
                    if name != nil || label != nil {
                        return PersonQueryMatch(
                            targetName: name,
                            targetRelationLabel: label,
                            targetOrganisation: nil,
                            targetLocation: nil,
                            isExplicitQuery: false
                        )
                    }
                }
            }
        }

        return nil
    }

    // MARK: - Private

    private static let relationLabels = [
        "sister", "brother", "mom", "mum", "dad", "father", "mother",
        "daughter", "son", "wife", "husband", "partner", "girlfriend", "boyfriend",
        "friend", "colleague", "coworker", "co-worker", "boss", "manager",
        "teacher", "uncle", "aunt", "cousin", "grandmother", "grandfather",
        "grandma", "grandpa",
    ]

    /// Extract a name and optional relation label from a candidate string.
    /// E.g. "my sister Sarah" → ("Sarah", "sister"); "Sarah" → ("Sarah", nil)
    private static func extractNameAndLabel(from text: String) -> (String?, String?) {
        let lower = text.lowercased()
        var detectedLabel: String?
        var remainder = text

        for label in relationLabels {
            if lower.hasPrefix("my \(label) ") {
                detectedLabel = label
                remainder = String(text.dropFirst("my \(label) ".count))
                    .trimmingCharacters(in: .whitespaces)
                break
            } else if lower.hasPrefix("\(label) ") {
                detectedLabel = label
                remainder = String(text.dropFirst(label.count + 1))
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // Extract first capitalised word(s) as the name.
        let words = remainder.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var nameParts: [String] = []
        for word in words {
            let stripped = word.trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:"))
            guard !stripped.isEmpty, let first = stripped.first else { break }
            if first.isUppercase || (!nameParts.isEmpty && first.isLetter) {
                let low = stripped.lowercased()
                let stopWords: Set<String> = [
                    "works", "is", "was", "has", "lives", "moved", "called",
                    "who", "that", "and", "or", "but", "the", "a", "an",
                ]
                if stopWords.contains(low), !nameParts.isEmpty { break }
                nameParts.append(stripped)
                if nameParts.count >= 2 { break }
            } else {
                break
            }
        }

        let name = nameParts.isEmpty ? nil : nameParts.joined(separator: " ")
        return (name, detectedLabel)
    }
}
