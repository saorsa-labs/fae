import Foundation

/// Assembles system prompts and manages personality responses.
///
/// Replaces: `src/personality.rs`
enum PersonalityManager {

    // MARK: - Condensed Voice Prompt (~2KB)

    static let voiceCorePrompt = """
        You are Fae, a proactive personal AI assistant.

        Core style:
        - Be concise by default (1-3 short sentences)
        - Be direct and practical. Natural warmth, brightness, playfulness. Upbeat and cheery.
        - Do not expose hidden chain-of-thought
        - NEVER use emojis, emoticons, or special symbols — TTS output
        - NEVER output JSON, XML, tool calls, code blocks, or any structured data format

        Opening style:
        - Respond directly — no preamble, no greeting before answer
        - Greeting rule: if user says hi/hello/hey/howdy → ONE short phrase ONLY
          Acceptable: "hey!", "hi!", "what's up?", "heya!", "hey, good to hear you."
        - Do not introduce yourself. Do not list capabilities.

        You are here for your user. Be their friend. Help guide them. Be genuinely interested \
        in their life. Remember what matters to them.

        Memory: Use context to personalize responses. Don't invent memories you don't have. \
        Honor forget requests immediately.

        Companion presence:
        - Always present and listening, like a friend in the room
        - Direct address — respond naturally and fully
        - Background noise, TV, music — stay quiet
        - Uncertain if addressed — err on the side of silence
        - Silence is respectful presence, not failure

        Safety:
        - NEVER delete files without explicit permission
        - NEVER remove content without explicit permission
        - Always explain intent before high-impact actions
        """

    // MARK: - Background Agent Prompt

    static let backgroundAgentPrompt = """
        You are a task executor for Fae, a voice AI assistant. Execute the user's request \
        with minimum tool calls. Your output will be spoken aloud by TTS, so:
        - Keep responses under 4 sentences
        - Use natural spoken language (no markdown, no code blocks, no JSON)
        - MUST always speak a result (never finish silently)
        - On success: state what was done concisely ("Done, I have set that up.")
        - On failure: explain briefly ("I could not create that because...")
        - No follow-up questions — complete the task or explain why you can't
        """

    // MARK: - Vision Prompt Fragment

    static let visionPrompt = """
        Vision understanding:
        - When a camera image is attached, you can see it.
        - Do not say "I cannot see images"
        - Visual analysis is local and private
        """

    // MARK: - Acknowledgment Arrays

    static let toolAcknowledgments = [
        "Checking that now.", "On it.", "Let me look into that.",
        "One moment.", "Working on that.", "Give me a second.",
        "Looking that up.", "Let me see.",
    ]

    static let thinkingAcknowledgments = [
        "Let me think about that.", "Thinking.",
        "Give me a moment to work that out.",
        "That's a good question, let me reason through it.",
        "Let me consider that carefully.", "Hmm, let me think.",
        "Working through that now.", "Hold on, I need to think this through.",
    ]

    static let approvalGranted = [
        "Got it, running that now.", "On it.",
        "Alright, going ahead.", "Okay, executing that.",
    ]

    static let approvalDenied = [
        "Understood, I won't do that.", "Okay, skipping that.",
        "Alright, cancelled.", "Got it, I'll leave that alone.",
    ]

    static let approvalTimeout = [
        "I'll skip that for now.", "No response, so I'll move on.",
        "Timed out waiting, I won't run that.",
    ]

    static let approvalAmbiguous = [
        "Was that a yes or no?", "Sorry, I didn't catch that. Yes or no?",
        "I need a clear yes or no.",
    ]

    // MARK: - Acknowledgment Rotation

    private static var ackCounter: Int = 0

    static func nextToolAcknowledgment() -> String {
        let phrase = toolAcknowledgments[ackCounter % toolAcknowledgments.count]
        ackCounter += 1
        return phrase
    }

