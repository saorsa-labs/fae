import Foundation

/// Native Discord channel adapter backed by Discord Gateway + REST APIs.
///
/// The adapter is dependency-free (Foundation + URLSession) and intended to be
/// wired by `ChannelManager` via the provided `messageHandler` callback.
actor DiscordAdapter {
    typealias MessageHandler = @Sendable (_ senderId: String, _ channelId: String, _ text: String) async -> String?

    private static let gatewayURL = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!
    private static let restBaseURL = URL(string: "https://discord.com/api/v10")!

    private let config: ChannelManager.ChannelConfig.DiscordConfig
    private let messageHandler: MessageHandler
    private let session: URLSession

    private let allowedChannelIds: Set<String>
    private let guildId: String?

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var shouldRun = false
    private var isGatewayReady = false
    private var reconnectAttempt = 0

    private var sessionId: String?
    private var resumeGatewayURL: URL?
    private var lastSequenceNumber: Int?

    private var heartbeatIntervalNanos: UInt64 = 45_000_000_000
    private var awaitingHeartbeatAck = false

    var isConnected: Bool {
        shouldRun && isGatewayReady && webSocketTask != nil
    }

    init(
        config: ChannelManager.ChannelConfig.DiscordConfig,
        messageHandler: @escaping MessageHandler,
        urlSession: URLSession = .shared
    ) {
        self.config = config
        self.messageHandler = messageHandler
        self.session = urlSession
        self.allowedChannelIds = Set(config.allowedChannelIds)
        self.guildId = config.guildId?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Public API

    func start() {
        guard !shouldRun else { return }
        guard normalizedToken != nil else {
            NSLog("DiscordAdapter: missing bot token; start aborted")
            return
        }

        shouldRun = true
        reconnectAttempt = 0

        Task { await connect() }
    }

    func stop() {
        guard shouldRun else { return }

        shouldRun = false
        reconnectAttempt = 0
        isGatewayReady = false
        awaitingHeartbeatAck = false

        sessionId = nil
        resumeGatewayURL = nil
        lastSequenceNumber = nil

        reconnectTask?.cancel()
        reconnectTask = nil

        heartbeatTask?.cancel()
        heartbeatTask = nil

        receiveTask?.cancel()
        receiveTask = nil

        if let webSocketTask {
            webSocketTask.cancel(with: .goingAway, reason: nil)
            self.webSocketTask = nil
        }

        NSLog("DiscordAdapter: stopped")
    }

    // MARK: - Connection Lifecycle

    private var normalizedToken: String? {
        guard let token = config.botToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            return nil
        }
        return token
    }

    private func connect() async {
        guard shouldRun else { return }
        guard normalizedToken != nil else {
            NSLog("DiscordAdapter: cannot connect without bot token")
            return
        }

        teardownForReconnect()

        let gatewayURL = resumeGatewayURL ?? Self.gatewayURL
        let task = session.webSocketTask(with: gatewayURL)
        webSocketTask = task
        task.resume()

        isGatewayReady = false
        awaitingHeartbeatAck = false

        receiveTask = Task { await receiveLoop(socket: task) }

        NSLog("DiscordAdapter: connecting to gateway %@", gatewayURL.absoluteString)
    }

    private func teardownForReconnect() {
        heartbeatTask?.cancel()
        heartbeatTask = nil

        receiveTask?.cancel()
        receiveTask = nil

        if let webSocketTask {
            webSocketTask.cancel(with: .goingAway, reason: nil)
            self.webSocketTask = nil
        }

        isGatewayReady = false
    }

    private func receiveLoop(socket: URLSessionWebSocketTask) async {
        while shouldRun {
            do {
                let message = try await socket.receive()
                let text: String

                switch message {
                case .string(let value):
                    text = value
                case .data(let data):
                    guard let value = String(data: data, encoding: .utf8) else {
                        NSLog("DiscordAdapter: dropped non-utf8 gateway payload")
                        continue
                    }
                    text = value
                @unknown default:
                    NSLog("DiscordAdapter: unknown websocket payload type")
                    continue
                }

                await handleGatewayPayload(text)
            } catch {
                guard shouldRun else { return }
                NSLog("DiscordAdapter: gateway receive failed: %@", String(describing: error))
                await scheduleReconnect(reason: "receive failure")
                return
            }
        }
    }

    private func scheduleReconnect(reason: String) async {
        guard shouldRun else { return }
        guard reconnectTask == nil else { return }

        teardownForReconnect()
        awaitingHeartbeatAck = false

        let delaySeconds = min(30.0, pow(2.0, Double(max(0, reconnectAttempt))))
        reconnectAttempt += 1

        NSLog("DiscordAdapter: reconnect scheduled in %.1fs (%@)", delaySeconds, reason)

        reconnectTask = Task {
            let nanos = UInt64(delaySeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            await performReconnectAfterDelay()
        }
    }

    private func performReconnectAfterDelay() async {
        reconnectTask = nil
        guard shouldRun else { return }
        await connect()
    }

    // MARK: - Gateway Protocol

    private func handleGatewayPayload(_ payload: String) async {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            NSLog("DiscordAdapter: invalid gateway JSON payload")
            return
        }

        if let sequence = json["s"] as? Int {
            lastSequenceNumber = sequence
        }

        guard let opcode = json["op"] as? Int else {
            NSLog("DiscordAdapter: gateway payload missing opcode")
            return
        }

        switch opcode {
        case 0: // DISPATCH
            await handleDispatch(json)

        case 1: // HEARTBEAT request
            await sendHeartbeat()

        case 7: // RECONNECT
            await scheduleReconnect(reason: "server requested reconnect")

        case 9: // INVALID_SESSION
            let resumable = (json["d"] as? Bool) ?? false
            if !resumable {
                sessionId = nil
                resumeGatewayURL = nil
                lastSequenceNumber = nil
            }
            await scheduleReconnect(reason: "invalid session")

        case 10: // HELLO
            await handleHello(json)

        case 11: // HEARTBEAT_ACK
            awaitingHeartbeatAck = false

        default:
            break
        }
    }

    private func handleHello(_ json: [String: Any]) async {
        guard let data = json["d"] as? [String: Any],
              let intervalMillis = data["heartbeat_interval"] as? Double
        else {
            NSLog("DiscordAdapter: HELLO missing heartbeat interval")
            return
        }

        heartbeatIntervalNanos = UInt64(intervalMillis * 1_000_000)
        startHeartbeatLoop()

        if let sessionId, let sequence = lastSequenceNumber {
            await sendResume(sessionId: sessionId, sequence: sequence)
        } else {
            await sendIdentify()
        }
    }

    private func handleDispatch(_ json: [String: Any]) async {
        guard let eventType = json["t"] as? String else { return }

        switch eventType {
        case "READY":
            if let data = json["d"] as? [String: Any] {
                sessionId = data["session_id"] as? String
                if let resumeGateway = data["resume_gateway_url"] as? String {
                    resumeGatewayURL = makeResumeGatewayURL(from: resumeGateway)
                }
            }

            isGatewayReady = true
            reconnectAttempt = 0
            NSLog("DiscordAdapter: gateway READY")

        case "RESUMED":
            isGatewayReady = true
            reconnectAttempt = 0
            NSLog("DiscordAdapter: gateway RESUMED")

        case "MESSAGE_CREATE":
            guard let event = json["d"] as? [String: Any] else { return }
            await handleMessageCreate(event)

        default:
            break
        }
    }

    private func makeResumeGatewayURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("ws://") || trimmed.hasPrefix("wss://") {
            let separator = trimmed.contains("?") ? "&" : "?"
            return URL(string: "\(trimmed)\(separator)v=10&encoding=json")
        }

        return URL(string: "wss://\(trimmed)/?v=10&encoding=json")
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()

        heartbeatTask = Task {
            while shouldContinueHeartbeatLoop() {
                let interval = heartbeatIntervalNanos
                let jitter = UInt64.random(in: 0...500_000_000) // 0-500ms jitter
                try? await Task.sleep(nanoseconds: interval + jitter)
                if Task.isCancelled { return }
                await heartbeatTick()
            }
        }
    }

    private func shouldContinueHeartbeatLoop() -> Bool {
        shouldRun && webSocketTask != nil
    }

    private func heartbeatTick() async {
        guard shouldRun else { return }

        if awaitingHeartbeatAck {
            await scheduleReconnect(reason: "heartbeat ack timeout")
            return
        }

        awaitingHeartbeatAck = true
        await sendHeartbeat()
    }

    private func sendHeartbeat() async {
        let payload: [String: Any] = [
            "op": 1,
            "d": lastSequenceNumber.map { $0 as Any } ?? NSNull(),
        ]
        await sendGatewayPayload(payload)
    }

    private func sendIdentify() async {
        guard let token = normalizedToken else { return }

        // Guild messages + message content + direct messages.
        let intents = (1 << 9) | (1 << 12) | (1 << 15)

        let payload: [String: Any] = [
            "op": 2,
            "d": [
                "token": token,
                "intents": intents,
                "properties": [
                    "os": "macOS",
                    "browser": "fae",
                    "device": "fae",
                ],
            ],
        ]

        await sendGatewayPayload(payload)
    }

    private func sendResume(sessionId: String, sequence: Int) async {
        guard let token = normalizedToken else { return }

        let payload: [String: Any] = [
            "op": 6,
            "d": [
                "token": token,
                "session_id": sessionId,
                "seq": sequence,
            ],
        ]

        await sendGatewayPayload(payload)
    }

    private func sendGatewayPayload(_ payload: [String: Any]) async {
        guard let socket = webSocketTask else { return }

        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let text = String(data: data, encoding: .utf8) else { return }
            try await socket.send(.string(text))
        } catch {
            NSLog("DiscordAdapter: failed sending gateway payload: %@", String(describing: error))
            guard shouldRun else { return }
            await scheduleReconnect(reason: "gateway send failure")
        }
    }

    // MARK: - Message Flow

    private func handleMessageCreate(_ event: [String: Any]) async {
        guard let channelId = event["channel_id"] as? String else { return }

        if let guildId, !guildId.isEmpty {
            guard let eventGuildId = event["guild_id"] as? String, eventGuildId == guildId else { return }
        }

        if !allowedChannelIds.isEmpty, !allowedChannelIds.contains(channelId) {
            return
        }

        guard let author = event["author"] as? [String: Any],
              let senderId = author["id"] as? String
        else {
            return
        }

        if (author["bot"] as? Bool) == true {
            return
        }

        guard let rawText = event["content"] as? String else { return }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let response = await messageHandler(senderId, channelId, text)
        guard let response else { return }

        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else { return }

        let chunks = splitMessage(trimmedResponse, limit: 2000)
        for (index, chunk) in chunks.enumerated() {
            do {
                try await sendMessage(chunk, toChannelId: channelId)
                if index < chunks.count - 1 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            } catch {
                NSLog("DiscordAdapter: failed sending message via REST: %@", String(describing: error))
                break
            }
        }
    }

    // MARK: - REST API

    private enum RestError: Error {
        case invalidURL
        case missingToken
        case invalidResponse
        case http(statusCode: Int, body: String)
    }

    private func sendMessage(_ content: String, toChannelId channelId: String) async throws {
        guard let token = normalizedToken else {
            throw RestError.missingToken
        }

        guard let url = URL(string: "channels/\(channelId)/messages", relativeTo: Self.restBaseURL) else {
            throw RestError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "content": content,
            "allowed_mentions": ["parse": []],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RestError.invalidResponse
        }

        if httpResponse.statusCode == 429 {
            var lastData = data
            var lastResponse: HTTPURLResponse = httpResponse
            for retryAttempt in 1...3 {
                let retryAfter = Double(lastResponse.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1.0
                NSLog("DiscordAdapter: rate limited, retry %d after %.1fs", retryAttempt, retryAfter)
                try? await Task.sleep(nanoseconds: UInt64((retryAfter + 0.1) * 1_000_000_000))
                let (retryData, retryResp) = try await session.data(for: request)
                guard let retryHTTP = retryResp as? HTTPURLResponse else {
                    throw RestError.invalidResponse
                }
                if (200...299).contains(retryHTTP.statusCode) {
                    return
                }
                if retryHTTP.statusCode != 429 {
                    let bodyText = String(data: retryData, encoding: .utf8) ?? "<non-utf8>"
                    throw RestError.http(statusCode: retryHTTP.statusCode, body: bodyText)
                }
                lastData = retryData
                lastResponse = retryHTTP
            }
            let bodyText = String(data: lastData, encoding: .utf8) ?? "<non-utf8>"
            throw RestError.http(statusCode: 429, body: bodyText)
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw RestError.http(statusCode: httpResponse.statusCode, body: bodyText)
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
}
