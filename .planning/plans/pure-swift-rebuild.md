# Fae Pure-Swift Rebuild — Execution Prompt

## Mission

Rebuild Fae as a **pure Swift macOS application** using Apple's MLX ecosystem, eliminating the Rust core (`libfae.a`, 106K lines) and C ABI FFI boundary entirely.

**Current**: Swift UI shell (50 files) → C ABI FFI → Rust static library (`libfae.a`)
**Target**: Pure Swift application → MLX-Swift for all ML inference

Fae has not launched yet. There is no user data to migrate. This is a clean rewrite.

---

## Repository

- **Repo**: `saorsa-labs/fae` (private)
- **Branch**: Create `feature/pure-swift-rebuild` from `main`
- **Swift source**: `native/macos/Fae/Sources/Fae/` (50 existing UI files)
- **Package file**: `native/macos/Fae/Package.swift`
- **Rust source (to be removed)**: `src/` (217 .rs files)
- **Config/data dir**: `~/Library/Application Support/fae/`

---

## Key Dependencies

| Package | URL | Purpose |
|---------|-----|---------|
| mlx-swift-lm | `https://github.com/ml-explore/mlx-swift-lm` (branch: `main`) | LLM inference (Qwen3-4B, 8B etc.) |
| mlx-audio-swift | `https://github.com/Blaizzy/mlx-audio-swift` (branch: `main`) | STT (Qwen3-ASR) + TTS (Qwen3-TTS) |
| GRDB.swift | `https://github.com/groue/GRDB.swift` (from: `7.0.0`) | SQLite memory store |
| TOMLKit | `https://github.com/LebJe/TOMLKit` (from: `0.6.0`) | Config file parsing |
| Sparkle | `https://github.com/sparkle-project/Sparkle` (from: `2.6.0`) | Auto-update (existing) |
| FaeHandoffKit | Local: `../../apple/FaeHandoffKit` | Apple Handoff (existing) |

---

## Architecture Overview

```
FaeApp (@main)
  └── FaeCore (actor) — replaces EmbeddedCoreSender + Rust handler
        ├── PipelineCoordinator (actor) — VAD → STT → LLM → TTS → playback
        │     ├── AudioCaptureManager (AVAudioEngine input tap)
        │     ├── AudioPlaybackManager (AVAudioEngine player node)
        │     ├── VoiceActivityDetector (energy-based, pure Swift)
        │     ├── STTEngine protocol ← MLXSTTEngine (Qwen3-ASR)
        │     ├── LLMEngine protocol ← MLXLLMEngine (Qwen3-4B)
        │     └── TTSEngine protocol ← MLXTTSEngine (Qwen3-TTS)
        ├── MemoryOrchestrator (recall before LLM, capture after turn)
        │     ├── SQLiteMemoryStore (GRDB.swift)
        │     └── EmbeddingEngine protocol ← MLXEmbeddingEngine
        ├── AgentLoop (tool execution loop with streaming)
        │     ├── ToolRegistry (15+ tools)
        │     └── ApprovalManager (voice privilege escalation)
        ├── FaeScheduler (11 built-in tasks, DispatchSourceTimer)
        ├── SkillManager (Python subprocess, JSON-RPC)
        ├── ChannelManager (Discord/WhatsApp webhooks)
        ├── PersonalityManager (prompt assembly, SOUL contract)
        ├── IntentClassifier (keyword-based tool routing)
        └── FaeConfig (TOML, Codable)
  └── FaeEventBus (Combine PassthroughSubject → NotificationCenter bridge)
```

### Key Design Decisions

1. **Swift actors** for all concurrent subsystems (pipeline, memory, agent, scheduler)
2. **Protocol-oriented ML** — `STTEngine`, `LLMEngine`, `TTSEngine`, `EmbeddingEngine` protocols for testability and swappability
3. **Combine event bus** — `PassthroughSubject<FaeEvent, Never>` replaces JSON event serialization. Compatibility bridge posts to existing `NotificationCenter` names so all 50 UI files work unchanged initially
4. **AsyncStream** for pipeline stages — audio chunks, transcriptions, tokens, synthesized audio all flow as async streams
5. **Same config format** — `config.toml` at `~/Library/Application Support/fae/`
6. **Same SQLite schema** — GRDB.swift reads/writes the same `fae.db` tables

---

## What Gets Deleted

| Deleted | Why |
|---------|-----|
| `src/` (all 217 .rs files, 106K lines) | Replaced by Swift |
| `Cargo.toml`, `Cargo.lock` | No more Rust |
| `include/fae.h` | No more C ABI |
| `Sources/CLibFae/` directory | No more C module map |
| `EmbeddedCoreSender.swift` | Replaced by `FaeCore` |
| `BackendEventRouter.swift` | Replaced by `FaeEventBus` |
| `HostCommandBridge.swift` | Direct method calls |

## What Stays Unchanged (38+ Swift UI files)

All orb, conversation, canvas, window, subtitle, animation, audio device, handoff, and help files. They consume `NotificationCenter` events which `FaeEventBus` continues to emit via compatibility bridge.

---

## Execution Phases

---

