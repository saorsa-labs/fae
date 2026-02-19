# Phase 2.1: BackendEventRouter Expansion (Swift)

Expand `BackendEventRouter.swift` to route all backend pipeline events to typed
`NotificationCenter` notifications. The Rust backend emits events via `faeBackendEvent`
with an `event` key. Currently only `capability.requested` is routed; all others are
dropped in the `default: break` arm.

## Architecture

Event flow:
```
Rust backend → fae_core_set_event_callback → faeEventCallback → NotificationCenter(.faeBackendEvent)
  → BackendEventRouter.route() → typed notifications → UI controllers
```

Backend event names (from `map_runtime_event()` in handler.rs):
- `pipeline.transcription` → `.faeTranscription`
- `pipeline.assistant_sentence` → `.faeAssistantMessage`
- `pipeline.generating` → `.faeAssistantGenerating`
- `pipeline.tool_executing`, `pipeline.tool_call`, `pipeline.tool_result` → `.faeToolExecution`
- `orb.state_changed`, `orb.palette_set_requested`, `orb.palette_cleared`,
  `orb.feeling_set_requested`, `orb.urgency_set_requested`, `orb.flash_requested` → `.faeOrbStateChanged`
- `pipeline.audio_level` → `.faeAudioLevel`
- `pipeline.control`, `pipeline.mic_status`, `pipeline.permissions_changed`,
  `pipeline.model_selected`, `pipeline.model_selection_prompt`, `pipeline.provider_fallback` → `.faePipelineState`
- `pipeline.memory_recall`, `pipeline.memory_write`, `pipeline.memory_conflict`,
  `pipeline.memory_migration` → `.faeMemoryActivity`

Also route from `channel.rs` emitted events (host command echoes):
- `orb.palette_set_requested`, `orb.feeling_set_requested` etc. (same .faeOrbStateChanged)
- `conversation.gate_set`, `conversation.text_injected`, `conversation.link_detected` (for UI feedback)

## Files

Primary:
- Modify: `native/macos/FaeNativeApp/Sources/FaeNativeApp/BackendEventRouter.swift`

New notification names will be declared in BackendEventRouter.swift via `extension Notification.Name`.

## Tasks

---

## Task 1: Define all typed notification names in BackendEventRouter.swift

Add all new `Notification.Name` constants to `BackendEventRouter.swift` in a new
`extension Notification.Name` block. Do not add any routing logic yet.

**New notification names to add:**
- `faeTranscription` — user speech text from STT
- `faeAssistantMessage` — LLM response text (partial or final)
- `faeAssistantGenerating` — generating state changed
- `faeToolExecution` — tool_executing / tool_call / tool_result
- `faeOrbStateChanged` — all orb state changes (mode, palette, feeling, urgency, flash)
- `faeAudioLevel` — audio RMS level for visualization
- `faePipelineState` — pipeline control, mic status, model events
- `faeMemoryActivity` — memory recall/write/conflict/migration

**Expected userInfo keys per notification (documented in comments):**
- `faeTranscription`: `text: String`, `is_final: Bool`
- `faeAssistantMessage`: `text: String`, `is_final: Bool`
- `faeAssistantGenerating`: `active: Bool`
- `faeToolExecution`: `type: String` ("executing"|"call"|"result"), `name: String`, optional `id`, `success`, `output_text`, `input_json`
- `faeOrbStateChanged`: `change_type: String`, `value: String` (optional), `urgency: Double` (optional)
- `faeAudioLevel`: `rms: Double`
- `faePipelineState`: `event: String`, `payload: [String: Any]`
- `faeMemoryActivity`: `event: String`, `payload: [String: Any]`

**Acceptance criteria:**
- All 8 new notification names compile
- Existing `faeCapabilityRequested` remains unchanged
- Zero Swift warnings

---

## Task 2: Route transcription events → .faeTranscription

In `BackendEventRouter.route()`, add a `case "pipeline.transcription":` arm.

**Routing logic:**
```swift
case "pipeline.transcription":
    let text = payload["text"] as? String ?? ""
    let isFinal = payload["is_final"] as? Bool ?? false
    NotificationCenter.default.post(
        name: .faeTranscription, object: nil,
        userInfo: ["text": text, "is_final": isFinal]
    )
```

**Acceptance criteria:**
- `pipeline.transcription` events are routed to `.faeTranscription`
- `text` and `is_final` keys are forwarded
- Zero warnings

---

## Task 3: Route assistant sentence and generating events → .faeAssistantMessage / .faeAssistantGenerating

Add two case arms:

**`pipeline.assistant_sentence` → `.faeAssistantMessage`:**
```swift
case "pipeline.assistant_sentence":
    let text = payload["text"] as? String ?? ""
    let isFinal = payload["is_final"] as? Bool ?? false
    NotificationCenter.default.post(
        name: .faeAssistantMessage, object: nil,
        userInfo: ["text": text, "is_final": isFinal]
    )
```

**`pipeline.generating` → `.faeAssistantGenerating`:**
```swift
case "pipeline.generating":
    let active = payload["active"] as? Bool ?? false
    NotificationCenter.default.post(
        name: .faeAssistantGenerating, object: nil,
        userInfo: ["active": active]
    )
```

**Acceptance criteria:**
- Both events routed correctly
- Zero warnings

---

## Task 4: Route tool call/result events → .faeToolExecution

Add three case arms for tool events. Each posts `.faeToolExecution` with a
`type` discriminant so consumers can switch on it:

**`pipeline.tool_executing`:**
```swift
case "pipeline.tool_executing":
    let name = payload["name"] as? String ?? ""
    NotificationCenter.default.post(
        name: .faeToolExecution, object: nil,
        userInfo: ["type": "executing", "name": name]
    )
```

