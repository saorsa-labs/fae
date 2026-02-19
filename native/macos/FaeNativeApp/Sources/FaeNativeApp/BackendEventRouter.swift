@preconcurrency import Foundation

/// Fan-out adapter that observes `.faeBackendEvent` (posted by `EmbeddedCoreSender`)
/// and translates known events into the typed notifications the rest of the stack
/// consumes. This bridges the gap between the generic C-ABI event callback and the
/// specific notification names that controllers like `JitPermissionController` expect.
///
/// ## Event flow
///
/// ```
/// Rust backend
///   → fae_core_set_event_callback
///   → faeEventCallback (C) → NotificationCenter(.faeBackendEvent)
///   → BackendEventRouter.route()
///   → typed notifications consumed by UI controllers
/// ```
///
/// ## Routing table
///
/// | Backend event name(s) | Notification posted |
/// |---|---|
/// | `pipeline.transcription` | `.faeTranscription` |
/// | `pipeline.assistant_sentence` | `.faeAssistantMessage` |
/// | `pipeline.generating` | `.faeAssistantGenerating` |
/// | `pipeline.tool_executing`, `.tool_call`, `.tool_result` | `.faeToolExecution` |
/// | `orb.*` (palette, feeling, urgency, flash, state) | `.faeOrbStateChanged` |
/// | `pipeline.audio_level` | `.faeAudioLevel` |
/// | `pipeline.memory_*` | `.faeMemoryActivity` |
/// | `capability.requested` | `.faeCapabilityRequested` |
/// | remaining `pipeline.*` | `.faePipelineState` |
final class BackendEventRouter: Sendable {
    /// Set once in `init`, never mutated — safe across isolation boundaries.
    private nonisolated(unsafe) let observation: NSObjectProtocol

