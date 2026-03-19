import Foundation

/// Outcome of executing a JavaScript tool-program in the JSC runtime.
///
/// Captures the script's final return value, any log lines emitted during
/// execution, and (when the script fails) a structured error description.
struct JSCScriptResult: Sendable, Equatable {

    /// Script exit status.
    enum Status: String, Sendable, Equatable {
        /// The script completed normally and produced a value.
        case success
        /// The script threw an unhandled exception or a host call was rejected.
        case failure
        /// The script was cancelled before completion (timeout or cooperative cancel).
        case cancelled
        /// The script exceeded a host-enforced budget (time, tool calls, or concurrency).
        case budgetExceeded
    }

    /// Whether the script succeeded, failed, or was cancelled.
    let status: Status

    /// The JSON-serialised return value of the script's default export, or `nil`
    /// when the script does not return a value or fails before producing one.
    let value: String?

    /// Console log lines captured during execution (`fae.log(...)` calls).
    let logs: [String]

    /// A human-readable error description when `status != .success`.
    let error: String?

    // MARK: - Convenience factories

    static func success(value: String?, logs: [String] = []) -> JSCScriptResult {
        JSCScriptResult(status: .success, value: value, logs: logs, error: nil)
    }

    static func failure(error: String, logs: [String] = []) -> JSCScriptResult {
        JSCScriptResult(status: .failure, value: nil, logs: logs, error: error)
    }

    static func cancelled(logs: [String] = []) -> JSCScriptResult {
        JSCScriptResult(status: .cancelled, value: nil, logs: logs, error: "Script execution was cancelled")
    }

    /// Create a budget-exceeded result with a specific reason.
    ///
    /// - Parameters:
    ///   - reason: Human-readable description of which budget limit was hit.
    ///   - logs: Log lines captured before the budget was exceeded.
    static func budgetExceeded(reason: String, logs: [String] = []) -> JSCScriptResult {
        JSCScriptResult(status: .budgetExceeded, value: nil, logs: logs, error: reason)
    }
}
