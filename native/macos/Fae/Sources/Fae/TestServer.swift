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
/// - `GET  /inputs`        — List pending secure input requests
/// - `GET  /cowork/state`  — Current Cowork window + attachment snapshot
/// - `GET  /cowork/conversation` — Current Cowork conversation snapshot
/// - `POST /cowork/open`   — Open the Cowork window, optionally to a section
/// - `POST /cowork/clear-attachments` — Remove Cowork attachments from the selected workspace
/// - `POST /cowork/clear-conversation` — Clear the Cowork conversation transcript
/// - `POST /cowork/attach-files`      — Add explicit file paths to Cowork
/// - `POST /cowork/paste`  — Paste text, file URLs, or an image into Cowork
/// - `POST /cowork/submit` — Submit a Cowork prompt through the selected agent
/// - `POST /reset`         — Clear conversation, events, and pipeline history
/// - `POST /memory/import-text`     — Import a raw artifact into memory inbox
/// - `POST /memory/ingest-pending`  — Ingest pending files from memory inbox folder
/// - `POST /memory/generate-digest` — Generate a digest from recent imported memories
/// - `POST /memory/recall`          — Return raw memory recall context for a query
/// - `POST /command`       — `{"name":"...","payload":{...}}` → FaeCore.sendCommand()
/// - `POST /input-response`— Resolve a pending secure input request
/// - `POST /test-input`    — Trigger input-required overlay (testing only)
@MainActor
final class TestServer {
    private var listener: NWListener?
    private weak var faeCore: FaeCore?
    private weak var debugConsole: DebugConsoleController?
    private weak var conversation: ConversationController?
    private weak var approvalOverlay: ApprovalOverlayController?
    private weak var auxiliaryWindows: AuxiliaryWindowManager?
    private weak var coworkWindow: CoworkWindowController?
    private var injectedTurnMuteDepth: Int = 0
    private var listeningStateBeforeInjectedTurns: Bool?

    private let port: UInt16 = 7433

