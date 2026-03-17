import CommonCrypto
import Foundation
import Network

/// Receives WhatsApp Cloud API webhooks over HTTP and sends replies via Graph API.
///
/// - Note: This adapter is intentionally minimal and self-contained:
///   - Runs a lightweight HTTP server using `NWListener`
///   - Verifies webhook challenge requests against `verifyToken`
///   - Parses inbound text messages and forwards them to `messageHandler`
///   - Sends outbound responses with WhatsApp Cloud API
actor WhatsAppAdapter {
    typealias MessageHandler = @Sendable (_ sender: String, _ text: String) async -> String?

    struct Config: Sendable {
        var accessToken: String
        var phoneNumberId: String
        var verifyToken: String
        var allowedNumbers: [String]
        var webhookPath: String
        var appSecret: String?

        init(
            accessToken: String,
            phoneNumberId: String,
            verifyToken: String,
            allowedNumbers: [String] = [],
            webhookPath: String = "/webhook",
            appSecret: String? = nil
        ) {
            self.accessToken = accessToken
            self.phoneNumberId = phoneNumberId
            self.verifyToken = verifyToken
            self.allowedNumbers = allowedNumbers
            self.webhookPath = webhookPath
            self.appSecret = appSecret
        }
    }

    private enum HTTPMethod: String {
        case get = "GET"
        case post = "POST"
    }

    private struct HTTPRequest {
        let method: HTTPMethod
        let path: String
        let queryItems: [String: String]
        let headers: [String: String]
        let body: Data
    }

    private struct HTTPResponse {
        let statusCode: Int
        let statusText: String
        let headers: [String: String]
        let body: Data

        static func text(_ text: String, statusCode: Int = 200, statusText: String = "OK") -> HTTPResponse {
            HTTPResponse(
                statusCode: statusCode,
                statusText: statusText,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: Data(text.utf8)
            )
        }

        static func json(_ body: String, statusCode: Int = 200, statusText: String = "OK") -> HTTPResponse {
            HTTPResponse(
                statusCode: statusCode,
                statusText: statusText,
                headers: ["Content-Type": "application/json"],
                body: Data(body.utf8)
            )
        }

        func serialized() -> Data {
            var mergedHeaders = headers
            mergedHeaders["Content-Length"] = String(body.count)
            mergedHeaders["Connection"] = "close"

            var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
            for (key, value) in mergedHeaders {
                response += "\(key): \(value)\r\n"
            }
            response += "\r\n"

            var data = Data(response.utf8)
            data.append(body)
            return data
        }
    }

    private struct WebhookEnvelope: Decodable {
        let entry: [Entry]

        struct Entry: Decodable {
            let changes: [Change]
        }

        struct Change: Decodable {
            let value: Value
        }

        struct Value: Decodable {
            let messages: [Message]?
        }

        struct Message: Decodable {
            let from: String
            let type: String?
            let text: TextContent?

            struct TextContent: Decodable {
                let body: String
            }
        }
    }

    private struct SendMessageRequest: Encodable {
        let messagingProduct: String
        let recipientType: String
        let to: String
        let type: String
        let text: TextBody

        struct TextBody: Encodable {
            let body: String
        }

        enum CodingKeys: String, CodingKey {
            case messagingProduct = "messaging_product"
            case recipientType = "recipient_type"
            case to
            case type
            case text
        }
    }

    private struct GraphAPIErrorEnvelope: Decodable {
        let error: GraphError

        struct GraphError: Decodable {
            let message: String
            let type: String?
            let code: Int?
        }
    }

    private let config: Config
    private let urlSession: URLSession
    private var messageHandler: MessageHandler?

    private var listener: NWListener?
    private var runningPort: UInt16?

    init(config: Config, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    var isRunning: Bool {
        listener != nil
    }

    func setMessageHandler(_ handler: @escaping MessageHandler) {
        messageHandler = handler
    }

    func start(port: UInt16) async throws {
        if listener != nil {
            NSLog("WhatsAppAdapter: already running on port %@", String(runningPort ?? 0))
            return
        }

        let nwPort = NWEndpoint.Port(rawValue: port)
        guard let nwPort else {
            throw NSError(
                domain: "WhatsAppAdapter",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Invalid port: \(port)"]
            )
        }

        let params = NWParameters.tcp
        let newListener = try NWListener(using: params, on: nwPort)

        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task {
                await self.handleConnection(connection)
            }
        }

        // Wait for listener to reach .ready or .failed.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false

            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !resumed else { return }
                    resumed = true
                    NSLog("WhatsAppAdapter: listening on port %@", String(port))
                    Task {
                        await self?.didBind(listener: newListener, port: port)
                    }
                    continuation.resume()
                case .failed(let error):
                    guard !resumed else { return }
                    resumed = true
                    NSLog("WhatsAppAdapter: listener failed — %@", error.localizedDescription)
                    continuation.resume(throwing: error)
                case .cancelled:
                    NSLog("WhatsAppAdapter: listener cancelled")
                default:
                    break
                }
            }

            newListener.start(queue: .global(qos: .utility))
        }
    }

    private func didBind(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.runningPort = port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        runningPort = nil
        NSLog("WhatsAppAdapter: stopped")
    }

    func sendText(to recipient: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let chunks = splitMessage(trimmed, limit: 4096)
        for (index, chunk) in chunks.enumerated() {
            await sendSingleText(to: recipient, text: chunk)
            if index < chunks.count - 1 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func sendSingleText(to recipient: String, text: String) async {
        guard let url = URL(string: "https://graph.facebook.com/v18.0/\(config.phoneNumberId)/messages") else {
            NSLog("WhatsAppAdapter: invalid Graph API URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.accessToken)", forHTTPHeaderField: "Authorization")

        let payload = SendMessageRequest(
            messagingProduct: "whatsapp",
            recipientType: "individual",
            to: recipient,
            type: "text",
            text: SendMessageRequest.TextBody(body: text)
        )

        do {
            request.httpBody = try JSONEncoder().encode(payload)
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                NSLog("WhatsAppAdapter: Graph API returned non-HTTP response")
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                if let graphError = try? JSONDecoder().decode(GraphAPIErrorEnvelope.self, from: data) {
                    NSLog("WhatsAppAdapter: Graph API error %@ (code=%@)",
                          graphError.error.message,
                          graphError.error.code.map(String.init) ?? "n/a")
                } else {
                    NSLog("WhatsAppAdapter: Graph API HTTP %@", String(httpResponse.statusCode))
                }
                return
            }

            NSLog("WhatsAppAdapter: sent message to %@", recipient)
        } catch {
            NSLog("WhatsAppAdapter: failed to send message — %@", error.localizedDescription)
        }
    }

    private func splitMessage(_ content: String, limit: Int) -> [String] {
        guard content.count > limit else { return [content] }
        var chunks: [String] = []
        var remaining = content
        while !remaining.isEmpty {
            if remaining.count <= limit {
                chunks.append(remaining)
                break
            }
            let cutoff = remaining.index(remaining.startIndex, offsetBy: limit)
            let searchRange = remaining.startIndex..<cutoff
            if let newlineIdx = remaining[searchRange].lastIndex(of: "\n") {
                chunks.append(String(remaining[...newlineIdx]))
                remaining = String(remaining[remaining.index(after: newlineIdx)...])
            } else {
                chunks.append(String(remaining[..<cutoff]))
                remaining = String(remaining[cutoff...])
            }
        }
        return chunks
    }

    // MARK: - Connection / HTTP handling

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .utility))

        let requestData = await receiveRequestData(from: connection)
        guard let requestData,
              let request = parseHTTPRequest(from: requestData)
        else {
            await send(response: .text("Bad Request", statusCode: 400, statusText: "Bad Request"), on: connection)
            connection.cancel()
            return
        }

        let response = await handle(request: request)
        await send(response: response, on: connection)
        connection.cancel()
    }

    private func receiveRequestData(from connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            var accumulated = Data()
            let maxRequestSize = 512 * 1024
            var resumed = false
            var timeoutItem: DispatchWorkItem?

            func finish(_ data: Data?) {
                guard !resumed else { return }
                resumed = true
                timeoutItem?.cancel()
                continuation.resume(returning: data)
            }

            func receiveNextChunk() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error {
                        NSLog("WhatsAppAdapter: receive error — %@", error.localizedDescription)
                        finish(nil)
                        return
                    }

                    if let data, !data.isEmpty {
                        accumulated.append(data)
                        if accumulated.count > maxRequestSize {
                            NSLog("WhatsAppAdapter: request exceeds max size")
                            finish(nil)
                            return
                        }

                        if Self.isRequestComplete(accumulated) {
                            finish(accumulated)
                            return
                        }
                    }

                    if isComplete {
                        finish(Self.isRequestComplete(accumulated) ? accumulated : nil)
                        return
                    }

                    receiveNextChunk()
                }
            }

            receiveNextChunk()

            // Timeout: abort if request isn't complete within 30 seconds.
            let item = DispatchWorkItem {
                NSLog("WhatsAppAdapter: connection timed out after 30s")
                finish(nil)
                connection.cancel()
            }
            timeoutItem = item
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: item)
        }
    }

    private static func isRequestComplete(_ data: Data) -> Bool {
        guard let headerTerminatorRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return false
        }
        let headerData = data.subdata(in: data.startIndex..<headerTerminatorRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return false
        }

        var contentLength = 0
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if key == "content-length" {
                let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                contentLength = Int(value) ?? 0
                break
            }
        }

        let bodySize = data.distance(from: headerTerminatorRange.upperBound, to: data.endIndex)
        return bodySize >= contentLength
    }

    private func parseHTTPRequest(from data: Data) -> HTTPRequest? {
        guard let headerTerminatorRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let headerData = data.subdata(in: data.startIndex..<headerTerminatorRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2,
              let method = HTTPMethod(rawValue: String(requestParts[0]))
        else {
            return nil
        }

        let target = String(requestParts[1])
        let urlComponents = URLComponents(string: "http://localhost\(target)")
        let path = urlComponents?.path ?? target
        var queryItems: [String: String] = [:]
        urlComponents?.queryItems?.forEach { item in
            queryItems[item.name] = item.value ?? ""
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                headers[key.lowercased()] = value
            }
        }

        let bodyStart = headerTerminatorRange.upperBound
        let body = bodyStart <= data.endIndex ? data.subdata(in: bodyStart..<data.endIndex) : Data()

        if let contentLengthValue = headers["content-length"],
           let contentLength = Int(contentLengthValue),
           body.count < contentLength {
            // Request may be incomplete if body spans multiple TCP frames.
            return nil
        }

        return HTTPRequest(method: method, path: path, queryItems: queryItems, headers: headers, body: body)
    }

    private func handle(request: HTTPRequest) async -> HTTPResponse {
        guard request.path == config.webhookPath else {
            return .text("Not Found", statusCode: 404, statusText: "Not Found")
        }

        switch request.method {
        case .get:
            return handleVerificationRequest(request)

        case .post:
            return await handleIncomingWebhook(request)
        }
    }

    private func handleVerificationRequest(_ request: HTTPRequest) -> HTTPResponse {
        let mode = request.queryItems["hub.mode"]
        let token = request.queryItems["hub.verify_token"]
        let challenge = request.queryItems["hub.challenge"]

        guard mode == "subscribe", token == config.verifyToken, let challenge else {
            NSLog("WhatsAppAdapter: webhook verification rejected")
            return .text("Forbidden", statusCode: 403, statusText: "Forbidden")
        }

        NSLog("WhatsAppAdapter: webhook verification accepted")
        return .text(challenge, statusCode: 200, statusText: "OK")
    }

    private func handleIncomingWebhook(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.headers["content-type"]?.lowercased().contains("application/json") == true else {
            return .text("Unsupported Media Type", statusCode: 415, statusText: "Unsupported Media Type")
        }

        if let appSecret = config.appSecret, !appSecret.isEmpty {
            guard let signature = request.headers["x-hub-signature-256"],
                  verifyHMAC(body: request.body, signature: signature, secret: appSecret) else {
                NSLog("WhatsAppAdapter: webhook signature verification failed")
                return .text("Forbidden", statusCode: 403, statusText: "Forbidden")
            }
        }

        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(WebhookEnvelope.self, from: request.body) else {
            NSLog("WhatsAppAdapter: failed to decode webhook payload")
            return .text("Bad Request", statusCode: 400, statusText: "Bad Request")
        }

        var handledCount = 0

        for entry in envelope.entry {
            for change in entry.changes {
                let messages = change.value.messages ?? []
                for message in messages {
                    guard let textBody = message.text?.body else {
                        continue
                    }

                    let text = textBody.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        continue
                    }
                    let sender = message.from
                    guard isAllowed(sender: sender) else {
                        NSLog("WhatsAppAdapter: blocked sender %@", sender)
                        continue
                    }

                    handledCount += 1
                    if let handler = messageHandler,
                       let reply = await handler(sender, text) {
                        await sendText(to: sender, text: reply)
                    }
                }
            }
        }

        if handledCount > 0 {
            NSLog("WhatsAppAdapter: handled %@ inbound message(s)", String(handledCount))
        }

        return .json("{\"status\":\"ok\"}", statusCode: 200, statusText: "OK")
    }

    private func isAllowed(sender: String) -> Bool {
        if config.allowedNumbers.isEmpty {
            return true
        }
        return config.allowedNumbers.contains(sender)
    }

    private func send(response: HTTPResponse, on connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            connection.send(content: response.serialized(), completion: .contentProcessed { error in
                if let error {
                    NSLog("WhatsAppAdapter: send response failed — %@", error.localizedDescription)
                }
                continuation.resume()
            })
        }
    }

    /// Verify HMAC-SHA256 signature from `X-Hub-Signature-256` header.
    ///
    /// Header format: `sha256=<hex>`.
    private func verifyHMAC(body: Data, signature: String, secret: String) -> Bool {
        let prefix = "sha256="
        guard signature.hasPrefix(prefix) else { return false }
        let expectedHex = String(signature.dropFirst(prefix.count))

        guard let keyData = secret.data(using: .utf8) else { return false }

        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        keyData.withUnsafeBytes { keyBytes in
            body.withUnsafeBytes { bodyBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyBytes.baseAddress, keyData.count,
                    bodyBytes.baseAddress, body.count,
                    &hmac
                )
            }
        }

        let computedHex = hmac.map { String(format: "%02x", $0) }.joined()

        // Constant-time comparison to prevent timing attacks.
        guard computedHex.count == expectedHex.count else { return false }
        var result: UInt8 = 0
        for (a, b) in zip(computedHex.utf8, expectedHex.utf8) {
            result |= a ^ b
        }
        return result == 0
    }
}