    static func nextThinkingAcknowledgment() -> String {
        let phrase = thinkingAcknowledgments[ackCounter % thinkingAcknowledgments.count]
        ackCounter += 1
        return phrase
    }

    static func nextApprovalGranted() -> String {
        let phrase = approvalGranted[ackCounter % approvalGranted.count]
        ackCounter += 1
        return phrase
    }

    static func nextApprovalDenied() -> String {
        let phrase = approvalDenied[ackCounter % approvalDenied.count]
        ackCounter += 1
        return phrase
    }

    static func nextApprovalTimeout() -> String {
        let phrase = approvalTimeout[ackCounter % approvalTimeout.count]
        ackCounter += 1
        return phrase
    }

    static func nextApprovalAmbiguous() -> String {
        let phrase = approvalAmbiguous[ackCounter % approvalAmbiguous.count]
        ackCounter += 1
        return phrase
    }

    // MARK: - Approval Prompt Formatting

    /// Format a human-readable approval prompt for a tool invocation.
    static func formatApprovalPrompt(toolName: String, inputJSON: String) -> String {
        switch toolName {
        case "bash":
            let cmd = extractField("command", from: inputJSON)
            let truncated = String(cmd.prefix(60))
            return "I'd like to run a command: \(truncated). Say yes or no."

        case "write":
            let path = extractField("path", from: inputJSON)
            let truncated = String(path.prefix(80))
            return "I'd like to create the file \(truncated). Say yes or no."

        case "edit":
            let path = extractField("path", from: inputJSON)
            let truncated = String(path.prefix(80))
            return "I'd like to edit \(truncated). Say yes or no."

        case "desktop", "desktop_automation":
            return "I'd like to use desktop automation. Say yes or no."

        case "python_skill":
            return "I'd like to run a Python skill. Say yes or no."

        default:
            return "I'd like to use the \(toolName) tool. Say yes or no."
        }
    }

    // MARK: - Prompt Assembly

    /// Assemble the full system prompt.
    ///
    /// - Parameters:
    ///   - voiceOptimized: Use condensed voice prompt (strips tools/skills).
    ///   - visionCapable: Include vision prompt fragment.
    ///   - userName: User's name for personalization.
    ///   - soulContract: SOUL.md content.
    ///   - memoryContext: Recalled memory text to inject.
    static func assemblePrompt(
        voiceOptimized: Bool = true,
        visionCapable: Bool = false,
        userName: String? = nil,
        soulContract: String? = nil,
        memoryContext: String? = nil
    ) -> String {
        var parts: [String] = []

        // 1. Core prompt.
        if voiceOptimized {
            parts.append(voiceCorePrompt)
        } else {
            // Full prompt would be loaded from Prompts/system_prompt.md bundle resource.
            // For now, use the voice prompt as fallback.
            parts.append(voiceCorePrompt)
        }

        // 2. Vision.
        if visionCapable {
            parts.append(visionPrompt)
        }

        // 3. SOUL contract.
        if let soul = soulContract, !soul.isEmpty {
            parts.append(soul)
        }

        // 4. User name.
        if let name = userName, !name.isEmpty {
            parts.append("""
                User context:
                - The user's name is \(name). Address them by name naturally when appropriate.
                """)
        }

        // 5. Memory context.
        if let memory = memoryContext, !memory.isEmpty {
            parts.append("""
                Recalled memories (use to personalize your response):
                \(memory)
                """)
        }

        // 6. Permission context.
        parts.append(PermissionStatusProvider.promptFragment())

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Private Helpers

    /// Extract a JSON field value (simple string extraction, not full parsing).
    private static func extractField(_ field: String, from json: String) -> String {
        // Simple pattern: "field": "value"
        let pattern = "\"\(field)\"\\s*:\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: json,
                range: NSRange(json.startIndex..., in: json)
              ),
              let range = Range(match.range(at: 1), in: json)
        else {
            return "(unknown)"
        }
        return String(json[range])
    }
}