    init(
        faeCore: FaeCore,
        debugConsole: DebugConsoleController,
        conversation: ConversationController,
        approvalOverlay: ApprovalOverlayController,
        auxiliaryWindows: AuxiliaryWindowManager,
        coworkWindow: CoworkWindowController
    ) {
        self.faeCore = faeCore
        self.debugConsole = debugConsole
        self.conversation = conversation
        self.approvalOverlay = approvalOverlay
        self.auxiliaryWindows = auxiliaryWindows
        self.coworkWindow = coworkWindow
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
        case ("GET", "/inputs"):
            handleInputs(connection: connection)
        case ("GET", "/cowork/state"):
            handleCoworkState(connection: connection)
        case ("GET", "/cowork/conversation"):
            handleCoworkConversation(connection: connection)
        case ("POST", "/cowork/open"):
            handleCoworkOpen(body: body, connection: connection)
        case ("POST", "/cowork/clear-attachments"):
            handleCoworkClearAttachments(connection: connection)
        case ("POST", "/cowork/clear-conversation"):
            handleCoworkClearConversation(connection: connection)
        case ("POST", "/cowork/attach-files"):
            handleCoworkAttachFiles(body: body, connection: connection)
        case ("POST", "/cowork/paste"):
            handleCoworkPaste(body: body, connection: connection)
        case ("POST", "/cowork/submit"):
            handleCoworkSubmit(body: body, connection: connection)
        case ("POST", "/reset"):
            handleReset(connection: connection)
        case ("POST", "/memory/import-text"):
            handleMemoryImportText(body: body, connection: connection)
        case ("POST", "/memory/ingest-pending"):
            handleMemoryIngestPending(body: body, connection: connection)
        case ("POST", "/memory/generate-digest"):
            handleMemoryGenerateDigest(connection: connection)
        case ("POST", "/memory/recall"):
            handleMemoryRecall(body: body, connection: connection)
        case ("POST", "/command"):
            handleCommand(body: body, connection: connection)
        case ("POST", "/input-response"):
            handleInputResponse(body: body, connection: connection)
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

            // Reject concurrent injection — two test processes hitting the same Fae
            // instance simultaneously causes the LLM worker to be cancelled and
            // restarted mid-inference, briefly doubling model RAM usage and OOM.
            let alreadyGenerating = self.conversation?.isGenerating ?? false
            let alreadySpeaking = await faeCore.isSpeaking()
            if alreadyGenerating || alreadySpeaking {
                self.sendResponse(connection: connection, status: 409, body: [
                    "error": "Fae is already generating — wait for the current turn to finish",
                    "isGenerating": alreadyGenerating,
                    "isSpeaking": alreadySpeaking,
                ] as [String: Any])
                return
            }

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
        let approvalVisible = auxiliaryWindows?.isApprovalVisible ?? false
        let approvalToolName = approvalOverlay?.activeApproval?.toolName
        let approvalRequestID = approvalOverlay?.activeApproval?.id

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

        let defaults = UserDefaults.standard
        sendResponse(connection: connection, status: 200, body: [
            "pipeline": state.rawValue,
            "toolMode": toolMode,
            "modelLabel": modelLabel,
            "thinkingEnabled": thinkingEnabled,
            "thinkingLevel": thinkingLevel,
            "hasOwnerSetUp": hasOwnerSetUp,
            "isListening": isListening,
            "approvalVisible": approvalVisible,
            "approvalToolName": approvalToolName as Any,
            "approvalRequestId": approvalRequestID as Any,
            "policyProfile": policyProfile,
            "dualModelEnabled":        FaeConfig.load().llm.dualModelEnabled,
            "operatorLoaded":          defaults.bool(forKey: "fae.runtime.operator_loaded"),
            "conciergeLoaded":         defaults.bool(forKey: "fae.runtime.concierge_loaded"),
            "currentRoute":            defaults.string(forKey: "fae.runtime.current_route") ?? "operator",
            "fallbackReason":          defaults.string(forKey: "fae.runtime.fallback_reason") ?? "unknown",
            "operatorWorkerRestarts":  defaults.integer(forKey: "fae.runtime.operator_worker_restarts"),
            "conciergeWorkerRestarts": defaults.integer(forKey: "fae.runtime.concierge_worker_restarts"),
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
        let backgroundLookupActive = conversation?.isBackgroundLookupActive ?? false
        let isGenerating = (conversation?.isGenerating ?? false) || backgroundLookupActive
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
            let activeInput = self?.approvalOverlay?.activeInput
            self?.sendResponse(connection: connection, status: 200, body: [
                "messages": serialized,
                "isGenerating": isGenerating,
                "isBackgroundLookupActive": backgroundLookupActive,
                "isSpeaking": isSpeaking,
                "hasDeferredTools": hasDeferredTools,
                "hasActiveInput": activeInput != nil,
                "activeInputId": activeInput?.id ?? "",
                "activeInputTitle": activeInput?.title ?? "",
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

        Task { @MainActor [weak self] in
            guard let self else { return }

            let requestID: UInt64?
            if let explicitID = json["id"] as? UInt64 {
                requestID = explicitID
            } else if let numericID = json["id"] as? Int {
                requestID = UInt64(numericID)
            } else {
                requestID = await faeCore.mostRecentPendingApprovalID()
            }

            guard let requestID else {
                self.sendResponse(connection: connection, status: 404, body: ["error": "no pending approval"])
                return
            }

            let pending = await faeCore.pendingApprovalSnapshots()
            let toolName = json["tool_name"] as? String
                ?? pending.first(where: { ($0["id"] as? UInt64) == requestID })?["tool"] as? String

            var payload: [String: Any] = ["approved": approved ?? (decisionStr != "no")]
            if let decisionStr { payload["decision"] = decisionStr }
            if let toolName { payload["tool_name"] = toolName }

            faeCore.respondToApproval(requestID: requestID, decisionStr: decisionStr, toolName: toolName, payload: payload)

            self.sendResponse(connection: connection, status: 200, body: [
                "ok": true,
                "approved": approved ?? (decisionStr != "no"),
                "decision": decisionStr ?? (approved == true ? "yes" : "no"),
                "requestId": requestID,
            ] as [String: Any])
        }
    }

    private func handleApprovals(connection: NWConnection) {
        guard let faeCore else {
            sendResponse(connection: connection, status: 503, body: ["error": "faeCore not available"])
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let pending = await faeCore.pendingApprovalSnapshots()
            self.sendResponse(connection: connection, status: 200, body: [
                "pending": pending,
            ])
        }
    }

    private func handleInputs(connection: NWConnection) {
        let pending = approvalOverlay?.activeInput.map(Self.serializeInputRequest(_:)).map { [$0] } ?? []
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
            await self.faeCore?.clearPendingApprovalsForTest()
            await self.faeCore?.clearAllToolApprovalsForTest()
            await self.faeCore?.clearUserSchedulerTasksForTest()
            self.approvalOverlay?.cancelInput()

            self.sendResponse(connection: connection, status: 200, body: [
                "ok": true,
                "cleared": ["conversation", "events", "history", "approvals", "inputs", "tool_grants", "scheduler_tasks"],
            ])
        }
    }

    // MARK: - Memory Test Endpoints

    private func handleMemoryImportText(body: Data?, connection: NWConnection) {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let rawText = json["text"] as? String,
              !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            sendResponse(connection: connection, status: 400, body: ["error": "missing or empty 'text' field"])
            return
        }

        guard let service = faeCore?.memoryInboxService else {
            sendResponse(connection: connection, status: 503, body: ["error": "memory inbox service not available"])
            return
        }

        let sourceType = (json["source_type"] as? String)
            .flatMap(MemoryArtifactSourceType.init(rawValue:))
            ?? .pastedText
        let nonceEnabled = json["dedupe_nonce"] as? Bool ?? false
        let nonce = nonceEnabled ? UUID().uuidString.lowercased() : nil
        let title = Self.appendNonce(value: json["title"] as? String, nonce: nonce)
        let origin = Self.appendNonce(value: json["origin"] as? String, nonce: nonce)
        let text = Self.appendNonceToText(rawText, nonce: nonce)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await service.importText(
                    title: title,
                    text: text,
                    origin: origin,
                    sourceType: sourceType
                )
                self.sendResponse(connection: connection, status: 200, body: [
                    "ok": true,
                    "artifact_id": result.artifact.id,
                    "record_id": result.record.id,
                    "source_type": result.artifact.sourceType.rawValue,
                    "was_duplicate": result.wasDuplicate,
                ])
            } catch {
                self.sendResponse(connection: connection, status: 500, body: [
                    "error": error.localizedDescription,
                ])
            }
        }
    }