### PHASE 0: Foundation

**Goal**: New package structure compiles with all 50 UI files, no Rust dependency.
**Deliverable**: `swift build` succeeds with stubs.

#### Task 0.1 — Rewrite `Package.swift`

Remove CLibFae target. Remove all `-force_load`/linker flags. Add MLX dependencies.

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Fae",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../apple/FaeHandoffKit"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main"),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift", branch: "main"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Fae",
            dependencies: [
                .product(name: "FaeHandoffKit", package: "FaeHandoffKit"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Sources/Fae",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("Metal"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
            ]
        ),
    ]
)
```

**Note**: Check the actual product names exported by `mlx-audio-swift` — they may differ from `MLXAudioTTS`/`MLXAudioSTT`. Read the package's `Package.swift` to confirm.

#### Task 0.2 — Create Core Types and Protocols

Create `Sources/Fae/Core/` directory with these new files:

**`FaeEvent.swift`** — Event enum replacing JSON serialization:
```swift
import Foundation

enum FaeEvent: Sendable {
    // Pipeline
    case pipelineStateChanged(PipelineState)
    case assistantGenerating(Bool)
    case audioLevel(Float)
    case transcription(text: String, isFinal: Bool)
    case assistantText(text: String, isFinal: Bool)

    // Runtime
    case runtimeState(RuntimeState)
    case runtimeProgress(stage: String, progress: Double)

    // Orb
    case orbStateChanged(mode: OrbMode, feeling: OrbFeeling)

    // Approval
    case approvalRequested(id: UInt64, toolName: String, input: String)
    case approvalResolved(id: UInt64, approved: Bool)

    // Memory
    case memoryRecalled(count: Int)
    case memoryCaptured(id: String)
}

enum PipelineState: String, Sendable {
    case stopped, starting, running, stopping, error
}

enum RuntimeState: String, Sendable {
    case starting, started, stopped, error
}
```

**`FaeEventBus.swift`** — Combine + NotificationCenter bridge:
```swift
import Combine
import Foundation

final class FaeEventBus: @unchecked Sendable {
    let subject = PassthroughSubject<FaeEvent, Never>()
    private var cancellable: AnyCancellable?

    init() {
        // Bridge: every FaeEvent also posts to NotificationCenter
        // so existing UI files (38+) continue working unchanged
        cancellable = subject.sink { [weak self] event in
            self?.postToNotificationCenter(event)
        }
    }

    func send(_ event: FaeEvent) {
        subject.send(event)
    }

    private func postToNotificationCenter(_ event: FaeEvent) {
        let nc = NotificationCenter.default
        switch event {
        case .pipelineStateChanged(let state):
            nc.post(name: .faePipelineState, object: nil, userInfo: ["state": state.rawValue])
        case .assistantGenerating(let active):
            nc.post(name: .faeAssistantGenerating, object: nil, userInfo: ["generating": active])
        case .audioLevel(let level):
            nc.post(name: .faeAudioLevel, object: nil, userInfo: ["level": level])
        case .runtimeState(let state):
            nc.post(name: .faeRuntimeState, object: nil, userInfo: ["state": state.rawValue])
        case .runtimeProgress(let stage, let progress):
            nc.post(name: .faeRuntimeProgress, object: nil, userInfo: ["stage": stage, "progress": progress])
        case .orbStateChanged(let mode, let feeling):
            nc.post(name: .faeOrbStateChanged, object: nil, userInfo: ["mode": mode, "feeling": feeling])
        case .approvalRequested(let id, let toolName, let input):
            nc.post(name: .faeApprovalRequested, object: nil, userInfo: ["id": id, "tool": toolName, "input": input])
        case .approvalResolved(let id, let approved):
            nc.post(name: .faeApprovalResolved, object: nil, userInfo: ["id": id, "approved": approved])
        default:
            break
        }
    }
}
```

**`MLProtocols.swift`** — ML engine protocols:
```swift
import Foundation

struct STTResult: Sendable {
    let text: String
    let language: String?
    let confidence: Float?
}

struct GenerationOptions: Sendable {
    var temperature: Float = 0.7
    var topP: Float = 0.9
    var maxTokens: Int = 2048
    var repetitionPenalty: Float = 1.1
}

protocol STTEngine: Actor {
    func load(modelID: String) async throws
    func transcribe(samples: [Float], sampleRate: Int) async throws -> STTResult
    var isLoaded: Bool { get }
}

protocol LLMEngine: Actor {
    func load(modelID: String) async throws
    func generate(messages: [ChatMessage], systemPrompt: String, options: GenerationOptions) -> AsyncThrowingStream<String, Error>
    var isLoaded: Bool { get }
}

protocol TTSEngine: Actor {
    func load(modelID: String) async throws
    func synthesize(text: String) -> AsyncThrowingStream<AudioBuffer, Error>
    var isLoaded: Bool { get }
}

protocol EmbeddingEngine: Actor {
    func load(modelID: String) async throws
    func embed(text: String) async throws -> [Float]
    var isLoaded: Bool { get }
}
```

**`FaeTypes.swift`** — Shared types:
```swift
import Foundation
import AVFoundation

