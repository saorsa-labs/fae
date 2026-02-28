import Foundation

/// Manages roleplay session state: active flag, title, character-to-voice mappings,
/// and session persistence for auto-resume.
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
    private let sessionPersistence = RoleplaySessionPersistence()

    // MARK: - Session Lifecycle

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
        // Persist session state.
        saveSessionState()
        let label = title ?? "untitled"
        let restoredNote = characterVoices.isEmpty ? "" : " Restored \(characterVoices.count) saved voice(s)."
        return "Roleplay session started: \(label). Assign character voices with assign_voice.\(restoredNote)"
    }

    /// Resume the last active session.
    func resume() -> String {
        if let state = sessionPersistence.loadLastActive() {
            self.isActive = true
            self.title = state.title
            self.characterVoices = state.characterVoices
            let label = state.title ?? "untitled"
            return "Resumed roleplay session: \(label) with \(state.characterVoices.count) character voice(s)."
        }
        return "No previous session to resume."
    }

    /// Assign a voice description to a character name.
    func assignVoice(character: String, description: String) -> String {
        let key = character.lowercased()
        characterVoices[key] = description
        // Persist updated voice assignments.
        if let title {
            persistence.save(voices: characterVoices, forTitle: title)
        }
        saveSessionState()
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
        // Save final state before clearing.
        if isActive, let title {
            sessionPersistence.markInactive(title: title)
        }
        isActive = false
        title = nil
        characterVoices = [:]
        return "Roleplay session ended."
    }

    /// List past session history.
    func history() -> String {
        let sessions = sessionPersistence.listAll()
        if sessions.isEmpty { return "No session history." }
        let lines = sessions.map { state in
            let label = state.title ?? "untitled"
            let chars = state.characterVoices.count
            let active = state.isActive ? " (active)" : ""
            let date = state.lastActiveDate.map { Self.formatDate($0) } ?? ""
            return "- \(label)\(active): \(chars) character(s) \(date)"
        }
        return "Session history:\n" + lines.joined(separator: "\n")
    }

    // MARK: - Private

    private func saveSessionState() {
        let state = SessionState(
            isActive: isActive,
            title: title,
            characterVoices: characterVoices,
            lastActiveDate: Date(),
            positionMarker: nil
        )
        sessionPersistence.save(state)
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "(\(formatter.string(from: date)))"
    }
}

// MARK: - Session State

/// Codable session state for persistence and resume.
struct SessionState: Codable {
    var isActive: Bool
    var title: String?
    var characterVoices: [String: String]
    var lastActiveDate: Date?
    var positionMarker: String?
}

// MARK: - Session Persistence

/// Handles reading/writing roleplay session state to disk.
///
/// Sessions stored at: `~/Library/Application Support/fae/roleplay_sessions.json`
private struct RoleplaySessionPersistence {

