import Foundation

// MARK: - Events

/// Server-push events from the daemon's `conversation.subscribe` stream
/// (voice spine V2/V3). Demuxed from `Response` frames by the `event` key.
enum DaemonPlaybackEvent: Sendable {
    /// One playback RMS reading (0.0–1.0) for `playbackID`.
    case level(rms: Float, playbackID: String)
    /// A playback ended — `reason` is `"completed"` (natural) or `"interrupted"`
    /// (barge-in via `audio.stop`).
    case ended(playbackID: String, reason: String)
}

// MARK: - Subscriber

/// A dedicated daemon connection that subscribes to the server-push event
/// stream and dispatches `audio.level` / `audio.playback_ended` events (voice
/// spine V3b).
///
/// Uses its OWN socket — never the TTS or LLM round-trip connections — so a
/// long-running event read can never block (or be blocked by) a synthesis or
/// turn round trip. Runs a background read loop on a serial dispatch queue;
/// events are delivered on a caller-supplied queue. Failures are logged and
/// self-limiting: a dead socket simply stops delivering events (the pipeline
/// falls back to its existing completion watchdogs), it never throws into the
/// caller.
final class DaemonEventSubscriber: @unchecked Sendable {
    private let socketPath: String
    private let tokenPath: String
    private let queue: DispatchQueue
    private let deliveryQueue: DispatchQueue
    private let delivery: @Sendable (DaemonPlaybackEvent) -> Void

    // `fd` is read/written from the serial `queue` (read loop) AND closed from
    // `stop()` on the caller's thread — so access is guarded by `stateLock`.
    // `stopped` is the cross-thread shutdown signal: once true, the read loop
    // exits and `stop()` becomes a no-op.
    private let stateLock = NSLock()
    private var fd: Int32 = -1
    private var stopped = false
    /// NDJSON line-framing buffer. Queue-confined: only touched in
    /// `readLineLocked` on the serial `queue` (stop() does not touch it).
    private var buffer = Data()

    /// - Parameters:
    ///   - socketPath: Unix socket of the running daemon.
    ///   - tokenPath: Bootstrap token file (same source as the TTS engine).
    ///   - deliveryQueue: Queue on which `delivery` is invoked.
    ///   - delivery: Called per `audio.level` / `audio.playback_ended` event.
    init(
        socketPath: String,
        tokenPath: String,
        deliveryQueue: DispatchQueue,
        delivery: @escaping @Sendable (DaemonPlaybackEvent) -> Void
    ) {
        self.socketPath = socketPath
        self.tokenPath = tokenPath
        self.queue = DispatchQueue(label: "fae.daemon-events.subscriber")
        self.deliveryQueue = deliveryQueue
        self.delivery = delivery
    }

    /// Connect, authenticate, subscribe, and start the read loop. Returns once
    /// the subscribe ack has been read; events then arrive on `deliveryQueue`.
    /// Throws on connect/auth/subscribe failure (the caller decides whether to
    /// proceed without events — the flag-OFF path never calls this).
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.connectLocked()
                    try self.authenticateAndSubscribeLocked()
                    continuation.resume()
                    // Begin the blocking event read loop on this serial queue.
                    self.queue.async { self.readLoopLocked() }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stop reading and close the socket. Safe to call multiple times.
    func stop() {
        queue.sync {
            stopped = true
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
            buffer.removeAll()
        }
    }

