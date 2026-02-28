import Foundation

/// Formats entity profiles into compact strings for `<memory_context>` injection.
/// Pure stateless utility — no actor, no dependencies beyond EntityStore types.
enum EntityContextFormatter {

    /// A resolved relationship edge ready for formatting (targetName already looked up).
    struct FormattedEdge: Sendable {
        var relationType: String
        var targetName: String
        var startedAt: UInt64?
        var endedAt: UInt64?
    }

    /// Format a single entity profile into a compact context string.
    ///
    /// Example output:
    /// ```
    /// [Sarah (sister, family): employer: Google. Mentioned 7×. Last 3 days ago.
    ///   Works at: Google (since 2022)
    ///   Lives in: London (since 2023)
    ///   Commitment: call her by Friday.]
    /// ```
    static func format(
        profile: EntityProfile,
        linkedRecords: [MemoryRecord],
        edges: [FormattedEdge] = []
    ) -> String {
        let entity = profile.entity
        var parts: [String] = []

        // Header: name + relation.
        var header = entity.canonicalName
        if let label = entity.relationLabel, let type_ = entity.relationType {
            header += " (\(label), \(type_.rawValue))"
        } else if let label = entity.relationLabel {
            header += " (\(label))"
        } else if let type_ = entity.relationType {
            header += " (\(type_.rawValue))"
        }

        // Inline facts (max 4).
        let factsStr = profile.facts.isEmpty ? "" : profile.facts
            .prefix(4)
            .map { "\($0.factKey): \($0.factValue)" }
            .joined(separator: "; ")

        // Recency.
        let recencyStr: String
        if entity.lastMentionedAt > 0 {
            let days = Int((Date().timeIntervalSince1970 - Double(entity.lastMentionedAt)) / 86_400)
            switch days {
            case 0: recencyStr = "Last today."
            case 1: recencyStr = "Last yesterday."
            default: recencyStr = "Last \(days) days ago."
            }
        } else {
            recencyStr = ""
        }

        var headerLine = "[\(header)"
        if !factsStr.isEmpty { headerLine += ": \(factsStr)." }
        if entity.mentionCount > 0 { headerLine += " Mentioned \(entity.mentionCount)×." }
        if !recencyStr.isEmpty { headerLine += " \(recencyStr)" }
        parts.append(headerLine)

        // Relationship edges (max 4).
        for edge in edges.prefix(4) {
            let label = formatRelationType(edge.relationType)
            var line = "  \(label): \(edge.targetName)"
            if let started = edge.startedAt, started > 0 {
                let year = Calendar.current.component(
                    .year, from: Date(timeIntervalSince1970: Double(started))
                )
                line += edge.endedAt == nil ? " (since \(year))" : " (\(year))"
            }
            parts.append(line)
        }

        // Linked records — commitments and events only, max 2 each.
        for c in linkedRecords.filter({ $0.kind == .commitment }).prefix(2) {
            let text = c.text
                .replacingOccurrences(of: "User commitment: ", with: "")
                .prefix(120)
            parts.append("  Commitment: \(text)")
        }
        for e in linkedRecords.filter({ $0.kind == .event }).prefix(2) {
            let text = e.text
                .replacingOccurrences(of: "User event: ", with: "")
                .prefix(120)
            parts.append("  Event: \(text)")
        }
        parts.append("]")

        return parts.joined(separator: "\n")
    }

    // MARK: - Private

    private static func formatRelationType(_ raw: String) -> String {
        switch raw {
        case "works_at": return "Works at"
        case "lives_in": return "Lives in"
        case "knows": return "Knows"
        case "reports_to": return "Reports to"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Format multiple profiles, truncated to `maxChars`.
    static func formatMultiple(
        profiles: [EntityProfile],
        maxChars: Int = MemoryConstants.entityMaxContextChars
    ) -> String {
        guard !profiles.isEmpty else { return "" }
        var sections: [String] = []
        var totalChars = 0

        for profile in profiles {
            let section = format(profile: profile, linkedRecords: [])
            if totalChars + section.count > maxChars, !sections.isEmpty { break }
            sections.append(section)
            totalChars += section.count
        }

        return sections.joined(separator: "\n")
    }
}
