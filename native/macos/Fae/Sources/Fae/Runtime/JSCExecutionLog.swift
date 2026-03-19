import Foundation

/// A single structured log entry captured during JSC tool-program execution.
///
/// Each entry records a discrete runtime event — script start/end, tool calls,
/// bridge operations, budget checks, and errors — with timestamps and metadata
/// sufficient to reconstruct the full execution timeline.
///
/// Used by ``JSCDeveloperHarness`` to provide detailed debugging output and
/// by ``JSCToolBridge`` to surface per-step execution trace data.
struct JSCExecutionLogEntry: Sendable, Equatable {

    /// The kind of runtime event this entry represents.
    enum Kind: String, Sendable, Equatable, CaseIterable {
        /// Script evaluation started.
        case scriptStart
        /// Script evaluation completed (success or failure).
        case scriptEnd
        /// A `fae.tool()` call was initiated by the script.
        case toolCallStart
        /// A `fae.tool()` call completed (success or error).
        case toolCallEnd
        /// A `fae.log()` message was emitted by the script.
        case logMessage
        /// A `fae.sleep()` call was initiated.
        case sleepStart
        /// A `fae.sleep()` call completed.
        case sleepEnd
        /// A budget limit was checked or enforced.
        case budgetCheck
        /// The script was cancelled (cooperative or timeout).
        case cancellation
        /// A JavaScript exception was caught.
        case jsException
        /// A drain-loop iteration completed.
        case drainIteration
    }

    /// What kind of event this entry represents.
    let kind: Kind

    /// When the event occurred.
    let timestamp: Date

    /// Human-readable description of the event.
    let message: String

    /// The tool name, if this entry relates to a tool call.
    let toolName: String?

    /// Whether the operation succeeded (for `toolCallEnd`, `scriptEnd`).
    let success: Bool?

    /// Duration in milliseconds (for `toolCallEnd`, `sleepEnd`, `scriptEnd`).
    let durationMs: Int?

    /// Additional key-value metadata for debugging.
    let metadata: [String: String]

    // MARK: - Convenience Factories

    /// Create a log entry with minimal required fields.
    static func entry(
        _ kind: Kind,
        message: String,
        toolName: String? = nil,
        success: Bool? = nil,
        durationMs: Int? = nil,
        metadata: [String: String] = [:]
    ) -> JSCExecutionLogEntry {
        JSCExecutionLogEntry(
            kind: kind,
            timestamp: Date(),
            message: message,
            toolName: toolName,
            success: success,
            durationMs: durationMs,
            metadata: metadata
        )
    }
}

/// Thread-safe collector for ``JSCExecutionLogEntry`` instances.
///
/// Accumulates log entries during a script execution and provides
/// query methods for post-run analysis. Used internally by the
/// bridge and harness; callers receive the final snapshot via
/// ``JSCScriptResult``.
final class JSCExecutionLog: @unchecked Sendable {

    /// Serial queue protecting the entries array.
    private let queue = DispatchQueue(label: "fae.jsc.execution-log")

    /// All entries collected during the execution.
    private var _entries: [JSCExecutionLogEntry] = []

    /// Append an entry to the log.
    func append(_ entry: JSCExecutionLogEntry) {
        queue.sync { _entries.append(entry) }
    }

    /// Append a convenience entry.
    func log(
        _ kind: JSCExecutionLogEntry.Kind,
        message: String,
        toolName: String? = nil,
        success: Bool? = nil,
        durationMs: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        append(.entry(
            kind,
            message: message,
            toolName: toolName,
            success: success,
            durationMs: durationMs,
            metadata: metadata
        ))
    }

    /// Return a snapshot of all entries.
    func snapshot() -> [JSCExecutionLogEntry] {
        queue.sync { _entries }
    }

    /// Return entries filtered by kind.
    func entries(ofKind kind: JSCExecutionLogEntry.Kind) -> [JSCExecutionLogEntry] {
        queue.sync { _entries.filter { $0.kind == kind } }
    }

    /// The total number of entries.
    var count: Int {
        queue.sync { _entries.count }
    }

    /// All tool call start entries, useful for counting tool invocations.
    var toolCalls: [JSCExecutionLogEntry] {
        entries(ofKind: .toolCallStart)
    }

    /// Whether any entry indicates a failure.
    var hasErrors: Bool {
        queue.sync {
            _entries.contains { entry in
                entry.kind == .jsException ||
                entry.kind == .cancellation ||
                (entry.success == false)
            }
        }
    }

    /// Format all entries as a human-readable timeline string.
    func formatTimeline() -> String {
        let entries = snapshot()
        guard let first = entries.first else { return "(empty execution log)" }
        let baseTime = first.timestamp

        return entries.map { entry in
            let offsetMs = Int(entry.timestamp.timeIntervalSince(baseTime) * 1000)
            let prefix = String(format: "+%04dms", offsetMs)
            let kindTag = "[\(entry.kind.rawValue)]"
            var line = "\(prefix) \(kindTag) \(entry.message)"
            if let tool = entry.toolName {
                line += " tool=\(tool)"
            }
            if let success = entry.success {
                line += " success=\(success)"
            }
            if let duration = entry.durationMs {
                line += " duration=\(duration)ms"
            }
            if !entry.metadata.isEmpty {
                let meta = entry.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
                line += " {\(meta)}"
            }
            return line
        }.joined(separator: "\n")
    }
}