    private var fileURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return appSupport
            .appendingPathComponent("fae")
            .appendingPathComponent("roleplay_sessions.json")
    }

    /// Load the last active session (if any).
    func loadLastActive() -> SessionState? {
        let all = loadAll()
        return all.first { $0.isActive }
    }

    /// List all sessions sorted by last active date (newest first).
    func listAll() -> [SessionState] {
        let all = loadAll()
        return all.sorted {
            ($0.lastActiveDate ?? .distantPast) > ($1.lastActiveDate ?? .distantPast)
        }
    }

    /// Save or update a session state.
    func save(_ state: SessionState) {
        // Skip persistence for untitled sessions to prevent unbounded growth.
        guard state.title != nil else { return }
        var all = loadAll()
        if let title = state.title, let idx = all.firstIndex(where: { $0.title == title }) {
            all[idx] = state
        } else {
            all.append(state)
        }
        writeAll(all)
    }

    /// Mark a session as inactive.
    func markInactive(title: String) {
        var all = loadAll()
        if let idx = all.firstIndex(where: { $0.title == title }) {
            all[idx].isActive = false
            all[idx].lastActiveDate = Date()
        }
        writeAll(all)
    }

    private func loadAll() -> [SessionState] {
        guard let url = fileURL else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([SessionState].self, from: data)
        } catch {
            return []
        }
    }

    private func writeAll(_ states: [SessionState]) {
        guard let url = fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(states)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("RoleplaySessionPersistence: save error: %@", error.localizedDescription)
        }
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
        Actions: start (begin session), resume (resume last session), \
        assign_voice (map character to voice description), \
        list_characters (show mappings), history (list past sessions), \
        save_voice (save character voice to global library), \
        load_voice (load voice from global library), \
        list_saved_voices (show global voice library), \
        preview_voice (speak sample with voice description), \
        stop (end session). \
        When active, use <voice character="Name">dialog</voice> tags in your response.
        """
    let parametersSchema = """
        {"action": "string (start|resume|assign_voice|list_characters|history|\
        save_voice|load_voice|list_saved_voices|preview_voice|stop)", \
        "title": "string (optional, for start)", \
        "character": "string (required for assign_voice/save_voice/load_voice)", \
        "voice_description": "string (required for assign_voice/preview_voice, under 50 words: gender, age, accent, style)", \
        "ref_audio_path": "string (optional for save_voice, path to WAV for voice cloning)"}
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

        case "resume":
            let result = await store.resume()
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

        case "history":
            let result = await store.history()
            return .success(result)

        case "save_voice":
            return await handleSaveVoice(input: input)

        case "load_voice":
            return await handleLoadVoice(input: input, store: store)

        case "list_saved_voices":
            return await handleListSavedVoices()

        case "preview_voice":
            guard let voiceDesc = input["voice_description"] as? String else {
                return .error("preview_voice requires: voice_description")
            }
            return .success("Preview requested for voice: \(voiceDesc). Use this description in a <voice> tag to hear it.")

        case "stop":
            let result = await store.stop()
            return .success(result)

        default:
            return .error("Unknown action: \(action). Use start, resume, assign_voice, list_characters, history, save_voice, load_voice, list_saved_voices, preview_voice, or stop.")
        }
    }

    // MARK: - Global Voice Library Actions

    private func handleSaveVoice(input: [String: Any]) async -> ToolResult {
        guard let character = input["character"] as? String else {
            return .error("save_voice requires: character")
        }

        let library = CharacterVoiceLibrary.shared
        let voiceDesc = input["voice_description"] as? String
        let refAudioPath = input["ref_audio_path"] as? String

        // Get voice from current session if not provided.
        let store = RoleplaySessionStore.shared
        let sessionVoice = await store.voiceForCharacter(character)
        let effectiveVoiceDesc = voiceDesc ?? sessionVoice

        var entry = CharacterVoiceEntry(name: character)
        entry.voiceInstruct = effectiveVoiceDesc
        entry.refAudioPath = refAudioPath
        entry.tags = []

        await library.save(entry)
        return .success("Saved voice for '\(character)' to global library.")
    }

    private func handleLoadVoice(input: [String: Any], store: RoleplaySessionStore) async -> ToolResult {
        guard let character = input["character"] as? String else {
            return .error("load_voice requires: character")
        }

        let library = CharacterVoiceLibrary.shared
        guard let entry = await library.find(name: character) else {
            return .error("No saved voice for '\(character)' in global library.")
        }

        if let voiceDesc = entry.voiceInstruct {
            _ = await store.assignVoice(character: character, description: voiceDesc)
            return .success("Loaded voice for '\(character)' from global library: \(voiceDesc)")
        }
        return .error("Voice entry for '\(character)' exists but has no instruct description.")
    }

    private func handleListSavedVoices() async -> ToolResult {
        let library = CharacterVoiceLibrary.shared
        let entries = await library.list()
        if entries.isEmpty {
            return .success("No saved voices in global library.")
        }
        let lines = entries.map { entry in
            var desc = "- \(entry.name)"
            if let vi = entry.voiceInstruct { desc += ": \(vi)" }
            if entry.refAudioPath != nil { desc += " [cloned]" }
            return desc
        }
        return .success("Global voice library:\n" + lines.joined(separator: "\n"))
    }
}