**`pipeline.tool_call`:**
```swift
case "pipeline.tool_call":
    var info: [String: Any] = ["type": "call",
                               "name": payload["name"] as? String ?? ""]
    if let id = payload["id"] as? String { info["id"] = id }
    if let inputJson = payload["input_json"] as? String { info["input_json"] = inputJson }
    NotificationCenter.default.post(name: .faeToolExecution, object: nil, userInfo: info)
```

**`pipeline.tool_result`:**
```swift
case "pipeline.tool_result":
    var info: [String: Any] = ["type": "result",
                               "name": payload["name"] as? String ?? "",
                               "success": payload["success"] as? Bool ?? false]
    if let id = payload["id"] as? String { info["id"] = id }
    if let out = payload["output_text"] as? String { info["output_text"] = out }
    NotificationCenter.default.post(name: .faeToolExecution, object: nil, userInfo: info)
```

**Acceptance criteria:**
- All three tool event types routed
- `type` discriminant present in all
- Zero warnings

---

## Task 5: Route orb state events → .faeOrbStateChanged

Add case arms for all orb events. Use `change_type` as discriminant:

- `"orb.state_changed"` → `change_type: "state_changed"`, forward `mode`, `feeling`, `palette`
- `"orb.palette_set_requested"` → `change_type: "palette_set"`, forward `palette`
- `"orb.palette_cleared"` → `change_type: "palette_cleared"`
- `"orb.feeling_set_requested"` → `change_type: "feeling_set"`, forward `feeling`
- `"orb.urgency_set_requested"` → `change_type: "urgency_set"`, forward `urgency: Double`
- `"orb.flash_requested"` → `change_type: "flash"`, forward `flash_type`

Each posts `.faeOrbStateChanged`. Build the `info` dict from payload keys present.

**Acceptance criteria:**
- All 6 orb event types routed
- `change_type` present in all
- Zero warnings

---

## Task 6: Route audio level events → .faeAudioLevel

Add case arm:

```swift
case "pipeline.audio_level":
    let rms = payload["rms"] as? Double ?? 0.0
    NotificationCenter.default.post(
        name: .faeAudioLevel, object: nil,
        userInfo: ["rms": rms]
    )
```

**Acceptance criteria:**
- `pipeline.audio_level` routed to `.faeAudioLevel`
- `rms` value forwarded as Double
- Zero warnings

---

## Task 7: Route pipeline control events → .faePipelineState

Route all pipeline lifecycle and state events by forwarding the event name and
payload directly (consumers can inspect `event` key to discriminate):

Events to handle: `pipeline.control`, `pipeline.mic_status`, `pipeline.generating`
(already handled in Task 3), `pipeline.model_selected`, `pipeline.model_selection_prompt`,
`pipeline.model_switch_requested`, `pipeline.provider_fallback`, `pipeline.permissions_changed`,
`pipeline.conversation_snapshot`, `pipeline.canvas_visibility`, `pipeline.voice_command`,
`pipeline.viseme`, `pipeline.skill_proposal`, `pipeline.noise_budget`,
`pipeline.intelligence_extraction`, `pipeline.briefing_ready`,
`pipeline.relationship_update`.

Use a helper pattern — match each by name and post `.faePipelineState` with
`userInfo: ["event": event, "payload": payload]`. Can use a `Set<String>` to group:

```swift
let pipelineStateEvents: Set<String> = [
    "pipeline.control", "pipeline.mic_status",
    "pipeline.model_selected", "pipeline.model_selection_prompt",
    "pipeline.model_switch_requested", "pipeline.provider_fallback",
    "pipeline.permissions_changed", "pipeline.conversation_snapshot",
    "pipeline.canvas_visibility", "pipeline.voice_command",
    "pipeline.viseme", "pipeline.skill_proposal", "pipeline.noise_budget",
    "pipeline.intelligence_extraction", "pipeline.briefing_ready",
    "pipeline.relationship_update"
]
if pipelineStateEvents.contains(event) {
    NotificationCenter.default.post(
        name: .faePipelineState, object: nil,
        userInfo: ["event": event, "payload": payload]
    )
}
```

Place this before the `default: break` in the switch.

**Acceptance criteria:**
- All listed pipeline events posted to `.faePipelineState`
- `event` and `payload` keys present
- Zero warnings

---

## Task 8: Route memory events → .faeMemoryActivity and final validation

Add case arms for memory events:

```swift
case "pipeline.memory_recall", "pipeline.memory_write",
     "pipeline.memory_conflict", "pipeline.memory_migration":
    NotificationCenter.default.post(
        name: .faeMemoryActivity, object: nil,
        userInfo: ["event": event, "payload": payload]
    )
```

Then run full Swift build validation to confirm zero errors and zero warnings.
Also check that `BackendEventRouter.swift` is well-organized with MARK comments.

**Final structure of BackendEventRouter.route():**
1. Transcription (`pipeline.transcription`)
2. Assistant messages (`pipeline.assistant_sentence`, `pipeline.generating`)
3. Tool execution (`pipeline.tool_executing`, `pipeline.tool_call`, `pipeline.tool_result`)
4. Orb state (all `orb.*` events)
5. Audio level (`pipeline.audio_level`)
6. Memory activity (`pipeline.memory_*`)
7. Capability (existing `capability.requested`)
8. Pipeline state (all remaining `pipeline.*` in pipelineStateEvents set)
9. `default: break`

**Acceptance criteria:**
- All 8 event categories routed
- Swift build: zero errors, zero warnings
- `default: break` only reached for truly unknown events
- MARK comments separate each category
