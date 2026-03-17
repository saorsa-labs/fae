import Foundation
import GRDB

/// Poll-based iMessage adapter.
///
/// Reads new messages from `~/Library/Messages/chat.db` in read-only mode and
/// forwards inbound payloads to a caller-provided async handler.
actor IMessageAdapter {
    struct IncomingMessage: Sendable {
        let rowID: Int64
        let text: String
        let sender: String
        let handleID: Int64
        let sentAt: Date
        let rawDateValue: Int64
    }

    typealias MessageHandler = @Sendable (IncomingMessage) async -> Void

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

    private let pollIntervalNanoseconds: UInt64 = 5_000_000_000
    private let handler: MessageHandler
    private let chatDBPath: String

    private var dbQueue: DatabaseQueue?
    private var pollTask: Task<Void, Never>?
    private(set) var isRunning = false
    private(set) var lastProcessedRowID: Int64 = 0

    init(handler: @escaping MessageHandler) {
        self.handler = handler
        self.chatDBPath = ("~/Library/Messages/chat.db" as NSString).expandingTildeInPath
    }

    func start() async {
        guard !isRunning else { return }

        do {
            try openReadOnlyDatabaseIfNeeded()
            try primeLastProcessedRowIDIfNeeded()
            _ = try await runMessagesAppleScriptProbe()
        } catch {
            NSLog("iMessageAdapter: failed to start: %@", error.localizedDescription)
            isRunning = false
            return
        }

        isRunning = true
        pollTask = Task {
            await self.pollLoop()
        }

        NSLog("iMessageAdapter: started (lastProcessedRowID=%lld)", lastProcessedRowID)
    }

    func stop() {
        guard isRunning else { return }

        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        dbQueue = nil

        NSLog("iMessageAdapter: stopped")
    }

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
        while isRunning, !Task.isCancelled {
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

        let messages = try fetchMessages(after: lastProcessedRowID)
        guard !messages.isEmpty else { return }

        for message in messages {
            await handler(message)
            lastProcessedRowID = message.rowID
        }
    }
    // MARK: - Database

    private func openReadOnlyDatabaseIfNeeded() throws {
        if dbQueue != nil {
            return
        }

        guard FileManager.default.fileExists(atPath: chatDBPath) else {
            throw AdapterError.chatDatabaseMissing(chatDBPath)
        }

        var config = Configuration()
        config.readonly = true
        do {
            dbQueue = try DatabaseQueue(path: chatDBPath, configuration: config)
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
        guard lastProcessedRowID == 0 else { return }
        guard let dbQueue else { return }

        let currentMax: Int64 = try dbQueue.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(ROWID), 0) FROM message"
            ) ?? 0
        }

        lastProcessedRowID = currentMax
    }

    private func fetchMessages(after rowID: Int64) throws -> [IncomingMessage] {
        guard let dbQueue else { return [] }

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
    private static func appleMessageDateToDate(_ rawValue: Int64) -> Date {
        guard rawValue > 0 else { return Date() }

        let appleReferenceSeconds = 978_307_200.0 // 2001-01-01 00:00:00 UTC

        if rawValue > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: (Double(rawValue) / 1_000_000_000.0) + appleReferenceSeconds)
        }

        return Date(timeIntervalSince1970: Double(rawValue) + appleReferenceSeconds)
    }
}