struct ChatMessage: Sendable, Codable {
    enum Role: String, Sendable, Codable { case system, user, assistant, tool }
    let role: Role
    let content: String
    let toolCallID: String?
    let name: String?

    init(role: Role, content: String, toolCallID: String? = nil, name: String? = nil) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.name = name
    }
}

struct AudioChunk: Sendable {
    let samples: [Float]
    let sampleRate: Int
}

struct SpeechSegment: Sendable {
    let samples: [Float]
    let sampleRate: Int
    let durationSeconds: Double
}

struct SentenceChunk: Sendable {
    let text: String
    let isFinal: Bool
}

struct ConversationTurn: Sendable {
    let userText: String
    let assistantText: String
    let timestamp: Date
    let toolsUsed: [String]
}

typealias AudioBuffer = AVAudioPCMBuffer
```

#### Task 0.3 — Create Stub `FaeCore.swift`

This replaces `EmbeddedCoreSender`. All methods are stubs that emit synthetic events so the UI compiles and can be tested:

```swift
import Foundation
import Combine

@MainActor
final class FaeCore: ObservableObject {
    let eventBus = FaeEventBus()

    @Published var pipelineState: PipelineState = .stopped
    @Published var isOnboarded: Bool = false
    @Published var userName: String? = nil
    @Published var toolMode: String = "full"

    // MARK: - Lifecycle

    func start() async throws {
        eventBus.send(.runtimeState(.starting))
        pipelineState = .starting
        eventBus.send(.pipelineStateChanged(.starting))

        // TODO: Phase 1 — load models, start pipeline

        pipelineState = .running
        eventBus.send(.pipelineStateChanged(.running))
        eventBus.send(.runtimeState(.started))
    }

    func stop() async {
        pipelineState = .stopping
        eventBus.send(.pipelineStateChanged(.stopping))

        // TODO: Phase 1 — stop pipeline, unload models

        pipelineState = .stopped
        eventBus.send(.pipelineStateChanged(.stopped))
        eventBus.send(.runtimeState(.stopped))
    }

    // MARK: - Commands

    func injectText(_ text: String) {
        // TODO: Phase 1 — inject into pipeline as if user spoke it
    }

    func respondToApproval(requestID: UInt64, approved: Bool) {
        eventBus.send(.approvalResolved(id: requestID, approved: approved))
        // TODO: Phase 3 — route to ApprovalManager
    }

    func patchConfig(key: String, value: String) {
        // TODO: Phase 1 — update FaeConfig and propagate
        switch key {
        case "tool_mode":
            toolMode = value
        default:
            break
        }
    }

    func getOnboardingState() -> Bool {
        return isOnboarded
    }

    func completeOnboarding() {
        isOnboarded = true
        // TODO: Phase 1 — persist to config.toml
    }

    // MARK: - Pipeline Control

    func startPipeline() async {
        pipelineState = .starting
        eventBus.send(.pipelineStateChanged(.starting))
        // TODO: Phase 1
        pipelineState = .running
        eventBus.send(.pipelineStateChanged(.running))
    }

    func stopPipeline() async {
        pipelineState = .stopping
        eventBus.send(.pipelineStateChanged(.stopping))
        // TODO: Phase 1
        pipelineState = .stopped
        eventBus.send(.pipelineStateChanged(.stopped))
    }
}
```

#### Task 0.4 — Rewire `FaeApp.swift`

Read the existing `FaeApp.swift` carefully. Key changes:

1. **Remove** `private let commandSender: EmbeddedCoreSender?` — replace with `@StateObject private var faeCore = FaeCore()`
2. **Remove** `BackendEventRouter` initialization — `FaeEventBus` handles this now
3. **Replace** `sender.sendCommand(name: "runtime.start", payload: [:])` → `Task { try? await faeCore.start() }`
4. **Replace** `restoreOnboardingState(sender:)` → use `faeCore.isOnboarded` directly
5. **Pass** `faeCore` as `.environmentObject(faeCore)` to views that need it
6. **Update** any `commandSender?.sendCommand(...)` calls to direct `faeCore.method()` calls

Every view that currently receives `commandSender: EmbeddedCoreSender?` as a parameter needs to accept `faeCore: FaeCore` instead. Grep for `EmbeddedCoreSender` and `commandSender` across all Swift files and update references.

#### Task 0.5 — Delete Rust-Bridge Files

- Delete `native/macos/Fae/Sources/Fae/EmbeddedCoreSender.swift`
- Delete `native/macos/Fae/Sources/Fae/BackendEventRouter.swift`
- Delete `native/macos/Fae/Sources/Fae/HostCommandBridge.swift`
- Delete `native/macos/Fae/Sources/CLibFae/` directory (entire thing)

#### Task 0.6 — Verify Compilation

Run `cd native/macos/Fae && swift build`. Fix all compilation errors. Every existing UI file must compile. The app won't do anything useful yet — that's fine. The goal is zero compilation errors with the new package structure.

**Common issues to expect**:
- UI files referencing `EmbeddedCoreSender` type — update to `FaeCore`
- UI files referencing `commandSender?.sendCommand(name:payload:)` — update to direct method calls
- `NotificationCenter` names that need to be declared as extensions (`.faePipelineState`, `.faeRuntimeState`, etc.)
- Import statements for `CLibFae` — remove them
- Any `ProcessCommandSender.swift` references to the old bridge — update

**Verification**: `swift build` exits 0.

---

### PHASE 1: Voice Pipeline

**Goal**: Working voice conversation — speak to Fae, get spoken response.
**Deliverable**: Say "hello" → hear response. First-audio latency < 1.5s.

#### Task 1.1 — Audio I/O

Create `Sources/Fae/Audio/`:

**`AudioCaptureManager.swift`** — AVAudioEngine input tap, 16kHz mono float32. Voice processing I/O unit for built-in echo cancellation. Device change monitoring via `AVAudioSession.routeChangeNotification`.

**`AudioPlaybackManager.swift`** — AVAudioPlayerNode for TTS output. Supports interrupt (barge-in: stop playback immediately when user speaks).

**`AudioToneGenerator.swift`** — Thinking tone (A3→C4 220Hz→262Hz, 300ms, volume 0.05, 40% fade) and listening tone. Generate via `AVAudioEngine` signal generation.

**Replaces**: `src/audio/{capture.rs, playback.rs, tone.rs, device_watcher.rs}` (1,408 lines of Rust)

#### Task 1.2 — Voice Activity Detection

Create `Sources/Fae/Pipeline/VoiceActivityDetector.swift`

Port energy-based VAD from `src/vad/mod.rs`: RMS threshold + hysteresis + silence timeout (700ms). Pure arithmetic, no ML dependency. Output: `AsyncStream<SpeechSegment>`.

#### Task 1.3 — STT Engine (Qwen3-ASR via mlx-audio-swift)

Create `Sources/Fae/ML/MLXSTTEngine.swift`

```swift
import MLXAudioSTT  // verify actual module name

