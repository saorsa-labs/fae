import Combine
import Foundation

/// Central event bus that replaces the Rust → C callback → JSON → NotificationCenter
/// chain with a typed Combine subject.
///
/// For backward compatibility, every `FaeEvent` is also bridged to the
/// `.faeBackendEvent` notification that `BackendEventRouter` consumes, ensuring
/// all 50+ existing UI controllers continue to work unchanged.
final class FaeEventBus: @unchecked Sendable {
    let subject = PassthroughSubject<FaeEvent, Never>()
    private var cancellable: AnyCancellable?

    init() {
        cancellable = subject.sink { [weak self] event in
            self?.postAsBackendEvent(event)
        }
    }

    func send(_ event: FaeEvent) {
        subject.send(event)
    }

    // MARK: - NotificationCenter Bridge

    /// Convert a `FaeEvent` into the same JSON-style dictionary format that
    /// the Rust core used to emit via `fae_core_poll_event`, and post it as
    /// `.faeBackendEvent`. This allows `BackendEventRouter` to route it to
    /// the typed notification names that existing UI controllers observe.
    private func postAsBackendEvent(_ event: FaeEvent) {
        var eventName: String
        var payload: [String: Any] = [:]

        switch event {
        case .pipelineStateChanged(let state):
            eventName = "pipeline.control"
            payload["state"] = state.rawValue

        case .assistantGenerating(let active):
            eventName = "pipeline.generating"
            payload["active"] = active

        case .audioLevel(let rms):
            eventName = "pipeline.audio_level"
            payload["rms"] = Double(rms)

        case .transcription(let text, let isFinal):
            eventName = "pipeline.transcription"
            payload["text"] = text
            payload["is_final"] = isFinal

        case .assistantText(let text, let isFinal):
            eventName = "pipeline.assistant_sentence"
            payload["text"] = text
            payload["is_final"] = isFinal

        case .runtimeState(let state):
            eventName = "runtime.\(state.rawValue)"

        case .runtimeProgress(let stage, let progress):
            eventName = "runtime.progress"
            payload["stage"] = stage
            payload["progress"] = progress

        case .orbStateChanged(let mode, let feeling, let palette):
            eventName = "orb.state_changed"
            payload["mode"] = mode
            payload["feeling"] = feeling
            if let palette { payload["palette"] = palette }

        case .approvalRequested(let id, let toolName, let input):
            eventName = "approval.requested"
            payload["request_id"] = id
            payload["tool_name"] = toolName
            payload["input_json"] = input

        case .approvalResolved(let id, let approved, let source):
            eventName = "approval.resolved"
            payload["request_id"] = id
            payload["approved"] = approved
            payload["source"] = source

        case .memoryRecalled(let count):
            eventName = "pipeline.memory_recall"
            payload["count"] = count

        case .memoryCaptured(let id):
            eventName = "pipeline.memory_write"
            payload["id"] = id

        case .toolExecuting(let name):
            eventName = "pipeline.tool_executing"
            payload["name"] = name

        case .toolCall(let id, let name, let inputJSON):
            eventName = "pipeline.tool_call"
            payload["id"] = id
            payload["name"] = name
            payload["input_json"] = inputJSON

        case .toolResult(let id, let name, let success, let output):
            eventName = "pipeline.tool_result"
            payload["id"] = id
            payload["name"] = name
            payload["success"] = success
            payload["output_text"] = output

        case .capabilityRequested(let capability, let reason):
            eventName = "capability.requested"
            payload["capability"] = capability
            payload["reason"] = reason
            payload["jit"] = true
        }

        let userInfo: [String: Any] = [
            "event": eventName,
            "payload": payload,
        ]

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .faeBackendEvent,
                object: nil,
                userInfo: userInfo
            )
        }
    }
}
