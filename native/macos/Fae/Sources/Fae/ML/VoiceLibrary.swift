import Foundation

/// Manages a library of named voice profiles for Fae's TTS.
///
/// Each voice is a pair: `{name}.wav` + `{name}.json` metadata, stored
/// in `~/Library/Application Support/fae/voices/`.
actor VoiceLibrary {

    /// Metadata for a saved voice profile.
    struct VoiceProfile: Codable, Sendable {
        var name: String
        var referenceText: String?
        var description: String?
        var createdAt: Date
    }

    /// Directory for voice profiles.
    static let voicesDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("fae/voices")
    }()

    /// The name of the currently active default voice (if any).
    private var defaultVoiceName: String?

    /// Path to the default voice preference file.
    private var defaultsPath: URL {
        Self.voicesDirectory.appendingPathComponent(".default")
    }

    init() {
        // Load default voice preference.
        if let data = try? Data(contentsOf: Self.voicesDirectory.appendingPathComponent(".default")),
           let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty
        {
            defaultVoiceName = name
        }
    }

    // MARK: - CRUD

    /// List all saved voice profiles.
    func list() -> [VoiceProfile] {
        ensureDirectory()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.voicesDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var profiles: [VoiceProfile] = []
        for file in files where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix(".") {
            if let data = try? Data(contentsOf: file),
               let profile = try? JSONDecoder.faeDecoder.decode(VoiceProfile.self, from: data)
            {
                profiles.append(profile)
            }
        }
        return profiles.sorted { $0.name < $1.name }
    }

    /// Save a voice to the library.
    ///
    /// Copies the WAV file and creates a metadata JSON.
    func save(name: String, wavURL: URL, referenceText: String?, description: String? = nil) throws {
        ensureDirectory()
        let sanitized = sanitizeName(name)
        let destWAV = Self.voicesDirectory.appendingPathComponent("\(sanitized).wav")
        let destJSON = Self.voicesDirectory.appendingPathComponent("\(sanitized).json")

        let fm = FileManager.default
        if fm.fileExists(atPath: destWAV.path) {
            try fm.removeItem(at: destWAV)
        }
        try fm.copyItem(at: wavURL, to: destWAV)

        let profile = VoiceProfile(
            name: name,
            referenceText: referenceText,
            description: description,
            createdAt: Date()
        )
        let data = try JSONEncoder.faeEncoder.encode(profile)
        try data.write(to: destJSON, options: .atomic)
        NSLog("VoiceLibrary: saved voice '%@'", name)
    }

    /// Load a voice by name. Returns (wavURL, referenceText) or nil if not found.
    func load(name: String) -> (url: URL, referenceText: String?)? {
        let sanitized = sanitizeName(name)
        let wavPath = Self.voicesDirectory.appendingPathComponent("\(sanitized).wav")
        let jsonPath = Self.voicesDirectory.appendingPathComponent("\(sanitized).json")

        guard FileManager.default.fileExists(atPath: wavPath.path) else { return nil }

        var refText: String?
        if let data = try? Data(contentsOf: jsonPath),
           let profile = try? JSONDecoder.faeDecoder.decode(VoiceProfile.self, from: data)
        {
            refText = profile.referenceText
        }
        return (wavPath, refText)
    }

    /// Delete a voice from the library.
    func delete(name: String) throws {
        let sanitized = sanitizeName(name)
        let wavPath = Self.voicesDirectory.appendingPathComponent("\(sanitized).wav")
        let jsonPath = Self.voicesDirectory.appendingPathComponent("\(sanitized).json")

        let fm = FileManager.default
        if fm.fileExists(atPath: wavPath.path) { try fm.removeItem(at: wavPath) }
        if fm.fileExists(atPath: jsonPath.path) { try fm.removeItem(at: jsonPath) }

        if defaultVoiceName == name {
            defaultVoiceName = nil
            try? fm.removeItem(at: defaultsPath)
        }
        NSLog("VoiceLibrary: deleted voice '%@'", name)
    }

    /// Set a voice as the default.
    func setDefault(name: String) throws {
        let sanitized = sanitizeName(name)
        let wavPath = Self.voicesDirectory.appendingPathComponent("\(sanitized).wav")
        guard FileManager.default.fileExists(atPath: wavPath.path) else {
            throw NSError(domain: "VoiceLibrary", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Voice '\(name)' not found"])
        }
        defaultVoiceName = name
        try name.data(using: .utf8)?.write(to: defaultsPath, options: .atomic)
        NSLog("VoiceLibrary: set default voice to '%@'", name)
    }

    /// Get the current default voice name.
    func getDefault() -> String? { defaultVoiceName }

    // MARK: - Private

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: Self.voicesDirectory,
            withIntermediateDirectories: true
        )
    }

    /// Sanitize a voice name for use as a filename (lowercase, alphanumeric + hyphens).
    private func sanitizeName(_ name: String) -> String {
        let cleaned = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "-_")).inverted)
            .joined(separator: "-")
        return cleaned.isEmpty ? "unnamed" : cleaned
    }
}

// MARK: - JSON Coding Helpers

private extension JSONDecoder {
    static let faeDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension JSONEncoder {
    static let faeEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
