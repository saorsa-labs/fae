import Foundation

/// Parsed event emitted by the ACPX stdio NDJSON stream.
enum ACPEvent: Sendable, Equatable {
    case agentMessageChunk(sessionId: String, content: String, isFinal: Bool)
    case toolCall(sessionId: String, toolName: String, toolCallId: String, input: String)
    case toolUpdate(sessionId: String, toolCallId: String, output: String, isComplete: Bool)
    case requestPermission(sessionId: String, toolName: String, description: String, requestId: String)
    case sessionComplete(sessionId: String, stopReason: String)
    case error(sessionId: String?, code: Int, message: String)
}

/// Errors produced by ACP request serialization.
enum ACPProtocolError: Error, LocalizedError, Sendable {
    case invalidJSONObject

    var errorDescription: String? {
        switch self {
        case .invalidJSONObject:
            return "ACP request could not be represented as valid JSON."
        }
    }
}

/// Content block sent as part of an ACP prompt request.
///
/// Text blocks serialize as:
/// `{ "type": "text", "text": "..." }`
///
/// Image blocks serialize as:
/// `{ "type": "image", "source": "...", "mime_type": "image/png" }`
struct ACPContentBlock: Sendable, Equatable {
    enum BlockType: String, Sendable, Equatable {
        case text
        case image
    }

    let type: BlockType
    let text: String?
    let source: String?
    let mimeType: String?

    static func text(_ value: String) -> ACPContentBlock {
        ACPContentBlock(type: .text, text: value, source: nil, mimeType: nil)
    }

    static func image(source: String, mimeType: String? = nil) -> ACPContentBlock {
        ACPContentBlock(type: .image, text: nil, source: source, mimeType: mimeType)
    }

    func jsonObject() -> [String: Any] {
        var object: [String: Any] = ["type": type.rawValue]

        switch type {
        case .text:
            object["text"] = text ?? ""
        case .image:
            object["source"] = source ?? ""
            if let mimeType, !mimeType.isEmpty {
                object["mime_type"] = mimeType
            }
        }

        return object
    }
}

/// Request Fae sends to ACPX over stdin (JSON-RPC 2.0).
enum ACPRequest: Sendable, Equatable {
    case prompt(sessionId: String, text: String, attachments: [ACPContentBlock])
    case approvePermission(requestId: String, approved: Bool)
    case cancelTurn(sessionId: String)

    /// ACPX JSON-RPC method name.
    var method: String {
        switch self {
        case .prompt:
            return "prompt"
        case .approvePermission:
            return "approve_permission"
        case .cancelTurn:
            return "cancel_turn"
        }
    }

    /// ACPX JSON-RPC params object.
    var params: [String: Any] {
        switch self {
        case .prompt(let sessionId, let text, let attachments):
            var content: [[String: Any]] = [[
                "type": "text",
                "text": text,
            ]]
            content.append(contentsOf: attachments.map { $0.jsonObject() })

            return [
                "sessionId": sessionId,
                "content": content,
            ]

        case .approvePermission(let requestId, let approved):
            return [
                "requestId": requestId,
                "approved": approved,
            ]

        case .cancelTurn(let sessionId):
            return [
                "sessionId": sessionId,
            ]
        }
    }

    /// JSON-RPC envelope represented as a Foundation object.
    func jsonRPCObject(id: String = UUID().uuidString) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
    }

    /// Serialize this request to compact JSON for stdin writes.
    func serializedData(id: String = UUID().uuidString) throws -> Data {
        let object = jsonRPCObject(id: id)
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ACPProtocolError.invalidJSONObject
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Serialize this request as a newline-delimited JSON string.
    func serializedLine(id: String = UUID().uuidString) throws -> String {
        let data = try serializedData(id: id)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return json + "\n"
    }
}

/// Parser for ACPX NDJSON stdout lines.
///
/// The parser is intentionally tolerant:
/// - malformed lines are logged and skipped
/// - unknown event types are logged and skipped
/// - missing required fields in known events are logged and skipped
struct ACPEventParser: Sendable {
    /// Parse one NDJSON line into a strongly typed `ACPEvent`.
    ///
    /// Returns `nil` for malformed or unknown lines.
    func parse(line: String) throws -> ACPEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let data = trimmed.data(using: .utf8) else {
            NSLog("ACPEventParser: unable to encode line as UTF-8: %@", trimmed)
            return nil
        }

