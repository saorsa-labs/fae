import Foundation

// MARK: - MetaOptHypothesisGenerator

/// Generates ranked hypotheses for meta-optimization from feedback patterns.
///
/// Phase 1 uses pattern-based analysis (no LLM required). Each pattern detector
/// maps a cluster of feedback events to a concrete, testable hypothesis about
/// what change to directive or config would improve benchmark scores.
///
/// Hypotheses are ranked by evidence count (most evidence = try first) so the
/// meta-optimizer tests the most promising candidates within its budget.
///
/// ## Pattern Detectors
/// - Tool-related corrections → lower temperature for structured output
/// - Frequent re-asks → increase memory recall or add conciseness directive
/// - Systematic interruptions → brevity directive
/// - Abandonments → clarification directive
/// - Follow-through praise → preserve what works (no changes for this cluster)
enum MetaOptHypothesisGenerator {

    // MARK: - Configuration

    /// Minimum evidence count for a pattern to produce a hypothesis.
    static let minimumEvidence = 3

    /// Maximum directive amendment length (chars). Keeps amendments concise.
    static let maxAmendmentLength = 200

    /// Maximum total directive size before refusing to append.
    static let maxDirectiveSize = 4000

    // MARK: - Public API

    /// Generate ranked hypotheses from feedback events and current config state.
    ///
    /// - Parameters:
    ///   - events: Unconsumed feedback events from the current cycle.
    ///   - currentDirective: Current directive.md content (for size checks and dedup).
    ///   - currentTemperature: Current LLM temperature setting.
    ///   - currentMaxRecall: Current memory.maxRecallResults setting.
    /// - Returns: Hypotheses sorted by evidence count (descending).
    static func generate(
        from events: [FeedbackEvent],
        currentDirective: String?,
        currentTemperature: Double,
        currentMaxRecall: Int
    ) -> [MetaOptHypothesis] {
        var hypotheses: [MetaOptHypothesis] = []

        let directiveSize = (currentDirective ?? "").count

        // Cluster events by signal type.
        let corrections = events.filter { $0.signalType == "correction" }
        let reasks = events.filter { $0.signalType == "re_ask" }
        let interruptions = events.filter { $0.signalType == "interruption" }
        let abandonments = events.filter { $0.signalType == "abandonment" }

        // --- Tool-related correction patterns → config + directive ---

        let toolCorrections = corrections.filter { isToolRelated($0) }
        if toolCorrections.count >= minimumEvidence && currentTemperature > 0.4 {
            let newTemp = max(currentTemperature - 0.2, 0.3)
            hypotheses.append(MetaOptHypothesis(
                id: UUID(),
                surface: .configKnob,
                description: "Tool call failures (\(toolCorrections.count) corrections) — reduce temperature from \(currentTemperature) to \(newTemp)",
                targetDimension: .toolCalling,
                change: .configAdjustment(
                    key: "llm.temperature",
                    oldValue: String(currentTemperature),
                    newValue: String(newTemp)
                ),
                evidenceCount: toolCorrections.count
            ))
        }

        // --- Re-ask patterns → memory recall + directive ---

        if reasks.count >= minimumEvidence {
            // Hypothesis 1: Increase memory recall to provide more context.
            if currentMaxRecall < 10 {
                let newRecall = min(currentMaxRecall + 2, 12)
                hypotheses.append(MetaOptHypothesis(
                    id: UUID(),
                    surface: .configKnob,
                    description: "Frequent re-asks (\(reasks.count)) — increase maxRecallResults from \(currentMaxRecall) to \(newRecall)",
                    targetDimension: .faeCapability,
                    change: .configAdjustment(
                        key: "memory.maxRecallResults",
                        oldValue: String(currentMaxRecall),
                        newValue: String(newRecall)
                    ),
                    evidenceCount: reasks.count
                ))
            }

            // Hypothesis 2: Directive to confirm understanding before acting.
            if directiveSize + 120 <= maxDirectiveSize {
                let amendment = "\n[auto-tuned: when the request is ambiguous, ask a clarifying question before responding at length]"
                if !directiveAlreadyContains(currentDirective, keywords: ["clarifying question", "confirm understanding"]) {
                    hypotheses.append(MetaOptHypothesis(
                        id: UUID(),
                        surface: .directive,
                        description: "Frequent re-asks (\(reasks.count)) — add clarification directive",
                        targetDimension: .assistantFit,
                        change: .directiveAmendment(amendment),
                        evidenceCount: reasks.count
                    ))
                }
            }
        }

        // --- Interruption patterns → brevity directive ---

        if interruptions.count >= minimumEvidence {
            if directiveSize + 100 <= maxDirectiveSize {
                let amendment = "\n[auto-tuned: keep responses concise, prefer 2-3 sentences unless detail is explicitly requested]"
                if !directiveAlreadyContains(currentDirective, keywords: ["concise", "shorter", "brief"]) {
                    hypotheses.append(MetaOptHypothesis(
                        id: UUID(),
                        surface: .directive,
                        description: "Frequent interruptions (\(interruptions.count)) — add brevity directive",
                        targetDimension: .assistantFit,
                        change: .directiveAmendment(amendment),
                        evidenceCount: interruptions.count
                    ))
                }
            }
        }

        // --- Abandonment patterns → relevance directive ---

        if abandonments.count >= minimumEvidence {
            if directiveSize + 130 <= maxDirectiveSize {
                let amendment = "\n[auto-tuned: address the user's actual question directly before offering additional context or caveats]"
                if !directiveAlreadyContains(currentDirective, keywords: ["address", "actual question", "directly"]) {
                    hypotheses.append(MetaOptHypothesis(
                        id: UUID(),
                        surface: .directive,
                        description: "Topic abandonments (\(abandonments.count)) — add relevance-first directive",
                        targetDimension: .assistantFit,
                        change: .directiveAmendment(amendment),
                        evidenceCount: abandonments.count
                    ))
                }
            }
        }

        // --- Non-tool correction patterns → understanding directive ---

        let nonToolCorrections = corrections.filter { !isToolRelated($0) }
        if nonToolCorrections.count >= minimumEvidence {
            if directiveSize + 110 <= maxDirectiveSize {
                let amendment = "\n[auto-tuned: pay close attention to user phrasing and confirm understanding before taking action]"
                if !directiveAlreadyContains(currentDirective, keywords: ["confirm understanding", "close attention"]) {
                    hypotheses.append(MetaOptHypothesis(
                        id: UUID(),
                        surface: .directive,
                        description: "Systematic misunderstanding (\(nonToolCorrections.count) corrections) — add understanding directive",
                        targetDimension: .faeCapability,
                        change: .directiveAmendment(amendment),
                        evidenceCount: nonToolCorrections.count
                    ))
                }
            }
        }

        // --- Serialization-related failures → lower temperature ---

        let serializationCorrections = corrections.filter { isSerializationRelated($0) }
        if serializationCorrections.count >= minimumEvidence && currentTemperature > 0.3 {
            let newTemp = max(currentTemperature - 0.3, 0.1)
            hypotheses.append(MetaOptHypothesis(
                id: UUID(),
                surface: .configKnob,
                description: "Serialization failures (\(serializationCorrections.count)) — reduce temperature from \(currentTemperature) to \(newTemp)",
                targetDimension: .serialization,
                change: .configAdjustment(
                    key: "llm.temperature",
                    oldValue: String(currentTemperature),
                    newValue: String(newTemp)
                ),
                evidenceCount: serializationCorrections.count
            ))
        }

        // Sort by evidence count (most evidence first = highest confidence).
        return hypotheses.sorted { $0.evidenceCount > $1.evidenceCount }
    }

