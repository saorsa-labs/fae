import Foundation

// MARK: - MetaOptMemorySeedGenerator

/// Generates strategic meta-memory seeds from feedback patterns.
///
/// Phase 3 of meta-optimization: when feedback events suggest the LLM would benefit
/// from having specific heuristic knowledge available during recall, this generator
/// proposes memory facts that will be retrieved in relevant conversations.
///
/// Unlike directive amendments (which are always present in the prompt), memory seeds
/// are only recalled when the hybrid ANN+FTS5 search finds them relevant to the current
/// query. This makes them a lighter-touch optimization surface — they shape behavior
/// contextually rather than globally.
///
/// ## Safety
/// - Seeds are stored as `fact` kind with `meta_opt_seed` tag for identification
/// - Seeds have a `staleAfterSecs` of 30 days — they expire if not reinforced
/// - Seeds can be deleted by memory ID on rollback
/// - Maximum 10 active seeds at any time to prevent memory pollution
enum MetaOptMemorySeedGenerator {

    // MARK: - Configuration

    /// Tag applied to all auto-generated memory seeds.
    static let seedTag = "meta_opt_seed"

    /// Maximum active seeds before refusing to add more.
    static let maxActiveSeeds = 10

    /// Stale-after duration: 30 days in seconds.
    static let staleAfterSecs: UInt64 = 30 * 24 * 3600

    /// Minimum feedback evidence to generate a seed.
    static let minEvidence = 4

    // MARK: - Seed Templates

    struct SeedTemplate: Sendable {
        /// What feedback pattern this addresses.
        let pattern: String
        /// The memory text to seed.
        let text: String
        /// Tags for the memory record (always includes `meta_opt_seed`).
        let tags: [String]
        /// Which dimension this is expected to improve.
        let targetDimension: EvalDimension
    }

    /// Built-in seed templates mapped to feedback signal clusters.
    static let templates: [SeedTemplate] = [
        // Tool preference seeds
        SeedTemplate(
            pattern: "tool_preference_local",
            text: "When asked about local projects or files, prefer file tools (read, bash, edit) over web_search. Check locally first.",
            tags: [seedTag, "tool_guidance"],
            targetDimension: .toolCalling
        ),
        SeedTemplate(
            pattern: "tool_preference_calendar",
            text: "When the user asks about their schedule or availability, always check calendar first before asking clarifying questions.",
            tags: [seedTag, "tool_guidance"],
            targetDimension: .toolCalling
        ),

        // Response style seeds
        SeedTemplate(
            pattern: "brevity_preference",
            text: "The user prefers concise responses. Default to 2-3 sentences unless they ask for detail.",
            tags: [seedTag, "style_guidance"],
            targetDimension: .assistantFit
        ),
        SeedTemplate(
            pattern: "directness_preference",
            text: "Address the user's question directly before offering context. Lead with the answer, not the reasoning.",
            tags: [seedTag, "style_guidance"],
            targetDimension: .assistantFit
        ),

        // Precision seeds
        SeedTemplate(
            pattern: "format_precision",
            text: "When producing JSON, XML, or YAML, output only the structured data — no surrounding text or markdown fences unless asked.",
            tags: [seedTag, "format_guidance"],
            targetDimension: .serialization
        ),
        SeedTemplate(
            pattern: "instruction_precision",
            text: "When given multi-step instructions, complete every step. Check the response against the original request before finishing.",
            tags: [seedTag, "behavior_guidance"],
            targetDimension: .faeCapability
        ),
    ]

    // MARK: - Hypothesis Generation

