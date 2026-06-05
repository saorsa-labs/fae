# Swift Frontend Integration Plan (Apple v1)

> **Status:** Phase 0 research artifact — requires owner approval before implementation  
> **Date:** 2026-06-01  
> **Scope:** Transform current Swift macOS Fae into a thin UX frontend for the Rust headless daemon  
> **Related:** `docs/architecture/headless-core-impl-plan-2026-06-01.md`, `docs/adr/002-embedded-rust-core.md`

---

## 1. Current Swift Architecture Inventory

### 1.1 Core Subsystems (Lines of Code)

| Component | File | LOC | Responsibility |
|-----------|------|-----|----------------|
| **FaeCore** | `Core/FaeCore.swift` | ~3,100 | Central coordinator, lifecycle, config, model loading, subsystem orchestration |
| **PipelineCoordinator** | `Pipeline/PipelineCoordinator.swift` | ~8,600 | Voice pipeline: mic → VAD → STT → LLM → TTS → playback, barge-in, tool routing |
| **FaeScheduler** | `Scheduler/FaeScheduler.swift` | ~2,300 | Background tasks, memory GC, morning briefing, awareness, skill distillation |
| **MemoryOrchestrator** | `Memory/MemoryOrchestrator.swift` | ~1,600 | Memory recall, capture, entity linking, embedding management |
| **SQLiteMemoryStore** | `Memory/SQLiteMemoryStore.swift` | ~1,500 | fae.db persistence, FTS5 search, GRDB wrapper |
| **ToolExecutor** | `Tools/ToolExecutor.swift` | ~800 | Tool execution pipeline, DamageControlPolicy, approval flow |
| **ToolRegistry** | `Tools/ToolRegistry.swift` | ~280 | Tool registration, schema generation, mode filtering |

### 1.2 Voice Pipeline Entry Points

```
AudioCaptureManager.startCapture() → AsyncStream<AudioChunk>
    ↓
PipelineCoordinator.runPipelineLoop(stream:)
    ↓
VAD (SileroVADEngine) → SpeechSegment
    ↓
SpeakerGate (speaker verification)
    ↓
STT (MLXSTTEngine/ParakeetStreamingEngine)
    ↓
LLM (MLXLLMEngine)
    ↓
TTS (FaeTTSAdapter/KokoroSwift)
    ↓
AudioPlaybackManager.enqueue(samples:)
```

### 1.3 Apple TCC-Gated Integrations

| Tool | Framework | TCC Permission | Entry Point |
|------|-----------|---------------|-------------|
| Calendar | EventKit | `com.apple.security.personal-information.calendars` | `CalendarTool.execute()` |
| Reminders | EventKit | `com.apple.security.personal-information.reminders` | `RemindersTool.execute()` |
| Contacts | Contacts | `com.apple.security.personal-information.addressbook` | `ContactsTool.execute()` |
| Mail | ScriptingBridge | Automation permission | `MailTool.execute()` |
| Notes | AppleScript | Automation permission | `NotesTool.execute()` |
| Microphone | AVFoundation | `com.apple.security.device.audio-input` | `AudioCaptureManager` |
| Camera | AVFoundation | `com.apple.security.device.camera` | `CameraTool`, proactive vision |
| Accessibility | AX API | `com.apple.security.accessibility` | `ClickTool`, `ReadScreenTool` |

### 1.4 Current Config & State Storage

| Data | Location | Format |
|------|----------|--------|
| Config | `~/.config/fae/config.toml` | TOML |
| Memory DB | `~/Library/Application Support/fae/fae.db` | SQLite |
| Speaker profiles | `~/Library/Application Support/fae/speakers.json` | JSON |
| Session history | `~/Library/Application Support/fae/fae.db` (sessions table) | SQLite |
| Skill definitions | `~/.local/share/fae/skills/` | Markdown |
| TCC state | macOS system | TCC database |
| UserDefaults | `fae.` namespace | NSUserDefaults |

