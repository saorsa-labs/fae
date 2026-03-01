import CryptoKit
import Foundation

/// Append-only local security event logger.
///
/// Writes JSONL events to `~/Library/Application Support/fae/security-events.jsonl`.
actor SecurityEventLogger {
    static let shared = SecurityEventLogger()

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let iso = ISO8601DateFormatter()
    private let maxBytes = 5 * 1024 * 1024
    private let rotateCount = 3

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        self.fileURL = appSupport
            .appendingPathComponent("fae")
            .appendingPathComponent("security-events.jsonl")

        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func log(
        event: String,
        toolName: String,
        decision: String? = nil,
        reasonCode: String? = nil,
        approved: Bool? = nil,
        success: Bool? = nil,
        error: String? = nil,
        arguments: [String: Any]? = nil
    ) {
        let argsHash = arguments.flatMap { Self.hashArguments($0) }
        let redactedError = SensitiveDataRedactor.redact(error)
        let record = SecurityEventRecord(
            id: UUID().uuidString,
            timestamp: iso.string(from: Date()),
            event: event,
            toolName: toolName,
            decision: decision,
            reasonCode: reasonCode,
            approved: approved,
            success: success,
            error: redactedError,
            argumentsHash: argsHash
        )

        do {
            let data = try encoder.encode(record)
            var line = data
            line.append(0x0A) // \n
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }

            if !isForensicModeEnabled() {
                try rotateIfNeeded()
            }

            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            NSLog("SecurityEventLogger: failed to append event: %@", error.localizedDescription)
        }
    }

    private func isForensicModeEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: "fae.security.forensicMode")
    }

    private func rotateIfNeeded() throws {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue >= maxBytes
        else {
            return
        }

        let fm = FileManager.default

        // Shift older archives: .2 -> .3, .1 -> .2
        if rotateCount > 1 {
            for idx in stride(from: rotateCount - 1, through: 1, by: -1) {
                let src = fileURL.appendingPathExtension("\(idx)")
                let dst = fileURL.appendingPathExtension("\(idx + 1)")
                if fm.fileExists(atPath: dst.path) {
                    try? fm.removeItem(at: dst)
                }
                if fm.fileExists(atPath: src.path) {
                    try? fm.moveItem(at: src, to: dst)
                }
            }
        }

        let firstArchive = fileURL.appendingPathExtension("1")
        if fm.fileExists(atPath: firstArchive.path) {
            try? fm.removeItem(at: firstArchive)
        }
        try? fm.moveItem(at: fileURL, to: firstArchive)
        fm.createFile(atPath: fileURL.path, contents: nil)
    }

    private static func hashArguments(_ args: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]) else {
            return nil
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct SecurityEventRecord: Codable {
    let id: String
    let timestamp: String
    let event: String
    let toolName: String
    let decision: String?
    let reasonCode: String?
    let approved: Bool?
    let success: Bool?
    let error: String?
    let argumentsHash: String?
}
