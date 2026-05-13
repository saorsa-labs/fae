import Foundation

/// A parsed tool call from LLM response text.
///
/// Represents a single `<tool_call>` block containing a tool name and arguments.
struct ToolCall: @unchecked Sendable {
    /// Tool name (e.g., "web_search", "calendar").
    let name: String
    /// Tool arguments as a JSON-compatible dictionary.
    let arguments: [String: Any]
}

/// A parsed `<tool_program>` block from the LLM response.
///
/// The LLM may emit one or more script blocks alongside (or instead of)
/// `<tool_call>` blocks. Each block contains JavaScript source that is
/// executed via ``JSCRuntime``.
struct ScriptBlock: Sendable, Equatable {
    /// The JavaScript source code to execute.
    let source: String

    /// Optional set of tools this script is allowed to call.
    /// When `nil`, the script inherits the current turn's tool access.
    let allowedTools: Set<String>?

    /// Optional budget override. When `nil`, ``ScriptBudget/default`` is used.
    let budget: ScriptBudget?

    /// When `true`, run in dry-run mode: record intended tool calls
    /// without executing them, then return the plan for user review.
    let dryRun: Bool
}

/// Parsing utilities for extracting tool calls and script blocks from LLM response text.
enum ToolCallParser {

    // MARK: - Tool Call Parsing