---

## 2. Target Architecture: Thin Swift Frontend

### 2.1 Subsystem Relocation Map

| Current Swift | Target Location | Notes |
|--------------|-----------------|-------|
| `PipelineCoordinator` (voice/LLM) | **Rust daemon** | Core brain moves to Rust |
| `FaeScheduler` | **Rust daemon** | Scheduler leader always in daemon |
| `MemoryOrchestrator` | **Rust daemon** | Memory recall/capture in Rust |
| `SQLiteMemoryStore` | **Rust daemon** | fae.db owned by daemon |
| `ToolExecutor` (generic) | **Rust daemon** | Tool routing in Rust |
| `MLXSTTEngine` | **Rust daemon** | STT via mistral.rs |
| `MLXLLMEngine` | **Rust daemon** | LLM via mistral.rs |
| `FaeTTSAdapter` | **Rust daemon** | TTS via ort/misaki-rs |
| `AudioCaptureManager` | **Swift** | Mic capture stays (macOS AVFoundation) |
| `AudioPlaybackManager` | **Swift** | TTS playback stays (macOS AVFoundation) |
| `AppleTools` (Calendar/Contacts/etc) | **Swift** | EventKit/Contacts frameworks require Swift |
| UI (SwiftUI/AppKit) | **Swift** | All UI stays in Swift |
| Orb rendering | **Swift** | Metal shaders stay |
| TCC permission dialogs | **Swift** | Native system dialogs |
| FaeRelayServer | **Swift** | Multipeer for iOS companion |

### 2.2 New Swift Components

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Swift Frontend                              │
├─────────────────────────────────────────────────────────────────────┤
│  UI Layer                                                           │
│  ├── FaeApp.swift                                                   │
│  ├── ContentView.swift                                              │
│  ├── ConversationWindowView.swift                                   │
│  ├── SettingsView.swift                                             │
│  └── NativeOrbView.swift (Metal)                                    │
├─────────────────────────────────────────────────────────────────────┤
│  NEW: DaemonBridge                                                  │
│  ├── DaemonConnection.swift         WebSocket + Unix socket client  │
│  ├── CommandProtocol.swift          JSON command/event codec        │
│  ├── AudioBridge.swift              PCM streaming to/from daemon    │
│  ├── EventRouter.swift              Daemon events → UI updates      │
│  └── HeartbeatMonitor.swift         Connection health + reconnect   │
├─────────────────────────────────────────────────────────────────────┤
│  Apple Platform Layer (remains in Swift)                            │
│  ├── AppleToolBridge.swift          Tool calls from daemon          │
│  ├── AudioCaptureManager.swift      Mic → daemon (PCM stream)       │
│  ├── AudioPlaybackManager.swift     Daemon TTS → speakers           │
│  ├── TCCPermissionManager.swift     Permission state + prompts      │
│  ├── NotificationBridge.swift       macOS notifications             │
│  └── FaeRelayServer.swift           iOS companion relay             │
├─────────────────────────────────────────────────────────────────────┤
│  Config & State (read-only mirrors)                                 │
│  ├── ConfigMirror.swift             Sync config from daemon         │
│  └── StateMirror.swift              Pipeline state, history         │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              │ WebSocket + Unix Socket
                              │ JSON commands, binary audio frames
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         Rust Daemon (fae-daemon)                    │
├─────────────────────────────────────────────────────────────────────┤
│  Pipeline        Memory       Tools       Scheduler      Engine     │
│  Coordinator     System       Router      Leader         mistral.rs │
│                                                          (E4B/Qwen3)│
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. Daemon Connection Lifecycle

### 3.1 Connection Establishment