actor MLXSTTEngine: STTEngine {
    private var model: (any STTModel)?  // verify actual type
    var isLoaded: Bool { model != nil }

    func load(modelID: String = "mlx-community/Qwen3-ASR-0.6B") async throws {
        // Use mlx-audio-swift's model loading API
    }

    func transcribe(samples: [Float], sampleRate: Int) async throws -> STTResult {
        // Use mlx-audio-swift's transcription API
    }
}
```

**Important**: Read the `mlx-audio-swift` README and source to understand the actual API. The exact types, method names, and import paths need to be verified.

**Replaces**: `src/stt/mod.rs` (parakeet-rs)

#### Task 1.4 — LLM Engine (Qwen3 via mlx-swift-lm)

Create `Sources/Fae/ML/MLXLLMEngine.swift`

```swift
import MLXLLM

actor MLXLLMEngine: LLMEngine {
    private var container: ModelContainer?
    var isLoaded: Bool { container != nil }

    func load(modelID: String) async throws {
        let config = ModelConfiguration(id: modelID)
        container = try await LLMModelFactory.shared.loadContainer(configuration: config)
    }

    func generate(messages: [ChatMessage], systemPrompt: String, options: GenerationOptions)
        -> AsyncThrowingStream<String, Error> {
        // Convert ChatMessage array to mlx-swift-lm's chat format
        // Use container.generate() with streaming
        // Strip <think>...</think> tags from output
        // Inject /no_think prefix
    }
}
```

Also create `Sources/Fae/ML/ThinkTagStripper.swift` — pure string logic that strips `<think>...</think>` blocks from a token stream. Port from existing Rust implementation.

**Replaces**: `src/llm/mod.rs` (804 lines) + `src/fae_llm/providers/local.rs` (550 lines)

#### Task 1.5 — TTS Engine (Qwen3-TTS via mlx-audio-swift)

Create `Sources/Fae/ML/MLXTTSEngine.swift`

```swift
import MLXAudioTTS  // verify actual module name

