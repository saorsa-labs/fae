import Foundation

/// A recorded tool-call intention from a dry-run script execution.
///
/// During dry-run mode, tool calls are intercepted before reaching
/// ``ToolExecutor`` and recorded here. The script receives synthetic
/// success results so it can run to completion, exposing its full
/// plan of intended calls without any side effects.
struct DryRunIntendedCall: Sendable, Equatable {
    /// The tool name that would be called.
    let toolName: String

    /// The arguments that would be passed to the tool.
    let argumentsJSON: String

    /// Sequential index of this call within the script execution.
    let callIndex: Int
}

/// The complete plan produced by a dry-run script execution.
///
/// Contains all tool calls the script intends to make, in order,
/// along with the script's final return value (which may reference
/// the synthetic tool outputs).
struct DryRunPlan: Sendable, Equatable {
    /// All tool calls the script intends to make, in execution order.
    let intendedCalls: [DryRunIntendedCall]

    /// The script's return value (using synthetic tool results).
    let scriptResult: JSCScriptResult

    /// Whether the plan is empty (no tool calls).
    var isEmpty: Bool { intendedCalls.isEmpty }

    /// Number of distinct tools referenced in the plan.
    var uniqueToolCount: Int {
        Set(intendedCalls.map(\.toolName)).count
    }

    // MARK: - Summary Formatting

    /// Generate a concise human-readable summary of the plan.
    ///
    /// Suitable for voice output or conversation display. Groups
    /// consecutive calls to the same tool and shows argument highlights.
    ///
    /// - Returns: A multi-line summary string.
    func summary() -> String {
        guard !intendedCalls.isEmpty else {
            return "The script would not make any tool calls."
        }

        var lines: [String] = []
        lines.append("This script plans to make \(intendedCalls.count) tool call\(intendedCalls.count == 1 ? "" : "s"):")
        lines.append("")

        for (index, call) in intendedCalls.enumerated() {
            let argPreview = Self.argumentPreview(call.argumentsJSON)
            let stepNumber = index + 1
            if argPreview.isEmpty {
                lines.append("\(stepNumber). \(call.toolName)")
            } else {
                lines.append("\(stepNumber). \(call.toolName): \(argPreview)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Generate a short one-line summary for voice output.
    ///
    /// - Returns: A brief description like "3 tool calls: read, write, bash".
    func briefSummary() -> String {
        guard !intendedCalls.isEmpty else {
            return "No tool calls planned."
        }

        let toolNames = intendedCalls.map(\.toolName)
        let uniqueNames = Array(Set(toolNames)).sorted()
        let toolList = uniqueNames.joined(separator: ", ")
        return "\(intendedCalls.count) tool call\(intendedCalls.count == 1 ? "" : "s"): \(toolList)"
    }

    // MARK: - Private Helpers

    /// Extract a short preview of tool arguments for display.
    private static func argumentPreview(_ json: String, maxLength: Int = 80) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ""
        }

        // Show key highlights based on common tool argument patterns.
        if let path = obj["path"] as? String {
            return path
        }
        if let command = obj["command"] as? String {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > maxLength
                ? String(trimmed.prefix(maxLength)) + "..."
                : trimmed
        }
        if let query = obj["query"] as? String {
            return "\"\(query)\""
        }
        if let action = obj["action"] as? String {
            return action
        }
        if let url = obj["url"] as? String {
            return url
        }

        // Fall back to showing all keys.
        let keys = obj.keys.sorted().joined(separator: ", ")
        return keys.isEmpty ? "" : "(\(keys))"
    }
}
