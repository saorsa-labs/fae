import Foundation
import Tokenizers

// MARK: - Shared Tool Enums

/// Risk level classification for tools.
///
/// Used by `VoiceIdentityPolicy` and retained on the `Tool` protocol for
/// informational purposes. No longer drives a separate approval pipeline.
enum ToolRiskLevel: String, Sendable {
    case low
    case medium
    case high
}

/// Source that triggered a tool invocation.
///
/// Recorded in security logs and used by proactive-task gating.
enum ActionSource: String, Sendable {
    case voice
    case text
    case scheduler
    case relay
    case skill
    case unknown
}

/// Result of a tool execution.
///
/// Every tool produces at minimum a prose ``output`` string consumed by the LLM.
/// Tools may additionally carry ``structuredData`` — a JSON-serialisable dictionary
/// that script-based callers (JSC tool-programs) can access without parsing prose.
///
/// Existing tool callers that only read ``output`` are unaffected; structured data
/// is an additive, optional path.
struct ToolResult: Sendable {
    /// Human-readable prose output consumed by the LLM for conversation.
    let output: String

    /// Whether this result represents an error condition.
    let isError: Bool

    /// Optional structured data for script-facing callers.
    ///
    /// When present, this dictionary is JSON-serialised and delivered alongside
    /// the prose ``output`` so that JSC tool-programs can work with typed values
    /// instead of parsing free-form text.
    ///
    /// Keys must be `String`; values must be JSON-serialisable (`Sendable`).
    /// Tools that do not produce structured data leave this `nil`.
    let structuredData: [String: any Sendable]?

    init(output: String, isError: Bool = false, structuredData: [String: any Sendable]? = nil) {
        self.output = output
        self.isError = isError
        self.structuredData = structuredData
    }

    /// Create a successful result with prose output only.
    static func success(_ output: String) -> ToolResult {
        ToolResult(output: output)
    }

    /// Create a successful result with both prose and structured data.
    static func success(_ output: String, structuredData: [String: any Sendable]) -> ToolResult {
        ToolResult(output: output, structuredData: structuredData)
    }

    /// Create an error result.
    static func error(_ message: String) -> ToolResult {
        ToolResult(output: message, isError: true)
    }

    // MARK: - Serialisation

    /// Serialise the structured data to a JSON string, or `nil` if no structured data.
    ///
    /// Falls back gracefully: if serialisation fails, returns `nil` rather than throwing.
    func serialiseStructuredData() -> String? {
        guard let data = structuredData else { return nil }
        guard JSONSerialization.isValidJSONObject(data) else { return nil }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
              let json = String(data: jsonData, encoding: .utf8)
        else { return nil }
        return json
    }

    /// Build the script-facing envelope: `{"output": "...", "data": {...}}`.
    ///
    /// Scripts receive this JSON string from `fae.tool()` promises. When no
    /// structured data is present, the envelope contains only `"output"`.
    func scriptEnvelope() -> String {
        var envelope: [String: Any] = ["output": output, "isError": isError]
        if let data = structuredData, JSONSerialization.isValidJSONObject(data) {
            envelope["data"] = data
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]),
              let json = String(data: jsonData, encoding: .utf8)
        else {
            // Fallback: return minimal JSON with just the output.
            let escaped = output
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return #"{"isError":\#(isError),"output":"\#(escaped)"}"#
        }
        return json
    }
}

/// Protocol for all Fae tools.
///
/// Replaces: tool trait from `src/fae_llm/tools/`
protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var parametersSchema: String { get }
    var requiresApproval: Bool { get }
    var riskLevel: ToolRiskLevel { get }
    /// A concrete `<tool_call>` example for the LLM to follow.
    var example: String { get }
    func execute(input: [String: Any]) async throws -> ToolResult
}

extension Tool {
    var requiresApproval: Bool { false }
    var riskLevel: ToolRiskLevel { .medium }
    var example: String { "" }

    /// Convert this tool's metadata to a native `ToolSpec` for MLX tool calling.
    ///
    /// Parses the string-based `parametersSchema` into structured JSON Schema
    /// properties and builds the `{"type":"function","function":{...}}` dict
    /// that MLXLMCommon's chat template expects.
    var toolSpec: ToolSpec {
        let (properties, required) = Self.parseParametersSchema(parametersSchema)
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ] as ToolSpec
    }

    /// Parse `parametersSchema` string into (properties, required) for JSON Schema.
    ///
    /// Handles two formats:
    /// - Simple:     `{"path": "string (required)"}`
    /// - Structured: `{"prompt":{"type":"string","description":"..."}}`
    private static func parseParametersSchema(_ schema: String) -> (
        [String: any Sendable], [String]
    ) {
        let trimmed = schema.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ([:], [])
        }

        var properties: [String: any Sendable] = [:]
        var required: [String] = []

        for (key, value) in raw {
            if let nested = value as? [String: Any], nested["type"] is String {
                // Structured format: {"type":"string","description":"..."}
                var prop: [String: any Sendable] = [:]
                if let t = nested["type"] as? String { prop["type"] = t }
                if let d = nested["description"] as? String { prop["description"] = d }
                properties[key] = prop
                // Mark required if explicitly flagged or no "optional" mention in description.
                if let req = nested["required"] as? Bool, req {
                    required.append(key)
                }
            } else if let desc = value as? String {
                // Simple format: "string (required)" or "integer (optional, default 10)"
                let (jsonType, isRequired) = inferJSONSchemaType(from: desc)
                var prop: [String: any Sendable] = ["type": jsonType]
                // Use the raw description as documentation.
                prop["description"] = desc
                properties[key] = prop
                if isRequired {
                    required.append(key)
                }
            }
        }

        return (properties, required)
    }

    /// Map a simple type descriptor to a JSON Schema type.
    ///
    /// Examples: `"string (required)"` → `("string", true)`,
    ///           `"integer (optional, default 10)"` → `("integer", false)`.
    private static func inferJSONSchemaType(from desc: String) -> (String, Bool) {
        let lower = desc.lowercased()
        let isRequired = lower.contains("required")

        if lower.hasPrefix("integer") { return ("integer", isRequired) }
        if lower.hasPrefix("number") || lower.hasPrefix("float") || lower.hasPrefix("double") {
            return ("number", isRequired)
        }
        if lower.hasPrefix("bool") { return ("boolean", isRequired) }
        if lower.hasPrefix("array") || lower.hasPrefix("[") { return ("array", isRequired) }
        if lower.hasPrefix("object") || lower.hasPrefix("{") { return ("object", isRequired) }
        if lower.hasPrefix("any") { return ("string", isRequired) }
        // Default to string.
        return ("string", isRequired)
    }
}