    init() {
        observation = NotificationCenter.default.addObserver(
            forName: .faeBackendEvent, object: nil, queue: .main
        ) { notification in
            BackendEventRouter.route(notification.userInfo as? [String: Any] ?? [:])
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(observation)
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private static func route(_ info: [String: Any]) {
        guard let event = info["event"] as? String else { return }
        let payload = info["payload"] as? [String: Any] ?? [:]

        switch event {

        // MARK: - Transcription

        case "pipeline.transcription":
            let text = payload["text"] as? String ?? ""
            let isFinal = payload["is_final"] as? Bool ?? false
            NotificationCenter.default.post(
                name: .faeTranscription, object: nil,
                userInfo: ["text": text, "is_final": isFinal]
            )

        // MARK: - Assistant Messages

        case "pipeline.assistant_sentence":
            let text = payload["text"] as? String ?? ""
            let isFinal = payload["is_final"] as? Bool ?? false
            NotificationCenter.default.post(
                name: .faeAssistantMessage, object: nil,
                userInfo: ["text": text, "is_final": isFinal]
            )

        case "pipeline.generating":
            let active = payload["active"] as? Bool ?? false
            NotificationCenter.default.post(
                name: .faeAssistantGenerating, object: nil,
                userInfo: ["active": active]
            )

        // MARK: - Tool Execution

        case "pipeline.tool_executing":
            let name = payload["name"] as? String ?? ""
            NotificationCenter.default.post(
                name: .faeToolExecution, object: nil,
                userInfo: ["type": "executing", "name": name]
            )

        case "pipeline.tool_call":
            var userInfo: [String: Any] = [
                "type": "call",
                "name": payload["name"] as? String ?? "",
            ]
            if let id = payload["id"] as? String { userInfo["id"] = id }
            if let inputJson = payload["input_json"] as? String {
                userInfo["input_json"] = inputJson
            }
            NotificationCenter.default.post(
                name: .faeToolExecution, object: nil, userInfo: userInfo
            )

        case "pipeline.tool_result":
            var userInfo: [String: Any] = [
                "type": "result",
                "name": payload["name"] as? String ?? "",
                "success": payload["success"] as? Bool ?? false,
            ]
            if let id = payload["id"] as? String { userInfo["id"] = id }
            if let outputText = payload["output_text"] as? String {
                userInfo["output_text"] = outputText
            }
            NotificationCenter.default.post(
                name: .faeToolExecution, object: nil, userInfo: userInfo
            )

        // MARK: - Orb State

        case "orb.state_changed":
            var userInfo: [String: Any] = ["change_type": "state_changed"]
            if let mode = payload["mode"] as? String { userInfo["mode"] = mode }
            if let feeling = payload["feeling"] as? String { userInfo["feeling"] = feeling }
            if let palette = payload["palette"] as? String { userInfo["palette"] = palette }
            NotificationCenter.default.post(
                name: .faeOrbStateChanged, object: nil, userInfo: userInfo
            )

        case "orb.palette_set_requested":
            var userInfo: [String: Any] = ["change_type": "palette_set"]
            if let palette = payload["palette"] as? String { userInfo["palette"] = palette }
            NotificationCenter.default.post(
                name: .faeOrbStateChanged, object: nil, userInfo: userInfo
            )

        case "orb.palette_cleared":
            NotificationCenter.default.post(
                name: .faeOrbStateChanged, object: nil,
                userInfo: ["change_type": "palette_cleared"]
            )

        case "orb.feeling_set_requested":
            var userInfo: [String: Any] = ["change_type": "feeling_set"]
            if let feeling = payload["feeling"] as? String { userInfo["feeling"] = feeling }
            NotificationCenter.default.post(
                name: .faeOrbStateChanged, object: nil, userInfo: userInfo
            )

        case "orb.urgency_set_requested":
            var userInfo: [String: Any] = ["change_type": "urgency_set"]
            if let urgency = payload["urgency"] as? Double { userInfo["urgency"] = urgency }
            NotificationCenter.default.post(
                name: .faeOrbStateChanged, object: nil, userInfo: userInfo
            )

        case "orb.flash_requested":
            var userInfo: [String: Any] = ["change_type": "flash"]
            if let flashType = payload["flash_type"] as? String {
                userInfo["flash_type"] = flashType
            }
            NotificationCenter.default.post(
                name: .faeOrbStateChanged, object: nil, userInfo: userInfo
            )

        // MARK: - Audio Level

        case "pipeline.audio_level":
            let rms = payload["rms"] as? Double ?? 0.0
            NotificationCenter.default.post(
                name: .faeAudioLevel, object: nil,
                userInfo: ["rms": rms]
            )

        // MARK: - Memory Activity

        case "pipeline.memory_recall",
             "pipeline.memory_write",
             "pipeline.memory_conflict",
             "pipeline.memory_migration":
            NotificationCenter.default.post(
                name: .faeMemoryActivity, object: nil,
                userInfo: ["event": event, "payload": payload]
            )

        // MARK: - Capability (JIT Permission)

        case "capability.requested":
            let jit = payload["jit"] as? Bool ?? false
            guard jit,
                  let capability = payload["capability"] as? String
            else { return }
            let reason = payload["reason"] as? String ?? ""
            NotificationCenter.default.post(
                name: .faeCapabilityRequested, object: nil,
                userInfo: ["capability": capability, "reason": reason, "jit": true]
            )

        // MARK: - Runtime Lifecycle

        case "runtime.starting", "runtime.started", "runtime.stopped", "runtime.error":
            NotificationCenter.default.post(
                name: .faeRuntimeState, object: nil,
                userInfo: ["event": event, "payload": payload]
            )

        case "runtime.progress":
            NotificationCenter.default.post(
                name: .faeRuntimeProgress, object: nil,
                userInfo: payload
            )

        // MARK: - Pipeline State (all remaining pipeline.* events)

        default:
            // Route remaining pipeline.* events to .faePipelineState for
            // consumers that want access to the raw pipeline lifecycle events.
            let pipelineStateEvents: Set<String> = [
                "pipeline.control",
                "pipeline.mic_status",
                "pipeline.model_selected",
                "pipeline.model_selection_prompt",
                "pipeline.model_switch_requested",
                "pipeline.provider_fallback",
                "pipeline.permissions_changed",
                "pipeline.conversation_snapshot",
                "pipeline.canvas_visibility",
                "pipeline.voice_command",
                "pipeline.viseme",
                "pipeline.skill_proposal",
                "pipeline.noise_budget",
                "pipeline.intelligence_extraction",
                "pipeline.briefing_ready",
                "pipeline.relationship_update",
                // Host-command echo events from channel.rs
                "device.transfer_requested",
                "device.home_requested",
                "conversation.gate_set",
                "conversation.text_injected",
                "conversation.link_detected",
                "capability.granted",
                "capability.denied",
                "onboarding.phase_advanced",
                "onboarding.completed",
                "approval.requested",
                "scheduler.updated",
                "scheduler.removed",
            ]
            if pipelineStateEvents.contains(event) {
                NotificationCenter.default.post(
                    name: .faePipelineState, object: nil,
                    userInfo: ["event": event, "payload": payload]
                )
            }
            // Truly unknown events are silently dropped.
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    // MARK: Transcription

    /// Posted when the STT pipeline emits a user speech transcription segment.
    ///
    /// userInfo keys:
    /// - `text: String` — transcribed text
    /// - `is_final: Bool` — whether this is the final segment for the utterance
    static let faeTranscription = Notification.Name("faeTranscription")

    // MARK: Assistant

    /// Posted when the LLM emits a sentence fragment (partial or final).
    ///
    /// userInfo keys:
    /// - `text: String` — sentence text
    /// - `is_final: Bool` — whether this sentence is complete
    static let faeAssistantMessage = Notification.Name("faeAssistantMessage")

    /// Posted when the LLM starts or stops generating a response.
    ///
    /// userInfo keys:
    /// - `active: Bool` — `true` when generation is in progress
    static let faeAssistantGenerating = Notification.Name("faeAssistantGenerating")

    // MARK: Tool Execution

    /// Posted for all tool execution lifecycle events.
    ///
    /// userInfo keys:
    /// - `type: String` — one of `"executing"`, `"call"`, `"result"`
    /// - `name: String` — tool name
    /// - `id: String?` — tool call ID (present for `"call"` and `"result"`)
    /// - `input_json: String?` — JSON-encoded tool input (present for `"call"`)
    /// - `success: Bool?` — whether the tool succeeded (present for `"result"`)
    /// - `output_text: String?` — tool output text (present for `"result"`)
    static let faeToolExecution = Notification.Name("faeToolExecution")

    // MARK: Orb State

    /// Posted when any orb state changes (palette, feeling, urgency, flash, or combined).
    ///
    /// userInfo keys:
    /// - `change_type: String` — discriminant: `"state_changed"`, `"palette_set"`,
    ///   `"palette_cleared"`, `"feeling_set"`, `"urgency_set"`, `"flash"`
    /// - `mode: String?` — orb mode (present for `"state_changed"`)
    /// - `feeling: String?` — orb feeling name (present for `"state_changed"`, `"feeling_set"`)
    /// - `palette: String?` — palette name (present for `"state_changed"`, `"palette_set"`)
    /// - `urgency: Double?` — urgency level 0.0–1.0 (present for `"urgency_set"`)
    /// - `flash_type: String?` — flash type (present for `"flash"`)
    static let faeOrbStateChanged = Notification.Name("faeOrbStateChanged")

    // MARK: Audio

    /// Posted continuously during TTS playback with the current audio RMS level.
    ///
    /// userInfo keys:
    /// - `rms: Double` — root-mean-square amplitude 0.0–1.0
    static let faeAudioLevel = Notification.Name("faeAudioLevel")

    // MARK: Pipeline State

    /// Posted for pipeline lifecycle events not handled by more specific notifications.
    ///
    /// userInfo keys:
    /// - `event: String` — the original backend event name (e.g. `"pipeline.control"`)
    /// - `payload: [String: Any]` — the raw event payload dictionary
    static let faePipelineState = Notification.Name("faePipelineState")

    // MARK: Memory

    /// Posted when memory recall, write, conflict, or migration events occur.
    ///
    /// userInfo keys:
    /// - `event: String` — the original backend event name
    /// - `payload: [String: Any]` — the raw event payload dictionary
    static let faeMemoryActivity = Notification.Name("faeMemoryActivity")

    // MARK: Runtime Lifecycle

    /// Posted for runtime lifecycle transitions (starting, started, stopped, error).
    ///
    /// userInfo keys:
    /// - `event: String` — one of `"runtime.starting"`, `"runtime.started"`,
    ///   `"runtime.stopped"`, `"runtime.error"`
    /// - `payload: [String: Any]` — event payload (may contain `"error"` message)
    static let faeRuntimeState = Notification.Name("faeRuntimeState")

    /// Posted when model download/load progress is reported during startup.
    ///
    /// userInfo keys vary by progress stage:
    /// - `stage: String` — `"download_started"`, `"aggregate_progress"`,
    ///   `"load_started"`, `"load_complete"`, `"error"`
    /// - `model_name: String?` — model being loaded
    /// - `progress: Double?` — 0.0–1.0 for `"aggregate_progress"`
    /// - `message: String?` — error description for `"error"`
    static let faeRuntimeProgress = Notification.Name("faeRuntimeProgress")
}