actor MLXTTSEngine: TTSEngine {
    private var model: (any TTSModel)?  // verify actual type
    var isLoaded: Bool { model != nil }

    func load(modelID: String = "mlx-community/Qwen3-TTS-0.6B") async throws {
        // Use mlx-audio-swift's model loading API
    }

    func synthesize(text: String) -> AsyncThrowingStream<AudioBuffer, Error> {
        // Use mlx-audio-swift's synthesis API with streaming
    }
}
```

**Important**: Read the `mlx-audio-swift` README and source to understand the actual streaming TTS API.

**Replaces**: `src/tts/kokoro/{engine.rs, phonemize.rs}` (~500 lines)

#### Task 1.6 — Pipeline Coordinator

Create `Sources/Fae/Pipeline/PipelineCoordinator.swift`

This is the **largest porting effort** — the Rust version is 5,192 lines. Port incrementally:

1. **Basic pipeline**: AudioCapture → VAD → STT → LLM → sentence chunking → TTS → Playback
2. **Echo suppression**: 1000ms tail, VAD reset when assistant stops speaking
3. **Barge-in**: Cancel generation Task + stop playback on speech detection
4. **Gate system**: Sleep/wake phrase detection
5. **Name detection**: `FAE_NAME_VARIANTS` array
6. **Text injection**: `injectText()` bypasses VAD/STT, goes straight to LLM
7. **Degraded modes**: TextOnly, LlmOnly when models unavailable

Supporting files:
- `Sources/Fae/Pipeline/TextProcessing.swift` — `findClauseBoundary()`, `findSentenceBoundary()`, `stripNonSpeechChars()`
- `Sources/Fae/Pipeline/EchoSuppressor.swift` — echo tail tracking, VAD reset logic
- `Sources/Fae/Pipeline/ConversationState.swift` — turn tracking, message history management

**Key reference files in Rust** (read these to understand the logic):
- `src/pipeline/coordinator.rs` — main state machine
- `src/pipeline/text_processing.rs` — sentence splitting
- `src/pipeline/echo.rs` — echo suppression

#### Task 1.7 — Personality & Prompts

Create `Sources/Fae/Core/PersonalityManager.swift`

**Replaces**: `src/personality.rs` (1,308 lines)

- Load `CORE_PROMPT` from `Prompts/system_prompt.md` (bundle resource)
- `VOICE_CORE_PROMPT` (~2KB condensed) — hardcoded constant
- `BACKGROUND_AGENT_PROMPT` — hardcoded constant
- Load `SOUL.md` from bundle
- `TOOL_ACKNOWLEDGMENTS` and `THINKING_ACKNOWLEDGMENTS` rotation arrays
- Full prompt assembly: core + vision + SOUL + user name + skills + capabilities + memory

#### Task 1.8 — Config

Create `Sources/Fae/Core/FaeConfig.swift`

```swift
import TOMLKit

struct FaeConfig: Codable {
    var audio: AudioConfig
    var llm: LLMConfig
    var stt: STTConfig
    var tts: TTSConfig
    var memory: MemoryConfig
    var intelligence: IntelligenceConfig
    var permissions: PermissionStore
    var channels: ChannelsConfig
    var userName: String?
    var onboarded: Bool

    static func load() throws -> FaeConfig { /* ~/Library/Application Support/fae/config.toml */ }
    func save() throws { ... }
    static func recommendedLocalModel() -> (modelID: String, contextSize: Int) { /* RAM-based selection */ }
}
```

**Replaces**: `src/config.rs` (2,292 lines)

Port `recommended_local_model()` auto-selection:
- >=48 GiB RAM → Qwen3-8B, context 32768
- >=32 GiB RAM → Qwen3-4B, context 16384
- <32 GiB RAM → Qwen3-1.7B, context 8192

#### Task 1.9 — Intent Classifier

Create `Sources/Fae/Core/IntentClassifier.swift`

**Replaces**: `src/intent.rs` (325 lines)

Direct port of keyword arrays and `classify_intent()`. Routes tool-needing queries to background agent vs direct voice LLM response.

#### Task 1.10 — Model Download & Progress

Create `Sources/Fae/ML/ModelManager.swift`

Wire MLX library download callbacks to `FaeEventBus` for progress UI (existing `ProgressOverlayView.swift` consumes these events).

#### Task 1.11 — Wire `FaeCore` to Real Components

Update `FaeCore.swift` to initialize and wire all Phase 1 components:
- Create `PipelineCoordinator` with real ML engines
- `start()` loads models via `ModelManager`, starts pipeline
- `stop()` stops pipeline, releases models
- `injectText()` forwards to pipeline
- Events flow through `FaeEventBus`

**Phase 1 verification**: Speak "hello" → hear spoken response. Check `/tmp/fae-test.log` for pipeline timing.

---

### PHASE 2: Memory & Intelligence

**Goal**: Fae remembers context across conversations.
**Deliverable**: Tell Fae your name → quit → relaunch → "what's my name?" → correct answer.

#### Task 2.1 — SQLite Memory Store (GRDB.swift)

Create `Sources/Fae/Memory/SQLiteMemoryStore.swift`

**Replaces**: `src/memory/sqlite.rs` (1,779 lines)

Same schema as Rust version (read `src/memory/schema.rs` for DDL):
- `memories` table (id, kind, content, confidence, embedding BLOB, timestamps)
- `memory_audit` table
- `contacts`, `voice_samples` tables
- Hybrid scoring: semantic 0.6 + confidence 0.2 + freshness 0.1 + kind bonus 0.1

Cosine similarity computed via Accelerate framework (`vDSP_dotpr`).

#### Task 2.2 — Embedding Engine

Create `Sources/Fae/ML/MLXEmbeddingEngine.swift`

**Replaces**: `src/memory/embedding.rs` (all-MiniLM-L6-v2 via ONNX)

Options:
1. Run all-MiniLM-L6-v2 via MLX (384-dim sentence embeddings)
2. Use Apple's `NLEmbedding` as simpler alternative (fewer dimensions but native)

Vectors stored as BLOB in SQLite.

#### Task 2.3 — Memory Orchestrator

Create `Sources/Fae/Memory/MemoryOrchestrator.swift`

**Replaces**: `src/memory/jsonl.rs` (MemoryOrchestrator portions)

- `recall(query:)` — semantic search before LLM generation
- `capture(turn:)` — extract and persist memories from completed turns
- `reflect()` — consolidate duplicate/overlapping memories
- `garbageCollect()` — retention cleanup

#### Task 2.4 — Backup & Health

Create `Sources/Fae/Memory/MemoryBackup.swift`

- `VACUUM INTO` backup with 7-day rotation
- `PRAGMA quick_check` integrity verification on startup

#### Task 2.5 — Wire Memory into Pipeline

Update `PipelineCoordinator` to:
1. Call `memoryOrchestrator.recall(query: transcription)` before LLM generation
2. Inject memory context into system prompt
3. Call `memoryOrchestrator.capture(turn:)` after each completed turn

---

### PHASE 3: Tools & Agent System

**Goal**: Fae can execute tools (bash, file I/O, web search, Apple ecosystem).
**Deliverable**: "What time is it?" → bash tool → approval overlay → spoken answer.

#### Task 3.1 — Tool Protocol & Registry

Create `Sources/Fae/Tools/Tool.swift` and `ToolRegistry.swift`:

```swift
protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: [String: Any] { get }  // JSON Schema
    func execute(input: [String: Any]) async throws -> ToolResult
}

