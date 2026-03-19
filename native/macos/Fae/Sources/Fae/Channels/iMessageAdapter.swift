import Foundation
import GRDB

/// Poll-based iMessage adapter conforming to `ChannelAdapter`.
///
/// Reads new messages from `~/Library/Messages/chat.db` in read-only mode and
/// produces `ChannelMessage` envelopes for the `ChannelGateway`. Replies are
/// sent back via AppleScript through the Messages app.
///
/// - Note: This is a class (not actor) to satisfy the `ChannelAdapter` protocol's
///   `onMessage` property requirement. Internal state is protected by `AdapterState`.
final class IMessageAdapter: ChannelAdapter, @unchecked Sendable {
    /// Internal representation of a message row from `chat.db`.
    struct IncomingMessage: Sendable {
        let rowID: Int64
        let text: String
        let sender: String
        let handleID: Int64
        let sentAt: Date
        let rawDateValue: Int64
    }

    /// Legacy handler type retained for backward compatibility with `ChannelManager`.
    typealias LegacyMessageHandler = @Sendable (IncomingMessage) async -> Void

    let kind: ChannelKind = .imessage
    var onMessage: (@Sendable (ChannelMessage) async -> String?)?

    private enum AdapterError: LocalizedError {
        case chatDatabaseMissing(String)
        case osascriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .chatDatabaseMissing(let path):
                return "Messages database not found at: \(path)"
            case .osascriptFailed(let detail):
                return "osascript failed: \(detail)"
            }
        }
    }

    /// Thread-safe wrapper for mutable adapter state.
    private final class AdapterState: @unchecked Sendable {
        private let lock = NSLock()
        private var _dbQueue: DatabaseQueue?
        private var _pollTask: Task<Void, Never>?
        private var _isRunning = false
        private var _lastProcessedRowID: Int64 = 0

        var dbQueue: DatabaseQueue? {
            get { lock.withLock { _dbQueue } }
            set { lock.withLock { _dbQueue = newValue } }
        }

        var isRunning: Bool {
            get { lock.withLock { _isRunning } }
            set { lock.withLock { _isRunning = newValue } }
        }

        var lastProcessedRowID: Int64 {
            get { lock.withLock { _lastProcessedRowID } }
            set { lock.withLock { _lastProcessedRowID = newValue } }
        }

        func setPollTask(_ task: Task<Void, Never>?) {
            lock.withLock { _pollTask = task }
        }

        func cancelAndClear() {
            lock.withLock {
                _isRunning = false
                _pollTask?.cancel()
                _pollTask = nil
                _dbQueue = nil
            }
        }
    }

    private let pollIntervalNanoseconds: UInt64 = 5_000_000_000
    private let chatDBPath: String
    private let legacyHandler: LegacyMessageHandler?
    private let state = AdapterState()

    var isRunning: Bool { state.isRunning }
    var lastProcessedRowID: Int64 { state.lastProcessedRowID }

    /// Create an adapter for use with `ChannelGateway`.
    ///
    /// The gateway sets `onMessage` after creation to receive `ChannelMessage` envelopes.
    init() {
        self.legacyHandler = nil
        self.chatDBPath = ("~/Library/Messages/chat.db" as NSString).expandingTildeInPath
    }

    /// Create an adapter with a legacy handler (backward compatibility with `ChannelManager`).
    ///
    /// - Parameter handler: Callback invoked for each raw `IncomingMessage`.
    init(handler: @escaping LegacyMessageHandler) {
        self.legacyHandler = handler
        self.chatDBPath = ("~/Library/Messages/chat.db" as NSString).expandingTildeInPath
    }

    // MARK: - ChannelAdapter

    func start() async throws {
        guard !state.isRunning else { return }

        try openReadOnlyDatabaseIfNeeded()
        try primeLastProcessedRowIDIfNeeded()
        _ = try await runMessagesAppleScriptProbe()

        state.isRunning = true
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.pollLoop()
        }
        state.setPollTask(task)

        NSLog("iMessageAdapter: started (lastProcessedRowID=%lld)", state.lastProcessedRowID)
    }

    func stop() async {
        guard state.isRunning else { return }
        state.cancelAndClear()
        NSLog("iMessageAdapter: stopped")
    }

    func send(response: String, to message: ChannelMessage) async throws {
        try await sendReply(text: response, to: message.senderId)
    }

    // MARK: - Legacy Send API

    /// Send a reply via AppleScript to the Messages app.
    ///
    /// - Parameters:
    ///   - text: The reply text.
    ///   - buddyNumber: The recipient's phone number or Apple ID.
    func sendReply(text: String, to buddyNumber: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBuddy = buddyNumber.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedText.isEmpty, !trimmedBuddy.isEmpty else { return }

        let script = [
            "on run argv",
            "    set outgoingText to item 1 of argv",
            "    set buddyNumber to item 2 of argv",
            "    tell application \"Messages\"",
            "        set targetService to 1st service whose service type = iMessage",
            "        send outgoingText to buddy buddyNumber of targetService",
            "    end tell",
            "end run",
        ]

        _ = try await runAppleScript(lines: script, arguments: [trimmedText, trimmedBuddy])
    }

    // MARK: - Polling

    private func pollLoop() async {
        while state.isRunning, !Task.isCancelled {
            do {
                try await pollOnce()
            } catch {
                NSLog("iMessageAdapter: poll failed: %@", error.localizedDescription)
            }

            do {
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            } catch {
                return
            }
        }
    }

    private func pollOnce() async throws {
        try openReadOnlyDatabaseIfNeeded()

        let messages = try fetchMessages(after: state.lastProcessedRowID)
        guard !messages.isEmpty else { return }

        for message in messages {
            // Gateway path: convert to ChannelMessage and dispatch.
            if let onMessage {
                let envelope = ChannelMessage(
                    id: "imsg-\(message.rowID)",
                    channel: .imessage,
                    senderId: message.sender,
                    senderDisplayName: nil,
                    text: message.text,
                    timestamp: message.sentAt
                )
                let reply = await onMessage(envelope)
                if let reply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try? await sendReply(text: reply, to: message.sender)
                }
            } else if let legacyHandler {
                // Legacy path: forward raw IncomingMessage to ChannelManager callback.
                await legacyHandler(message)
            }
            state.lastProcessedRowID = message.rowID
        }
    }

    // MARK: - Database

    private func openReadOnlyDatabaseIfNeeded() throws {
        if state.dbQueue != nil {
            return
        }

        guard FileManager.default.fileExists(atPath: chatDBPath) else {
            throw AdapterError.chatDatabaseMissing(chatDBPath)
        }

        var config = Configuration()
        config.readonly = true
        do {
            state.dbQueue = try DatabaseQueue(path: chatDBPath, configuration: config)
        } catch {
            let desc = error.localizedDescription
            if desc.contains("permission") || desc.contains("not permitted") {
                throw AdapterError.chatDatabaseMissing(
                    "\(chatDBPath) — Full Disk Access may be required in System Settings > Privacy"
                )
            }
            throw error
        }
    }

    private func primeLastProcessedRowIDIfNeeded() throws {
        guard state.lastProcessedRowID == 0 else { return }
        guard let dbQueue = state.dbQueue else { return }

        let currentMax: Int64 = try dbQueue.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(ROWID), 0) FROM message"
            ) ?? 0
        }

        state.lastProcessedRowID = currentMax
    }

    private func fetchMessages(after rowID: Int64) throws -> [IncomingMessage] {
        guard let dbQueue = state.dbQueue else { return [] }

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        m.ROWID AS row_id,
                        m.text AS text,
                        m.handle_id AS handle_id,
                        m.date AS msg_date,
                        h.id AS sender
                    FROM message m
                    LEFT JOIN handle h ON h.ROWID = m.handle_id
                    WHERE m.ROWID > ?
                      AND m.is_from_me = 0
                      AND m.text IS NOT NULL
                      AND LENGTH(TRIM(m.text)) > 0
                      AND COALESCE(m.service, '') = 'iMessage'
                    ORDER BY m.ROWID ASC
                    """,
                arguments: [rowID]
            )

            return rows.compactMap { row in
                guard let rowID = row["row_id"] as Int64?,
                      let text = row["text"] as String?
                else {
                    return nil
                }

                let handleID = row["handle_id"] as Int64? ?? 0
                let rawDate = row["msg_date"] as Int64? ?? 0
                let sender = (row["sender"] as String?)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedSender = sender?.isEmpty == false ? (sender ?? "unknown") : "unknown"
                return IncomingMessage(
                    rowID: rowID,
                    text: text,
                    sender: normalizedSender,
                    handleID: handleID,
                    sentAt: Self.appleMessageDateToDate(rawDate),
                    rawDateValue: rawDate
                )
            }
        }
    }

    // MARK: - AppleScript

    private func runMessagesAppleScriptProbe() async throws -> String {
        let script = [
            "tell application \"Messages\"",
            "    return name",
            "end tell",
        ]
        return try await runAppleScript(lines: script, arguments: [])
    }

    private func runAppleScript(lines: [String], arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        var args: [String] = []
        for line in lines {
            args.append("-e")
            args.append(line)
        }
        if !arguments.isEmpty {
            args.append("--")
            args.append(contentsOf: arguments)
        }
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Timeout after 10 seconds to prevent indefinite blocking.
        let timeoutSeconds = 10.0
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while process.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        if process.isRunning {
            process.terminate()
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms grace
            if process.isRunning {
                process.interrupt()
            }
            throw AdapterError.osascriptFailed("timed out after \(Int(timeoutSeconds))s")
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw AdapterError.osascriptFailed(err.isEmpty ? "unknown error" : err)
        }

        return out
    }

    // MARK: - Date conversion

    /// Converts Message.framework date (Apple epoch, often nanoseconds) into `Date`.
    static func appleMessageDateToDate(_ rawValue: Int64) -> Date {
        guard rawValue > 0 else { return Date() }

        let appleReferenceSeconds = 978_307_200.0 // 2001-01-01 00:00:00 UTC

        if rawValue > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: (Double(rawValue) / 1_000_000_000.0) + appleReferenceSeconds)
        }

        return Date(timeIntervalSince1970: Double(rawValue) + appleReferenceSeconds)
    }
}
