import Foundation
import Network

/// Lightweight localhost-only HTTP test server for driving Fae programmatically.
///
/// Activated only via `--test-server` CLI argument or `FAE_TEST_SERVER=1` env var.
/// Completely inert in normal use — zero overhead when not started.
///
/// Endpoints:
/// - `GET  /health`        — Pipeline state + readiness check
/// - `POST /inject`        — `{"text":"..."}` → FaeCore.injectText()
/// - `GET  /status`        — Pipeline state, tool mode, model label, thinking, onboarded
/// - `GET  /events?since=N`— Debug console events since sequence N
/// - `GET  /conversation`  — Messages array + isGenerating + streamingText
/// - `POST /cancel`        — Cancel current LLM generation
/// - `POST /config`        — `{"key":"...","value":"..."}` → FaeCore.patchConfig()
/// - `POST /approve`       — `{"approved":true}` → resolve pending tool approval
/// - `GET  /approvals`     — List pending approval requests
/// - `POST /reset`         — Clear conversation, events, and pipeline history
/// - `POST /command`       — `{"name":"...","payload":{...}}` → FaeCore.sendCommand()
/// - `POST /test-input`    — Trigger input-required overlay (testing only)
@MainActor
final class TestServer {
    private var listener: NWListener?
    private weak var faeCore: FaeCore?
    private weak var debugConsole: DebugConsoleController?
    private weak var conversation: ConversationController?
    private weak var approvalOverlay: ApprovalOverlayController?
    private var injectedTurnMuteDepth: Int = 0
    private var listeningStateBeforeInjectedTurns: Bool?

    private let port: UInt16 = 7433