struct ToolResult: Sendable {
    let content: String
    let isError: Bool
}
```

#### Task 3.2 — Built-in Tools (15+)

Create `Sources/Fae/Tools/` directory with one file per tool:

| File | Tool | Implementation Notes |
|------|------|---------------------|
| `ReadTool.swift` | `read` | `FileManager` / `String(contentsOf:)` |
| `WriteTool.swift` | `write` | `Data.write(to:)` |
| `EditTool.swift` | `edit` | Line-based string replacement |
| `BashTool.swift` | `bash` | `Process` (Foundation) |
| `WebSearchTool.swift` | `web_search` | `URLSession` |
| `FetchURLTool.swift` | `fetch_url` | `URLSession` |
| `CalendarTool.swift` | `calendar` | **EventKit** (native, much simpler than Rust's AppleScript) |
| `ContactsTool.swift` | `contacts` | **Contacts.framework** (native) |
| `MailTool.swift` | `mail` | AppleScript bridge |
| `RemindersTool.swift` | `reminders` | **EventKit** (native) |
| `NotesTool.swift` | `notes` | AppleScript bridge |
| `DesktopTool.swift` | `desktop_automation` | `CGWindowServer`, `NSEvent` |
| `PythonSkillTool.swift` | `python_skill` | `Process` subprocess |
| `SchedulerTools.swift` | `scheduler_*` | Direct scheduler calls |
| `X0XTool.swift` | `x0x` | `URLSession` HTTP client to `x0xd` |

Apple ecosystem tools (calendar, contacts, reminders) are **significantly simpler** in Swift — EventKit and Contacts.framework are native, replacing the Rust→AppleScript bridge.

#### Task 3.3 — Agent Loop

Create `Sources/Fae/Agent/AgentLoop.swift`

**Replaces**: `src/fae_llm/agent/{loop_engine.rs, executor.rs, accumulator.rs}` (6,072 lines)

```swift
actor AgentLoop {
    func run(messages: [ChatMessage], tools: [Tool]) -> AsyncThrowingStream<AgentEvent, Error>
    // LLM generate → parse tool calls → execute tools → loop
    // Max 10 turns, max 5 tools per turn, 30s timeout per tool
    // Streams SentenceChunks for TTS
}
```

Port: streaming accumulator, tool call JSON parsing, duplicate response detection, per-turn tool allowlist selection.

#### Task 3.4 — Approval System

Create `Sources/Fae/Agent/ApprovalManager.swift`

```swift
actor ApprovalManager {
    func requestApproval(toolName: String, inputJSON: String) async -> Bool
    // Sends .approvalRequested via FaeEventBus
    // Existing ApprovalOverlayView shows (unchanged)
    // User clicks Yes/No or speaks "yes"/"no"
    // faeCore.respondToApproval() routes back here
    // 58s auto-deny timeout
}
```

#### Task 3.5 — Voice Command Parser

Create `Sources/Fae/Core/VoiceCommandParser.swift`

Port `parse_approval_response()` (yes/no detection) and `parse_voice_command()` (show/hide conversation, switch model, etc.) from `src/voice_command.rs`.

---

### PHASE 4: Background Systems

**Goal**: Full feature parity with Rust Fae.
**Deliverable**: All 11 scheduler tasks run. Python skills work. Channels connected.

#### Task 4.1 — Scheduler

Create `Sources/Fae/Scheduler/FaeScheduler.swift`

**Replaces**: `src/scheduler/{runner.rs, tasks.rs}` (3,611 lines)

All 11 built-in tasks via `DispatchSourceTimer` + `Calendar`:

| Task | Schedule |
|------|----------|
| `memory_backup` | daily 02:00 |
| `memory_gc` | daily 03:30 |
| `memory_reflect` | every 6h |
| `memory_reindex` | every 3h |
| `memory_migrate` | every 1h |
| `noise_budget_reset` | daily 00:00 |
| `morning_briefing` | daily 08:00 |
| `skill_proposals` | daily 11:00 |
| `stale_relationships` | every 7d |
| `check_fae_update` | every 6h |
| `skill_health_check` | every 5min |

#### Task 4.2 — Skills Manager

Create `Sources/Fae/Skills/SkillManager.swift`

**Replaces**: `src/skills/` (10,593 lines)

Keep Python subprocess approach via `Process`. Port JSON-RPC protocol, health monitoring, PEP 723 parsing, uv bootstrap. Same architecture, different language.

#### Task 4.3 — Channel Integrations

Create `Sources/Fae/Channels/ChannelManager.swift`

**Replaces**: `src/channels/` (1,736 lines)

Discord/WhatsApp webhook receiver + message routing into LLM pipeline.

#### Task 4.4 — Intelligence

Create `Sources/Fae/Intelligence/`:
- `MorningBriefing.swift`
- `SkillProposals.swift`
- `NoiseBudget.swift`

**Replaces**: `src/intelligence/` (3,842 lines)

#### Task 4.5 — Canvas

Create `Sources/Fae/Canvas/CanvasManager.swift`

**Replaces**: `src/canvas/` (3,748 lines)

Scene graph → HTML rendering, WebSocket sync.

#### Task 4.6 — Credentials

Create `Sources/Fae/Core/CredentialManager.swift`

**Replaces**: `src/credentials/` (1,640 lines)

Native `Security.framework` Keychain access — much simpler in Swift than Rust.

#### Task 4.7 — x0x Network Listener

Create `Sources/Fae/Network/X0XListener.swift`

**Replaces**: `src/x0x_listener.rs` (200 lines)

SSE client via `URLSession`, trust filtering (only Trusted + verified), rate limiting (10/min per sender, 30/min global).

#### Task 4.8 — Diagnostics

Create `Sources/Fae/Core/DiagnosticsManager.swift`

**Replaces**: `src/diagnostics/` (2,000 lines)

Health checks, log rotation, runtime audit.

---

### PHASE 5: Polish & Ship

**Goal**: Production-ready release.
**Deliverable**: Full app bundle, codesigned, all features working.

#### Task 5.1 — Onboarding

Update `OnboardingController.swift` — replace Rust backend queries with direct `faeCore.isOnboarded` / `faeCore.completeOnboarding()`.

#### Task 5.2 — Settings

Update all settings tabs to use `FaeCore` directly:
- `SettingsModelsTab.swift` — model selection via `faeCore.config.llm`
- `SettingsToolsTab.swift` — tool mode via `faeCore.config.permissions.toolMode`
- `SettingsChannelsTab.swift` — channel config via `faeCore.config.channels`
- `SettingsDeveloperTab.swift` — diagnostics via `faeCore`

#### Task 5.3 — Build System

Update `justfile` — remove all Rust recipes (`build-staticlib`, `check`, `lint`), replace with Swift:

```just
build:
    cd native/macos/Fae && swift build

