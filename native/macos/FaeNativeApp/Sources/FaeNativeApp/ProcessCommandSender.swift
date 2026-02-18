import Foundation

/// Spawns the `fae-host` subprocess and bridges host commands over stdin/stdout pipes.
///
/// Commands are serialized as newline-delimited JSON and written to the
/// subprocess's stdin. Responses and events are read from stdout and logged.
/// When a `capability.requested` event with `jit: true` arrives on stdout, a
/// `faeCapabilityRequested` notification is posted on the main queue so that
/// `JitPermissionController` can trigger the native macOS permission dialog.
final class ProcessCommandSender: HostCommandSender {
    private let binaryURL: URL
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private let readQueue = DispatchQueue(label: "com.saorsalabs.fae.host-stdout", qos: .utility)
    private var requestCounter: UInt64 = 0

    init(binaryURL: URL) {
        self.binaryURL = binaryURL
    }

    /// Launch the subprocess and set up pipes.
    func start() throws {
        let proc = Process()
        proc.executableURL = binaryURL

        let stdin = Pipe()
        let stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice

        // Read stdout lines on background queue
        let stdoutHandle = stdout.fileHandleForReading
        readQueue.async { [weak self] in
            self?.readLoop(handle: stdoutHandle)
        }

        try proc.run()

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout

        NSLog("ProcessCommandSender: launched fae-host at %@", binaryURL.path)
    }

    func sendCommand(name: String, payload: [String: Any]) {
        guard let stdinPipe else {
            NSLog("ProcessCommandSender: not started, cannot send %@", name)
            return
        }

        requestCounter += 1
        let requestId = "swift-\(requestCounter)"

        let envelope: [String: Any] = [
            "v": 1,
            "request_id": requestId,
            "command": name,
            "payload": payload,
        ]

        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope),
              var line = String(data: data, encoding: .utf8)
        else {
            NSLog("ProcessCommandSender: failed to serialize command %@", name)
            return
        }

        line.append("\n")

        guard let lineData = line.data(using: .utf8) else { return }
        stdinPipe.fileHandleForWriting.write(lineData)
    }

    func stop() {
        stdinPipe?.fileHandleForWriting.closeFile()
        stdinPipe = nil
        process?.waitUntilExit()
        process = nil
        NSLog("ProcessCommandSender: stopped")
    }

    // MARK: - Stdout Processing

    private func readLoop(handle: FileHandle) {
        var accumulated = Data()

        while true {
            let data = handle.availableData
            if data.isEmpty { break }  // EOF

            accumulated.append(data)

            // Process complete lines
            while let newlineRange = accumulated.range(of: Data([0x0A])) {
                let lineData = accumulated.subdata(
                    in: accumulated.startIndex..<newlineRange.lowerBound
                )
                accumulated.removeSubrange(accumulated.startIndex...newlineRange.lowerBound)

                guard let lineStr = String(data: lineData, encoding: .utf8),
                      !lineStr.trimmingCharacters(in: .whitespaces).isEmpty
                else {
                    continue
                }

                NSLog("ProcessCommandSender [stdout]: %@", lineStr)
                parseEventLine(lineStr)
            }
        }

        NSLog("ProcessCommandSender: stdout closed (subprocess exited)")
    }

    /// Parse a stdout NDJSON line as an event envelope and dispatch notifications
    /// for events that the Swift layer needs to handle natively.
    ///
    /// Only `capability.requested` events with `jit: true` trigger a notification.
    /// All other events are logged via `readLoop` and silently ignored here.
    private func parseEventLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = json["event"] as? String,
              let payload = json["payload"] as? [String: Any]
        else {
            return
        }

        switch event {
        case "capability.requested":
            guard let capability = payload["capability"] as? String,
                  let reason = payload["reason"] as? String
            else { return }
            let jit = payload["jit"] as? Bool ?? false
            // Only JIT requests trigger native permission dialogs mid-conversation.
            // Non-JIT (proactive/initial) capability requests are handled separately.
            guard jit else { return }

            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .faeCapabilityRequested,
                    object: nil,
                    userInfo: [
                        "capability": capability,
                        "reason": reason,
                        "jit": jit
                    ]
                )
            }

        default:
            break
        }
    }

    deinit {
        stop()
    }
}
