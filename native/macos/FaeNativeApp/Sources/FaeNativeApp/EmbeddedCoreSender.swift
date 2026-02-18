import CLibFae
import Foundation

/// Wrapper so the opaque C handle can be passed across isolation boundaries.
/// Safe because the handle is only accessed from the serial `commandQueue`.
private struct SendableHandle: @unchecked Sendable {
    let raw: FaeCoreHandle
}

/// Sends host commands to the embedded Rust core via the C ABI (libfae.a).
///
/// Replaces `ProcessCommandSender` — no subprocess, no pipes, zero IPC.
/// Commands are serialised on a dedicated background queue so the blocking
/// `fae_core_send_command` call never stalls the main thread.
final class EmbeddedCoreSender: HostCommandSender {
    /// Opaque handle to the Fae runtime (owned, must be destroyed on deinit).
    private var handle: FaeCoreHandle?

    /// Monotonic counter for generating unique request IDs.
    /// Only accessed from `commandQueue` to avoid data races.
    private var requestCounter: UInt64 = 0

    /// Serial queue for all C ABI calls so they never block the main actor.
    /// Also serialises `requestCounter` access.
    private let commandQueue = DispatchQueue(label: "com.saorsalabs.fae.command-sender")

    /// Initialize the Rust runtime with a JSON configuration string.
    ///
    /// - Parameter configJSON: Configuration JSON (e.g. `"{}"`).
    init(configJSON: String = "{}") {
        handle = configJSON.withCString { ptr in
            fae_core_init(ptr)
        }
        if handle == nil {
            NSLog("EmbeddedCoreSender: fae_core_init returned null — init failed")
        }
    }

    /// Start the Rust runtime (spawns the command server on the tokio runtime).
    ///
    /// Must be called before `sendCommand`. Registers an event callback that
    /// posts Rust-side events to `NotificationCenter` as `.faeBackendEvent`.
    func start() throws {
        guard let handle else {
            throw EmbeddedCoreError.notInitialized
        }
        let rc = fae_core_start(handle)
        if rc != 0 {
            throw EmbeddedCoreError.startFailed(code: rc)
        }

        // Register the event callback so Rust events reach the Swift UI.
        fae_core_set_event_callback(handle, faeEventCallback, nil)

        NSLog("EmbeddedCoreSender: runtime started with event callback")
    }

    /// Send a fire-and-forget command to the Rust backend on a background queue.
    func sendCommand(name: String, payload: [String: Any]) {
        guard let handle else {
            NSLog("EmbeddedCoreSender: not initialized, cannot send %@", name)
            return
        }

        let sendable = SendableHandle(raw: handle)
        commandQueue.async { [weak self] in
            guard let self else { return }
            self.requestCounter += 1
            let requestId = "swift-\(self.requestCounter)"

            guard let jsonString = Self.buildEnvelopeJSON(
                requestId: requestId, command: name, payload: payload
            ) else {
                NSLog("EmbeddedCoreSender: failed to serialize command %@", name)
                return
            }

            Self.executeCommand(sendable.raw, json: jsonString, label: name)
        }
    }

    /// Query the backend on the serial queue and return the parsed response
    /// payload. Use for startup queries like `onboarding.get_state`.
    func queryCommand(name: String, payload: [String: Any]) async -> [String: Any]? {
        guard let handle else {
            NSLog("EmbeddedCoreSender: not initialized, cannot query %@", name)
            return nil
        }

        let sendable = SendableHandle(raw: handle)
        let localQueue = commandQueue
        return await withCheckedContinuation { [weak self] continuation in
            localQueue.async {
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                self.requestCounter += 1
                let requestId = "swift-\(self.requestCounter)"

                guard let jsonString = Self.buildEnvelopeJSON(
                    requestId: requestId, command: name, payload: payload
                ) else {
                    NSLog("EmbeddedCoreSender: failed to serialize query %@", name)
                    continuation.resume(returning: nil)
                    return
                }

                let result = Self.executeCommandWithResponse(
                    sendable.raw, json: jsonString, label: name
                )
                continuation.resume(returning: result)
            }
        }
    }

    /// Stop the runtime and release the handle.
    ///
    /// Synchronously drains the command queue before destroying the handle so
    /// that in-flight commands using a captured `SendableHandle` finish before
    /// the underlying pointer is freed.
    func stop() {
        guard let handle else { return }
        // Nil the handle first so no new work is enqueued.
        self.handle = nil
        // Drain any in-flight commands that captured the old handle value.
        commandQueue.sync {}
        fae_core_stop(handle)
        fae_core_destroy(handle)
        NSLog("EmbeddedCoreSender: stopped and destroyed")
    }

    deinit {
        stop()
    }

    // MARK: - Private helpers

    private static func buildEnvelopeJSON(
        requestId: String, command: String, payload: [String: Any]
    ) -> String? {
        let envelope: [String: Any] = [
            "v": 1,
            "request_id": requestId,
            "command": command,
            "payload": payload,
        ]
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    private static func executeCommand(
        _ handle: FaeCoreHandle, json: String, label: String
    ) {
        let responsePtr = json.withCString { ptr in
            fae_core_send_command(handle, ptr)
        }
        if let responsePtr {
            let responseStr = String(cString: responsePtr)
            NSLog("EmbeddedCoreSender: send_command ok for %@ (%d bytes)", label, responseStr.count)
            fae_string_free(responsePtr)
        } else {
            NSLog("EmbeddedCoreSender: send_command returned null for %@", label)
        }
    }

    private static func executeCommandWithResponse(
        _ handle: FaeCoreHandle, json: String, label: String
    ) -> [String: Any]? {
        let responsePtr = json.withCString { ptr in
            fae_core_send_command(handle, ptr)
        }
        guard let responsePtr else {
            NSLog("EmbeddedCoreSender: send_command returned null for %@", label)
            return nil
        }
        let responseStr = String(cString: responsePtr)
        fae_string_free(responsePtr)

        guard let data = responseStr.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            NSLog("EmbeddedCoreSender: failed to parse response for %@", label)
            return nil
        }
        return parsed
    }
}

/// C-level callback invoked synchronously by the Rust runtime during
/// `fae_core_send_command`. Parses the event JSON and posts a notification
/// on the main thread so the UI layer can observe backend events.
private func faeEventCallback(eventJson: UnsafePointer<CChar>?, userData: UnsafeMutableRawPointer?) {
    guard let eventJson else { return }
    let jsonString = String(cString: eventJson)

    guard let data = jsonString.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        NSLog("EmbeddedCoreSender: failed to parse event JSON")
        return
    }

    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .faeBackendEvent,
            object: nil,
            userInfo: parsed
        )
    }
}

extension Notification.Name {
    static let faeBackendEvent = Notification.Name("faeBackendEvent")
}

/// Errors specific to the embedded Rust core lifecycle.
enum EmbeddedCoreError: LocalizedError {
    case notInitialized
    case startFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Fae runtime failed to initialize (fae_core_init returned null)"
        case .startFailed(let code):
            return "Fae runtime failed to start (fae_core_start returned \(code))"
        }
    }
}
