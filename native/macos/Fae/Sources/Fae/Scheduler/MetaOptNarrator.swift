import Foundation

// MARK: - MetaOptNarrator

/// Converts technical meta-optimization results into natural language for non-technical users.
///
/// The narrator translates every `MetaOptResult` into companion-style speech that
/// Fae can deliver in the morning briefing or show in the Settings UI. No technical
/// jargon — no "temperature", "benchmark", "dimension scores", or "hypothesis".
///
/// ## Framing
/// Each optimization surface maps to how a person describes self-improvement:
/// - Directive → "I learned a new habit"
/// - Config → "I fine-tuned how I think"
/// - Skill → "I picked up a new routine"
/// - Memory seed → "I made a mental note"
///
/// ## Usage
/// ```swift
/// let narrative = MetaOptNarrator.narrate(summary)
/// // → "I made a couple of adjustments overnight. I noticed I was getting in the
/// //    way when you asked about your projects, so I check your files first now.
/// //    I also trimmed how much I say — you seemed to prefer shorter answers.
/// //    If anything feels off, just tell me to undo it."
/// ```
enum MetaOptNarrator {

    // MARK: - Public API

    /// Generate a complete narrative from a meta-optimization summary.
    ///
    /// Returns `nil` if there are no kept changes to report.
    static func narrate(_ summary: MetaOptSummary) -> String? {
        let keptResults = summary.results.filter(\.kept)
        guard !keptResults.isEmpty else { return nil }

        var parts: [String] = []

        // Opening — varies by count.
        if keptResults.count == 1 {
            parts.append("I made a small adjustment overnight.")
        } else {
            parts.append("I made a couple of adjustments overnight.")
        }

        // Describe each kept change.
        for result in keptResults {
            if let description = describeChange(result) {
                parts.append(description)
            }
        }

        // Closing — always offer undo.
        parts.append("If anything feels off, just tell me to undo it.")

        return parts.joined(separator: " ")
    }

    /// Generate a single-line description for a result (for Settings UI timeline).
    static func timelineEntry(_ result: MetaOptResult) -> String {
        if result.kept {
            return describeChange(result) ?? "Made an improvement"
        } else {
            return "Tried a change but it didn't help, so I reverted it"
        }
    }

    /// Generate a brief status line for the morning briefing when there's nothing to report.
    static func noChangesNarrative() -> String? {
        nil // Don't mention it if nothing changed — silence is fine.
    }

    /// Generate a confirmation message after a user-requested rollback.
    static func describeRollback(_ changeDescription: String) -> String {
        let lower = changeDescription.lowercased()
        if lower.contains("temperature") || lower.contains("config") {
            return "Done — I've reverted that thinking adjustment. I'll go back to how I was before."
        }
        if lower.contains("concise") || lower.contains("brevity") || lower.contains("interruption") {
            return "Done — I've undone the brevity change. I'll be more detailed again."
        }
        if lower.contains("skill") || lower.contains("routine") {
            return "Done — I've removed that routine. It won't affect my responses anymore."
        }
        if lower.contains("memory") || lower.contains("seed") || lower.contains("note") {
            return "Done — I've forgotten that mental note. It won't come up in our conversations."
        }
        return "Done — I've undone my last overnight adjustment. Things should feel like before."
    }

    // MARK: - Change Descriptions

    /// Describe a single kept change in natural language.
    private static func describeChange(_ result: MetaOptResult) -> String? {
        switch result.surface {
        case .directive:
            return describeDirectiveChange(result)
        case .configKnob:
            return describeConfigChange(result)
        case .skill:
            return describeSkillChange(result)
        case .memorySeed:
            return describeMemorySeedChange(result)
        }
    }

    // MARK: - Directive Descriptions

    private static func describeDirectiveChange(_ result: MetaOptResult) -> String? {
        guard case .directiveAmendment(let text) = changeFromDescription(result) else {
            return describeFromKeywords(result.description)
        }
        let lower = text.lowercased()

        if lower.contains("concise") || lower.contains("shorter") || lower.contains("brief") {
            return "I noticed you prefer shorter answers, so I'm keeping things more concise now."
        }
        if lower.contains("clarifying question") || lower.contains("confirm understanding") {
            return "I'll ask before diving in now when your request could mean different things."
        }
        if lower.contains("actual question") || lower.contains("directly") {
            return "I'm getting better at cutting to the point — answering your question first, then adding context."
        }
        if lower.contains("close attention") || lower.contains("phrasing") {
            return "I'm paying closer attention to exactly what you ask, so I don't go off track."
        }

        return describeFromKeywords(result.description)
    }

    // MARK: - Config Descriptions

    private static func describeConfigChange(_ result: MetaOptResult) -> String? {
        let desc = result.description.lowercased()

        if desc.contains("temperature") {
            if desc.contains("reduce") || desc.contains("lower") {
                return "I'm being more careful and precise with tasks — especially when you need structured answers."
            } else {
                return "I'm being a bit more creative in how I respond now."
            }
        }
        if desc.contains("maxrecallresults") || desc.contains("recall") {
            if desc.contains("increase") {
                return "I'm pulling in more context from our past conversations when answering."
            } else {
                return "I'm focusing on the most relevant memories instead of pulling in too much."
            }
        }

        return "I fine-tuned how I think about your requests."
    }

    // MARK: - Skill Descriptions

