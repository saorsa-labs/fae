import Foundation

// MARK: - MetaOptSkillGenerator

/// Generates instruction-only skill candidates from capability gaps and feedback patterns.
///
/// Phase 2 of meta-optimization: when feedback events cluster around a missing capability
/// that could be addressed by injecting structured instructions into the LLM context,
/// this generator proposes a skill that can be tested against FaeBenchmark.
///
/// ## Safety
/// - Only generates `instruction` type skills (no executable scripts)
/// - Skills are created in the personal directory and can be deleted on rollback
/// - Names are prefixed with `auto-` to distinguish from user-created skills
/// - Skill body size is capped at 2000 characters
///
/// ## Skill Templates
/// Each template addresses a category of capability gap with structured LLM instructions.
/// Templates are designed to be general-purpose — they improve behavior across many
/// conversations, not just for specific benchmark questions.
enum MetaOptSkillGenerator {

    // MARK: - Configuration

    /// Prefix for auto-generated skill names (distinguishes from user skills).
    static let autoSkillPrefix = "auto-"

    /// Maximum body size for generated skills (chars).
    static let maxSkillBodySize = 2000

    /// Minimum evidence count in capability_gaps before generating a skill.
    static let minGapEvidence = 3

    // MARK: - Skill Templates

    /// A template for generating a skill from a capability gap category.
    struct SkillTemplate: Sendable {
        /// Gap category this template addresses (matches CapabilityGap.category).
        let category: String
        /// The skill name to create (will be prefixed with `auto-`).
        let skillName: String
        /// Human-readable description for SKILL.md frontmatter.
        let description: String
        /// The instruction body for SKILL.md.
        let body: String
        /// Which benchmark dimension this skill primarily improves.
        let targetDimension: EvalDimension
    }

    /// Built-in templates for common capability gap categories.
    static let templates: [SkillTemplate] = [
        // Tool usage patterns
        SkillTemplate(
            category: "tool_selection",
            skillName: "smart-tool-routing",
            description: "Guides tool selection: prefer local tools over web, check files before searching, use calendar before asking about schedule.",
            body: """
                # Smart Tool Routing

                When the user asks a question, follow this tool selection priority:

                ## Local-First Rule
                - Questions about the user's projects, files, or code → use `read`, `bash`, or `edit` first
                - Questions about the user's schedule → use `calendar` before asking
                - Questions about contacts → use `contacts` before guessing
                - Only use `web_search` when the answer genuinely requires external information

                ## Multi-Step Patterns
                - For scheduling: check calendar → check contacts → create event
                - For file operations: read first → understand → then modify
                - For research: check memory first → then web search → summarize findings

                ## Avoid
                - Do not use `web_search` for questions about the user's own life, projects, or preferences
                - Do not call tools speculatively — have a clear reason for each call
                - Do not chain more than 3 tool calls without explaining intermediate results
                """,
            targetDimension: .toolCalling
        ),

        // Structured output quality
        SkillTemplate(
            category: "structured_output",
            skillName: "precise-formatting",
            description: "Ensures clean JSON/XML/YAML output with valid syntax, complete fields, and correct escaping.",
            body: """
                # Precise Formatting

                When asked to produce structured output (JSON, XML, YAML, or any specified format):

                ## Rules
                1. Output ONLY the requested format — no surrounding text, no markdown fences unless asked
                2. Include ALL required fields — never omit a field even if the value is empty (use null/empty string)
                3. Escape special characters correctly (quotes in JSON, & in XML, colons in YAML)
                4. Validate mentally before outputting: would a parser accept this?

                ## JSON Specifics
                - Always use double quotes for keys and string values
                - Use null (not "null" or None) for missing values
                - Numbers and booleans are unquoted

                ## XML Specifics
                - Always close tags, even self-closing ones
                - Escape &, <, >, ", ' in text content
                - Include XML declaration if asked for a complete document

                ## YAML Specifics
                - Use consistent indentation (2 spaces)
                - Quote strings that contain special characters (: { } [ ] , & * ? | - < > = ! % @ `)
                - Use block scalars (| or >) for multi-line strings
                """,
            targetDimension: .serialization
        ),

        // Memory discipline
        SkillTemplate(
            category: "memory_discipline",
            skillName: "memory-precision",
            description: "Improves memory recall usage: verify facts before stating, distinguish remembered from inferred, update stale information.",
            body: """
                # Memory Precision

                When using recalled memories to answer questions:

                ## Verification
                - If memory context includes a fact, state it with confidence
                - If memory is absent for something the user likely told you, say "I don't have that noted" rather than guessing
                - If memory seems outdated (old dates, past events), acknowledge the recency: "Last I noted, ..."

                ## Superseding
                - When the user provides new information that contradicts memory, acknowledge the update explicitly
                - Profile facts (name, preferences) from memory supersede guesses — use them
                - When multiple memories conflict, prefer the most recent one

                ## What Not To Do
                - Never fabricate memories — if you don't remember, say so
                - Never state a memory as absolute truth if the confidence is low
                - Never ignore recalled context — it was retrieved for a reason
                """,
            targetDimension: .faeCapability
        ),

        // Instruction following
        SkillTemplate(
            category: "instruction_following",
            skillName: "precise-execution",
            description: "Strengthens instruction following: complete all steps, respect constraints, don't add unrequested extras.",
            body: """
                # Precise Execution

                When the user gives specific instructions:

                ## Complete Every Step
                - If the user lists steps 1-5, execute ALL five — don't stop at step 3
                - If the user asks for "X and Y", provide BOTH X and Y
                - Check your response against the original request before finishing

                ## Respect Constraints
                - "Only" means exclude everything else
                - "Don't" means never, not "unless it seems helpful"
                - Word limits and format requirements are hard constraints, not suggestions

                ## No Unrequested Extras
                - Don't add disclaimers, caveats, or "also consider..." unless asked
                - Don't suggest alternatives when the user specified what they want
                - Don't explain your reasoning unless asked — just do the thing
                """,
            targetDimension: .assistantFit
        ),

        // Conversation quality
        SkillTemplate(
            category: "conversation_quality",
            skillName: "natural-conversation",
            description: "Improves conversational flow: match user energy, vary response length, avoid robotic patterns.",
            body: """
                # Natural Conversation

                ## Match Energy
                - Short question → short answer (don't over-explain)
                - Detailed question → detailed answer (don't under-deliver)
                - Casual tone ��� casual response
                - Technical question → precise technical answer

                ## Response Length
                - Default to 2-3 sentences for simple questions
                - Expand only when the topic genuinely requires it
                - If the user interrupted your last response, your next response should be shorter

                ## Avoid Robotic Patterns
                - Don't start every response with "Sure!" or "Of course!"
                - Don't end every response with "Let me know if you need anything else"
                - Vary your openings and closings naturally
                - Don't echo the question back before answering
                """,
            targetDimension: .assistantFit
        ),
    ]

