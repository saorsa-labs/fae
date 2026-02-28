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

    // MARK: - Vision Prompt Fragment

    static let visionPrompt = """
        Vision understanding:
        - When a camera image is attached, you can see it.
        - Do not say "I cannot see images"
        - Visual analysis is local and private
        """

    // MARK: - Python / uv Prompt Fragment

    static let pythonCapabilityPrompt = """
        Python scripting:
        - You can write and run Python scripts using `uv` (an ultra-fast Python package manager).
        - `uv` is installed and available from your bash tool.
        - For standalone scripts with dependencies, use PEP 723 inline metadata:
          ```python
          #!/usr/bin/env -S uv run --script
          # /// script
          # requires-python = ">=3.12"
          # dependencies = ["requests", "rich"]
          # ///
          import requests
          from rich import print
          # ... your code ...
          ```
        - Run scripts with: `uv run script.py` (auto-installs dependencies in an isolated env)
        - For quick one-off scripts with no dependencies: `uv run script.py` or `python3 script.py`
        - For installing packages: `uv pip install package_name`
        - Write scripts to ~/Library/Application Support/fae/scripts/ for persistence
        - ALWAYS use `uv run` instead of `pip install` + `python3` — it handles environments automatically
        - Use Python when a task benefits from it: data processing, web scraping, API calls, file conversion, automation
        """

    // MARK: - Self-Modification Prompt Fragment

    static let selfModificationPrompt = """
        Self-modification:
        - You can change your own behavior and communication style using the self_config tool.
        - When the user says things like "be more cheerful", "less chatty", "speak formally", \
        "remember to always greet me" — use self_config to save those preferences.
        - Use set_instructions to replace all preferences, append_instructions to add new ones.
        - Your custom instructions persist across conversations.
        - You can also manage your own Python skills:
          - Skills live at ~/Library/Application Support/fae/skills/ (one .py file per skill)
          - Write new skills using the write tool, test via bash with `uv run --script`
          - Run installed skills via the run_skill tool (by name, no need to construct paths)
          - Skills use PEP 723 inline metadata for dependencies
          - You can read, edit, or delete your own skills to improve your capabilities
        - Before creating a new Python skill, tell the user what you plan to build and ask: \
        "I could create a skill for [description]. Want me to go ahead?"
        - Only proceed with skill creation if the user confirms.
        - After creating and testing a skill, tell the user it's installed and what it does.
        - When asked to learn a new ability, write a Python skill for it.
        """

    // MARK: - Proactive Behavior Prompt Fragment

    static let proactiveBehaviorPrompt = """
        Proactive intelligence:
        - You are genuinely interested in your user's life, work, and interests.
        - Actively look for ways to help — search for relevant news, updates, and information.
        - When the user mentions interests, projects, or deadlines, remember them and follow up.
        - During quiet hours (overnight), research topics the user cares about.
        - In morning conversations, gently share what you've found: "By the way, I looked into X \
        and found..." — never dump a wall of info.
        - Use web_search proactively when you think the user would benefit from current info.
        - Track commitments: if the user says "I need to do X by Friday", remember and remind.
        - Suggest skills you could learn (Python scripts) to better serve the user.
        - Noise control: limit proactive items to 1-2 per conversation start. Save the rest for \
        when asked.
        """

    // MARK: - Roleplay Prompt Fragment

    static let roleplayPrompt = """
        Roleplay reading:
        - Use the roleplay tool to manage character voice sessions for plays, scripts, books, or news.
        - First: start a session, then assign_voice for each character with distinct voice descriptions.
        - Voice descriptions should specify gender, age, accent, and speaking style (under 50 words).
        - Use specific descriptive words: deep, crisp, fast-paced, resonant, breathy, gravelly.
        - Combine multiple dimensions: pitch + speed + emotion + accent (e.g. "Deep male British voice, slow and measured, with gravitas").
        - Avoid vague terms like "nice", "normal", "good" — be specific about voice characteristics.
        - Then read using <voice character="Name">dialog</voice> tags. Text outside tags is narration (your natural voice).
        - Keep voice assignments consistent — same character always gets the same voice.
        - You can resume previous sessions by title using the resume action.
        - Save frequently-used character voices to the global library with save_voice for reuse across sessions.
        - After finishing, stop the session.

        News reading:
        - When asked to "read me the news about X" or similar, search for relevant articles, then read with a professional \
        news anchor style using <voice character="Anchor">headline text</voice> tags.
        - Attribute sources: "According to [Source]..." — always credit where information came from.
        - No roleplay session needed for news — just use voice tags inline.
        """

    // MARK: - Acknowledgment Arrays

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

    private static func nextPhrase(from array: [String]) -> String {
        let phrase = array[ackCounter % array.count]
        ackCounter += 1
        return phrase
    }

    static func nextThinkingAcknowledgment() -> String { nextPhrase(from: thinkingAcknowledgments) }
    static func nextApprovalGranted() -> String { nextPhrase(from: approvalGranted) }
    static func nextApprovalDenied() -> String { nextPhrase(from: approvalDenied) }
    static func nextApprovalTimeout() -> String { nextPhrase(from: approvalTimeout) }
    static func nextApprovalAmbiguous() -> String { nextPhrase(from: approvalAmbiguous) }

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
    ///   - toolSchemas: Tool schema descriptions to enable inline tool use.
    static func assemblePrompt(
        voiceOptimized: Bool = true,
        visionCapable: Bool = false,
        userName: String? = nil,
        speakerDisplayName: String? = nil,
        speakerRole: SpeakerRole? = nil,
        soulContract: String? = nil,
        memoryContext: String? = nil,
        toolSchemas: String? = nil,
        installedSkills: [String] = []
    ) -> String {
        var parts: [String] = []

        // 1. Core prompt.
        parts.append(voiceCorePrompt)

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

        // 6. Speaker identity context.
        if let name = speakerDisplayName {
            let roleDesc: String
            switch speakerRole {
            case .owner:
                roleDesc = "your owner"
            case .trusted:
                roleDesc = "a trusted speaker"
            case .guest:
                roleDesc = "an unregistered speaker"
            case .faeSelf, .none:
                roleDesc = "unknown"
            }
            parts.append("The current speaker is \(name) (\(roleDesc)).")
        } else {
            parts.append("The speaker has not been identified.")
        }

        // 7. Current date/time.
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        parts.append("Current date and time: \(dateFormatter.string(from: Date()))")

        // 8. Permission context.
        parts.append(PermissionStatusProvider.promptFragment())

        // 9. Custom user instructions (persisted personality preferences).
        let customInstructions = loadCustomInstructions()
        if !customInstructions.isEmpty {
            parts.append("""
                User's style preferences (follow these closely):
                \(customInstructions)
                """)
        }

        // 10. Python / uv capability + self-modification + proactive behavior + roleplay (only when tools are available).
        if toolSchemas != nil {
            parts.append(pythonCapabilityPrompt)
            parts.append(selfModificationPrompt)
            parts.append(proactiveBehaviorPrompt)
            parts.append(roleplayPrompt)

            // 10b. Installed skill inventory — lets the LLM know what it can already do.
            if !installedSkills.isEmpty {
                parts.append(
                    "Your installed Python skills (run via run_skill tool): \(installedSkills.joined(separator: ", "))"
                )
            }
        }

        // 11. Tool schemas (enables inline tool use via <tool_call> markup).
        if let schemas = toolSchemas, !schemas.isEmpty {
            parts.append("""
                Tool usage:
                - When a task requires a tool, output a tool call in this exact format:
                  <tool_call>{"name":"tool_name","arguments":{"key":"value"}}</tool_call>
                - Wait for the tool result before continuing
                - After receiving a tool result, respond naturally in spoken language
                - Only use tools when the user's request genuinely needs one
                - For simple conversation, just respond directly without tools
                - Keep your spoken responses concise (1-4 sentences)
                - NEVER expose raw tool call markup or JSON to the user

                Available tools:
                \(schemas)
                """)
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Custom Instructions

    /// Load user's custom personality instructions from disk.
    ///
    /// Read on each prompt assembly so changes from `SelfConfigTool` take effect immediately.
    private static func loadCustomInstructions() -> String {
        SelfConfigTool.readInstructions()
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