    // MARK: - Signal Classification

    /// Heuristic: does this feedback event relate to tool calling?
    private static func isToolRelated(_ event: FeedbackEvent) -> Bool {
        let text = (event.userInput ?? "") + (event.assistantOutput ?? "")
        let lower = text.lowercased()
        return lower.contains("tool") ||
               lower.contains("function") ||
               lower.contains("calendar") ||
               lower.contains("reminder") ||
               lower.contains("search") ||
               lower.contains("web_search") ||
               lower.contains("tool_call") ||
               lower.contains("<tool_call>")
    }

    /// Heuristic: does this feedback event relate to structured output?
    private static func isSerializationRelated(_ event: FeedbackEvent) -> Bool {
        let text = (event.userInput ?? "") + (event.assistantOutput ?? "")
        let lower = text.lowercased()
        return lower.contains("json") ||
               lower.contains("xml") ||
               lower.contains("yaml") ||
               lower.contains("format") ||
               lower.contains("parse") ||
               lower.contains("structured")
    }

    /// Check if the current directive already contains keywords suggesting a similar amendment.
    private static func directiveAlreadyContains(_ directive: String?, keywords: [String]) -> Bool {
        guard let directive, !directive.isEmpty else { return false }
        let lower = directive.lowercased()
        return keywords.contains { lower.contains($0.lowercased()) }
    }
}