```swift
// DaemonConnection.swift
actor DaemonConnection {
    enum Transport: Sendable {
        case unixSocket(path: String)    // ~/.fae/fae.sock
        case webSocket(url: URL)         // ws://127.0.0.1:9876/fae
    }
    
    enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case connected(protocolVersion: UInt32)
        case reconnecting(attempt: Int, maxAttempts: Int)
        case failed(error: String)
    }
    
    private(set) var state: ConnectionState = .disconnected
    
    /// Attempt connection with fallback strategy:
    /// 1. Unix socket (fastest, preferred)
    /// 2. WebSocket localhost (fallback)
    func connect() async throws {
        state = .connecting
        
        // Try Unix socket first
        let socketPath = "~/.fae/fae.sock".expandingTildeInPath
        if FileManager.default.fileExists(atPath: socketPath) {
            if let conn = try? await connectUnixSocket(socketPath) {
                state = .connected(protocolVersion: conn.version)
                return
            }
        }
        
        // Fall back to WebSocket
        let wsURL = URL(string: "ws://127.0.0.1:9876/fae")!
        let conn = try await connectWebSocket(wsURL)
        state = .connected(protocolVersion: conn.version)
    }
}
```

### 3.2 Startup Sequence

```
┌──────────────────────────────────────────────────────────────────┐
│ App Launch                                                        │
├──────────────────────────────────────────────────────────────────┤
│ 1. Swift: Load FaeApp                                             │
│ 2. Swift: Check for existing daemon process (launchd or running) │
│ 3. Swift: If no daemon → spawn fae-daemon subprocess             │
│ 4. Swift: DaemonConnection.connect() with retry                   │
│ 5. Daemon: Sends `runtime.ready` event with capabilities          │
│ 6. Swift: Query TCC permissions, send `capability.status`        │
│ 7. Daemon: Loads models, sends `model.loaded` events              │
│ 8. Swift: Starts audio capture, begins streaming to daemon        │
│ 9. Daemon: Pipeline ready, sends `pipeline.state = running`       │
│10. Swift: Updates UI, orb transitions to listening mode           │
└──────────────────────────────────────────────────────────────────┘
```

### 3.3 Reconnection Strategy

```swift
// HeartbeatMonitor.swift
actor HeartbeatMonitor {
    private let connection: DaemonConnection
    private let pingInterval: TimeInterval = 5.0
    private let pingTimeout: TimeInterval = 3.0
    private let maxReconnectAttempts = 5
    private let reconnectBackoff: [TimeInterval] = [0.5, 1, 2, 4, 8]
    
    func start() async {
        while true {
            try? await Task.sleep(for: .seconds(pingInterval))
            
            let pongReceived = await connection.ping(timeout: pingTimeout)
            if !pongReceived {
                await handleConnectionLoss()
            }
        }
    }
    
    private func handleConnectionLoss() async {
        for (attempt, delay) in reconnectBackoff.enumerated() {
            try? await Task.sleep(for: .seconds(delay))
            
            do {
                try await connection.connect()
                await resumeAudioStreaming()
                return
            } catch {
                NSLog("Reconnect attempt %d failed: %@", attempt + 1, error.localizedDescription)
            }
        }
        
        // All attempts failed → show "daemon offline" UI
        await showDaemonOfflineState()
    }
}
```

---

## 4. Command/Event Protocol (v2)

### 4.1 Command Envelope (Swift → Daemon)

```json
{
  "v": 2,
  "request_id": "uuid",
  "command": "conversation.inject_text",
  "payload": {
    "text": "What's on my calendar today?"
  }
}
```

### 4.2 Event Envelope (Daemon → Swift)

```json
{
  "v": 2,
  "event_id": "uuid",
  "event": "assistant.text",
  "payload": {
    "text": "You have three meetings today...",
    "is_final": false
  }
}
```

### 4.3 Swift Protocol Implementation

