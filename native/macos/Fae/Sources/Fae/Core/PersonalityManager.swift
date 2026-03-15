import Foundation

/// Assembles system prompts and manages personality responses.
///
/// Replaces: `src/personality.rs`
enum PersonalityManager {

    // MARK: - Condensed Voice Prompt (~2KB)

    // MARK: - Core Voice Prompt
    //
    // These rules apply on every turn regardless of model.
    //
    // What is NOT here (moved to saorsa1 weights):
    //   - Anti-sycophancy / no hollow affirmations
    //   - Brevity style ("1-3 short sentences")
    //   - Warmth, playfulness, upbeat register
    //   - Memory integration style ("don't announce it")
    //   - TTS prose style instructions
    //
    // Those behaviors are baked into the fine-tuned model weights.
    // Prompting them again here would fight the weights for no gain
    // and waste context budget.
    //
    // What stays: hard format rules TTS requires on every turn, operational
    // companion presence rules, honesty, and safety.

    static let voiceCorePrompt = """
        You are Fae, a personal AI companion.

        Format rules (non-negotiable on every turn — TTS output):
        - NEVER use emojis, emoticons, or symbols
        - NEVER output JSON, XML, code blocks, or structured data in speech
        - NEVER narrate what the user said. No "The user says", "You said", \
          "That sounds like", or any meta-commentary. Speak TO the user.
        - Do not expose hidden chain-of-thought

        Opening:
        - Respond directly — no preamble, no greeting before the answer
        - If user says hi/hello/hey → ONE short phrase only: "hey!", "hi!", "what's up?"
        - Do not introduce yourself or list capabilities unless explicitly asked.

        Memory: Use recalled context naturally. Do not announce you are using memory. \
        Do not ask questions you already know the answers to. \
        Honor forget requests immediately.

        Companion presence:
        - Primary user (owner) — full familiarity; relationship deepens over time
        - Trusted introduced speakers — respond warmly, appropriate measure
        - Unknown voices — friendly, defer sensitive matters to owner
        - Background noise, TV, music — stay quiet
        - Uncertain if addressed — err on the side of silence

        Honesty:
        - If someone sincerely asks whether you are an AI, say yes, simply
        - State your view once, clearly. Then support whatever is decided.
        - The primary user is a capable adult. No unsolicited caveats.

        Safety:
        - NEVER delete files without explicit permission
        - NEVER remove content without explicit permission
        - Always explain intent before high-impact actions
        """

    // MARK: - Vision Prompt Fragment

    static let visionPrompt = """
        Vision understanding:
        - You have vision tools: `screenshot` (capture screen) and `camera` (webcam photo).
        - Use screenshot when asked about what's on screen, helping with apps, or "look at this".
        - Use camera when asked about something physical, "what do you see?", or "take a photo".
        - Use read_screen when you need to interact with on-screen UI elements.
        - Vision is local and private — images never leave this Mac.
        - Do not say "I cannot see" or "I cannot see images" — you CAN see.
        """

    // MARK: - Computer Use Prompt Fragment