    private func handleMemoryIngestPending(body: Data?, connection: NWConnection) {
        guard let service = faeCore?.memoryInboxService else {
            sendResponse(connection: connection, status: 503, body: ["error": "memory inbox service not available"])
            return
        }

        let json = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        let limit = max(1, json["limit"] as? Int ?? 16)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let results = try await service.ingestPendingFiles(limit: limit)
                self.sendResponse(connection: connection, status: 200, body: [
                    "ok": true,
                    "imported_count": results.count,
                    "duplicate_count": results.filter(\.wasDuplicate).count,
                ])
            } catch {
                self.sendResponse(connection: connection, status: 500, body: [
                    "error": error.localizedDescription,
                ])
            }
        }
    }

    private func handleMemoryGenerateDigest(connection: NWConnection) {
        guard let service = faeCore?.memoryDigestService else {
            sendResponse(connection: connection, status: 503, body: ["error": "memory digest service not available"])
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let digest = try await service.generateDigest() {
                    self.sendResponse(connection: connection, status: 200, body: [
                        "ok": true,
                        "created": true,
                        "digest_id": digest.id,
                        "kind": digest.kind.rawValue,
                        "source_count": Self.digestSourceCount(from: digest.metadata),
                    ])
                } else {
                    self.sendResponse(connection: connection, status: 200, body: [
                        "ok": true,
                        "created": false,
                        "source_count": 0,
                    ])
                }
            } catch {
                self.sendResponse(connection: connection, status: 500, body: [
                    "error": error.localizedDescription,
                ])
            }
        }
    }

    private func handleMemoryRecall(body: Data?, connection: NWConnection) {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let query = json["query"] as? String,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            sendResponse(connection: connection, status: 400, body: ["error": "missing or empty 'query' field"])
            return
        }

        guard let faeCore else {
            sendResponse(connection: connection, status: 503, body: ["error": "faeCore not available"])
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let context = await faeCore.recallMemoryContextForTest(query: query) ?? ""
            let normalized = context.lowercased()
            let hasProvenance = normalized.contains("pasted text")
                || normalized.contains("file")
                || normalized.contains("pdf")
                || normalized.contains("url")
                || normalized.contains("cowork attachment")
                || normalized.contains("proactive")

            self.sendResponse(connection: connection, status: 200, body: [
                "ok": true,
                "has_context": !context.isEmpty,
                "context_length": context.count,
                "has_memory_insights": context.contains("Memory insights:"),
                "has_supporting_memories": context.contains("Supporting memories:"),
                "has_provenance_labels": hasProvenance,
                "mentions_pasted_text": normalized.contains("pasted text"),
                "mentions_file": normalized.contains("file"),
                "context": context,
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
        if name == "conversation.gate_set", let active = payload["active"] as? Bool {
            setListening(active)
        }
        faeCore.sendCommand(name: name, payload: payload)

        sendResponse(connection: connection, status: 200, body: [
            "ok": true,
            "name": name,
            "payload_keys": payload.keys.sorted(),
        ])
    }

    private func handleInputResponse(body: Data?, connection: NWConnection) {
        guard let request = approvalOverlay?.activeInput else {
            sendResponse(connection: connection, status: 404, body: ["error": "no active input request"])
            return
        }

        let json = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        let requestID = json["request_id"] as? String ?? request.id
        guard requestID == request.id else {
            sendResponse(connection: connection, status: 400, body: ["error": "request_id does not match active input"])
            return
        }

        if let rawFormValues = json["form_values"] as? [String: Any] {
            let values = rawFormValues.reduce(into: [String: String]()) { partial, entry in
                partial[entry.key] = "\(entry.value)"
            }
            approvalOverlay?.submitForm(values: values)
            sendResponse(connection: connection, status: 200, body: [
                "ok": true,
                "request_id": requestID,
                "submitted": true,
                "mode": "form",
            ])
            return
        }

        let text = json["text"] as? String ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            approvalOverlay?.cancelInput()
            sendResponse(connection: connection, status: 200, body: [
                "ok": true,
                "request_id": requestID,
                "submitted": false,
                "cancelled": true,
                "mode": "text",
            ])
            return
        }

        approvalOverlay?.submitInput(text: text)
        sendResponse(connection: connection, status: 200, body: [
            "ok": true,
            "request_id": requestID,
            "submitted": true,
            "mode": "text",
        ])
    }

    private func handleCoworkState(connection: NWConnection) {
        guard let coworkWindow else {
            sendResponse(connection: connection, status: 503, body: ["error": "coworkWindow not available"])
            return
        }

        sendResponse(connection: connection, status: 200, body: [
            "ok": true,
            "state": coworkWindow.snapshotForTesting(),
        ])
    }

    private func handleCoworkConversation(connection: NWConnection) {
        guard let coworkWindow else {
            sendResponse(connection: connection, status: 503, body: ["error": "coworkWindow not available"])
            return
        }

        sendResponse(connection: connection, status: 200, body: [
            "ok": true,
            "conversation": coworkWindow.conversationSnapshotForTesting(),
        ])
    }

    private func handleCoworkOpen(body: Data?, connection: NWConnection) {
        guard let coworkWindow else {
            sendResponse(connection: connection, status: 503, body: ["error": "coworkWindow not available"])
            return
        }

        let json = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        let section = (json["section"] as? String).flatMap(CoworkWorkspaceSection.init(rawValue:))
        if json["section"] != nil, section == nil {
            sendResponse(connection: connection, status: 400, body: ["error": "invalid cowork section"])
            return
        }

        coworkWindow.openForTesting(section: section)
        sendResponse(connection: connection, status: 200, body: [
            "ok": true,
            "state": coworkWindow.snapshotForTesting(),
        ])
    }

    private func handleCoworkClearAttachments(connection: NWConnection) {
        guard let coworkWindow else {
            sendResponse(connection: connection, status: 503, body: ["error": "coworkWindow not available"])
            return
        }

        sendResponse(connection: connection, status: 200, body: [
            "ok": true,
            "state": coworkWindow.clearAttachmentsForTesting(),
        ])
    }

    private func handleCoworkClearConversation(connection: NWConnection) {
        guard let coworkWindow else {
            sendResponse(connection: connection, status: 503, body: ["error": "coworkWindow not available"])
            return
        }

        sendResponse(connection: connection, status: 200, body: [
            "ok": true,
            "conversation": coworkWindow.clearConversationForTesting(),
        ])
    }

    private func handleCoworkAttachFiles(body: Data?, connection: NWConnection) {
        guard let coworkWindow else {
            sendResponse(connection: connection, status: 503, body: ["error": "coworkWindow not available"])
            return
        }

        let json = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        guard let paths = json["paths"] as? [String], !paths.isEmpty else {
            sendResponse(connection: connection, status: 400, body: ["error": "missing or empty 'paths' field"])
            return
        }

        let missingPaths = paths.filter { !FileManager.default.fileExists(atPath: $0) }
        guard missingPaths.isEmpty else {
            sendResponse(connection: connection, status: 400, body: [
                "error": "one or more attachment paths do not exist",
                "missing_paths": missingPaths,
            ])
            return
        }

        let replaceExisting = json["replace_existing"] as? Bool ?? false
        sendResponse(connection: connection, status: 200, body: [
            "ok": true,
            "state": coworkWindow.addAttachmentsForTesting(paths: paths, replaceExisting: replaceExisting),
        ])
    }

    private func handleCoworkPaste(body: Data?, connection: NWConnection) {
        guard let coworkWindow else {
            sendResponse(connection: connection, status: 503, body: ["error": "coworkWindow not available"])
            return
        }

        let json = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        let replaceExisting = json["replace_existing"] as? Bool ?? false

        do {
            let state: [String: Any]
            if let text = json["text"] as? String, !text.isEmpty {
                state = try coworkWindow.pasteTextForTesting(text, replaceExisting: replaceExisting)
            } else if let imagePath = json["image_path"] as? String, !imagePath.isEmpty {
                guard FileManager.default.fileExists(atPath: imagePath) else {
                    sendResponse(connection: connection, status: 400, body: [
                        "error": "image_path does not exist",
                        "image_path": imagePath,
                    ])
                    return
                }
                state = try coworkWindow.pasteImageForTesting(at: imagePath, replaceExisting: replaceExisting)
            } else if let paths = json["paths"] as? [String], !paths.isEmpty {
                let missingPaths = paths.filter { !FileManager.default.fileExists(atPath: $0) }
                guard missingPaths.isEmpty else {
                    sendResponse(connection: connection, status: 400, body: [
                        "error": "one or more pasted file paths do not exist",
                        "missing_paths": missingPaths,
                    ])
                    return
                }
                state = try coworkWindow.pasteFilesForTesting(paths: paths, replaceExisting: replaceExisting)
            } else {
                sendResponse(connection: connection, status: 400, body: [
                    "error": "provide 'text', 'image_path', or 'paths' for cowork paste",
                ])
                return
            }

            sendResponse(connection: connection, status: 200, body: [
                "ok": true,
                "state": state,
            ])
        } catch {
            sendResponse(connection: connection, status: 500, body: [
                "error": error.localizedDescription,
            ])
        }
    }

    private func handleCoworkSubmit(body: Data?, connection: NWConnection) {
        guard let coworkWindow else {
            sendResponse(connection: connection, status: 503, body: ["error": "coworkWindow not available"])
            return
        }

        let json = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        guard let prompt = json["prompt"] as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            sendResponse(connection: connection, status: 400, body: ["error": "missing or empty 'prompt' field"])
            return
        }

        do {
            let clearConversation = json["clear_conversation"] as? Bool ?? false
            let conversation = try coworkWindow.submitPromptForTesting(prompt, clearConversation: clearConversation)
            sendResponse(connection: connection, status: 200, body: [
                "ok": true,
                "conversation": conversation,
            ])
        } catch {
            sendResponse(connection: connection, status: 500, body: [
                "error": error.localizedDescription,
            ])
        }
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

    private static func appendNonce(value: String?, nonce: String?) -> String? {
        guard let value, !value.isEmpty else { return value }
        guard let nonce, !nonce.isEmpty else { return value }
        return "\(value) [\(String(nonce.prefix(8)))]"
    }

    private static func appendNonceToText(_ value: String, nonce: String?) -> String {
        guard let nonce, !nonce.isEmpty else { return value }
        return value + "\n\nTest nonce: \(nonce)"
    }

    private static func digestSourceCount(from metadata: String?) -> Int {
        guard let metadata,
              let data = metadata.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = dict["source_record_ids"] as? [String]
        else {
            return 0
        }
        return ids.count
    }

    private static func serializeInputRequest(_ request: ApprovalOverlayController.InputRequest) -> [String: Any] {
        let fields: [[String: Any]] = request.fields.map { field in
            var payload: [String: Any] = [
                "id": field.id,
                "label": field.label,
                "placeholder": field.placeholder,
                "is_secure": field.isSecure,
                "required": field.required,
                "is_multiline": field.isMultiline,
                "must_be_https": field.mustBeHttps,
            ]
            if let minLength = field.minLength { payload["min_length"] = minLength }
            if let maxLength = field.maxLength { payload["max_length"] = maxLength }
            if let regex = field.regex, !regex.isEmpty { payload["regex"] = regex }
            if let allowedValues = field.allowedValues, !allowedValues.isEmpty {
                payload["allowed_values"] = allowedValues
            }
            return payload
        }

        return [
            "id": request.id,
            "title": request.title,
            "prompt": request.prompt,
            "mode": request.isForm ? "form" : "text",
            "fields": fields,
        ]
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