build-release:
    cd native/macos/Fae && swift build -c release

test:
    cd native/macos/Fae && swift test

bundle:
    @just build-release
    # codesign + bundle steps

run:
    @just _kill-fae
    open native/macos/Fae/.build/release/Fae.app --stdout /tmp/fae-test.log --stderr /tmp/fae-test.log

check:
    cd native/macos/Fae && swift build && swift test
```

#### Task 5.4 — CI Updates

`.github/workflows/ci.yml` — remove Rust toolchain and `cargo` steps. Replace with `swift build`, `swift test`.

`.github/workflows/release.yml` — macOS arm64 only (MLX = Apple Silicon only). Remove Linux/Windows cross-compilation.

#### Task 5.5 — Relay Server

Update `FaeRelayServer.swift` — replace `EmbeddedCoreSender` with `FaeCore` for `commandSender` and `audioSender`.

---

## Existing NotificationCenter Names (must be preserved)

These names are consumed by the 38+ unchanged UI files. `FaeEventBus` must emit all of them:

| Name | Used By |
|------|---------|
| `.faeBackendEvent` | (legacy — can be removed if no UI file depends on raw events) |
| `.faeOrbStateChanged` | `OrbStateBridgeController` |
| `.faePipelineState` | `OrbStateBridgeController`, `ContentView`, others |
| `.faeRuntimeState` | `FaeApp`, `OnboardingController` |
| `.faeRuntimeProgress` | `ProgressOverlayView` |
| `.faeAssistantGenerating` | `ConversationBridgeController`, `OrbStateBridgeController` |
| `.faeAudioLevel` | `NativeOrbView` |
| `.faeApprovalRequested` | `ApprovalOverlayController` |
| `.faeApprovalResolved` | `ApprovalOverlayController` |
| `.faeApprovalRespond` | (Swift → Core direction, handled by `faeCore.respondToApproval()`) |

**Critical**: Before deleting any file, grep for its usage across ALL Swift files. The UI files are the source of truth for what events/notifications they consume.

---

## Memory Budget (all models loaded)

| Model | RAM |
|-------|-----|
| Qwen3-ASR 0.6B (4-bit) | ~400MB |
| Qwen3-4B LLM (4-bit) | ~2.5GB |
| Qwen3-TTS 0.6B | ~700MB |
| Embedding model | ~90MB |
| **Total** | **~3.7GB** |

---

## Risk Areas

| Risk | Mitigation |
|------|------------|
| **mlx-audio-swift STT API immaturity** | Protocol design allows swapping to WhisperKit (Core ML) as fallback |
| **mlx-audio-swift TTS streaming gaps** | Keep `AVSpeechSynthesizer` as degraded fallback |
| **LLM tool calling not native in mlx-swift-lm** | Implement structured output parsing (JSON in `<tool_call>` tags) |
| **Pipeline coordinator complexity (5,192 lines)** | Port incrementally: basic → echo → barge-in → gate → approval |
| **Apple Silicon only** | Acceptable — MLX is Apple Silicon only by design |

---

## Verification Checklist

### Per-Phase

- [ ] **Phase 0**: `swift build` compiles all 50 UI files with no Rust dependency
- [ ] **Phase 1**: Speak "hello" → hear response. First-audio < 1.5s, T/s > 60
- [ ] **Phase 2**: Tell name → ask later → correct recall
- [ ] **Phase 3**: "What time is it?" → bash tool → approval → spoken answer
- [ ] **Phase 4**: Morning briefing at 08:00. Backup runs. Python skill executes.
- [ ] **Phase 5**: Full bundle, codesign, launch, onboarding, settings

### End-to-End Smoke Test

1. `just build-release && just bundle && just run`
2. Complete onboarding (grant mic permission)
3. Say "Hello Fae, my name is David"
4. Say "What time is it?" (triggers bash tool + approval)
5. Say "Search for the weather in Edinburgh" (triggers web search)
6. Say "Check my calendar for today" (triggers calendar tool)
7. Quit, relaunch, say "What's my name?" (memory recall)
8. Verify: `tail -f /tmp/fae-test.log` shows pipeline timing events

### Performance Targets

| Metric | Target |
|--------|--------|
| First audio latency | < 1.5s |
| LLM tokens/sec | > 60 (4B model) |
| STT latency | < 500ms |
| TTS first chunk | < 200ms |
| Memory recall | < 50ms |
| Cold start (models cached) | < 10s |

---

## Important References

### Rust Source Files to Read Before Porting

| Rust File | Lines | Port To | Priority |
|-----------|-------|---------|----------|
| `src/pipeline/coordinator.rs` | 5,192 | `PipelineCoordinator.swift` | Phase 1 (critical) |
| `src/config.rs` | 2,292 | `FaeConfig.swift` | Phase 1 |
| `src/personality.rs` | 1,308 | `PersonalityManager.swift` | Phase 1 |
| `src/memory/sqlite.rs` | 1,779 | `SQLiteMemoryStore.swift` | Phase 2 |
| `src/memory/schema.rs` | ~200 | `SQLiteMemoryStore.swift` | Phase 2 |
| `src/memory/types.rs` | ~400 | `SQLiteMemoryStore.swift` | Phase 2 |
| `src/memory/embedding.rs` | ~300 | `MLXEmbeddingEngine.swift` | Phase 2 |
| `src/fae_llm/agent/loop_engine.rs` | ~2,000 | `AgentLoop.swift` | Phase 3 |
| `src/fae_llm/agent/executor.rs` | ~2,000 | `AgentLoop.swift` | Phase 3 |
| `src/fae_llm/agent/accumulator.rs` | ~2,000 | `AgentLoop.swift` | Phase 3 |
| `src/scheduler/runner.rs` | ~1,800 | `FaeScheduler.swift` | Phase 4 |
| `src/scheduler/tasks.rs` | ~1,800 | `FaeScheduler.swift` | Phase 4 |
| `src/skills/` | 10,593 | `SkillManager.swift` | Phase 4 |
| `src/intent.rs` | 325 | `IntentClassifier.swift` | Phase 1 |
| `src/voice_command.rs` | ~200 | `VoiceCommandParser.swift` | Phase 3 |

### Behavioral Truth Sources (must be preserved exactly)

- `Prompts/system_prompt.md` — core personality prompt
- `SOUL.md` — behavioral contract
- `docs/guides/Memory.md` — memory architecture docs

### Existing Swift Files to Modify (grep for `commandSender` and `EmbeddedCoreSender`)

Every file that references the old bridge needs updating. The list in the plan overview covers the known ones, but **always grep to find them all**.

---

## Estimated Output

| Phase | New Swift LOC | Weeks |
|-------|---------------|-------|
| Phase 0: Foundation | ~1,500 | 1 |
| Phase 1: Voice Pipeline | ~4,000 | 4-5 |
| Phase 2: Memory | ~2,500 | 2 |
| Phase 3: Tools & Agent | ~3,000 | 3 |
| Phase 4: Background Systems | ~3,500 | 3 |
| Phase 5: Polish & Ship | ~1,500 | 2 |
| **Total** | **~16,000** | **15-17** |

106K Rust lines → 16K Swift lines. Reduction from: no FFI layer, no serialization, native Apple frameworks, MLX handling model loading, Swift concurrency being more concise.