    // MARK: - Hypothesis Generation

    /// Generate skill creation hypotheses from capability gaps and feedback patterns.
    ///
    /// - Parameters:
    ///   - gaps: Unaddressed capability gaps from improvement store.
    ///   - events: Feedback events from the current cycle.
    ///   - existingSkillNames: Names of all currently discovered skills (to avoid duplicates).
    /// - Returns: Skill creation hypotheses, sorted by gap evidence count.
    static func generateHypotheses(
        from gaps: [CapabilityGap],
        events: [FeedbackEvent],
        existingSkillNames: Set<String>
    ) -> [MetaOptHypothesis] {
        var hypotheses: [MetaOptHypothesis] = []

        // Strategy 1: Match capability gaps to skill templates.
        for gap in gaps where gap.evidenceCount >= minGapEvidence && !gap.addressed {
            guard let template = templates.first(where: { $0.category == gap.category }) else {
                continue
            }

            let fullName = autoSkillPrefix + template.skillName
            guard !existingSkillNames.contains(fullName) else { continue }

            hypotheses.append(MetaOptHypothesis(
                id: UUID(),
                surface: .skill,
                description: "Create '\(fullName)' skill for capability gap: \(gap.description)",
                targetDimension: template.targetDimension,
                change: .skillCreation(
                    name: fullName,
                    description: template.description,
                    body: template.body
                ),
                evidenceCount: gap.evidenceCount
            ))
        }

        // Strategy 2: Infer gaps from feedback patterns when no explicit gap exists.
        let toolFailures = events.filter {
            $0.signalType == "correction" && isToolRelated($0)
        }
        if toolFailures.count >= minGapEvidence {
            let name = autoSkillPrefix + "smart-tool-routing"
            if !existingSkillNames.contains(name),
               !hypotheses.contains(where: { skillName(from: $0) == name }) {
                let template = templates.first { $0.skillName == "smart-tool-routing" }!
                hypotheses.append(MetaOptHypothesis(
                    id: UUID(),
                    surface: .skill,
                    description: "Create '\(name)' — \(toolFailures.count) tool-related corrections detected",
                    targetDimension: .toolCalling,
                    change: .skillCreation(
                        name: name,
                        description: template.description,
                        body: template.body
                    ),
                    evidenceCount: toolFailures.count
                ))
            }
        }

        let serializationFailures = events.filter {
            $0.signalType == "correction" && isSerializationRelated($0)
        }
        if serializationFailures.count >= minGapEvidence {
            let name = autoSkillPrefix + "precise-formatting"
            if !existingSkillNames.contains(name),
               !hypotheses.contains(where: { skillName(from: $0) == name }) {
                let template = templates.first { $0.skillName == "precise-formatting" }!
                hypotheses.append(MetaOptHypothesis(
                    id: UUID(),
                    surface: .skill,
                    description: "Create '\(name)' — \(serializationFailures.count) serialization corrections detected",
                    targetDimension: .serialization,
                    change: .skillCreation(
                        name: name,
                        description: template.description,
                        body: template.body
                    ),
                    evidenceCount: serializationFailures.count
                ))
            }
        }

        return hypotheses.sorted { $0.evidenceCount > $1.evidenceCount }
    }

    // MARK: - Helpers

    /// Extract the skill name from a hypothesis (if it's a skill creation).
    private static func skillName(from hypothesis: MetaOptHypothesis) -> String? {
        if case .skillCreation(let name, _, _) = hypothesis.change {
            return name
        }
        return nil
    }

    private static func isToolRelated(_ event: FeedbackEvent) -> Bool {
        let text = (event.userInput ?? "") + (event.assistantOutput ?? "")
        let lower = text.lowercased()
        return lower.contains("tool") || lower.contains("calendar") ||
               lower.contains("reminder") || lower.contains("search") ||
               lower.contains("tool_call") || lower.contains("<tool_call>")
    }

    private static func isSerializationRelated(_ event: FeedbackEvent) -> Bool {
        let text = (event.userInput ?? "") + (event.assistantOutput ?? "")
        let lower = text.lowercased()
        return lower.contains("json") || lower.contains("xml") ||
               lower.contains("yaml") || lower.contains("format") ||
               lower.contains("structured")
    }
}
