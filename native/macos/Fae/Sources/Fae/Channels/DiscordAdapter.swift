import Foundation

/// Native Discord channel adapter conforming to `ChannelAdapter`.
///
/// Connects to the Discord Gateway via WebSocket, receives `MESSAGE_CREATE` events,
/// converts them into `ChannelMessage` envelopes for the `ChannelGateway`, and sends
/// replies via the Discord REST API with 2000-character message splitting.
///
/// Preserves the full WebSocket lifecycle: heartbeat, resume, reconnect with
/// exponential backoff.
///
/// - Note: This is a class (not actor) to satisfy the `ChannelAdapter` protocol's
///   `onMessage` property requirement. Internal state is protected by `AdapterState`.
final class DiscordAdapter: ChannelAdapter, @unchecked Sendable {
    /// Legacy handler type retained for backward compatibility with `ChannelManager`.
    typealias LegacyMessageHandler = @Sendable (_ senderId: String, _ channelId: String, _ text: String) async -> String?

    private static let gatewayURL = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!
    private static let restBaseURL = URL(string: "https://discord.com/api/v10")!

    let kind: ChannelKind = .discord
    var onMessage: (@Sendable (ChannelMessage) async -> String?)?

    private let config: ChannelManager.ChannelConfig.DiscordConfig
    private let legacyHandler: LegacyMessageHandler?
    private let session: URLSession

    private let allowedChannelIds: Set<String>
    private let guildId: String?

    /// Thread-safe wrapper for mutable adapter state.
    private final class AdapterState: @unchecked Sendable {
        private let lock = NSLock()

        private var _webSocketTask: URLSessionWebSocketTask?
        private var _receiveTask: Task<Void, Never>?
        private var _heartbeatTask: Task<Void, Never>?
        private var _reconnectTask: Task<Void, Never>?

        private var _shouldRun = false
        private var _isGatewayReady = false
        private var _reconnectAttempt = 0

        private var _sessionId: String?
        private var _resumeGatewayURL: URL?
        private var _lastSequenceNumber: Int?

        private var _heartbeatIntervalNanos: UInt64 = 45_000_000_000
        private var _awaitingHeartbeatAck = false

        var shouldRun: Bool {
            get { lock.withLock { _shouldRun } }
            set { lock.withLock { _shouldRun = newValue } }
        }

        var isGatewayReady: Bool {
            get { lock.withLock { _isGatewayReady } }
            set { lock.withLock { _isGatewayReady = newValue } }
        }

        var reconnectAttempt: Int {
            get { lock.withLock { _reconnectAttempt } }
            set { lock.withLock { _reconnectAttempt = newValue } }
        }

        var sessionId: String? {
            get { lock.withLock { _sessionId } }
            set { lock.withLock { _sessionId = newValue } }
        }

        var resumeGatewayURL: URL? {
            get { lock.withLock { _resumeGatewayURL } }
            set { lock.withLock { _resumeGatewayURL = newValue } }
        }

        var lastSequenceNumber: Int? {
            get { lock.withLock { _lastSequenceNumber } }
            set { lock.withLock { _lastSequenceNumber = newValue } }
        }

        var heartbeatIntervalNanos: UInt64 {
            get { lock.withLock { _heartbeatIntervalNanos } }
            set { lock.withLock { _heartbeatIntervalNanos = newValue } }
        }

        var awaitingHeartbeatAck: Bool {
            get { lock.withLock { _awaitingHeartbeatAck } }
            set { lock.withLock { _awaitingHeartbeatAck = newValue } }
        }

        var webSocketTask: URLSessionWebSocketTask? {
            get { lock.withLock { _webSocketTask } }
            set { lock.withLock { _webSocketTask = newValue } }
        }

        var hasReconnectTask: Bool {
            lock.withLock { _reconnectTask != nil }
        }

        func setWebSocketAndClearReady(_ task: URLSessionWebSocketTask) {
            lock.withLock {
                _webSocketTask = task
                _isGatewayReady = false
                _awaitingHeartbeatAck = false
            }
        }

        func setReceiveTask(_ task: Task<Void, Never>?) {
            lock.withLock { _receiveTask = task }
        }

        func setHeartbeatTask(_ task: Task<Void, Never>?) {
            lock.withLock { _heartbeatTask = task }
        }

        func setReconnectTask(_ task: Task<Void, Never>?) {
            lock.withLock { _reconnectTask = task }
        }

        func clearReconnectTask() {
            lock.withLock { _reconnectTask = nil }
        }