```swift
// CommandProtocol.swift
struct CommandEnvelope: Codable, Sendable {
    let v: UInt32 = 2
    let requestId: String
    let command: String
    let payload: [String: AnyCodable]
}

struct EventEnvelope: Codable, Sendable {
    let v: UInt32
    let eventId: String
    let event: String
    let payload: [String: AnyCodable]
}

// Command types
enum DaemonCommand: String {
    case runtimeStart = "runtime.start"
    case runtimeStop = "runtime.stop"
    case conversationInjectText = "conversation.inject_text"
    case conversationGateSet = "conversation.gate_set"
    case configGet = "config.get"
    case configPatch = "config.patch"
    case approvalRespond = "approval.respond"
    case capabilityStatus = "capability.status"
    case toolExecuteApple = "tool.execute_apple"  // NEW: daemon delegates to Swift
    case audioFrame = "audio.frame"               // Binary PCM chunk
}

// Event types
enum DaemonEvent: String {
    case runtimeState = "runtime.state"
    case pipelineState = "pipeline.state"
    case assistantText = "assistant.text"
    case assistantGenerating = "assistant.generating"
    case thinkingText = "thinking.text"
    case transcription = "transcription"
    case audioLevel = "audio.level"
    case approvalRequested = "approval.requested"
    case toolExecuteRequest = "tool.execute_request"  // Daemon requests Apple tool
    case ttsAudio = "tts.audio"                       // Binary PCM for playback
    case orbState = "orb.state"
    case modelLoaded = "model.loaded"
}
```

### 4.4 Binary Audio Framing

```
┌─────────────────────────────────────────────────────────────────┐
│ Audio Frame Header (8 bytes)                                     │
├─────────────────────────────────────────────────────────────────┤
│ Bytes 0-3: Frame type (uint32, little-endian)                    │
│            0x01 = mic PCM (Swift → Daemon)                       │
│            0x02 = TTS PCM (Daemon → Swift)                       │
│ Bytes 4-5: Sample rate (uint16, little-endian) / 100             │
│            160 = 16000 Hz, 240 = 24000 Hz                        │
│ Bytes 6-7: Frame length in samples (uint16, little-endian)       │
├─────────────────────────────────────────────────────────────────┤
│ Audio data: Float32 PCM samples (mono)                           │
└─────────────────────────────────────────────────────────────────┘
```

---

## 5. TCC Permissions & Apple Tool Bridge

### 5.1 Permission State Model

```swift
// TCCPermissionManager.swift
@MainActor
final class TCCPermissionManager: ObservableObject {
    @Published var microphoneStatus: PermissionStatus = .unknown
    @Published var calendarStatus: PermissionStatus = .unknown
    @Published var remindersStatus: PermissionStatus = .unknown
    @Published var contactsStatus: PermissionStatus = .unknown
    @Published var cameraStatus: PermissionStatus = .unknown
    @Published var accessibilityStatus: PermissionStatus = .unknown
    
    enum PermissionStatus: String, Sendable {
        case unknown
        case notDetermined
        case authorized
        case denied
        case restricted
    }
    
    /// Query all TCC states and send to daemon
    func syncPermissionsWithDaemon() async {
        await updateAllStatuses()
        
        let capabilities: [String: String] = [
            "microphone": microphoneStatus.rawValue,
            "calendar": calendarStatus.rawValue,
            "reminders": remindersStatus.rawValue,
            "contacts": contactsStatus.rawValue,
            "camera": cameraStatus.rawValue,
            "accessibility": accessibilityStatus.rawValue,
        ]
        
        await DaemonConnection.shared.send(
            command: .capabilityStatus,
            payload: ["capabilities": capabilities]
        )
    }
    
    /// Daemon requests a permission → trigger native dialog
    func handlePermissionRequest(capability: String) async -> Bool {
        switch capability {
        case "microphone":
            return await AVCaptureDevice.requestAccess(for: .audio)
        case "calendar":
            return await requestEventKitAccess(for: .event)
        case "reminders":
            return await requestEventKitAccess(for: .reminder)
        case "contacts":
            return await requestContactsAccess()
        case "camera":
            return await AVCaptureDevice.requestAccess(for: .video)
        case "accessibility":
            // Cannot programmatically request — show guidance
            showAccessibilitySettingsGuidance()
            return false
        default:
            return false
        }
    }
}
```