    deinit {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    // MARK: - Queue-confined internals

    private func connectLocked() throws {
        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw DaemonLLMEngineError.connectionFailed("socket(): \(Self.errnoString())")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path) - 1
        var pathBytes = Array(socketPath.utf8)
        guard pathBytes.count <= maxPath else {
            Darwin.close(sock)
            throw DaemonLLMEngineError.connectionFailed("socket path too long: \(socketPath)")
        }
        pathBytes.append(0)
        withUnsafeMutableBytes(of: &addr.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source.prefix(destination.count))
            }
        }
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let detail = Self.errnoString()
            Darwin.close(sock)
            throw DaemonLLMEngineError.connectionFailed("connect(\(socketPath)): \(detail)")
        }
        stateLock.lock()
        fd = sock
        stateLock.unlock()
    }
    private func currentFD() -> Int32 {
        stateLock.lock()
        let value = fd
        stateLock.unlock()
        return value
    }

    /// Authenticate + send `conversation.subscribe`, reading both acks. Reuses
    /// the same `readLineLocked` framing the read loop will use.
    private func authenticateAndSubscribeLocked() throws {
        let token: String
        do {
            token = try String(contentsOfFile: tokenPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw DaemonLLMEngineError.tokenUnreadable(tokenPath)
        }
        guard !token.isEmpty else {
            throw DaemonLLMEngineError.tokenUnreadable(tokenPath)
        }

        let authFrame = try DaemonWire.encodeFrame(
            requestID: "sub-auth",
            command: "session.authenticate",
            payload: ["client_id": "swift-frontend-bootstrap", "token": token])
        try writeLocked(authFrame)
        // Validate the auth ack (don't blindly discard) — a failed auth must
        // surface now, not as a silent no-events connection.
        let authLine = try readLineLocked()
        if let authObj = DaemonWire.parseObjectLine(authLine) {
            _ = try DaemonWire.unwrapResponse(authObj)
        }

        let subscribeFrame = try DaemonWire.encodeFrame(
            requestID: "sub-1",
            command: "conversation.subscribe",
            payload: [:])
        try writeLocked(subscribeFrame)
        let subscribeLine = try readLineLocked()
        if let subscribeObj = DaemonWire.parseObjectLine(subscribeLine) {
            _ = try DaemonWire.unwrapResponse(subscribeObj)
        }
    }

    /// Continuous event read loop. Runs on the serial queue until `stop()` or
    /// Continuous event read loop. Runs on the serial queue until `stop()`
    /// (which closes the fd) or the socket closes. A thrown error ends the loop
    /// (logged); the pipeline's existing watchdogs handle a missing
    /// `playback_ended`. `stop()` closes the fd concurrently, which makes the
    /// blocked `recv` return — so this loop never blocks shutdown.
    private func readLoopLocked() {
        while !isStopped {
            let line: String
            do {
                line = try readLineLocked()
            } catch {
                if !isStopped {
                    NSLog("DaemonEventSubscriber: read loop ended (%@)", error.localizedDescription)
                }
                return
            }
            guard let object = DaemonWire.parseObjectLine(line),
                  let event = object["event"] as? String,
                  let payload = object["payload"] as? [String: Any]
            else {
                continue  // non-event frame (e.g. a stray response) — ignore
            }
            dispatchEvent(event, payload)
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        let value = stopped
        stateLock.unlock()
        return value
    }

    private func dispatchEvent(_ event: String, _ payload: [String: Any]) {
        let playbackID = (payload["playback_id"] as? String) ?? ""
        let delivered: DaemonPlaybackEvent?
        switch event {
        case "audio.level":
            if let rms = payload["rms"] as? Double {
                delivered = .level(rms: Float(rms), playbackID: playbackID)
            } else {
                delivered = nil
            }
        case "audio.playback_ended":
            let reason = (payload["reason"] as? String) ?? "completed"
            delivered = .ended(playbackID: playbackID, reason: reason)
        default:
            delivered = nil  // unknown event — forward-compatible ignore
        }
        guard let event = delivered else { return }
        // Deliver on the caller-supplied queue, not this read-loop queue, so a
        // slow handler never stalls the socket read.
        deliveryQueue.async { self.delivery(event) }
    }

    private func writeLocked(_ data: Data) throws {
        let fd = currentFD()
        guard fd >= 0 else { throw DaemonLLMEngineError.notConnected }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 {
                    if errno == EINTR { continue }
                    throw DaemonLLMEngineError.connectionFailed("send(): \(Self.errnoString())")
                }
                sent += n
            }
        }
    }

    private func readLineLocked() throws -> String {
        let fd = currentFD()
        guard fd >= 0 else { throw DaemonLLMEngineError.notConnected }
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let line = String(data: lineData, encoding: .utf8) else {
                    throw DaemonLLMEngineError.protocolError("non-UTF8 frame from daemon")
                }
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.recv(fd, base, raw.count, 0)
            }
            if count == 0 {
                throw DaemonLLMEngineError.connectionFailed("daemon closed the connection")
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw DaemonLLMEngineError.connectionFailed("recv(): \(Self.errnoString())")
            }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    private static func errnoString() -> String {
        if let cString = strerror(errno) {
            return String(cString: cString)
        }
        return "errno \(errno)"
    }
}