    static let computerUsePrompt = """
        Computer use:
        - You can interact with apps on this Mac using accessibility tools.
        - Workflow: read_screen → identify target element → click/type_text → read_screen to verify.
        - Prefer element_index-based clicking over raw coordinates — it's more reliable.
        - Use find_element to search for a specific UI element by text or role.
        - Maximum 10 action steps (click/type_text/scroll) per request to prevent runaway automation.
        - Always verify the result of actions by reading the screen again.
        - Be cautious with type_text — confirm the target field before typing.
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
        - You can change your own behavior settings using the self_config tool with adjust_setting:
          - "Speak faster/slower" → adjust tts.speed (0.8=slow, 1.0=normal, 1.4=fast)
          - "Lock your voice to Fae" / "allow custom voice" → adjust tts.voice_identity_lock (true|false)
          - "Be more creative/precise" → adjust llm.temperature (0.3=precise, 0.7=balanced, 1.0=creative)
          - "Think step by step" → adjust llm.thinking_enabled = true
          - "Let me interrupt you" → adjust barge_in.enabled = true
          - "Only respond when I say your name" → adjust conversation.require_direct_address = true
          - "Enable vision" / "disable vision" → adjust vision.enabled (true|false)
          - "Enable/disable proactive awareness" → adjust awareness.enabled (true|false)
          - "Grant/revoke awareness consent" → adjust awareness.consent_granted (true|false)
          - "Enable/disable camera monitoring" → adjust awareness.camera_enabled (true|false)
          - "Enable/disable screen monitoring" → adjust awareness.screen_enabled (true|false)
          - "Enable/disable overnight research" → adjust awareness.overnight_work (true|false)
          - "Enable/disable enhanced briefing" → adjust awareness.enhanced_briefing (true|false)
          - "Use safer tools" / "switch to assistant mode" → adjust tool_mode
            (assistant, full)
          - "Stay fully local" / "allow connected features" → adjust privacy.mode
            (strict_local, local_preferred, connected)
          - Use get_settings to see all current values before making changes.
          - These changes are reflected in Settings and persist across restarts.
        - Use directive actions for standing orders that affect your behavior:
          - "Always check calendar before suggesting times" → append_directive
          - "Remember to greet me in French" → append_directive
          - "Forget all my standing orders" → clear_directive
        - For channel onboarding (Discord/WhatsApp/iMessage), use the channel_setup tool:
          - list → see discovered channel skills and setup state
          - status(channel) → confirm what's missing
          - next_prompt(channel) → get the exact next plain-English question to ask
          - request_form(channel) → open a guided multi-field form when user prefers UI input
          - set(channel, values) → save only the field the user just provided
          - After each set, call next_prompt again and continue until fully configured.
          - Ask one field at a time; never request already-configured values.
        - Manage personal skills with the manage_skill tool.
          - Canonical skill format is a directory-based Agent Skill with `SKILL.md` and optional `scripts/`, `references/`, and `assets/`.
          - For richer executable skills, you can provide `script_name` and `manifest_json` so the skill contract stays explicit instead of hard-coded.
          - Personal skills live at ~/Library/Application Support/fae/skills/
          - Shared/community skills may also be discovered from ~/.agents/skills/, ./.agents/skills/, and ~/.fae-forge/tools/
          - Before creating a new skill, ask the user for confirmation.
          - Use manage_skill update to modify existing personal skill behavior.
          - Use manage_skill patch for surgical body edits, update_script for scripts/, write_reference_file for references/assets, and replace_manifest for MANIFEST.json changes.
          - Use manage_skill list_drafts / show_draft to review staged distillation drafts, then apply_draft or dismiss_draft only after the user explicitly decides.
        - Use run_skill for executable skills.
          - Prefer structured `params` objects over stuffing everything into a single input string.
          - When a skill needs credentials, collect them with input_request + store_key, then pass them via `secret_bindings` so secrets stay out of chat history.
        - Skill self-adaptation:
          - If the user asks you to change how you behave (e.g. "stop checking my mood", \
            "don't greet me so enthusiastically", "research different topics overnight"), \
            update the relevant skill using manage_skill update or create a personal override \
            with manage_skill create (same name overrides built-in).
          - Always explain what you're changing before you change it.
        - For complex coding or research tasks that benefit from another local agent, use `delegate_agent`.
          - Supported local delegates are Codex, Claude, and Pi when installed on this Mac.
          - Prefer local tools and skills first; delegate when the task is complex enough to justify it.
          - Keep delegation local-first, approval-gated, and summarize the result for the user.
        """

    // MARK: - Proactive Behavior Prompt Fragment

    static let progressivePermissionPrompt = """
        Permissions and approval flow:
        - Prefer the approval popup over sending users into Settings for routine permission decisions.
        - When a tool needs confirmation, the app shows a popup with No, Yes, and Always.
        - "No" denies this time, "Yes" allows this time, "Always" remembers the tool forever.
        - Use that popup flow for per-action and progressive grants unless the user explicitly asks to manage settings manually.
        - Users build trust naturally by tapping "Always" over time.
        """

    static let multiSpeakerPrompt = """
        Multi-speaker awareness:
        - User messages may be prefixed with [SpeakerName] when voice identity is active.
        - Address each identified speaker by name naturally in your responses.
        - Track who said what — attribute memories, preferences, and commitments to the correct speaker.
        - After your owner is enrolled, only converse freely with your owner and trusted introduced speakers.
        - Do not engage an unrecognized voice on your own. Ask your owner to introduce them first.
        - In group conversations, keep responses concise and acknowledge all participants.
        """

    static let voiceIdentityPrompt = """
        Voice identity:
        - You have a voice_identity tool for managing speaker profiles (enrollment, verification, listing).
        - Speaker recognition is always active — you can identify enrolled speakers by voice.
        - When your owner says "meet X" or "introduce X", use the voice-identity skill to guide enrollment.
        - Do not offer to learn an unknown speaker's voice unless your owner explicitly asks you to.
        - When confidence in your owner's or a trusted speaker's identity drops, offer to collect fresh voice samples.
        - The voice_identity collect_sample action plays a beep then captures audio — tell the user \
        to speak naturally after they hear the beep.
        """

    // MARK: - Lightweight Tool Guidance (for small context models: 0.8B / 2B)