### 5.2 Apple Tool Bridge (Daemon → Swift → Apple Frameworks)

```swift
// AppleToolBridge.swift
actor AppleToolBridge {
    private let permissionManager: TCCPermissionManager
    
    /// Handle tool execution request from daemon
    func executeAppleTool(
        requestId: String,
        toolName: String,
        input: [String: Any]
    ) async {
        let result: ToolResult
        
        switch toolName {
        case "calendar":
            result = await CalendarTool().execute(input: input)
        case "reminders":
            result = await RemindersTool().execute(input: input)
        case "contacts":
            result = await ContactsTool().execute(input: input)
        case "mail":
            result = await MailTool().execute(input: input)
        case "notes":
            result = await NotesTool().execute(input: input)
        default:
            result = .error("Unknown Apple tool: \(toolName)")
        }
        
        // Send result back to daemon
        await DaemonConnection.shared.send(
            command: .toolExecuteApple,
            payload: [
                "request_id": requestId,
                "tool_name": toolName,
                "result": result.serialize()
            ]
        )
    }
}
```

### 5.3 Permission-Gated Tool Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ User: "What's on my calendar today?"                             │
├─────────────────────────────────────────────────────────────────┤
│ 1. Daemon: LLM decides to call `calendar` tool                   │
│ 2. Daemon: Checks capability.status["calendar"]                  │
│    - If "authorized" → send tool.execute_request to Swift        │
│    - If "notDetermined" → send capability.request to Swift       │
│    - If "denied" → LLM receives "Calendar access denied" error   │
│ 3. Swift: TCCPermissionManager triggers native TCC dialog        │
│ 4. Swift: User grants/denies                                     │
│ 5. Swift: Sends capability.status update to daemon               │
│ 6. Daemon: Retries tool if now authorized, or reports error      │
│ 7. Swift: AppleToolBridge executes CalendarTool.execute()        │
│ 8. Swift: Sends tool result back to daemon                       │
│ 9. Daemon: LLM incorporates calendar data into response          │
│10. Daemon: Sends assistant.text to Swift for display/TTS         │
└─────────────────────────────────────────────────────────────────┘
```

---

## 6. Audio Pipeline Integration

### 6.1 Microphone → Daemon

```swift
// AudioBridge.swift
actor AudioBridge {
    private let captureManager = AudioCaptureManager()
    private let playbackManager = AudioPlaybackManager()
    private var isStreaming = false
    
    /// Start streaming mic audio to daemon
    func startMicStreaming() async throws {
        guard !isStreaming else { return }
        
        let stream = try await captureManager.startCapture()
        isStreaming = true
        
        for await chunk in stream {
            guard isStreaming else { break }
            
            // Send raw PCM to daemon via binary frame
            let frame = AudioFrame(
                type: .micPCM,
                sampleRate: UInt16(AudioCaptureManager.targetSampleRate / 100),
                samples: chunk.samples
            )
            await DaemonConnection.shared.sendBinary(frame.serialize())
        }
    }
    
    /// Stop mic streaming (on sleep/disconnect)
    func stopMicStreaming() async {
        isStreaming = false
        await captureManager.stopCapture()
    }
}
```

### 6.2 Daemon TTS → Playback

```swift
// AudioBridge.swift (continued)
extension AudioBridge {
    /// Handle incoming TTS audio from daemon
    func handleTTSAudio(_ frame: AudioFrame) async {
        let sampleRate = Int(frame.sampleRate) * 100
        let isFinal = frame.flags.contains(.isFinal)
        
        await playbackManager.enqueue(
            samples: frame.samples,
            sampleRate: sampleRate,
            isFinal: isFinal
        )
    }
    
