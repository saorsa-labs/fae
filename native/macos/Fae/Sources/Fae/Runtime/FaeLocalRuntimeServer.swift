import Foundation
import Network

struct FaeLocalRuntimeDescriptor: Sendable {
    let baseURL: URL
    let bearerToken: String
    let defaultModel: String
}

@MainActor
final class FaeLocalRuntimeServer {
    private enum ChatOutcome {
        case completed(String)
        case pendingApproval(String)
        case timedOut(String?)
    }

    private struct ParsedRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data?
    }

    private var listener: NWListener?
    private weak var faeCore: FaeCore?
    private weak var conversation: ConversationController?
    private weak var approvalOverlay: ApprovalOverlayController?

    let descriptor: FaeLocalRuntimeDescriptor
    private let port: UInt16

    init(
        faeCore: FaeCore,
        conversation: ConversationController,
        approvalOverlay: ApprovalOverlayController,
        port: UInt16 = 7434
    ) {
        self.faeCore = faeCore
        self.conversation = conversation
        self.approvalOverlay = approvalOverlay
        self.port = port
        self.descriptor = FaeLocalRuntimeDescriptor(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            bearerToken: Self.generateBearerToken(),
            defaultModel: "fae-agent-local"
        )
    }

    func start() {
        guard listener == nil else { return }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!
        )

        do {
            listener = try NWListener(using: params)
        } catch {
            NSLog("FaeLocalRuntimeServer: failed to create listener — %@", error.localizedDescription)
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                NSLog("FaeLocalRuntimeServer: listening on 127.0.0.1:%d", self?.port ?? 0)
            case .failed(let error):
                NSLog("FaeLocalRuntimeServer: listener failed — %@", error.localizedDescription)
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

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(on: connection)
    }

    private nonisolated func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, _, error in
            guard let self, let data else {
                connection.cancel()
                return
            }
            if let error {
                NSLog("FaeLocalRuntimeServer: receive error — %@", error.localizedDescription)
                connection.cancel()
                return
            }
            Task { @MainActor in
                self.processRequest(data: data, connection: connection)
            }
        }
    }

    private func processRequest(data: Data, connection: NWConnection) {
        guard let request = parseRequest(from: data) else {
            sendResponse(connection: connection, status: 400, body: ["error": "malformed request"])
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            handleHealth(connection: connection)
        case ("GET", "/v1/models"):
            guard authorize(request) else {
                sendResponse(connection: connection, status: 401, body: ["error": "unauthorized"])
                return
            }
            sendResponse(connection: connection, status: 200, body: FaeOpenAICompatResponseFactory.models(defaultModel: descriptor.defaultModel))
        case ("POST", "/v1/chat/completions"):
            guard authorize(request) else {
                sendResponse(connection: connection, status: 401, body: ["error": "unauthorized"])
                return
            }
            handleChatCompletion(body: request.body, connection: connection)
        default:
            sendResponse(connection: connection, status: 404, body: ["error": "not found", "path": request.path])
        }
    }

    private func handleHealth(connection: NWConnection) {
        let pipeline = faeCore?.pipelineState.rawValue ?? "stopped"
        sendResponse(connection: connection, status: 200, body: [
            "status": "ok",
            "pipeline": pipeline,
            "endpoint": descriptor.baseURL.absoluteString,
        ])
    }

    private func handleChatCompletion(body: Data?, connection: NWConnection) {
        guard let body else {
            sendResponse(connection: connection, status: 400, body: ["error": "missing body"])
            return
        }
        guard let faeCore, let conversation else {
            sendResponse(connection: connection, status: 503, body: ["error": "runtime unavailable"])
            return
        }

        let decoder = JSONDecoder()
        let request: FaeOpenAICompatChatRequest
        do {
            request = try decoder.decode(FaeOpenAICompatChatRequest.self, from: body)
        } catch {
            sendResponse(connection: connection, status: 400, body: ["error": "invalid request body"])
            return
        }

        if request.stream == true {
            sendResponse(connection: connection, status: 400, body: ["error": "streaming not supported yet"])
            return
        }

        let injectedPrompt = request.injectedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !injectedPrompt.isEmpty else {
            sendResponse(connection: connection, status: 400, body: ["error": "missing user prompt"])
            return
        }

        let requestID = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let startedAt = Date()
        let baselineApprovalID = approvalOverlay?.activeApproval?.id

        conversation.lastInteractionTimestamp = Date()
        setCoworkConversationRouting(active: true)
        faeCore.injectDesktopText(injectedPrompt)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.awaitOutcome(since: startedAt, baselineApprovalID: baselineApprovalID)
            let body: [String: Any]
            switch outcome {
            case .completed(let content):
                body = FaeOpenAICompatResponseFactory.chatCompletion(
                    id: requestID,
                    model: request.model,
                    content: content,
                    finishReason: "stop",
                    faeStatus: "completed",
                    approvalPending: false
                )
            case .pendingApproval(let toolName):
                body = FaeOpenAICompatResponseFactory.chatCompletion(
                    id: requestID,
                    model: request.model,
                    content: "Fae is waiting for local approval before running \(toolName).",
                    finishReason: "stop",
                    faeStatus: "pending_approval",
                    approvalPending: true
                )
            case .timedOut(let partial):
                body = FaeOpenAICompatResponseFactory.chatCompletion(
                    id: requestID,
                    model: request.model,
                    content: partial ?? "Fae accepted the request and is still working.",
                    finishReason: "length",
                    faeStatus: "accepted",
                    approvalPending: false
                )
            }
            self.sendResponse(connection: connection, status: 200, body: body)
            Task { @MainActor [weak self] in
                await self?.clearCoworkConversationRoutingWhenIdle(since: startedAt)
            }
        }
    }

    private func awaitOutcome(since: Date, baselineApprovalID: UInt64?) async -> ChatOutcome {
        let deadline = Date().addingTimeInterval(45)

        while Date() < deadline {
            if let approval = approvalOverlay?.activeApproval,
               approval.id != baselineApprovalID
            {
                return .pendingApproval(approval.toolName)
            }

            if let conversation {
                if !conversation.isGenerating,
                   !conversation.isStreaming,
                   let assistant = conversation.messages.last(where: { message in
                       message.role == .assistant && message.timestamp >= since.addingTimeInterval(-0.25)
                   })
                {
                    return .completed(assistant.content)
                }

                if !conversation.isGenerating,
                   !conversation.streamingText.isEmpty,
                   conversation.lastInteractionTimestamp >= since.addingTimeInterval(-0.25)
                {
                    return .completed(conversation.streamingText)
                }
            }

            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        return .timedOut(conversation?.streamingText.nilIfEmpty)
    }

    private func clearCoworkConversationRoutingWhenIdle(since: Date) async {
        let deadline = Date().addingTimeInterval(60)

        while Date() < deadline {
            let approvalPending = approvalOverlay?.activeApproval != nil
            let hasFreshAssistantReply = conversation?.messages.contains(where: { message in
                message.role == .assistant && message.timestamp >= since.addingTimeInterval(-0.25)
            }) == true
            let isIdle = conversation?.isGenerating == false && conversation?.isStreaming == false

            if !approvalPending && (hasFreshAssistantReply || isIdle) {
                break
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        setCoworkConversationRouting(active: false)
    }

    private func setCoworkConversationRouting(active: Bool) {
        NotificationCenter.default.post(
            name: .faeCoworkConversationRoutingChanged,
            object: nil,
            userInfo: ["active": active]
        )
    }

    private func authorize(_ request: ParsedRequest) -> Bool {
        guard let authHeader = request.headers["authorization"] else { return false }
        let prefix = "Bearer "
        guard authHeader.hasPrefix(prefix) else { return false }
        let token = String(authHeader.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return token == descriptor.bearerToken
    }

    private func parseRequest(from data: Data) -> ParsedRequest? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let parts = raw.components(separatedBy: "\r\n\r\n")
        guard let head = parts.first else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestLineParts = requestLine.split(separator: " ")
        guard requestLineParts.count >= 2 else { return nil }

        let method = String(requestLineParts[0]).uppercased()
        let path = String(requestLineParts[1].split(separator: "?", maxSplits: 1)[0])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let body: Data?
        if parts.count > 1 {
            body = parts.dropFirst().joined(separator: "\r\n\r\n").data(using: .utf8)
        } else {
            body = nil
        }

        return ParsedRequest(method: method, path: path, headers: headers, body: body)
    }

    private func sendResponse(connection: NWConnection, status: Int, body: [String: Any]) {
        let jsonData: Data
        do {
            jsonData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            sendRawResponse(connection: connection, status: 500, contentType: "application/json", body: Data("{\"error\":\"serialization failed\"}".utf8))
            return
        }
        sendRawResponse(connection: connection, status: status, contentType: "application/json", body: jsonData)
    }

    private func sendRawResponse(connection: NWConnection, status: Int, contentType: String, body: Data) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        case 503: statusText = "Service Unavailable"
        default: statusText = "OK"
        }

        let headers = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "\r\n",
        ].joined(separator: "\r\n")

        let responseData = Data(headers.utf8) + body
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func generateBearerToken() -> String {
        [UUID().uuidString.replacingOccurrences(of: "-", with: ""), UUID().uuidString.replacingOccurrences(of: "-", with: "")]
            .joined()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