    init(faeCore: FaeCore, debugConsole: DebugConsoleController, conversation: ConversationController, approvalOverlay: ApprovalOverlayController) {
        self.faeCore = faeCore
        self.debugConsole = debugConsole
        self.conversation = conversation
        self.approvalOverlay = approvalOverlay
    }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!
        )

        do {
            listener = try NWListener(using: params)
        } catch {
            NSLog("TestServer: failed to create listener — %@", error.localizedDescription)
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                NSLog("TestServer: listening on 127.0.0.1:%d", 7433)
            case .failed(let error):
                NSLog("TestServer: listener failed — %@", error.localizedDescription)
            default:
                break
            }
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(on: connection)
    }

    private nonisolated func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data else {
                connection.cancel()
                return
            }
            if let error {
                NSLog("TestServer: receive error — %@", error.localizedDescription)
                connection.cancel()
                return
            }
            Task { @MainActor in
                self.processRequest(data: data, connection: connection)
            }
        }
    }

    private func processRequest(data: Data, connection: NWConnection) {
        // Body size limit: 64KB
        if data.count > 65536 {
            sendResponse(connection: connection, status: 400, body: ["error": "request body too large"])
            return
        }

        guard let raw = String(data: data, encoding: .utf8) else {
            sendResponse(connection: connection, status: 400, body: ["error": "invalid request"])
            return
        }

        // Parse first line: "METHOD /path HTTP/1.1"
        let firstLine = raw.prefix(while: { $0 != "\r" && $0 != "\n" })
        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            sendResponse(connection: connection, status: 400, body: ["error": "malformed request"])
            return
        }

        let method = String(parts[0]).uppercased()
        let fullPath = String(parts[1])

        // Split path and query string
        let pathComponents = fullPath.split(separator: "?", maxSplits: 1)
        let path = String(pathComponents[0])
        let query = pathComponents.count > 1 ? parseQuery(String(pathComponents[1])) : [:]

        // Extract body (after \r\n\r\n)
        var bodyData: Data?
        if let range = raw.range(of: "\r\n\r\n") {
            let bodyString = String(raw[range.upperBound...])
            if !bodyString.isEmpty {
                bodyData = bodyString.data(using: .utf8)
            }
        }

        route(method: method, path: path, query: query, body: bodyData, connection: connection)
    }

    // MARK: - Routing

    private func route(method: String, path: String, query: [String: String], body: Data?, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/health"):
            handleHealth(connection: connection)
        case ("POST", "/inject"):
            handleInject(body: body, connection: connection)
        case ("GET", "/status"):
            handleStatus(connection: connection)
        case ("GET", "/events"):
            handleEvents(query: query, connection: connection)
        case ("GET", "/conversation"):
            handleConversation(connection: connection)
        case ("POST", "/cancel"):
            handleCancel(connection: connection)
        case ("POST", "/config"):
            handleConfig(body: body, connection: connection)
        case ("POST", "/approve"):
            handleApprove(body: body, connection: connection)
        case ("GET", "/approvals"):
            handleApprovals(connection: connection)
        case ("POST", "/reset"):
            handleReset(connection: connection)
        case ("POST", "/command"):
            handleCommand(body: body, connection: connection)
        case ("POST", "/test-input"):
            handleTestInput(body: body, connection: connection)
        default:
            sendResponse(connection: connection, status: 404, body: ["error": "not found", "path": path])
        }
    }

    // MARK: - Endpoint Handlers

    private func handleHealth(connection: NWConnection) {
        let state = faeCore?.pipelineState ?? .stopped
        let isReady = state == .running
        sendResponse(connection: connection, status: 200, body: [
            "status": isReady ? "ok" : "not_ready",
            "pipeline": state.rawValue,
        ])
    }

    private func handleInject(body: Data?, connection: NWConnection) {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = json["text"] as? String, !text.isEmpty
        else {
            sendResponse(connection: connection, status: 400, body: ["error": "missing or empty 'text' field"])
            return
        }

        guard let faeCore else {
            sendResponse(connection: connection, status: 503, body: ["error": "faeCore not available"])
            return
        }

        let turnId = UUID().uuidString

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.beginInjectedTurnIsolation()

            // Add to conversation panel (mimics ConversationController.handleUserSent)
            self.conversation?.appendMessage(role: .user, content: text)
            faeCore.injectText(text)

            Task { @MainActor [weak self] in
                await self?.endInjectedTurnIsolationWhenIdle()
            }

            self.sendResponse(connection: connection, status: 200, body: [
                "ok": true,
                "injected": text,
                "turn_id": turnId,
            ])
        }
    }

    private func handleStatus(connection: NWConnection) {
        let state = faeCore?.pipelineState ?? .stopped
        let toolMode = faeCore?.toolMode ?? "unknown"
        let modelLabel = conversation?.loadedModelLabel ?? ""
        let thinkingEnabled = faeCore?.thinkingEnabled ?? false
        let thinkingLevel = faeCore?.thinkingLevel.rawValue ?? FaeThinkingLevel.fast.rawValue
        let hasOwnerSetUp = faeCore?.hasOwnerSetUp ?? false
        let isListening = conversation?.isListening ?? false

        // Derive policy profile from tool mode (matches PolicyProfile enum rawValues)
        let policyProfile: String
        switch toolMode {
        case "off", "read_only":
            policyProfile = "moreCautious"
        case "full_no_approval":
            policyProfile = "moreAutonomous"
        default:
            policyProfile = "balanced"
        }

        sendResponse(connection: connection, status: 200, body: [
            "pipeline": state.rawValue,
            "toolMode": toolMode,
            "modelLabel": modelLabel,
            "thinkingEnabled": thinkingEnabled,
            "thinkingLevel": thinkingLevel,
            "hasOwnerSetUp": hasOwnerSetUp,
            "isListening": isListening,
            "policyProfile": policyProfile,
        ])
    }

    private func handleEvents(query: [String: String], connection: NWConnection) {
        let since = Int(query["since"] ?? "0") ?? 0
        let events = debugConsole?.events ?? []

        // Events array index is the monotonic sequence number
        let startIndex = max(0, min(since, events.count))
        let slice = Array(events[startIndex...])

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let serialized: [[String: Any]] = slice.enumerated().map { offset, event in
            let normalizedKind: String
            switch event.kind {
            case .toolCall, .toolResult:
                normalizedKind = "Tool"
            default:
                normalizedKind = event.kind.rawValue
            }
            return [
                "seq": startIndex + offset,
                "ts": isoFormatter.string(from: event.timestamp),
                "kind": normalizedKind,
                "raw_kind": event.kind.rawValue,
                "text": event.text,
            ]
        }

        sendResponse(connection: connection, status: 200, body: [
            "events": serialized,
            "total": events.count,
            "since": since,
        ])
    }

    private func handleConversation(connection: NWConnection) {
        let messages = conversation?.messages ?? []
        let isGenerating = conversation?.isGenerating ?? false
        let streamingText = conversation?.streamingText ?? ""

        let serialized: [[String: Any]] = messages.map { msg in
            [
                "id": msg.id.uuidString,
                "role": msg.role.rawValue,
                "content": msg.content,
                "timestamp": msg.timestamp.timeIntervalSince1970,
            ]
        }

        // Query speaking and deferred tool state from PipelineCoordinator (async actor calls).
        Task { @MainActor [weak self] in
            let isSpeaking = await self?.faeCore?.isSpeaking() ?? false
            let hasDeferredTools = await self?.faeCore?.hasPendingDeferredTools() ?? false
            self?.sendResponse(connection: connection, status: 200, body: [
                "messages": serialized,
                "isGenerating": isGenerating,
                "isSpeaking": isSpeaking,
                "hasDeferredTools": hasDeferredTools,
                "isListening": self?.conversation?.isListening ?? false,
                "streamingText": streamingText,
                "count": messages.count,
            ])
        }
    }

    private func beginInjectedTurnIsolation() async {
        guard let conversation else { return }
        if injectedTurnMuteDepth == 0 {
            listeningStateBeforeInjectedTurns = conversation.isListening
            if conversation.isListening {
                await setListeningStateForTestIsolation(false)
            }
        }
        injectedTurnMuteDepth += 1
    }

    private func endInjectedTurnIsolationWhenIdle() async {
        guard injectedTurnMuteDepth > 0 else { return }

        let maxPolls = 240
        for _ in 0..<maxPolls {
            let isGenerating = conversation?.isGenerating ?? false
            let isSpeaking = await faeCore?.isSpeaking() ?? false
            let hasDeferredTools = await faeCore?.hasPendingDeferredTools() ?? false
            if !isGenerating && !isSpeaking && !hasDeferredTools {
                break
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        injectedTurnMuteDepth = max(0, injectedTurnMuteDepth - 1)
        guard injectedTurnMuteDepth == 0 else { return }

        if listeningStateBeforeInjectedTurns == true {
            await setListeningStateForTestIsolation(true)
        }
        listeningStateBeforeInjectedTurns = nil
    }

    private func setListening(_ active: Bool) {
        conversation?.isListening = active
        NotificationCenter.default.post(
            name: .faeConversationGateSet,
            object: nil,
            userInfo: ["active": active]
        )
    }

    private func setListeningStateForTestIsolation(_ active: Bool) async {
        conversation?.isListening = active
        await faeCore?.setMicMutedForTesting(!active)
    }

    private func handleCancel(connection: NWConnection) {
        faeCore?.cancel()
        sendResponse(connection: connection, status: 200, body: ["ok": true, "cancelled": true])
    }

    // MARK: - Config Endpoint

    private func handleConfig(body: Data?, connection: NWConnection) {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let key = json["key"] as? String, !key.isEmpty
        else {
            sendResponse(connection: connection, status: 400, body: ["error": "missing 'key' field"])
            return
        }

        guard let faeCore else {
            sendResponse(connection: connection, status: 503, body: ["error": "faeCore not available"])
            return
        }

        // Coerce string booleans/numbers to native types so patchConfig's type guards work.
        // YAML "true"/"false" arrive as JSON strings, but patchConfig expects Bool/Float/Int.
        let rawValue = json["value"]
        let value: Any?
        if let str = rawValue as? String {
            switch str.lowercased() {
            case "true":  value = true
            case "false": value = false
            default:
                if let intVal = Int(str) { value = intVal }
                else if let dblVal = Double(str) { value = dblVal }
                else { value = str }
            }
        } else {
            value = rawValue
        }

        // Read previous value
        let previous: String
        switch key {
        case "tool_mode":
            previous = faeCore.toolMode
        case "llm.thinking_enabled":
            previous = String(faeCore.thinkingEnabled)
        default:
            previous = "unknown"
        }

        faeCore.patchConfig(key: key, payload: ["value": value as Any])

        // Read current value after patch
        let current: String
        switch key {
        case "tool_mode":
            current = faeCore.toolMode
        case "llm.thinking_enabled":
            current = String(faeCore.thinkingEnabled)
        default:
            current = "applied"
        }

        sendResponse(connection: connection, status: 200, body: [
            "ok": true,
            "key": key,
            "previous": previous,
            "current": current,
        ])
    }

    // MARK: - Approval Endpoints

    /// POST /approve — `{"approved":true}` or `{"decision":"always"}` → resolve pending tool approval.
    ///
    /// Supported `decision` values: `"yes"`, `"no"`, `"always"`, `"approveAllReadOnly"`, `"approveAll"`.
    /// When `decision` is omitted, falls back to `approved` bool.
    private func handleApprove(body: Data?, connection: NWConnection) {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            sendResponse(connection: connection, status: 400, body: ["error": "invalid JSON body"])
            return
        }

        // Must have either "approved" or "decision" field.
        let decisionStr = json["decision"] as? String
        let approved = json["approved"] as? Bool
        guard decisionStr != nil || approved != nil else {
            sendResponse(connection: connection, status: 400, body: ["error": "missing 'approved' or 'decision' field"])
            return
        }

        guard let faeCore else {
            sendResponse(connection: connection, status: 503, body: ["error": "faeCore not available"])
            return
        }

        // Determine request ID: explicit or from active approval.
        let requestID: UInt64
        if let explicitID = json["id"] as? UInt64 {
            requestID = explicitID
        } else if let numericID = json["id"] as? Int {
            requestID = UInt64(numericID)
        } else if let activeID = approvalOverlay?.activeApproval?.id {
            requestID = activeID
        } else {
            sendResponse(connection: connection, status: 404, body: ["error": "no pending approval"])
            return
        }

        let toolName = json["tool_name"] as? String ?? approvalOverlay?.activeApproval?.toolName

        var payload: [String: Any] = ["approved": approved ?? true]
        if let decisionStr { payload["decision"] = decisionStr }
        if let toolName { payload["tool_name"] = toolName }

        faeCore.respondToApproval(requestID: requestID, decisionStr: decisionStr, toolName: toolName, payload: payload)

        sendResponse(connection: connection, status: 200, body: [
            "ok": true,
            "approved": approved ?? (decisionStr != "no"),
            "decision": decisionStr ?? (approved == true ? "yes" : "no"),
            "requestId": requestID,
        ] as [String: Any])
    }

    private func handleApprovals(connection: NWConnection) {
        var pending: [[String: Any]] = []
        if let approval = approvalOverlay?.activeApproval {
            pending.append([
                "id": approval.id,
                "tool": approval.toolName,
                "summary": approval.description,
            ])
        }

        sendResponse(connection: connection, status: 200, body: [
            "pending": pending,
        ])
    }

    // MARK: - Reset Endpoint

    private func handleReset(connection: NWConnection) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            // 1. Cancel and await full stop (generation + TTS playback + deferred tools)
            await self.faeCore?.cancelAndWait()

            // 3. Clear conversation UI
            self.conversation?.clearMessages()
            self.conversation?.streamingText = ""
            self.conversation?.isGenerating = false
            self.conversation?.isStreaming = false

            // 4. Clear debug events
            self.debugConsole?.clear()

            // 5. Reset pipeline conversation history
            await self.faeCore?.resetConversationAsync()

            self.sendResponse(connection: connection, status: 200, body: [
                "ok": true,
                "cleared": ["conversation", "events", "history"],
            ])
        }
    }

    // MARK: - Command Endpoint

    /// POST /command — Dispatch a host command through FaeCore.
    ///
    /// JSON body:
    /// - `name`: command name (required)
    /// - `payload`: command payload object (optional, defaults to `{}`)
    private func handleCommand(body: Data?, connection: NWConnection) {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let name = json["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            sendResponse(connection: connection, status: 400, body: ["error": "missing 'name' field"])
            return
        }

        guard let faeCore else {
            sendResponse(connection: connection, status: 503, body: ["error": "faeCore not available"])
            return
        }

        let payload = json["payload"] as? [String: Any] ?? [:]
        faeCore.sendCommand(name: name, payload: payload)

        sendResponse(connection: connection, status: 200, body: [
            "ok": true,
            "name": name,
            "payload_keys": payload.keys.sorted(),
        ])
    }

    // MARK: - Test Input Endpoint

    /// POST /test-input — Trigger input-required overlay for testing.
    ///
    /// Optional JSON body:
    /// - `title`: Card header (default: "Fae needs your input")
    /// - `prompt`: Description text (default: "Please provide the requested information")
    /// - `is_secure`: Show SecureField (default: false)
    /// - `is_multiline`: Show multi-line TextEditor (default: false)
    /// - `placeholder`: Input placeholder text (default: "")
    /// - `mode`: "text" (single field) or "form" (multiple fields)
    /// - `fields`: Array of field objects for form mode
    private func handleTestInput(body: Data?, connection: NWConnection) {
        let json: [String: Any]
        if let body, let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            json = parsed
        } else {
            json = [:]
        }

        let requestId = UUID().uuidString
        var info: [String: Any] = [
            "request_id": requestId,
            "title": json["title"] as? String ?? "Fae needs your input",
            "prompt": json["prompt"] as? String ?? "Please provide the requested information",
        ]

        if let isSecure = json["is_secure"] as? Bool { info["is_secure"] = isSecure }
        if let isMultiline = json["is_multiline"] as? Bool { info["is_multiline"] = isMultiline }
        if let placeholder = json["placeholder"] as? String { info["placeholder"] = placeholder }
        if let mode = json["mode"] as? String { info["mode"] = mode }
        if let fields = json["fields"] { info["fields"] = fields }

        NotificationCenter.default.post(name: .faeInputRequired, object: nil, userInfo: info)

        sendResponse(connection: connection, status: 200, body: [
            "ok": true,
            "request_id": requestId,
        ])
    }

    // MARK: - Response Helpers

    private func sendResponse(connection: NWConnection, status: Int, body: [String: Any]) {
        let jsonData: Data
        do {
            jsonData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            let fallback = "{\"error\":\"serialization failed\"}".data(using: .utf8)!
            sendRawResponse(connection: connection, status: 500, contentType: "application/json", body: fallback)
            return
        }
        sendRawResponse(connection: connection, status: status, contentType: "application/json", body: jsonData)
    }

    private func sendRawResponse(connection: NWConnection, status: Int, contentType: String, body: Data) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        case 503: statusText = "Service Unavailable"
        default:  statusText = "Error"
        }

        var header = "HTTP/1.1 \(status) \(statusText)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "\r\n"

        var responseData = header.data(using: .utf8)!
        responseData.append(body)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Query Parsing

    private func parseQuery(_ queryString: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                result[key] = value
            }
        }
        return result
    }
}