    /// Stop playback (barge-in from daemon)
    func stopPlayback() async {
        await playbackManager.stop()
    }
}
```

### 6.3 Latency Considerations

| Hop | Expected Latency | Notes |
|-----|------------------|-------|
| Mic capture → Swift buffer | ~2ms | AVAudioEngine tap |
| Swift → Daemon (Unix socket) | <1ms | Local IPC |
| Daemon STT | ~200ms | Qwen3-ASR streaming |
| Daemon LLM TTFT | ~100-400ms | E4B/Qwen3 dependent on GPU |
| Daemon TTS chunk | ~50ms | Kokoro streaming |
| Daemon → Swift (Unix socket) | <1ms | Local IPC |
| Swift → Speaker | ~5ms | AVAudioPlayerNode |
| **Total voice-to-first-word** | ~400-700ms | Target: ADR-002 SLO of <1s |

---

## 7. UX & Failure States

### 7.1 Connection States UI

| State | Orb Visual | UI Indicator | User Action |
|-------|------------|--------------|-------------|
| `connecting` | Pulsing white | "Connecting..." spinner | Wait |
| `connected` | Normal idle (breathing) | None | Ready |
| `reconnecting` | Pulsing orange | "Reconnecting (2/5)..." | Wait |
| `failed` | Dim gray | "Daemon offline" banner | "Restart Daemon" button |
| `daemon_crashed` | Red pulse | "Fae needs to restart" alert | "Restart" button |

### 7.2 Graceful Degradation

```swift
// EventRouter.swift
actor EventRouter {
    /// Handle daemon disconnect during active conversation
    func handleMidConversationDisconnect() async {
        // 1. Stop TTS playback
        await AudioBridge.shared.stopPlayback()
        
        // 2. Show transient "Connection lost" notice
        await MainActor.run {
            NotificationCenter.default.post(
                name: .faeConnectionLost,
                object: nil
            )
        }
        
        // 3. Buffer any pending user input
        // 4. Attempt reconnection in background
        // 5. On reconnect: replay buffered input if user confirms
    }
    
    /// Handle model loading failure
    func handleModelLoadFailure(engine: String, error: String) async {
        switch engine {
        case "stt":
            // STT failed: show "Voice unavailable, type your message"
            await showTextOnlyMode()
        case "llm":
            // LLM failed: show "Fae is having trouble thinking"
            await showDegradedConversationMode()
        case "tts":
            // TTS failed: show "Voice output unavailable"
            await showTextOnlyResponseMode()
        default:
            break
        }
    }
}
```

### 7.3 Daemon Crash Recovery

```swift
// FaeCore.swift (transformed)
@MainActor
final class FaeCore: ObservableObject {
    @Published var daemonState: DaemonState = .stopped
    
    private var daemonProcess: Process?
    private var crashCount = 0
    private let maxCrashesBeforeGiveUp = 3
    
    func handleDaemonCrash() async {
        crashCount += 1
        
        if crashCount >= maxCrashesBeforeGiveUp {
            // Too many crashes → show manual intervention dialog
            await showFatalCrashDialog()
            return
        }
        
        // Auto-restart with backoff
        let delay = pow(2.0, Double(crashCount - 1))
        try? await Task.sleep(for: .seconds(delay))
        
        await startDaemon()
    }
    