    /// Parse tool calls from response text.
    ///
    /// Supports three format families:
    /// - JSON (Qwen3): `<tool_call>{"name":"...","arguments":{...}}</tool_call>`
    /// - XML (Qwen3.5): `<tool_call><function=name><parameter=key>value</parameter></function></tool_call>`
    /// - Gemma 4: `<|tool_call>call:name{key:<|"|>value<|"|>}<tool_call|>`
    static func parseToolCalls(from text: String) -> [ToolCall] {
        var calls: [ToolCall] = []
        var searchStart = text.startIndex

        // Qwen format: <tool_call>...</tool_call>
        while let openRange = text.range(of: "<tool_call>", range: searchStart..<text.endIndex) {
            let closeRange = text.range(of: "</tool_call>", range: openRange.upperBound..<text.endIndex)
            let contentEnd = closeRange?.lowerBound ?? text.endIndex
            let content = text[openRange.upperBound..<contentEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Try JSON format first (Qwen3): {"name":"...","arguments":{...}}
            if let call = parseJSONToolCall(content) {
                calls.append(call)
            }
            // Fall back to XML parameter format (Qwen3.5): <function=name><parameter=key>value</parameter></function>
            else if let call = parseXMLToolCall(content) {
                calls.append(call)
            }

            searchStart = closeRange?.upperBound ?? text.endIndex
        }

        // Gemma format: <|tool_call>call:name{...}<tool_call|>
        if calls.isEmpty {
            searchStart = text.startIndex
            while let openRange = text.range(of: "<|tool_call>", range: searchStart..<text.endIndex) {
                let closeRange = text.range(of: "<tool_call|>", range: openRange.upperBound..<text.endIndex)
                let contentEnd = closeRange?.lowerBound ?? text.endIndex
                let content = String(text[openRange.upperBound..<contentEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if let call = parseGemmaToolCall(content) {
                    calls.append(call)
                }

                searchStart = closeRange?.upperBound ?? text.endIndex
            }
        }

        // Bare Gemma format without tags: call:name{...} (e.g. from streaming)
        if calls.isEmpty, text.contains("call:"), let call = parseGemmaToolCall(text) {
            calls.append(call)
        }

        return calls
    }

    // MARK: - Script Block Parsing

    /// Parse `<tool_program>` blocks from response text.
    ///
    /// Format:
    /// ```
    /// <tool_program>
    /// // JavaScript source
    /// </tool_program>
    /// ```
    ///
    /// Optional attributes (JSON) can be provided in a `<tool_program_meta>` block
    /// immediately before the `<tool_program>`:
    /// ```
    /// <tool_program_meta>{"allowed_tools":["read","write"],"max_tool_calls":10}</tool_program_meta>
    /// <tool_program>
    /// // JS source
    /// </tool_program>
    /// ```
    static func parseScriptBlocks(from text: String) -> [ScriptBlock] {
        var blocks: [ScriptBlock] = []
        var searchStart = text.startIndex

        while let openRange = text.range(of: "<tool_program>", range: searchStart..<text.endIndex) {
            let closeRange = text.range(of: "</tool_program>", range: openRange.upperBound..<text.endIndex)
            let contentEnd = closeRange?.lowerBound ?? text.endIndex
            let source = String(text[openRange.upperBound..<contentEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !source.isEmpty else {
                searchStart = closeRange?.upperBound ?? text.endIndex
                continue
            }

            // Look for a preceding <tool_program_meta> block.
            var allowedTools: Set<String>?
            var budget: ScriptBudget?
            var dryRun = false
            if let metaEnd = text.range(of: "</tool_program_meta>", range: searchStart..<openRange.lowerBound),
               let metaStart = text.range(of: "<tool_program_meta>", range: searchStart..<metaEnd.lowerBound)
            {
                let metaContent = String(text[metaStart.upperBound..<metaEnd.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let data = metaContent.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    if let tools = json["allowed_tools"] as? [String] {
                        allowedTools = Set(tools)
                    }
                    if let maxCalls = json["max_tool_calls"] as? Int {
                        budget = ScriptBudget(
                            maxToolCalls: maxCalls,
                            maxWallClockSeconds: (json["max_wall_clock_seconds"] as? TimeInterval) ?? ScriptBudget.default.maxWallClockSeconds,
                            maxConcurrentToolCalls: (json["max_concurrent_tool_calls"] as? Int) ?? ScriptBudget.default.maxConcurrentToolCalls
                        )
                    }
                    if let dr = json["dry_run"] as? Bool {
                        dryRun = dr
                    }
                }
            }

            blocks.append(ScriptBlock(
                source: source,
                allowedTools: allowedTools,
                budget: budget,
                dryRun: dryRun
            ))

            searchStart = closeRange?.upperBound ?? text.endIndex
        }

        return blocks
    }

    // MARK: - Markup Stripping

    /// Strip tool call markup from response text, leaving only human-readable content.
    static func stripToolCallMarkup(_ text: String) -> String {
        var result = text

        // Strip Qwen format: <tool_call>...</tool_call>
        while let open = result.range(of: "<tool_call>") {
            if let close = result.range(of: "</tool_call>", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
                break
            }
        }

        // Strip Gemma format: <|tool_call>...<tool_call|>
        while let open = result.range(of: "<|tool_call>") {
            if let close = result.range(of: "<tool_call|>", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
                break
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private Parsing Helpers

    static func parseJSONToolCall(_ content: String) -> ToolCall? {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String
        else { return nil }
        let args = json["arguments"] as? [String: Any] ?? [:]
        return ToolCall(name: name, arguments: args)
    }

    /// Parse Qwen3.5 XML parameter format: `<function=name><parameter=key>value</parameter></function>`
    static func parseXMLToolCall(_ content: String) -> ToolCall? {
        guard let funcMatch = content.range(of: "<function="),
              let funcEnd = content.range(of: ">", range: funcMatch.upperBound..<content.endIndex)
        else { return nil }
        let name = String(content[funcMatch.upperBound..<funcEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        var args: [String: Any] = [:]
        var paramSearchStart = funcEnd.upperBound
        while let paramOpen = content.range(of: "<parameter=", range: paramSearchStart..<content.endIndex),
              let paramNameEnd = content.range(of: ">", range: paramOpen.upperBound..<content.endIndex)
        {
            let key = String(content[paramOpen.upperBound..<paramNameEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                paramSearchStart = paramNameEnd.upperBound
                continue
            }

            let nextBoundary = nextXMLParameterBoundary(in: content, from: paramNameEnd.upperBound)
            let paramClose = content.range(of: "</parameter>", range: paramNameEnd.upperBound..<nextBoundary)
            let valueEnd = paramClose?.lowerBound ?? nextBoundary
            let value = String(content[paramNameEnd.upperBound..<valueEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Try to parse value as JSON for nested objects/arrays/numbers/booleans.
            if let data = value.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data)
            {
                args[key] = parsed
            } else {
                args[key] = value
            }

            paramSearchStart = paramClose?.upperBound ?? valueEnd
        }

        return ToolCall(name: name, arguments: args)
    }

    private static func nextXMLParameterBoundary(in content: String, from start: String.Index) -> String.Index {
        let parameterOpen = content.range(of: "<parameter=", range: start..<content.endIndex)?.lowerBound
        let functionClose = content.range(of: "</function", range: start..<content.endIndex)?.lowerBound

        return [parameterOpen, functionClose, content.endIndex]
            .compactMap { $0 }
            .min() ?? content.endIndex
    }

    /// Parse Gemma tool call format: `call:name{key:<|"|>value<|"|>,key2:value2}`
    ///
    /// Gemma 4 uses `<|"|>` as string delimiters in tool call arguments.
    /// Older Gemma models use `<escape>` markers. Both are supported.
    static func parseGemmaToolCall(_ content: String) -> ToolCall? {
        guard let callRange = content.range(of: "call:") else { return nil }
        let remaining = String(content[callRange.upperBound...])

        guard let braceStart = remaining.firstIndex(of: "{") else { return nil }
        let funcName = String(remaining[remaining.startIndex..<braceStart])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !funcName.isEmpty else { return nil }

        guard let braceEnd = remaining.lastIndex(of: "}") else { return nil }
        var argsStr = String(remaining[remaining.index(after: braceStart)..<braceEnd])

        var args: [String: Any] = [:]
        let gemmaStringDelimiter = "<|\"|>"
        let legacyEscape = "<escape>"

        while !argsStr.isEmpty {
            argsStr = argsStr.trimmingCharacters(in: .whitespaces)
            guard let colonIdx = argsStr.firstIndex(of: ":") else { break }
            let key = String(argsStr[argsStr.startIndex..<colonIdx])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            argsStr = String(argsStr[argsStr.index(after: colonIdx)...])

            // Gemma 4 string delimiter: <|"|>value<|"|>
            if argsStr.hasPrefix(gemmaStringDelimiter) {
                argsStr = String(argsStr.dropFirst(gemmaStringDelimiter.count))
                if let endDelim = argsStr.range(of: gemmaStringDelimiter) {
                    let value = String(argsStr[argsStr.startIndex..<endDelim.lowerBound])
                    args[key] = value
                    argsStr = String(argsStr[endDelim.upperBound...])
                    if argsStr.hasPrefix(",") { argsStr = String(argsStr.dropFirst()) }
                    continue
                }
            }

            // Legacy escape marker: <escape>value<escape>
            if argsStr.hasPrefix(legacyEscape) {
                argsStr = String(argsStr.dropFirst(legacyEscape.count))
                if let endEscape = argsStr.range(of: legacyEscape) {
                    let value = String(argsStr[argsStr.startIndex..<endEscape.lowerBound])
                    args[key] = value
                    argsStr = String(argsStr[endEscape.upperBound...])
                    if argsStr.hasPrefix(",") { argsStr = String(argsStr.dropFirst()) }
                    continue
                }
            }

            // Unquoted value: read until comma or end
            let commaIdx = argsStr.firstIndex(of: ",") ?? argsStr.endIndex
            let value = String(argsStr[argsStr.startIndex..<commaIdx])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            argsStr = commaIdx < argsStr.endIndex
                ? String(argsStr[argsStr.index(after: commaIdx)...]) : ""

            // Try JSON parse for numbers/booleans, fall back to string.
            if let data = value.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data)
            {
                args[key] = parsed
            } else {
                args[key] = value
            }
        }

        return ToolCall(name: funcName, arguments: args)
    }
}
