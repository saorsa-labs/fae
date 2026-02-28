import Foundation

/// Manages roleplay session state: active flag, title, and character-to-voice mappings.
///
/// Voice assignments are persisted to `roleplay_voices.json` keyed by session
/// title so that resuming a session with the same title restores previously
/// assigned character voices.
actor RoleplaySessionStore {
    static let shared = RoleplaySessionStore()

    private(set) var isActive: Bool = false
    private(set) var title: String?
    private(set) var characterVoices: [String: String] = [:]

    private let persistence = RoleplayVoicePersistence()

    /// Start a new roleplay session.
    ///
    /// If a session with the same title was previously used, saved voice
    /// assignments are automatically restored.
    func start(title: String?) -> String {
        self.isActive = true
        self.title = title
        // Restore saved voices for this title (if any).
        if let title {
            self.characterVoices = persistence.load(forTitle: title)
        } else {
            self.characterVoices = [:]
        }
        let label = title ?? "untitled"
        let restoredNote = characterVoices.isEmpty ? "" : " Restored \(characterVoices.count) saved voice(s)."
        return "Roleplay session started: \(label). Assign character voices with assign_voice.\(restoredNote)"
    }

    /// Assign a voice description to a character name.
    func assignVoice(character: String, description: String) -> String {
        let key = character.lowercased()
        characterVoices[key] = description
        // Persist updated voice assignments.
        if let title {
            persistence.save(voices: characterVoices, forTitle: title)
        }
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

// MARK: - Voice Persistence

/// Handles reading and writing roleplay voice assignments to disk.
///
/// Voice assignments are stored in a JSON file at:
/// `~/Library/Application Support/fae/roleplay_voices.json`
///
/// Structure:
/// ```json
/// {
///   "Session Title": {
///     "hamlet": "deep male voice, brooding, Shakespearean",
///     "narrator": "calm, measured, storytelling"
///   }
/// }
/// ```
private struct RoleplayVoicePersistence {

    private var fileURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("fae")
            .appendingPathComponent("roleplay_voices.json")
    }

    /// Load saved voice assignments for a given session title.
    ///
    /// Returns an empty dictionary if no saved data exists or the file is corrupt.
    func load(forTitle title: String) -> [String: String] {
        guard let url = fileURL else { return [:] }

        do {
            let data = try Data(contentsOf: url)
            let all = try JSONDecoder().decode([String: [String: String]].self, from: data)
            return all[title] ?? [:]
        } catch {
            // Missing file or corrupt data — start fresh (don't log missing file).
            if !((error as NSError).domain == NSCocoaErrorDomain
                && (error as NSError).code == NSFileReadNoSuchFileError)
            {
                NSLog("RoleplayVoicePersistence: load error: %@", error.localizedDescription)
            }
            return [:]
        }
    }

    /// Save voice assignments for a given session title.
    ///
    /// Merges with existing sessions on disk so other sessions are preserved.
    func save(voices: [String: String], forTitle title: String) {
        guard let url = fileURL else { return }

        // Load existing sessions first.
        var all: [String: [String: String]] = [:]
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        {
            all = decoded
        }

        // Update this session.
        all[title] = voices

        // Ensure directory exists.
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(all)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("RoleplayVoicePersistence: save error: %@", error.localizedDescription)
        }
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
    let example = #"<tool_call>{"name":"roleplay","arguments":{"action":"start","title":"Hamlet Act 3"}}</tool_call>"#

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