    private func startDaemon() async {
        let daemonPath = Bundle.main.url(
            forResource: "fae-daemon",
            withExtension: nil,
            subdirectory: "MacOS"
        )!
        
        daemonProcess = Process()
        daemonProcess?.executableURL = daemonPath
        daemonProcess?.arguments = ["--socket", "~/.fae/fae.sock".expandingTildeInPath]
        
        daemonProcess?.terminationHandler = { [weak self] process in
            if process.terminationStatus != 0 {
                Task { await self?.handleDaemonCrash() }
            }
        }
        
        try? daemonProcess?.run()
    }
}
```

---

## 8. Migration Strategy

### 8.1 Phase-by-Phase Transition

| Phase | Swift Changes | Daemon Work | Risk |
|-------|--------------|-------------|------|
| **Phase 1** | Add `DaemonConnection` stub that returns mock events | None (Swift still runs everything) | None |
| **Phase 2** | Add `AudioBridge` that can stream to daemon OR local | Daemon accepts audio, runs STT | Low |
| **Phase 3** | Route LLM calls through daemon when connected | Daemon runs full pipeline | Medium |
| **Phase 4** | Remove `MLXSTTEngine`, `MLXLLMEngine`, `FaeTTSAdapter` from Swift | Daemon handles all ML | Medium |
| **Phase 5** | Remove `PipelineCoordinator`, `FaeScheduler`, `MemoryOrchestrator` | Daemon is authoritative | High |
| **Phase 6** | Swift is thin frontend only | Production | None |

### 8.2 Feature Flag Architecture

```swift
// FeatureFlags.swift
enum FeatureFlags {
    /// Use daemon for LLM inference (false = local MLX)
    @AppStorage("ff.daemon.llm") static var useDaemonLLM = false
    
    /// Use daemon for STT (false = local MLX)
    @AppStorage("ff.daemon.stt") static var useDaemonSTT = false
    
    /// Use daemon for TTS (false = local Kokoro)
    @AppStorage("ff.daemon.tts") static var useDaemonTTS = false
    
    /// Use daemon for memory (false = local SQLite)
    @AppStorage("ff.daemon.memory") static var useDaemonMemory = false
    