        func markStarted() {
            lock.withLock {
                _shouldRun = true
                _reconnectAttempt = 0
            }
        }

        func teardownForReconnect() {
            lock.withLock {
                _heartbeatTask?.cancel()
                _heartbeatTask = nil

                _receiveTask?.cancel()
                _receiveTask = nil

                if let ws = _webSocketTask {
                    ws.cancel(with: .goingAway, reason: nil)
                    _webSocketTask = nil
                }

                _isGatewayReady = false
            }
        }

        func fullStop() {
            lock.withLock {
                _shouldRun = false
                _reconnectAttempt = 0
                _isGatewayReady = false
                _awaitingHeartbeatAck = false

                _sessionId = nil
                _resumeGatewayURL = nil
                _lastSequenceNumber = nil

                _reconnectTask?.cancel()
                _reconnectTask = nil

                _heartbeatTask?.cancel()
                _heartbeatTask = nil

                _receiveTask?.cancel()
                _receiveTask = nil

                if let ws = _webSocketTask {
                    ws.cancel(with: .goingAway, reason: nil)
                    _webSocketTask = nil
                }
            }
        }

        func markReady(sessionId: String?, resumeGatewayURL: URL?) {
            lock.withLock {
                _sessionId = sessionId
                if let url = resumeGatewayURL {
                    _resumeGatewayURL = url
                }
                _isGatewayReady = true
                _reconnectAttempt = 0
            }
        }

        func markResumed() {
            lock.withLock {
                _isGatewayReady = true
                _reconnectAttempt = 0
            }
        }

        func clearSessionForInvalidSession() {
            lock.withLock {
                _sessionId = nil
                _resumeGatewayURL = nil
                _lastSequenceNumber = nil
            }
        }

        /// Increments reconnect attempt and returns the delay.
        func incrementReconnectAndGetDelay() -> Double {
            lock.withLock {
                _awaitingHeartbeatAck = false
                let delay = min(30.0, pow(2.0, Double(max(0, _reconnectAttempt))))
                _reconnectAttempt += 1
                return delay
            }
        }

        /// Returns true if heartbeat ack was pending (timeout), sets it to true otherwise.
        func checkAndSetHeartbeatAck() -> Bool {
            lock.withLock {
                if _awaitingHeartbeatAck {
                    return true
                }
                _awaitingHeartbeatAck = true
                return false
            }
        }

        var isConnected: Bool {
            lock.withLock {
                _shouldRun && _isGatewayReady && _webSocketTask != nil
            }
        }

        func shouldContinueHeartbeatLoop() -> Bool {
            lock.withLock {
                _shouldRun && _webSocketTask != nil
            }
        }
    }

    private let state = AdapterState()

    var isConnected: Bool { state.isConnected }

