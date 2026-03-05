import Foundation

/// Manages HEARTBEAT.md — Fae's user-editable proactive behavior prompt contract.
///
/// Runtime cadence, timers, and safety gates still live in code/config. HEARTBEAT.md
/// is loaded fresh into the model prompt so edits change how Fae frames proactive behavior.
enum HeartbeatManager {
    static var userHeartbeatURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("fae/heartbeat.md")
    }

    static func defaultHeartbeat() -> String {
        if let url = Bundle.faeResources.url(forResource: "HEARTBEAT", withExtension: "md"),
           let content = try? String(contentsOf: url, encoding: .utf8),
           !content.isEmpty
        {
            return content
        }

        return """
            # HEARTBEAT.md
            - Be quiet by default.
            - Surface proactive help in brief, high-signal moments.
            - Prefer approvals in the popup before sending people into Settings.
            """
    }

    static func loadHeartbeat() -> String {
        let url = userHeartbeatURL
        if FileManager.default.fileExists(atPath: url.path),
           let content = try? String(contentsOf: url, encoding: .utf8),
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return content
        }
        return defaultHeartbeat()
    }

    static func saveHeartbeat(_ text: String) throws {
        let url = userHeartbeatURL
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func resetToDefault() throws {
        try saveHeartbeat(defaultHeartbeat())
    }

    static func ensureUserCopy() {
        let url = userHeartbeatURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try saveHeartbeat(defaultHeartbeat())
            NSLog("HeartbeatManager: copied default HEARTBEAT.md to %@", url.path)
        } catch {
            NSLog("HeartbeatManager: failed to copy default HEARTBEAT.md: %@", error.localizedDescription)
        }
    }

    static var isModified: Bool {
        let url = userHeartbeatURL
        guard FileManager.default.fileExists(atPath: url.path),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else { return false }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
            != defaultHeartbeat().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var lineCount: Int {
        loadHeartbeat().components(separatedBy: .newlines).count
    }
}