    /// Use daemon for scheduler (false = local FaeScheduler)
    @AppStorage("ff.daemon.scheduler") static var useDaemonScheduler = false
}
```

### 8.3 Compatibility Mode

During transition, Swift can run in "compatibility mode":
- Daemon unavailable → Fall back to local MLX engines
- Daemon connected → Route to daemon
- Hybrid: Use daemon for STT/LLM, local for TTS (or vice versa)

```swift
// PipelineRouter.swift
actor PipelineRouter {
    func transcribe(samples: [Float]) async throws -> STTResult {
        if FeatureFlags.useDaemonSTT && DaemonConnection.shared.isConnected {
            return try await DaemonConnection.shared.requestSTT(samples: samples)
        } else {
            return try await localSTTEngine.transcribe(samples: samples, sampleRate: 16000)
        }
    }
}
```

---

## 9. Validation Scenarios

### 9.1 Connection Lifecycle Tests

| Scenario | Expected Behavior | Validation |
|----------|-------------------|------------|
| App launch, daemon running | Connect <1s, UI ready | Automated |
| App launch, daemon not running | Spawn daemon, connect <5s | Automated |
| Daemon crash during idle | Auto-restart, reconnect <10s | Automated |
| Daemon crash during speech | Stop TTS, show notice, restart | Manual |
| Network flap (WebSocket mode) | Reconnect with backoff | Automated |
| Unix socket deleted | Fall back to WebSocket, retry socket | Automated |

### 9.2 Apple Tool Integration Tests

| Scenario | Expected Behavior | Validation |
|----------|-------------------|------------|
| Calendar query, authorized | Events returned <500ms | Automated |
| Calendar query, not determined | TCC dialog, then events | Manual |
| Calendar query, denied | Error message, no crash | Automated |
| Contacts search | Results returned, privacy preserved | Automated |
| Mail send (dangerous) | DamageControl approval → Swift | Manual |

### 9.3 Audio Pipeline Tests

| Scenario | Expected Behavior | Validation |
|----------|-------------------|------------|
| Wake word detection | Daemon STT detects, pipeline activates | Automated |
| Barge-in during TTS | Daemon signals stop, Swift stops playback <50ms | Automated |
| TTS streaming | Chunks play smoothly, no pops/clicks | Manual |
| Mic mute toggle | Audio frames stop, daemon notified | Automated |
| Reconnect during speech | Buffer resumes, no lost audio | Manual |

### 9.4 Failure Recovery Tests

| Scenario | Expected Behavior | Validation |
|----------|-------------------|------------|
| LLM OOM crash | Daemon restarts with lower context | Automated |
| Model file corrupted | Error event, re-download prompt | Manual |
| TCC revoked mid-session | Tool returns error, LLM adapts | Automated |
| Disk full | Graceful error, no data loss | Manual |

---

## 10. Files to Create/Modify

### 10.1 New Swift Files

```
native/macos/Fae/Sources/Fae/
├── DaemonBridge/
│   ├── DaemonConnection.swift      # WebSocket + Unix socket client
│   ├── CommandProtocol.swift       # JSON command/event codec
│   ├── AudioBridge.swift           # PCM streaming to/from daemon
│   ├── EventRouter.swift           # Daemon events → UI updates
│   ├── HeartbeatMonitor.swift      # Connection health + reconnect
│   └── FeatureFlags.swift          # Gradual migration flags
├── AppleBridge/
│   ├── AppleToolBridge.swift       # Tool calls from daemon
│   ├── TCCPermissionManager.swift  # Centralized TCC state
│   └── NotificationBridge.swift    # macOS notifications
└── PipelineRouter.swift            # Local vs daemon routing
```

### 10.2 Files to Deprecate (Phase 5+)

```
# Remove after daemon handles everything
Pipeline/PipelineCoordinator.swift   # 8,600 lines → daemon
Scheduler/FaeScheduler.swift         # 2,300 lines → daemon
Memory/MemoryOrchestrator.swift      # 1,600 lines → daemon
Memory/SQLiteMemoryStore.swift       # 1,500 lines → daemon
ML/MLXSTTEngine.swift                # → daemon mistral.rs
ML/MLXLLMEngine.swift                # → daemon mistral.rs
ML/FaeTTSAdapter.swift               # → daemon ort/misaki-rs
```

### 10.3 Files to Refactor

```
Core/FaeCore.swift                   # Coordinator → DaemonConnection manager
Core/FaeEventBus.swift               # Add daemon event sources
Tools/ToolExecutor.swift             # Thin wrapper for Apple tools only
FaeRelayServer.swift                 # Route companion traffic → daemon
```

---

## 11. Open Questions for Owner Decision

1. **Daemon bundling**: Ship daemon inside Fae.app bundle, or separate install via Homebrew/pkg?

2. **Launchd integration**: Auto-start daemon at login via launchd plist, or on-demand spawn?

3. **Multi-Mac support**: When daemon runs on one Mac, can another Mac connect remotely (requires auth)?

4. **iOS companion handoff**: Does iOS app connect to daemon directly, or through FaeRelayServer on Mac?

5. **Offline mode**: When no daemon and no internet, should Swift maintain a minimal local LLM path?

6. **Update coordination**: When Swift app updates, how to coordinate daemon binary update?

---

## 12. Related Documents

- **Design source**: `docs/architecture/headless-core-impl-plan-2026-06-01.md`
- **Protocol reference**: `docs/adr/002-embedded-rust-core.md` (historical, command format basis)
- **Memory migration**: `docs/architecture/memory-migration-plan.md` (G4 gate)
- **Daemon security**: `docs/architecture/daemon-control-plane.md` (G5 gate, pending)

---

## Summary

This plan transforms Swift Fae from a 15,000+ LOC monolith into a ~3,000 LOC thin frontend that:

1. **Owns Apple platform integration**: TCC permissions, EventKit, Contacts, microphone capture, TTS playback, Multipeer relay
2. **Delegates brain to daemon**: Voice pipeline, LLM, memory, scheduler all move to Rust
3. **Maintains UX quality**: Graceful degradation, reconnection, crash recovery
4. **Enables gradual migration**: Feature flags allow component-by-component transition
5. **Preserves latency SLOs**: Local Unix socket keeps IPC overhead <1ms per hop