    /// Generate memory seed hypotheses from feedback patterns.
    ///
    /// - Parameters:
    ///   - events: Feedback events from the current cycle.
    ///   - existingSeedCount: Number of currently active meta_opt_seed records.
    /// - Returns: Memory seed hypotheses.
    static func generateHypotheses(
        from events: [FeedbackEvent],
        existingSeedCount: Int
    ) -> [MetaOptHypothesis] {
        guard existingSeedCount < maxActiveSeeds else {
            return []  // Don't pollute memory with too many seeds.
        }

        var hypotheses: [MetaOptHypothesis] = []
        let remainingSlots = maxActiveSeeds - existingSeedCount

        // Analyze feedback patterns.
        let corrections = events.filter { $0.signalType == "correction" }
        let reasks = events.filter { $0.signalType == "re_ask" }
        let interruptions = events.filter { $0.signalType == "interruption" }
        let abandonments = events.filter { $0.signalType == "abandonment" }

        // Tool-related corrections → tool preference seed.
        let toolCorrections = corrections.filter { isToolRelated($0) }
        if toolCorrections.count >= minEvidence {
            if let template = templates.first(where: { $0.pattern == "tool_preference_local" }) {
                hypotheses.append(makeHypothesis(from: template, evidence: toolCorrections.count))
            }
        }

        // Re-asks about schedule/calendar → calendar preference seed.
        let scheduleReasks = reasks.filter { isScheduleRelated($0) }
        if scheduleReasks.count >= minEvidence {
            if let template = templates.first(where: { $0.pattern == "tool_preference_calendar" }) {
                hypotheses.append(makeHypothesis(from: template, evidence: scheduleReasks.count))
            }
        }

        // Interruptions → brevity preference seed.
        if interruptions.count >= minEvidence {
            if let template = templates.first(where: { $0.pattern == "brevity_preference" }) {
                hypotheses.append(makeHypothesis(from: template, evidence: interruptions.count))
            }
        }

        // Abandonments → directness preference seed.
        if abandonments.count >= minEvidence {
            if let template = templates.first(where: { $0.pattern == "directness_preference" }) {
                hypotheses.append(makeHypothesis(from: template, evidence: abandonments.count))
            }
        }

        // Serialization corrections → format precision seed.
        let serializationCorrections = corrections.filter { isSerializationRelated($0) }
        if serializationCorrections.count >= minEvidence {
            if let template = templates.first(where: { $0.pattern == "format_precision" }) {
                hypotheses.append(makeHypothesis(from: template, evidence: serializationCorrections.count))
            }
        }

        // General corrections → instruction precision seed.
        if corrections.count >= minEvidence * 2 {
            if let template = templates.first(where: { $0.pattern == "instruction_precision" }) {
                hypotheses.append(makeHypothesis(from: template, evidence: corrections.count))
            }
        }

        // Limit to remaining memory slots.
        return Array(hypotheses.sorted { $0.evidenceCount > $1.evidenceCount }.prefix(remainingSlots))
    }

    // MARK: - Helpers

    private static func makeHypothesis(from template: SeedTemplate, evidence: Int) -> MetaOptHypothesis {
        MetaOptHypothesis(
            id: UUID(),
            surface: .memorySeed,
            description: "Seed memory: \(template.pattern) (\(evidence) events)",
            targetDimension: template.targetDimension,
            change: .memorySeedInsertion(text: template.text, tags: template.tags),
            evidenceCount: evidence
        )
    }

    static func isToolRelated(_ event: FeedbackEvent) -> Bool {
        let text = (event.userInput ?? "") + (event.assistantOutput ?? "")
        let lower = text.lowercased()
        return lower.contains("tool") || lower.contains("calendar") ||
               lower.contains("search") || lower.contains("tool_call")
    }

    static func isScheduleRelated(_ event: FeedbackEvent) -> Bool {
        let text = (event.userInput ?? "") + (event.assistantOutput ?? "")
        let lower = text.lowercased()
        return lower.contains("schedule") || lower.contains("calendar") ||
               lower.contains("meeting") || lower.contains("appointment")
    }

    static func isSerializationRelated(_ event: FeedbackEvent) -> Bool {
        let text = (event.userInput ?? "") + (event.assistantOutput ?? "")
        let lower = text.lowercased()
        return lower.contains("json") || lower.contains("xml") ||
               lower.contains("yaml") || lower.contains("format")
    }
}
