import Foundation

/// Writes debug events to `/tmp/fae-debug.jsonl` as newline-delimited JSON.
///
/// Each line: `{"seq":N,"ts":"ISO8601","kind":"LLM","text":"..."}`
///
/// Activated via `DebugConsoleController.fileLoggerCallback` when the test
/// server is running. Zero overhead when callback is not set.
@MainActor
final class DebugFileLogger {
    private let fileHandle: FileHandle?
    private let isoFormatter: ISO8601DateFormatter

    static let logPath = "/tmp/fae-debug.jsonl"

    init() {
        isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Create or truncate the log file
        FileManager.default.createFile(atPath: Self.logPath, contents: nil)
        fileHandle = FileHandle(forWritingAtPath: Self.logPath)
        fileHandle?.seekToEndOfFile()

        NSLog("DebugFileLogger: writing to %@", Self.logPath)
    }

    deinit {
        fileHandle?.closeFile()
    }

    /// Log callback suitable for `DebugConsoleController.fileLoggerCallback`.
    func log(event: DebugEvent, seq: Int) {
        guard let fileHandle else { return }

        let record: [String: Any] = [
            "seq": seq,
            "ts": isoFormatter.string(from: event.timestamp),
            "kind": event.kind.rawValue,
            "text": event.text,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8)
        else { return }

        line += "\n"
        if let lineData = line.data(using: .utf8) {
            fileHandle.write(lineData)
        }
    }
}