        let root: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("ACPEventParser: non-object JSON line: %@", trimmed)
                return nil
            }
            root = parsed
        } catch {
            NSLog("ACPEventParser: JSON parse error: %@ — line: %@", error.localizedDescription, trimmed)
            return nil
        }

        if let event = parseJSONRPC(root: root) {
            return event
        }

        if let event = parseNDJSONEvent(root: root) {
            return event
        }

        NSLog("ACPEventParser: unknown ACP event payload: %@", trimmed)
        return nil
    }

    // MARK: - NDJSON Event Parsing

    private func parseNDJSONEvent(root: [String: Any]) -> ACPEvent? {
        guard let type = stringValue(in: root, keys: ["type", "event"])?.lowercased() else {
            return nil
        }

        let sessionId = stringValue(in: root, keys: ["sessionId", "session_id"])

        switch type {
        case "agent_message_chunk":
            guard let sessionId else {
                NSLog("ACPEventParser: missing sessionId for agent_message_chunk")
                return nil
            }
            let content = stringValue(in: root, keys: ["text", "content", "message"]) ?? ""
            let isFinal = boolValue(in: root, keys: ["isFinal", "is_final", "final"]) ?? false
            return .agentMessageChunk(sessionId: sessionId, content: content, isFinal: isFinal)

        case "tool_call":
            guard let sessionId else {
                NSLog("ACPEventParser: missing sessionId for tool_call")
                return nil
            }
            guard let toolName = stringValue(in: root, keys: ["toolName", "tool_name", "name"]),
                  let toolCallId = stringValue(in: root, keys: ["toolCallId", "tool_call_id", "id"])
            else {
                NSLog("ACPEventParser: missing toolName/toolCallId for tool_call")
                return nil
            }
            let input = stringifyValue(
                root["input"] ?? root["input_json"] ?? root["arguments"] ?? root["args"]
            )
            return .toolCall(
                sessionId: sessionId,
                toolName: toolName,
                toolCallId: toolCallId,
                input: input
            )

        case "tool_call_update", "tool_update":
            guard let sessionId else {
                NSLog("ACPEventParser: missing sessionId for tool_update")
                return nil
            }
            guard let toolCallId = stringValue(in: root, keys: ["toolCallId", "tool_call_id", "id"]) else {
                NSLog("ACPEventParser: missing toolCallId for tool_update")
                return nil
            }
            let output = stringifyValue(root["output"] ?? root["output_text"] ?? root["result"])
            let explicitComplete = boolValue(in: root, keys: ["isComplete", "is_complete", "completed"])
            let statusComplete = stringValue(in: root, keys: ["status"])?.lowercased() == "completed"
            return .toolUpdate(
                sessionId: sessionId,
                toolCallId: toolCallId,
                output: output,
                isComplete: explicitComplete ?? statusComplete
            )

        case "request_permission", "approval_requested":
            guard let sessionId else {
                NSLog("ACPEventParser: missing sessionId for request_permission")
                return nil
            }
            guard let toolName = stringValue(in: root, keys: ["toolName", "tool_name", "name"]),
                  let requestId = stringValue(in: root, keys: ["requestId", "request_id", "id"])
            else {
                NSLog("ACPEventParser: missing toolName/requestId for request_permission")
                return nil
            }
            let description = stringValue(in: root, keys: ["description", "reason", "message"]) ?? ""
            return .requestPermission(
                sessionId: sessionId,
                toolName: toolName,
                description: description,
                requestId: requestId
            )

        case "prompt_complete", "session_complete":
            guard let sessionId else {
                NSLog("ACPEventParser: missing sessionId for session completion")
                return nil
            }
            let stopReason = stringValue(in: root, keys: ["stopReason", "stop_reason", "reason"]) ?? "unknown"
            return .sessionComplete(sessionId: sessionId, stopReason: stopReason)

        case "error":
            let code = intValue(in: root, keys: ["code"]) ?? -1
            let message = stringValue(in: root, keys: ["message", "error"]) ?? "Unknown ACP error"
            return .error(sessionId: sessionId, code: code, message: message)

        default:
            return nil
        }
    }

    // MARK: - JSON-RPC 2.0 Parsing

    private func parseJSONRPC(root: [String: Any]) -> ACPEvent? {
        guard (root["jsonrpc"] as? String) == "2.0" else {
            return nil
        }

        if let errorObject = root["error"] as? [String: Any] {
            let sessionId = stringValue(in: root, keys: ["sessionId", "session_id"])
            let code = intValue(in: errorObject, keys: ["code"]) ?? -1
            let message = stringValue(in: errorObject, keys: ["message"]) ?? "Unknown ACP error"
            return .error(sessionId: sessionId, code: code, message: message)
        }

        guard let method = (root["method"] as? String)?.lowercased() else {
            return nil
        }

        let params = root["params"] as? [String: Any] ?? [:]
        return eventFromMethod(method, params: params)
    }

    private func eventFromMethod(_ method: String, params: [String: Any]) -> ACPEvent? {
        switch method {
        case "agent_message_chunk", "agent/message_chunk", "agent.message_chunk":
            guard let sessionId = stringValue(in: params, keys: ["sessionId", "session_id"]) else {
                NSLog("ACPEventParser: missing sessionId for JSON-RPC agent_message_chunk")
                return nil
            }
            let content = stringValue(in: params, keys: ["text", "content", "message"]) ?? ""
            let isFinal = boolValue(in: params, keys: ["isFinal", "is_final", "final"]) ?? false
            return .agentMessageChunk(sessionId: sessionId, content: content, isFinal: isFinal)

        case "tool_call", "tool/call", "tool.call":
            guard let sessionId = stringValue(in: params, keys: ["sessionId", "session_id"]),
                  let toolName = stringValue(in: params, keys: ["toolName", "tool_name", "name"]),
                  let toolCallId = stringValue(in: params, keys: ["toolCallId", "tool_call_id", "id"])
            else {
                NSLog("ACPEventParser: missing fields for JSON-RPC tool_call")
                return nil
            }
            let input = stringifyValue(params["input"] ?? params["input_json"] ?? params["arguments"])
            return .toolCall(
                sessionId: sessionId,
                toolName: toolName,
                toolCallId: toolCallId,
                input: input
            )

        case "tool_call_update", "tool/update", "tool.call_update", "tool_update":
            guard let sessionId = stringValue(in: params, keys: ["sessionId", "session_id"]),
                  let toolCallId = stringValue(in: params, keys: ["toolCallId", "tool_call_id", "id"])
            else {
                NSLog("ACPEventParser: missing fields for JSON-RPC tool_update")
                return nil
            }
            let output = stringifyValue(params["output"] ?? params["output_text"] ?? params["result"])
            let explicitComplete = boolValue(in: params, keys: ["isComplete", "is_complete", "completed"])
            let statusComplete = stringValue(in: params, keys: ["status"])?.lowercased() == "completed"
            return .toolUpdate(
                sessionId: sessionId,
                toolCallId: toolCallId,
                output: output,
                isComplete: explicitComplete ?? statusComplete
            )

        case "request_permission", "approval/request", "approval.requested":
            guard let sessionId = stringValue(in: params, keys: ["sessionId", "session_id"]),
                  let toolName = stringValue(in: params, keys: ["toolName", "tool_name", "name"]),
                  let requestId = stringValue(in: params, keys: ["requestId", "request_id", "id"])
            else {
                NSLog("ACPEventParser: missing fields for JSON-RPC request_permission")
                return nil
            }
            let description = stringValue(in: params, keys: ["description", "reason", "message"]) ?? ""
            return .requestPermission(
                sessionId: sessionId,
                toolName: toolName,
                description: description,
                requestId: requestId
            )

        case "session_complete", "prompt_complete", "session/complete", "turn/complete":
            guard let sessionId = stringValue(in: params, keys: ["sessionId", "session_id"]) else {
                NSLog("ACPEventParser: missing sessionId for JSON-RPC session_complete")
                return nil
            }
            let stopReason = stringValue(in: params, keys: ["stopReason", "stop_reason", "reason"]) ?? "unknown"
            return .sessionComplete(sessionId: sessionId, stopReason: stopReason)

        case "error":
            let sessionId = stringValue(in: params, keys: ["sessionId", "session_id"])
            let code = intValue(in: params, keys: ["code"]) ?? -1
            let message = stringValue(in: params, keys: ["message", "error"]) ?? "Unknown ACP error"
            return .error(sessionId: sessionId, code: code, message: message)

        default:
            return nil
        }
    }

    // MARK: - Helpers

    private func stringValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                return value
            }
        }
        return nil
    }

    private func boolValue(in object: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = object[key] as? Bool {
                return value
            }
            if let number = object[key] as? NSNumber {
                return number.boolValue
            }
            if let string = object[key] as? String {
                let lowered = string.lowercased()
                if lowered == "true" { return true }
                if lowered == "false" { return false }
            }
        }
        return nil
    }

    private func intValue(in object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? Int {
                return value
            }
            if let number = object[key] as? NSNumber {
                return number.intValue
            }
            if let string = object[key] as? String, let value = Int(string) {
                return value
            }
        }
        return nil
    }

    private func stringifyValue(_ value: Any?) -> String {
        guard let value else { return "" }

        if let string = value as? String {
            return string
        }

        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8)
        else {
            return "\(value)"
        }

        return json
    }
}
