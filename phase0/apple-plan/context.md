# Context: Swift Frontend Integration Planning

## Relevant Files (with line counts)

### Core Architecture
| File | Lines | Key Insight |
|------|-------|-------------|
| `native/macos/Fae/Sources/Fae/Core/FaeCore.swift` | ~3,100 | Central coordinator; owns lifecycle, config, subsystem orchestration; will become DaemonConnection manager |
| `native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift` | ~8,600 | Voice pipeline brain; mic→VAD→STT→LLM→TTS→playback; **moves to Rust daemon** |
| `native/macos/Fae/Sources/Fae/Scheduler/FaeScheduler.swift` | ~2,300 | Background tasks, memory GC, awareness; **moves to Rust daemon** |
| `native/macos/Fae/Sources/Fae/Memory/MemoryOrchestrator.swift` | ~1,600 | Memory recall/capture, entity linking; **moves to Rust daemon** |
| `native/macos/Fae/Sources/Fae/Memory/SQLiteMemoryStore.swift` | ~1,500 | fae.db persistence, FTS5 search; **moves to Rust daemon** |

### Apple Platform Integration (stays in Swift)
| File | Lines | Key Insight |
|------|-------|-------------|
| `native/macos/Fae/Sources/Fae/Tools/AppleTools.swift` | ~1,100 | Calendar, Reminders, Contacts, Mail, Notes tools; **requires Swift for EventKit/Contacts frameworks** |
| `native/macos/Fae/Sources/Fae/Audio/AudioCaptureManager.swift` | ~600 | AVAudioEngine mic capture; **stays in Swift** |
| `native/macos/Fae/Sources/Fae/Audio/AudioPlaybackManager.swift` | ~400 | AVAudioPlayerNode TTS playback; **stays in Swift** |
| `native/macos/Fae/Sources/Fae/FaeRelayServer.swift` | ~450 | Multipeer Connectivity for iOS companion; **stays in Swift** |

### Tool Execution
| File | Lines | Key Insight |
|------|-------|-------------|
| `native/macos/Fae/Sources/Fae/Tools/ToolExecutor.swift` | ~800 | Tool execution pipeline with DamageControlPolicy; generic routing moves to daemon, Apple tool bridge stays |
| `native/macos/Fae/Sources/Fae/Tools/ToolRegistry.swift` | ~280 | Tool registration; splits into daemon tools + Swift Apple tools |

### ML Engines (move to Rust daemon)
| File | Lines | Key Insight |
|------|-------|-------------|
| `native/macos/Fae/Sources/Fae/ML/MLXSTTEngine.swift` | ~140 | Qwen3-ASR via MLX; **replaced by mistral.rs STT** |
| `native/macos/Fae/Sources/Fae/ML/FaeTTSAdapter.swift` | ~300 | Kokoro TTS via KokoroSwift; **replaced by ort/misaki-rs** |
| `native/macos/Fae/Sources/Fae/ML/ModelManager.swift` | ~800 | Model loading/lifecycle; **moves to daemon** |

### Configuration & Events
| File | Lines | Key Insight |
|------|-------|-------------|
| `native/macos/Fae/Sources/Fae/Core/FaeConfig.swift` | ~1,500 | Config schema; daemon owns truth, Swift mirrors read-only |
| `native/macos/Fae/Sources/Fae/Core/FaeEvent.swift` | ~60 | Event types; maps to daemon protocol events |
| `native/macos/Fae/Sources/Fae/Core/FaeEventBus.swift` | ~100 | Combine-based event bus; will route daemon events |

## Design Documents
| Document | Status | Key Content |
|----------|--------|-------------|
| `docs/architecture/headless-core-impl-plan-2026-06-01.md` | Source of truth | Phase 0-5 plan, gates G1-G6, mistral.rs decision |
| `docs/adr/002-embedded-rust-core.md` | Superseded | Historical C ABI design, JSON protocol v1 (useful reference) |
| `AGENTS.md` | Active | Pure Swift runtime, memory critical, scheduler cadence |

## Key Patterns Already in Codebase

### 1. Event Bus Pattern
```swift
// FaeEventBus.swift
enum FaeEvent: Sendable {
    case pipelineStateChanged(FaePipelineState)
    case assistantText(text: String, isFinal: Bool)
    case toolExecuting(name: String)
    // ... can add daemon events here
}
```

### 2. Actor-Based Concurrency
```swift
actor PipelineCoordinator { ... }
actor FaeScheduler { ... }
actor MemoryOrchestrator { ... }
actor AudioCaptureManager { ... }
// New DaemonConnection, AudioBridge should follow same pattern
```

### 3. Tool Protocol
```swift
protocol Tool: Sendable {
    var name: String { get }
    func execute(input: [String: Any]) async throws -> ToolResult
}
```

### 4. TCC Permission Pattern (AppleTools.swift:48-89)
```swift
private func requestPermission(capability: String) async -> Bool {
    await withCheckedContinuation { continuation in
        // Post .faeCapabilityRequested, listen for grant/deny
    }
}
```

## Dependencies & Constraints

### TCC Permissions Requiring Swift
- `com.apple.security.personal-information.calendars` → EventKit
- `com.apple.security.personal-information.reminders` → EventKit
- `com.apple.security.personal-information.addressbook` → Contacts framework
- `com.apple.security.device.audio-input` → AVFoundation
- `com.apple.security.device.camera` → AVFoundation
- Automation permission → ScriptingBridge/AppleScript

### Data Locations
- Config: `~/.config/fae/config.toml`
- Memory: `~/Library/Application Support/fae/fae.db`
- Speakers: `~/Library/Application Support/fae/speakers.json`
- Skills: `~/.local/share/fae/skills/`
- Daemon socket (new): `~/.fae/fae.sock`

### Latency Budget (from ADR-002)
- Text inject to generation start: p95 ≤ 40ms
- C ABI command dispatch: p95 ≤ 0.25ms
- IPC request/response: p95 ≤ 3ms (Unix socket should be faster)

## Implementation Risks

1. **Audio streaming latency**: PCM frames over WebSocket/Unix socket adds 1-2ms per hop; need binary framing, not JSON
2. **TCC permission timing**: Daemon requests tool → Swift prompts user → grant/deny; async flow needs careful coordination
3. **Crash recovery**: Daemon crash during TTS playback must cleanly stop Swift playback (no orphaned audio)
4. **Feature flag complexity**: Hybrid local+daemon mode during transition may have subtle state sync bugs
5. **Model loading race**: Daemon may still be loading models when Swift tries to send first command
6. **Memory migration**: G4 gate requires zero-loss migration of `fae.db` to daemon; schema compatibility

## Validation Checkpoints

1. **Unit tests**: `swift test` must pass throughout transition
2. **Integration tests**: Add daemon connection mocks for offline testing
3. **Live scenario script**: `docs/checklists/main-and-cowork-live-test-scenarios.md`
4. **Release checklist**: `docs/checklists/app-release-validation.md`