    /// Create an adapter for use with `ChannelGateway`.
    ///
    /// The gateway sets `onMessage` after creation to receive `ChannelMessage` envelopes.
    init(
        config: ChannelManager.ChannelConfig.DiscordConfig,
        urlSession: URLSession = .shared
    ) {
        self.config = config
        self.legacyHandler = nil
        self.session = urlSession
        self.allowedChannelIds = Set(config.allowedChannelIds)
        self.guildId = config.guildId?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Create an adapter with a legacy handler (backward compatibility with `ChannelManager`).
    init(
        config: ChannelManager.ChannelConfig.DiscordConfig,
        messageHandler: @escaping LegacyMessageHandler,
        urlSession: URLSession = .shared
    ) {
        self.config = config
        self.legacyHandler = messageHandler
        self.session = urlSession
        self.allowedChannelIds = Set(config.allowedChannelIds)
        self.guildId = config.guildId?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - ChannelAdapter

    func start() async throws {
        guard !state.shouldRun else { return }
        guard normalizedToken != nil else {
            NSLog("DiscordAdapter: missing bot token; start aborted")
            return
        }

        state.markStarted()
        await connect()
    }

    func stop() async {
        guard state.shouldRun else { return }
        state.fullStop()
        NSLog("DiscordAdapter: stopped")
    }

    func send(response: String, to message: ChannelMessage) async throws {
        guard let channelId = message.threadId else {
            NSLog("DiscordAdapter: cannot send response — message has no threadId (channelId)")
            return
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let chunks = splitMessage(trimmed, limit: 2000)
        for (index, chunk) in chunks.enumerated() {
            try await sendMessage(chunk, toChannelId: channelId)
            if index < chunks.count - 1 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
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
        guard state.shouldRun else { return }
        guard normalizedToken != nil else {
            NSLog("DiscordAdapter: cannot connect without bot token")
            return
        }

        state.teardownForReconnect()

        let gatewayURL = state.resumeGatewayURL ?? Self.gatewayURL
        let task = session.webSocketTask(with: gatewayURL)
        state.setWebSocketAndClearReady(task)
        task.resume()

        let receiveTask: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop(socket: task)
        }
        state.setReceiveTask(receiveTask)

        NSLog("DiscordAdapter: connecting to gateway %@", gatewayURL.absoluteString)
    }

    private func receiveLoop(socket: URLSessionWebSocketTask) async {
        while state.shouldRun {
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
                guard state.shouldRun else { return }
                NSLog("DiscordAdapter: gateway receive failed: %@", String(describing: error))
                await scheduleReconnect(reason: "receive failure")
                return
            }
        }
    }

    private func scheduleReconnect(reason: String) async {
        guard state.shouldRun else { return }
        guard !state.hasReconnectTask else { return }

        state.teardownForReconnect()

        let delaySeconds = state.incrementReconnectAndGetDelay()
        NSLog("DiscordAdapter: reconnect scheduled in %.1fs (%@)", delaySeconds, reason)

        let reconnectTask: Task<Void, Never> = Task { [weak self] in
            let nanos = UInt64(delaySeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard let self else { return }
            await self.performReconnectAfterDelay()
        }
        state.setReconnectTask(reconnectTask)
    }

    private func performReconnectAfterDelay() async {
        state.clearReconnectTask()
        guard state.shouldRun else { return }
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
            state.lastSequenceNumber = sequence
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
                state.clearSessionForInvalidSession()
            }
            await scheduleReconnect(reason: "invalid session")

        case 10: // HELLO
            await handleHello(json)

        case 11: // HEARTBEAT_ACK
            state.awaitingHeartbeatAck = false

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

        state.heartbeatIntervalNanos = UInt64(intervalMillis * 1_000_000)
        startHeartbeatLoop()

        let sessionId = state.sessionId
        let lastSeq = state.lastSequenceNumber

        if let sessionId, let sequence = lastSeq {
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
                let sid = data["session_id"] as? String
                var resumeURL: URL?
                if let resumeGateway = data["resume_gateway_url"] as? String {
                    resumeURL = makeResumeGatewayURL(from: resumeGateway)
                }
                state.markReady(sessionId: sid, resumeGatewayURL: resumeURL)
            }
            NSLog("DiscordAdapter: gateway READY")

        case "RESUMED":
            state.markResumed()
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
        state.setHeartbeatTask(nil) // cancel previous

        let heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while self.state.shouldContinueHeartbeatLoop() {
                let interval = self.state.heartbeatIntervalNanos
                let jitter = UInt64.random(in: 0...500_000_000) // 0-500ms jitter
                try? await Task.sleep(nanoseconds: interval + jitter)
                if Task.isCancelled { return }
                await self.heartbeatTick()
            }
        }
        state.setHeartbeatTask(heartbeatTask)
    }

    private func heartbeatTick() async {
        guard state.shouldRun else { return }

        if state.checkAndSetHeartbeatAck() {
            await scheduleReconnect(reason: "heartbeat ack timeout")
            return
        }

        await sendHeartbeat()
    }

    private func sendHeartbeat() async {
        let seq = state.lastSequenceNumber
        let payload: [String: Any] = [
            "op": 1,
            "d": seq.map { $0 as Any } ?? NSNull(),
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
        guard let socket = state.webSocketTask else { return }

        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            guard let text = String(data: data, encoding: .utf8) else { return }
            try await socket.send(.string(text))
        } catch {
            NSLog("DiscordAdapter: failed sending gateway payload: %@", String(describing: error))
            guard state.shouldRun else { return }
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

        let senderName = author["username"] as? String
        let messageId = event["id"] as? String

        // Gateway path: convert to ChannelMessage and dispatch.
        if let onMessage {
            let envelope = ChannelMessage(
                id: messageId ?? UUID().uuidString,
                channel: .discord,
                senderId: senderId,
                senderDisplayName: senderName,
                text: text,
                timestamp: Date(),
                threadId: channelId
            )
            let response = await onMessage(envelope)
            if let response {
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
        } else if let legacyHandler {
            // Legacy path: forward to ChannelManager callback.
            let response = await legacyHandler(senderId, channelId, text)
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
