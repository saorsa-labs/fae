import Foundation

/// A reusable character voice entry in the global voice library.
struct CharacterVoiceEntry: Codable, Sendable {
    var name: String
    var voiceInstruct: String?
    var presetSpeaker: String?
    var refAudioPath: String?
    var refText: String?
    var tags: [String] = []
}

/// Global character voice library — reusable voice profiles across roleplay sessions.
///
/// Storage: `~/Library/Application Support/fae/character_voices.json`
actor CharacterVoiceLibrary {
    static let shared = CharacterVoiceLibrary()

    private var entries: [CharacterVoiceEntry] = []
    private var loaded = false

    private var fileURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return appSupport
            .appendingPathComponent("fae")
            .appendingPathComponent("character_voices.json")
    }

    // MARK: - CRUD

    /// List all entries, sorted by name.
    func list() -> [CharacterVoiceEntry] {
        ensureLoaded()
        return entries.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Find a character voice by name (case-insensitive).
    func find(name: String) -> CharacterVoiceEntry? {
        ensureLoaded()
        return entries.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Save or update a character voice entry.
    func save(_ entry: CharacterVoiceEntry) {
        ensureLoaded()
        let key = entry.name.lowercased()
        if let idx = entries.firstIndex(where: { $0.name.lowercased() == key }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        persist()
    }

    /// Delete a character voice by name.
    func delete(name: String) {
        ensureLoaded()
        entries.removeAll { $0.name.lowercased() == name.lowercased() }
        persist()
    }

    // MARK: - Persistence

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let url = fileURL else { return }
        do {
            let data = try Data(contentsOf: url)
            entries = try JSONDecoder().decode([CharacterVoiceEntry].self, from: data)
        } catch {
            // Missing file is fine — start with empty library.
            entries = []
        }
    }

    private func persist() {
        guard let url = fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("CharacterVoiceLibrary: save error: %@", error.localizedDescription)
        }
    }
}