    private static func describeSkillChange(_ result: MetaOptResult) -> String? {
        let desc = result.description.lowercased()

        if desc.contains("tool-routing") || desc.contains("tool routing") {
            return "I picked up a better routine for finding your files and using tools — I'll check locally before searching the web."
        }
        if desc.contains("formatting") || desc.contains("precise-formatting") {
            return "I'm better at producing clean, structured data when you need JSON, XML, or other formats."
        }
        if desc.contains("memory-precision") || desc.contains("memory precision") {
            return "I'm being more careful about what I remember and how I use it in conversation."
        }
        if desc.contains("precise-execution") || desc.contains("instruction") {
            return "I'm following your instructions more carefully — completing every step you ask for."
        }
        if desc.contains("natural-conversation") || desc.contains("conversation quality") {
            return "I'm working on being more natural — matching your energy and not over-explaining."
        }

        return "I picked up a new routine that should help with \(extractTopicHint(desc))."
    }

    // MARK: - Memory Seed Descriptions

    private static func describeMemorySeedChange(_ result: MetaOptResult) -> String? {
        let desc = result.description.lowercased()

        if desc.contains("tool_preference") || desc.contains("tool") {
            return "I made a mental note about how you prefer to work — I'll check your files and calendar before reaching for web search."
        }
        if desc.contains("brevity") || desc.contains("concise") {
            return "I noted that you prefer shorter, more direct answers."
        }
        if desc.contains("directness") {
            return "I made a note to lead with the answer, not the reasoning."
        }
        if desc.contains("format") || desc.contains("serialization") {
            return "I reminded myself to be precise when you need structured output."
        }
        if desc.contains("instruction") {
            return "I made a note to always complete every step when you give me a list."
        }

        return "I made a mental note that should help me respond better."
    }

    // MARK: - Helpers

    /// Try to extract the MetaOptChange from the result description.
    /// Since MetaOptResult stores description but not the raw change,
    /// we parse keywords from the description string.
    private static func changeFromDescription(_ result: MetaOptResult) -> MetaOptChange? {
        // The result stores the hypothesis description, not the raw change.
        // We use keyword matching on the description instead.
        nil
    }

    /// Extract a topic hint from a description for generic fallback messages.
    private static func extractTopicHint(_ description: String) -> String {
        if description.contains("tool") { return "how I use tools" }
        if description.contains("format") { return "formatting" }
        if description.contains("memory") { return "how I use our conversation history" }
        if description.contains("conversation") { return "our conversations" }
        return "how I help you"
    }

    /// Describe a change using keywords from the hypothesis description.
    private static func describeFromKeywords(_ description: String) -> String {
        let lower = description.lowercased()
        if lower.contains("brevity") || lower.contains("interruption") {
            return "I trimmed how much I say — you seemed to prefer shorter answers."
        }
        if lower.contains("clarifi") || lower.contains("re-ask") {
            return "I'll check I understand what you mean before launching into a long answer."
        }
        if lower.contains("abandon") || lower.contains("relevance") {
            return "I'm focusing on answering your actual question first, then adding extras only if needed."
        }
        if lower.contains("correction") || lower.contains("misunderstand") {
            return "I'm paying closer attention to what you mean, so I don't misunderstand."
        }
        return "I adjusted how I respond based on our recent conversations."
    }
}

// MARK: - MetaOptNarrator Timeline Support

extension MetaOptNarrator {

    /// A single entry for the Settings UI improvement timeline.
    struct TimelineItem: Sendable, Identifiable {
        let id: String
        let date: Date
        let description: String
        let surface: MetaOptSurface
        let kept: Bool
        /// The hypothesis ID, used for rollback.
        let hypothesisId: String
    }

    /// Convert recent meta-opt log entries from ImprovementStore into timeline items.
    static func buildTimeline(from logEntries: [[String: Any]]) -> [TimelineItem] {
        logEntries.compactMap { entry in
            guard let surface = entry["surface"] as? String,
                  let description = entry["description"] as? String,
                  let createdAt = entry["created_at"] as? String,
                  let kept = entry["kept"] as? Bool else {
                return nil
            }

            let date = ISO8601DateFormatter().date(from: createdAt) ?? Date()
            let optSurface = MetaOptSurface(rawValue: surface) ?? .directive

            // Build the human-readable description.
            let humanDesc: String
            if kept {
                let mockResult = MetaOptResult(
                    hypothesisId: UUID(),
                    surface: optSurface,
                    description: description,
                    targetDimension: .faeCapability,
                    beforeScores: .empty,
                    afterScores: .empty,
                    delta: .empty,
                    kept: true,
                    reason: "",
                    timestamp: date
                )
                humanDesc = timelineEntry(mockResult)
            } else {
                humanDesc = "Tried a change but it didn't help — reverted"
            }

            return TimelineItem(
                id: (entry["hypothesis_id"] as? String) ?? UUID().uuidString,
                date: date,
                description: humanDesc,
                surface: optSurface,
                kept: kept,
                hypothesisId: (entry["hypothesis_id"] as? String) ?? ""
            )
        }
    }

    /// Format a surface name for display in the UI.
    static func surfaceDisplayName(_ surface: MetaOptSurface) -> String {
        switch surface {
        case .directive:  return "Habit"
        case .configKnob: return "Thinking"
        case .skill:      return "Routine"
        case .memorySeed: return "Mental Note"
        }
    }

    /// Icon name (SF Symbol) for each surface.
    static func surfaceIcon(_ surface: MetaOptSurface) -> String {
        switch surface {
        case .directive:  return "brain.head.profile"
        case .configKnob: return "slider.horizontal.3"
        case .skill:      return "sparkles"
        case .memorySeed: return "note.text"
        }
    }
}
