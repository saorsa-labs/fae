import Foundation

@MainActor
final class CoworkRemoteModelCatalog: ObservableObject {
    static let shared = CoworkRemoteModelCatalog()

    struct Entry: Codable, Equatable, Sendable {
        let providerPresetID: String
        let baseURL: String
        let models: [String]
        let refreshedAt: Date
    }

    @Published private(set) var entries: [String: Entry] = [:]

    private let storageURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = appSupport.appendingPathComponent("fae", isDirectory: true)
        self.storageURL = directory.appendingPathComponent("cowork-remote-model-catalog.json")
        self.entries = Self.loadEntries(from: storageURL)
    }

    nonisolated static let defaultFreshnessTTL: TimeInterval = 60 * 60 * 12

    func entry(providerPresetID: String, baseURL: String) -> Entry? {
        let key = cacheKey(providerPresetID: providerPresetID, baseURL: baseURL)
        return entries[key]
    }

    func cachedModels(providerPresetID: String, baseURL: String, maxAge: TimeInterval? = nil) -> [String] {
        guard let entry = entry(providerPresetID: providerPresetID, baseURL: baseURL) else { return [] }
        if let maxAge, !isFresh(entry: entry, maxAge: maxAge) {
            return []
        }
        return entry.models
    }

    func isFresh(entry: Entry, maxAge: TimeInterval = defaultFreshnessTTL) -> Bool {
        Date().timeIntervalSince(entry.refreshedAt) <= maxAge
    }

    func update(providerPresetID: String, baseURL: String, models: [String]) {
        let normalizedModels = models
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let key = cacheKey(providerPresetID: providerPresetID, baseURL: baseURL)
        entries[key] = Entry(
            providerPresetID: providerPresetID,
            baseURL: baseURL,
            models: normalizedModels,
            refreshedAt: Date()
        )
        persist()
    }

    private func cacheKey(providerPresetID: String, baseURL: String) -> String {
        "\(providerPresetID.lowercased())::\(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private func persist() {
        do {
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // Best-effort cache only.
        }
    }

    private static func loadEntries(from url: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else {
            return [:]
        }
        return decoded
    }
}