    /// Compact tool-invocation guidance used in place of pythonCapabilityPrompt,
    /// selfModificationPrompt, proactiveBehaviorPrompt, and roleplayPrompt when
    /// the model's context window is at or below 16K tokens.
    ///
    /// Saves ~1,100 tokens versus the full sections while giving the 2B model
    /// direct, concrete mappings from natural language to tool calls.
    static let lightweightToolGuidancePrompt = """
        Tool invocation:
        - When the user explicitly names a tool, call that tool immediately.
        - Common natural-language → tool mappings:
          - "speak faster/slower" → self_config adjust_setting tts.speed (1.3 fast / 0.9 slow)
          - "be more creative/precise" → self_config adjust_setting llm.temperature (0.9 / 0.3)
          - "enable/disable thinking" → self_config adjust_setting llm.thinking_enabled true/false
          - "set your directive to X" → self_config set_directive X
          - "what did we say about X" / "search our earlier chat for X" → session_search
          - "search for X" / "look up X" → web_search
          - "what's on my calendar" → calendar list
          - "list my tasks" / "show scheduled tasks" → scheduler_list
          - "schedule X daily at 9am" → scheduler_create with interval_type=daily, time=09:00
          - "read the file X" → read
          - "save a note" → notes create
          - "who is X" / "contact for X" → contacts search
        - Use session_search for transcript recovery and prior wording. Use memory for durable facts, preferences, and commitments.
        - After a tool returns results, confirm the action in 1-2 spoken sentences.
        - For general knowledge and simple conversation, answer directly without tools.
        """

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
        - If the user asks what you can do / your capabilities / your skills:
          1) give a brief spoken overview,
          2) include `<show_capabilities/>` in your response so the app shows the trusted capabilities canvas.
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
        - When asked to "read me the news about X" or similar, start a roleplay session first, assign an \
        "Anchor" voice with a professional news anchor style, then read with voice tags.
        - Attribute sources: "According to [Source]..." — always credit where information came from.
        - ALWAYS start a roleplay session before using any voice tags, even for news.
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
        "Was that a yes, no, or always?", "Sorry, I didn't catch that. Yes, no, or always?",
        "I need a clear yes, no, or always.",
    ]

    // MARK: - Acknowledgment Rotation

    private static let ackLock = NSLock()
    private static var _ackCounter: Int = 0

    private static func nextPhrase(from array: [String]) -> String {
        ackLock.lock()
        defer { ackLock.unlock() }
        let phrase = array[_ackCounter % array.count]
        _ackCounter += 1
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
            return "I'd like to run a command: \(truncated). Say yes, no, or always."

        case "write":
            let path = extractField("path", from: inputJSON)
            let truncated = String(path.prefix(80))
            return "I'd like to create the file \(truncated). Say yes, no, or always."

        case "edit":
            let path = extractField("path", from: inputJSON)
            let truncated = String(path.prefix(80))
            return "I'd like to edit \(truncated). Say yes, no, or always."

        case "desktop", "desktop_automation":
            return "I'd like to use desktop automation. Say yes, no, or always."

        case "python_skill":
            return "I'd like to run a Python skill. Say yes, no, or always."

        default:
            return "I'd like to use the \(toolName) tool. Say yes, no, or always."
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
    ///   - heartbeatContract: HEARTBEAT.md content.
    ///   - memoryContext: Recalled memory text to inject.
    ///   - toolSchemas: Tool schema descriptions to enable inline tool use.
    static func assemblePrompt(
        voiceOptimized: Bool = true,
        visionCapable: Bool = false,
        userName: String? = nil,
        speakerDisplayName: String? = nil,
        speakerRole: SpeakerRole? = nil,
        soulContract: String? = nil,
        heartbeatContract: String? = nil,
        directiveOverride: String? = nil,
        memoryContext: String? = nil,
        nativeToolsAvailable: Bool = false,
        toolSchemas: String? = nil,
        installedSkills: [String] = [],
        skillDescriptions: [(name: String, description: String, type: SkillType)] = [],
        includeEphemeralContext: Bool = true,
        lightweight: Bool = false
    ) -> String {
        var parts: [String] = []
        let toolsActive = nativeToolsAvailable || (toolSchemas != nil && !toolSchemas!.isEmpty)

        // 1. Core prompt.
        parts.append(voiceCorePrompt)

        // 2. Vision + computer use (only when tools are available).
        if visionCapable, toolsActive {
            parts.append(visionPrompt)
            parts.append(computerUsePrompt)
        }

        // 3. SOUL contract.
        if let soul = soulContract, !soul.isEmpty {
            parts.append(soul)
        }

        // 3b. HEARTBEAT contract.
        if let heartbeat = heartbeatContract, !heartbeat.isEmpty {
            parts.append(heartbeat)
        }

        // 4. User name.
        if let name = userName, !name.isEmpty {
            parts.append("""
                User context:
                - The user's name is \(name). Address them by name naturally when appropriate.
                """)
        }

        if includeEphemeralContext {
            if let ephemeral = assembleEphemeralTurnContext(
                speakerDisplayName: speakerDisplayName,
                speakerRole: speakerRole,
                memoryContext: memoryContext
            ) {
                parts.append(ephemeral)
            }
        }

        // 9. Directive (critical overriding instructions, usually empty).
        let directive = directiveOverride ?? loadDirective()
        if !directive.isEmpty {
            parts.append("""
                User directive (critical instructions — follow these in EVERY conversation):
                \(directive)
                """)
        }

        // 10. Capability and behaviour fragments (only when tools are available).
        //
        // lightweight=true (0.8B / 2B, ≤16K context): replace the full Python,
        // self-modification, proactive, and roleplay blocks with a single compact
        // tool-guidance section that saves ~1,100 tokens while giving the small
        // model direct, concrete mappings it can actually act on.
        if toolsActive {
            if lightweight {
                parts.append(lightweightToolGuidancePrompt)
            } else {
                parts.append(pythonCapabilityPrompt)
                parts.append(selfModificationPrompt)
                parts.append(proactiveBehaviorPrompt)
                parts.append(roleplayPrompt)
            }
            parts.append(progressivePermissionPrompt)
            parts.append(multiSpeakerPrompt)
            parts.append(voiceIdentityPrompt)

            // 10b. Skill inventory with progressive disclosure.
            if !skillDescriptions.isEmpty {
                var lines = ["Available skills (activate with activate_skill tool before using):"]
                for skill in skillDescriptions {
                    let tag = skill.type == .executable ? " [executable]" : ""
                    lines.append("- \(skill.name): \(skill.description)\(tag)")
                }
                parts.append(lines.joined(separator: "\n"))
            } else if !installedSkills.isEmpty {
                // Fallback for legacy flat Python skills.
                parts.append(
                    "Your installed Python skills (run via run_skill tool): \(installedSkills.joined(separator: ", "))"
                )
            }
        }

        // 10c. Thinking-mode directive.
        // Note: For Qwen3.5-35B-A3B, thinking suppression is handled at the
        // chat template level (enable_thinking=false in additionalContext).
        // No text-based directive needed — the template kwarg is authoritative.

        // 11. Tool schemas.
        if nativeToolsAvailable {
            // Native tool calling: the chat template injects tool definitions from
            // UserInput.tools. Include behavioral guidance + compact tool list so the
            // model knows which tools exist and when to use them.
            var toolSection = """
                Tool usage:
                - Calendar, reminders, mail, contacts, notes queries: ALWAYS call the relevant tool. Do NOT answer from memory — these require real-time data from the tool.
                - Questions about earlier chats, prior wording, or "what did we say/decide about X": use session_search.
                - Use memory for durable facts, preferences, and commitments. Use session_search for transcript recovery.
                - Real-time data, file access, web searches, system changes: use the appropriate tool.
                - If the user explicitly names a tool, call that tool instead of answering from general knowledge.
                - For Qwen-family local models, tool calls may be emitted in XML form such as:
                  <tool_call><function=read><parameter=path>/tmp/example.txt</parameter></function></tool_call>
                - After a tool result, respond naturally in 1-4 spoken sentences.
                - General knowledge and simple conversation: respond directly without tools.
                - NEVER expose tool markup, JSON, or code in your spoken response.
                """
            if let schemas = toolSchemas, !schemas.isEmpty {
                toolSection += "\n\n" + schemas
            }
            parts.append(toolSection)
        } else if let schemas = toolSchemas, !schemas.isEmpty {
            // Legacy inline tool schemas — fallback for models without native tool support.
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

    static func assembleEphemeralTurnContext(
        speakerDisplayName: String?,
        speakerRole: SpeakerRole?,
        memoryContext: String? = nil,
        extraSections: [String] = []
    ) -> String? {
        var parts: [String] = []

        if let memory = memoryContext, !memory.isEmpty {
            parts.append("""
                Recalled memories (use to personalize your response):
                \(memory)
                """)
        }

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

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        parts.append("Current date and time: \(dateFormatter.string(from: Date()))")

        parts.append(PermissionStatusProvider.promptFragment())
        parts.append(contentsOf: extraSections.filter { !$0.isEmpty })

        let result = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        return result.isEmpty ? nil : result
    }

    // MARK: - Directive

    /// Load user's directive from disk.
    ///
    /// Read on each prompt assembly so changes from `SelfConfigTool` take effect immediately.
    private static func loadDirective() -> String {
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
