import Foundation

/// Manages roleplay session state: active flag, title, and character-to-voice mappings.
actor RoleplaySessionStore {
    static let shared = RoleplaySessionStore()

    private(set) var isActive: Bool = false
    private(set) var title: String?
    private(set) var characterVoices: [String: String] = [:]

    /// Start a new roleplay session, clearing any previous state.
    func start(title: String?) -> String {
        self.isActive = true
        self.title = title
        self.characterVoices = [:]
        let label = title ?? "untitled"
        return "Roleplay session started: \(label). Assign character voices with assign_voice."
    }

    /// Assign a voice description to a character name.
    func assignVoice(character: String, description: String) -> String {
        let key = character.lowercased()
        characterVoices[key] = description
        return "Voice assigned: \(character) → \(description)"
    }

    /// List all current character-to-voice mappings.
    func listCharacters() -> String {
        guard !characterVoices.isEmpty else {
            return "No characters assigned yet."
        }
        let lines = characterVoices.sorted(by: { $0.key < $1.key })
            .map { "- \($0.key): \($0.value)" }
        return "Characters:\n" + lines.joined(separator: "\n")
    }

    /// Look up the voice instruct description for a character (case-insensitive).
    func voiceForCharacter(_ name: String) -> String? {
        characterVoices[name.lowercased()]
    }

    /// Stop the current roleplay session.
    func stop() -> String {
        isActive = false
        title = nil
        characterVoices = [:]
        return "Roleplay session ended."
    }
}

// MARK: - Roleplay Tool

/// Tool for managing multi-voice roleplay reading sessions.
///
/// When active, the LLM uses `<voice character="Name">dialog</voice>` tags
/// inline during generation. The pipeline's `VoiceTagStripper` parses these
/// and routes each segment to TTS with the appropriate voice description.
struct RoleplayTool: Tool {
    let name = "roleplay"
    let description = """
        Manage a roleplay reading session with distinct character voices. \
        Actions: start (begin session), assign_voice (map character to voice description), \
        list_characters (show mappings), stop (end session). \
        When active, use <voice character="Name">dialog</voice> tags in your response.
        """
    let parametersSchema = """
        {"action": "string (start|assign_voice|list_characters|stop)", \
        "title": "string (optional, for start)", \
        "character": "string (required for assign_voice)", \
        "voice_description": "string (required for assign_voice, under 50 words: gender, age, accent, style)"}
        """
    let requiresApproval = false

    func execute(input: [String: Any]) async throws -> ToolResult {
        guard let action = input["action"] as? String else {
            return .error("Missing required parameter: action")
        }

        let store = RoleplaySessionStore.shared

        switch action {
        case "start":
            let title = input["title"] as? String
            let result = await store.start(title: title)
            return .success(result)

        case "assign_voice":
            guard let character = input["character"] as? String,
                  let voiceDesc = input["voice_description"] as? String
            else {
                return .error("assign_voice requires: character, voice_description")
            }
            let result = await store.assignVoice(character: character, description: voiceDesc)
            return .success(result)

        case "list_characters":
            let result = await store.listCharacters()
            return .success(result)

        case "stop":
            let result = await store.stop()
            return .success(result)

        default:
            return .error("Unknown action: \(action). Use start, assign_voice, list_characters, or stop.")
        }
    }
}
