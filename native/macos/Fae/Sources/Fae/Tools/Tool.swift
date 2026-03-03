import Foundation
import Tokenizers

/// Result of a tool execution.
struct ToolResult: Sendable {
    let output: String
    let isError: Bool

    init(output: String, isError: Bool = false) {
        self.output = output
        self.isError = isError
    }

    static func success(_ output: String) -> ToolResult {
        ToolResult(output: output)
    }

    static func error(_ message: String) -> ToolResult {
        ToolResult(output: message, isError: true)
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
