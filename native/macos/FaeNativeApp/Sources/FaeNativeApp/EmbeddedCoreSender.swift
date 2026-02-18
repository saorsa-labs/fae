import CLibFae
import Foundation

/// Sends host commands to the embedded Rust core via the C ABI (libfae.a).
///
/// Replaces `ProcessCommandSender` — no subprocess, no pipes, zero IPC.
/// Commands are dispatched synchronously through `fae_core_send_command`
/// which blocks on the internal tokio runtime.
final class EmbeddedCoreSender: HostCommandSender {
    /// Opaque handle to the Fae runtime (owned, must be destroyed on deinit).
    private var handle: FaeCoreHandle?
    private var requestCounter: UInt64 = 0

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

    /// Send a command to the Rust backend and log the response.
    func sendCommand(name: String, payload: [String: Any]) {
        guard let handle else {
            NSLog("EmbeddedCoreSender: not initialized, cannot send %@", name)
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
              let jsonString = String(data: data, encoding: .utf8)
        else {
            NSLog("EmbeddedCoreSender: failed to serialize command %@", name)
            return
        }

        let responsePtr = jsonString.withCString { ptr in
            fae_core_send_command(handle, ptr)
        }

        if let responsePtr {
            let responseStr = String(cString: responsePtr)
            NSLog("EmbeddedCoreSender [response]: %@", responseStr)
            fae_string_free(responsePtr)
        } else {
            NSLog("EmbeddedCoreSender: send_command returned null for %@", name)
        }
    }

    /// Stop the runtime and release the handle.
    func stop() {
        guard let handle else { return }
        fae_core_stop(handle)
        fae_core_destroy(handle)
        self.handle = nil
        NSLog("EmbeddedCoreSender: stopped and destroyed")
    }

    deinit {
        stop()
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
