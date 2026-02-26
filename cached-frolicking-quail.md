> ⚠️ **ARCHIVAL DOCUMENT — HISTORICAL PLAN ONLY**
> 
> This file captures an earlier migration planning snapshot. It is **not** the source of truth for current implementation status or build/release procedures. Follow repository root `README.md`, `CLAUDE.md`, and `native/macos/Fae/README.md` for current guidance.

# Plan: Fae Pure-Swift Rebuild with MLX

## Context

Fae is a macOS voice assistant (STT → LLM → TTS pipeline) currently built as a Swift UI shell (50 files) embedding a Rust core (`libfae.a`, 106K lines) via C ABI FFI. The Rust core handles all ML inference (mistral.rs for LLM, parakeet-rs for STT, Kokoro-82M/ONNX for TTS) plus memory, tools, scheduler, personality, and pipeline orchestration.

**Problem**: The FFI boundary creates significant complexity — C ABI functions, JSON command/event serialization, `-force_load` linker hacks, dead-strip workarounds, dual build systems (cargo + SPM), and debugging across two languages. The Rust ML inference backend (mistral.rs) supports fewer models than MLX and is ~2x slower on Apple Silicon.

**Solution**: Rebuild Fae as a pure Swift application using Apple's MLX ecosystem:
- **mlx-swift-lm** (Apple official) — LLM inference, 2x faster, 30+ model architectures
- **mlx-audio-swift** (Blaizzy) — Qwen3-ASR for STT, Qwen3-TTS for TTS, native Swift
- **GRDB.swift** — SQLite memory store
- **Swift concurrency** — async/await, actors, AsyncStream replace tokio channels

Fae has not launched yet, so there is no user data migration concern. This is a clean rewrite.

**Outcome**: Single-language app, no FFI, simpler build (just `swift build`), faster inference, broader model support, iOS-ready architecture, alignment with Apple's MLX direction (WWDC 2025, M5 Neural Accelerators).

---

## What Goes Away

| Removed | Why |
|---------|-----|
| `src/` (all 217 .rs files, 106K lines) | Replaced by Swift |
| `Cargo.toml`, `Cargo.lock` | No more Rust |
| `include/fae.h` | No more C ABI |
| `Sources/CLibFae/` | No more C module map |
| `libfae.a` build step | No more static library |
| `-force_load` linker hacks | No dead-strip issues |
| `src/linker_anchor.rs` | No more anti-strip anchor |
| `src/ffi.rs` (8 extern "C" functions) | Direct Swift calls |
| `src/host/` (JSON command/event protocol) | Native Swift events |
| mistralrs, candle, ort, cpal, parakeet-rs deps | MLX + AVAudioEngine |
| `EmbeddedCoreSender.swift` | Replaced by `FaeCore` |
| `BackendEventRouter.swift` | Replaced by `FaeEventBus` |
| `HostCommandBridge.swift` | Direct method calls |

## What Stays (50 Swift UI Files)

All existing UI files remain — orb, conversation, canvas, settings, onboarding, approval overlay, auxiliary windows. They currently consume `NotificationCenter` events, which the new `FaeEventBus` will continue to emit via a compatibility bridge.

---

## Architecture

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
3. **Combine event bus** — `PassthroughSubject<FaeEvent, Never>` replaces JSON event serialization. Compatibility bridge posts to existing `NotificationCenter` names so all 50 UI files work unchanged initially.
4. **AsyncStream** for pipeline stages — audio chunks, transcriptions, tokens, synthesized audio all flow as async streams
5. **Same config format** — `config.toml` at `~/Library/Application Support/fae/`
6. **Same SQLite schema** — GRDB.swift reads/writes the same `fae.db` tables

### Memory Budget (all models loaded simultaneously)

| Model | RAM |
|-------|-----|
| Qwen3-ASR 0.6B (4-bit) | ~400MB |
| Qwen3-4B LLM (4-bit) | ~2.5GB |
| Qwen3-TTS 0.6B | ~700MB |
| Embedding model | ~90MB |
| **Total** | **~3.7GB** |

Auto-selection by RAM (same tiers as current):
- >=48 GiB → Qwen3-8B LLM
- >=32 GiB → Qwen3-4B LLM
- <32 GiB → Qwen3-1.7B LLM

---

## Implementation Phases

### Phase 0: Foundation (~1 week)

**Goal**: New package structure compiles with all 50 UI files, no Rust dependency.

#### 0.1 Rewrite `Package.swift`

Remove CLibFae target, remove all `-force_load`/linker flags. Add MLX dependencies:

```swift
dependencies: [
    .package(path: "../../apple/FaeHandoffKit"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    // MLX ecosystem
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main"),
    .package(url: "https://github.com/Blaizzy/mlx-audio-swift", branch: "main"),
    // Data
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
```

**Files**: `native/macos/Fae/Package.swift`

#### 0.2 Core Types and Protocols

Create new files in `Sources/Fae/Core/`:

| New File | Purpose |
|----------|---------|
| `FaeEvent.swift` | Event enum (replaces `RuntimeEvent` + JSON serialization) |
| `FaeEventBus.swift` | Combine subject + NotificationCenter compatibility bridge |
| `MLProtocols.swift` | `STTEngine`, `LLMEngine`, `TTSEngine`, `EmbeddingEngine` protocols |
| `FaeTypes.swift` | `AudioChunk`, `SpeechSegment`, `SentenceChunk`, `ChatMessage`, `ConversationTurn` |

#### 0.3 Stub `FaeCore.swift`

Replace `EmbeddedCoreSender`. Stubs all methods, emits synthetic events for UI testing:

```swift
@MainActor
final class FaeCore: ObservableObject {
    let eventBus = FaeEventBus()
    @Published var pipelineState: PipelineState = .stopped
    @Published var isOnboarded: Bool = false

    func start() async throws { /* stub */ }
    func stop() async { /* stub */ }
    func injectText(_ text: String) { /* stub */ }
    func respondToApproval(requestID: UInt64, approved: Bool) { /* stub */ }
    func patchConfig(key: String, value: Any) { /* stub */ }
}
```

#### 0.4 Rewire `FaeApp.swift`

Replace `commandSender: EmbeddedCoreSender?` with `@StateObject private var faeCore = FaeCore()`. Replace `sender.sendCommand(...)` calls with `faeCore.method()` calls. Pass `faeCore` as environment object.

**Key changes in `FaeApp.swift`**:
- Line 87: `private let commandSender: EmbeddedCoreSender?` → removed
- Line 92: `BackendEventRouter` → `FaeEventBus` compatibility bridge
- Lines 112-119: `EmbeddedCoreSender(configJSON: "{}")` → `FaeCore()`
- Line 215-216: `relayServer.commandSender = commandSender` → `relayServer.faeCore = faeCore`
- Line 417: `sender.sendCommand(name: "runtime.start", payload: [:])` → `Task { try? await faeCore.start() }`
- Lines 482-523: `restoreOnboardingState(sender:)` → `faeCore.isOnboarded` (direct property)

#### 0.5 Delete Rust-bridge files

- Delete `EmbeddedCoreSender.swift`
- Delete `BackendEventRouter.swift`
- Delete `HostCommandBridge.swift`
- Delete `Sources/CLibFae/` directory

#### 0.6 Verify compilation

`swift build` succeeds with all 50 UI files + stubs. No Rust build step.

---

### Phase 1: Voice Pipeline (~4-5 weeks)

**Goal**: Working voice conversation — speak to Fae, get spoken response.

#### 1.1 Audio I/O

**New files**: `Sources/Fae/Audio/AudioCaptureManager.swift`, `AudioPlaybackManager.swift`, `AudioToneGenerator.swift`

Replaces: `src/audio/{capture.rs, playback.rs, tone.rs, device_watcher.rs}` (1,408 lines)

- `AVAudioEngine` input tap for capture (16kHz mono float32)
- `AVAudioPlayerNode` for playback
- Built-in echo cancellation via voice processing I/O unit (`kAudioUnitSubType_VoiceProcessingIO`)
- Thinking tone (A3→C4, 300ms, volume 0.05) and listening tone via `AVAudioEngine` signal generation
- Device change monitoring via `AVAudioSession.routeChangeNotification`

#### 1.2 Voice Activity Detection

**New file**: `Sources/Fae/Pipeline/VoiceActivityDetector.swift`

Replaces: `src/vad/mod.rs` (~100 lines)

Port energy-based VAD: RMS threshold + hysteresis + silence timeout (700ms). Pure arithmetic, no ML.

#### 1.3 STT Engine (Qwen3-ASR)

**New file**: `Sources/Fae/ML/MLXSTTEngine.swift`

Replaces: `src/stt/mod.rs` (parakeet-rs)

```swift
import MLXAudioSTT

actor MLXSTTEngine: STTEngine {
    private var model: (any STTModel)?
    func load(modelID: String = "mlx-community/Qwen3-ASR-0.6B") async throws { ... }
    func transcribe(samples: [Float], sampleRate: Int) async throws -> STTResult { ... }
}
```

Qwen3-ASR: 52 languages, exceeds Whisper-large-v3 accuracy, native Swift.

#### 1.4 LLM Engine (Qwen3 via mlx-swift-lm)

**New file**: `Sources/Fae/ML/MLXLLMEngine.swift`

Replaces: `src/llm/mod.rs` (804 lines) + `src/fae_llm/providers/local.rs` (550 lines)

```swift
import MLXLLM

actor MLXLLMEngine: LLMEngine {
    private var container: ModelContainer?
    private var session: ChatSession?
    func load(modelID: String) async throws { ... }
    func generate(messages: [ChatMessage], systemPrompt: String, options: GenerationOptions)
        -> AsyncThrowingStream<String, Error> { ... }
}
```

Port from Rust:
- `ThinkTagStripper` (strips `<think>...</think>` from stream) — 60 lines, pure string logic
- `/no_think` prefix injection
- History management (trim to `max_history_messages`)
- Interrupt support via `Task.cancel()`

#### 1.5 TTS Engine (Qwen3-TTS)

**New file**: `Sources/Fae/ML/MLXTTSEngine.swift`

Replaces: `src/tts/kokoro/{engine.rs, phonemize.rs}` (~500 lines)

```swift
import MLXAudioTTS

actor MLXTTSEngine: TTSEngine {
    private var model: (any TTSModel)?
    func load(modelID: String = "mlx-community/Qwen3-TTS-0.6B") async throws { ... }
    func synthesize(text: String) -> AsyncThrowingStream<AudioBuffer, Error> { ... }
}
```

Qwen3-TTS: streaming ~120ms to first chunk, voice cloning, 10 languages.

#### 1.6 Pipeline Coordinator

**New file**: `Sources/Fae/Pipeline/PipelineCoordinator.swift`

Replaces: `src/pipeline/coordinator.rs` (5,192 lines) — the largest porting effort.

```swift
actor PipelineCoordinator {
    // Wires: AudioCapture → VAD → STT → LLM → sentence chunking → TTS → Playback
    // Handles: echo suppression, barge-in, gate/sleep, text injection
    func run() async { ... }
    func stop() { ... }
    func injectText(_ text: String) { ... }
}
```

Port from Rust:
- `find_clause_boundary()` / `find_sentence_boundary()` — sentence splitting for TTS pipelining
- Echo suppression (1000ms tail, VAD reset when assistant stops speaking)
- Barge-in (cancel generation task + stop playback on speech detection)
- Gate system (sleep/wake phrase detection)
- Name detection (`FAE_NAME_VARIANTS` array)
- Degraded modes (TextOnly, LlmOnly when models unavailable)

Supporting files:
- `Sources/Fae/Pipeline/TextProcessing.swift` — `findClauseBoundary()`, `stripNonSpeechChars()`
- `Sources/Fae/Pipeline/EchoSuppressor.swift` — echo tail tracking, VAD reset logic
- `Sources/Fae/Pipeline/ConversationState.swift` — turn tracking, history

#### 1.7 Personality & Prompts

**New file**: `Sources/Fae/Core/PersonalityManager.swift`

Replaces: `src/personality.rs` (1,308 lines)

- Load `CORE_PROMPT` from `Prompts/system_prompt.md` bundle resource
- `VOICE_CORE_PROMPT` (~2KB condensed) hardcoded
- `BACKGROUND_AGENT_PROMPT` hardcoded
- `SOUL.md` loaded from bundle
- `TOOL_ACKNOWLEDGMENTS` and `THINKING_ACKNOWLEDGMENTS` rotation arrays
- Full prompt assembly stack: core + vision + SOUL + user name + skills + capabilities + memory

#### 1.8 Config

**New file**: `Sources/Fae/Core/FaeConfig.swift`

Replaces: `src/config.rs` (2,292 lines)

```swift
import TOMLKit

struct FaeConfig: Codable {
    var audio: AudioConfig
    var llm: LLMConfig  // model_id, temperature, top_p, max_tokens, context_size
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
}
```

Port `recommended_local_model()` auto-selection logic (RAM-based tier selection).

#### 1.9 Intent Classifier

**New file**: `Sources/Fae/Core/IntentClassifier.swift`

Replaces: `src/intent.rs` (325 lines)

Direct port of keyword arrays and `classify_intent()`. Routes tool-needing queries to background agent vs direct voice LLM.

#### 1.10 Model Download & Progress

**New file**: `Sources/Fae/ML/ModelManager.swift`

Wire MLX library download callbacks to `FaeEventBus` for progress UI:

```swift
actor ModelManager {
    func downloadAndLoad(stt: MLXSTTEngine, llm: MLXLLMEngine, tts: MLXTTSEngine) async throws {
        eventBus.send(.runtimeProgress(stage: "stt", progress: 0))
        try await stt.load()
        eventBus.send(.runtimeProgress(stage: "llm", progress: 0.33))
        try await llm.load()
        eventBus.send(.runtimeProgress(stage: "tts", progress: 0.66))
        try await tts.load()
        eventBus.send(.runtimeProgress(stage: "ready", progress: 1.0))
    }
}
```

**Phase 1 delivers**: Working voice conversation. Speak → hear response. No tools, no memory, no scheduler.

---

### Phase 2: Memory & Intelligence (~2 weeks)

**Goal**: Fae remembers context across conversations.

#### 2.1 SQLite Memory Store

**New file**: `Sources/Fae/Memory/SQLiteMemoryStore.swift`

Replaces: `src/memory/sqlite.rs` (1,779 lines)

```swift
import GRDB

actor SQLiteMemoryStore: MemoryStore {
    private let dbQueue: DatabaseQueue
    // Same schema as Rust: memories, memory_audit, contacts, voice_samples, etc.
    // Hybrid scoring: semantic 0.6 + confidence 0.2 + freshness 0.1 + kind bonus 0.1
}
```

Port from Rust: All table schemas from `src/memory/schema.rs`, hybrid scoring from `src/memory/types.rs`.

#### 2.2 Embedding Engine

**New file**: `Sources/Fae/ML/MLXEmbeddingEngine.swift`

Replaces: `src/memory/embedding.rs` (all-MiniLM-L6-v2 via ONNX)

Use MLX to run all-MiniLM-L6-v2 (384-dim sentence embeddings) or explore Apple's `NLEmbedding` as simpler alternative. Vectors stored as BLOB in SQLite, cosine similarity computed via Accelerate framework.

#### 2.3 Memory Orchestrator

**New file**: `Sources/Fae/Memory/MemoryOrchestrator.swift`

Replaces: `src/memory/jsonl.rs` (MemoryOrchestrator portions)

- `recall(query:)` — semantic search before LLM generation
- `capture(turn:)` — extract and persist memories from completed turns
- `reflect()` — consolidate duplicate/overlapping memories
- `garbageCollect()` — retention cleanup

#### 2.4 Backup & Health

**New file**: `Sources/Fae/Memory/MemoryBackup.swift`

- `VACUUM INTO` backup with 7-day rotation
- `PRAGMA quick_check` integrity verification on startup

#### 2.5 Wire Memory into Pipeline

Update `PipelineCoordinator` to:
1. Call `memoryOrchestrator.recall(query: transcription)` before LLM generation
2. Inject memory context into system prompt
3. Call `memoryOrchestrator.capture(turn:)` after each completed turn

**Phase 2 delivers**: Fae remembers what you told her. Contextual responses improve over time.

---

### Phase 3: Tools & Agent System (~3 weeks)

**Goal**: Fae can execute tools (bash, file I/O, web search, Apple ecosystem, Python skills).

#### 3.1 Tool Protocol & Registry

**New files**: `Sources/Fae/Tools/Tool.swift`, `Sources/Fae/Tools/ToolRegistry.swift`

```swift
protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: JSONSchema { get }
    func execute(input: [String: Any]) async throws -> ToolResult
}
```

#### 3.2 Built-in Tools (15+)

| New File | Replaces | Notes |
|----------|----------|-------|
| `ReadTool.swift` | `tools/read.rs` | `FileManager` / `String(contentsOf:)` |
| `WriteTool.swift` | `tools/write.rs` | `Data.write(to:)` |
| `EditTool.swift` | `tools/edit.rs` | Line-based string replacement |
| `BashTool.swift` | `tools/bash.rs` | `Process` (Foundation) |
| `WebSearchTool.swift` | `tools/web_search.rs` | `URLSession` |
| `FetchURLTool.swift` | `tools/fetch_url.rs` | `URLSession` |
| `CalendarTool.swift` | `tools/apple/calendar.rs` | **EventKit** (native, simpler than AppleScript bridge) |
| `ContactsTool.swift` | `tools/apple/contacts.rs` | **Contacts.framework** (native) |
| `MailTool.swift` | `tools/apple/mail.rs` | AppleScript bridge |
| `RemindersTool.swift` | `tools/apple/reminders.rs` | **EventKit** (native) |
| `NotesTool.swift` | `tools/apple/notes.rs` | AppleScript bridge |
| `DesktopTool.swift` | `tools/desktop/` | `CGWindowServer`, `NSEvent` |
| `PythonSkillTool.swift` | `tools/python_skill.rs` | `Process` subprocess |
| `SchedulerTools.swift` | `tools/scheduler_*.rs` | Direct scheduler calls |
| `X0XTool.swift` | `tools/x0x.rs` | `URLSession` HTTP client |

Apple ecosystem tools (calendar, contacts, reminders) become **significantly simpler** — EventKit and Contacts.framework are native Swift, replacing the Rust→AppleScript bridge.

#### 3.3 Agent Loop

**New file**: `Sources/Fae/Agent/AgentLoop.swift`

Replaces: `src/fae_llm/agent/{loop_engine.rs, executor.rs, accumulator.rs}` (6,072 lines)

```swift
actor AgentLoop {
    // LLM generate → parse tool calls → execute tools → loop
    // Max 10 turns, max 5 tools per turn, 30s timeout per tool
    // Streams SentenceChunks to TTS via AsyncStream
    func run(messages: [ChatMessage], tools: [Tool]) -> AsyncThrowingStream<AgentEvent, Error>
}
```

Port: streaming accumulator, tool call JSON parsing, duplicate response detection, per-turn tool allowlist selection.

#### 3.4 Approval System

**New file**: `Sources/Fae/Agent/ApprovalManager.swift`

Replaces: `src/pipeline/voice_approval.rs`

```swift
actor ApprovalManager {
    // Sends .approvalRequested via FaeEventBus → existing ApprovalOverlayView shows
    // User clicks Yes/No or speaks "yes"/"no" → faeCore.respondToApproval()
    // 58s auto-deny timeout
    func requestApproval(toolName: String, inputJSON: String) async -> Bool
}
```

Existing `ApprovalOverlayController.swift` and `ApprovalOverlayView.swift` stay unchanged — they already observe NotificationCenter events.

#### 3.5 Voice Command Parser

**New file**: `Sources/Fae/Core/VoiceCommandParser.swift`

Port `parse_approval_response()` (yes/no detection) and `parse_voice_command()` (show/hide conversation, switch model, etc.).

**Phase 3 delivers**: "What time is it?" → bash tool → spoken answer. Calendar queries, web searches, file operations all work.

---

### Phase 4: Background Systems (~3 weeks)

**Goal**: Full feature parity with Rust Fae.

#### 4.1 Scheduler

**New file**: `Sources/Fae/Scheduler/FaeScheduler.swift`

Replaces: `src/scheduler/{runner.rs, tasks.rs}` (3,611 lines)

All 11 built-in tasks, `DispatchSourceTimer` + `Calendar` for scheduling:

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

#### 4.2 Skills Manager

**New file**: `Sources/Fae/Skills/SkillManager.swift`

Replaces: `src/skills/` (10,593 lines)

Keep Python subprocess approach via `Process`. Port JSON-RPC protocol, health monitoring, PEP 723 parsing, uv bootstrap. This is the most complex port but the architecture is identical.

#### 4.3 Channel Integrations

**New file**: `Sources/Fae/Channels/ChannelManager.swift`

Replaces: `src/channels/` (1,736 lines)

Discord/WhatsApp webhook receiver + message routing into LLM pipeline.

#### 4.4 Intelligence

**New files**: `Sources/Fae/Intelligence/MorningBriefing.swift`, `SkillProposals.swift`, `NoiseBudget.swift`

Replaces: `src/intelligence/` (3,842 lines)

#### 4.5 Canvas

**New file**: `Sources/Fae/Canvas/CanvasManager.swift`

Replaces: `src/canvas/` (3,748 lines). Scene graph → HTML rendering, WebSocket sync.

#### 4.6 Credentials

**New file**: `Sources/Fae/Core/CredentialManager.swift`

Replaces: `src/credentials/` (1,640 lines). Native `Security.framework` Keychain access — simpler in Swift than Rust.

#### 4.7 x0x Network Listener

**New file**: `Sources/Fae/Network/X0XListener.swift`

Replaces: `src/x0x_listener.rs` (200 lines). SSE client via `URLSession`, trust filtering, rate limiting.

#### 4.8 Diagnostics

**New file**: `Sources/Fae/Core/DiagnosticsManager.swift`

Replaces: `src/diagnostics/` (2,000 lines). Health checks, log rotation, runtime audit.

**Phase 4 delivers**: Full feature parity. Everything the Rust Fae could do.

---

### Phase 5: Polish & Ship (~2 weeks)

#### 5.1 Onboarding

Update `OnboardingController.swift` — currently queries Rust backend for onboarding state. Replace with direct `FaeConfig.onboarded` property check. Remove `restoreOnboardingState(sender:)` from `FaeApp.swift`.

#### 5.2 Settings

Update settings tabs to use `FaeCore` directly instead of `commandSender`:
- `SettingsModelsTab.swift` — model selection via `faeCore.config.llm`
- `SettingsToolsTab.swift` — tool mode via `faeCore.config.permissions.toolMode`
- `SettingsChannelsTab.swift` — channel config via `faeCore.config.channels`
- `SettingsDeveloperTab.swift` — diagnostics via `faeCore`

#### 5.3 Build System

Update `justfile`:

```just
build:
    cd native/macos/Fae && swift build

build-release:
    cd native/macos/Fae && swift build -c release

test:
    cd native/macos/Fae && swift test

bundle:
    @just build-release
    # codesign + bundle

run:
    @just _kill-fae
    open native/macos/Fae/.build/release/Fae.app --stdout /tmp/fae-test.log --stderr /tmp/fae-test.log

check:
    cd native/macos/Fae && swift build && swift test
```

#### 5.4 CI Updates

`.github/workflows/ci.yml` — remove Rust toolchain, `cargo` steps. Replace with `swift build`, `swift test`.

`.github/workflows/release.yml` — macOS arm64 only (MLX = Apple Silicon only). Remove Linux/Windows cross-compilation.

#### 5.5 Relay Server

Update `FaeRelayServer.swift` to use `FaeCore` instead of `EmbeddedCoreSender` for `commandSender` and `audioSender`.

---

## Files Changed Summary

### Deleted (3 Swift + CLibFae + all Rust)

| File | Reason |
|------|--------|
| `Sources/Fae/EmbeddedCoreSender.swift` | Replaced by `FaeCore` |
| `Sources/Fae/BackendEventRouter.swift` | Replaced by `FaeEventBus` |
| `Sources/Fae/HostCommandBridge.swift` | Direct method calls |
| `Sources/CLibFae/` (directory) | No more C module |
| `src/` (entire directory) | Replaced by Swift |
| `include/fae.h` | No more C header |
| `Cargo.toml`, `Cargo.lock` | No more Rust |

### Modified (existing Swift files)

| File | Change |
|------|--------|
| `Package.swift` | Remove CLibFae, add MLX/GRDB/TOML deps |
| `FaeApp.swift` | `EmbeddedCoreSender` → `FaeCore`, remove JSON command dispatch |
| `ContentView.swift` | Accept `FaeCore` as environment object |
| `SettingsView.swift` | `commandSender` param → `faeCore` |
| `SettingsModelsTab.swift` | Direct model config |
| `SettingsToolsTab.swift` | Direct tool mode config |
| `SettingsChannelsTab.swift` | Direct channel config |
| `SettingsDeveloperTab.swift` | Direct diagnostics |
| `OnboardingController.swift` | Direct config instead of command dispatch |
| `ApprovalOverlayController.swift` | `faeCore.respondToApproval()` instead of notification |
| `FaeRelayServer.swift` | `faeCore` instead of `commandSender`/`audioSender` |
| `ProcessCommandSender.swift` | Remove or adapt |

### Unchanged (38 Swift UI files)

All orb, conversation, canvas, window, subtitle, animation, audio device, handoff, and help files. They consume `NotificationCenter` events which `FaeEventBus` continues to emit.

### New Swift Files (~35-40 files)

| Directory | Files | Purpose |
|-----------|-------|---------|
| `Sources/Fae/Core/` | `FaeCore.swift`, `FaeEvent.swift`, `FaeEventBus.swift`, `FaeConfig.swift`, `PersonalityManager.swift`, `IntentClassifier.swift`, `VoiceCommandParser.swift`, `CredentialManager.swift`, `DiagnosticsManager.swift`, `FaeTypes.swift` | Core infrastructure |
| `Sources/Fae/ML/` | `MLProtocols.swift`, `MLXLLMEngine.swift`, `MLXSTTEngine.swift`, `MLXTTSEngine.swift`, `MLXEmbeddingEngine.swift`, `ModelManager.swift`, `ThinkTagStripper.swift` | ML inference |
| `Sources/Fae/Pipeline/` | `PipelineCoordinator.swift`, `VoiceActivityDetector.swift`, `TextProcessing.swift`, `EchoSuppressor.swift`, `ConversationState.swift` | Voice pipeline |
| `Sources/Fae/Audio/` | `AudioCaptureManager.swift`, `AudioPlaybackManager.swift`, `AudioToneGenerator.swift` | Audio I/O |
| `Sources/Fae/Memory/` | `SQLiteMemoryStore.swift`, `MemoryOrchestrator.swift`, `MemoryBackup.swift` | Memory system |
| `Sources/Fae/Agent/` | `AgentLoop.swift`, `ApprovalManager.swift` | Tool execution |
| `Sources/Fae/Tools/` | `ToolRegistry.swift`, `Tool.swift`, 15 tool files | Tools |
| `Sources/Fae/Scheduler/` | `FaeScheduler.swift` | Background tasks |
| `Sources/Fae/Skills/` | `SkillManager.swift` | Python skills |
| `Sources/Fae/Channels/` | `ChannelManager.swift` | Discord/WhatsApp |
| `Sources/Fae/Intelligence/` | `MorningBriefing.swift`, `SkillProposals.swift`, `NoiseBudget.swift` | Proactive intelligence |
| `Sources/Fae/Canvas/` | `CanvasManager.swift` | Canvas rendering |
| `Sources/Fae/Network/` | `X0XListener.swift` | x0x network |

---

## Risk Areas & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| **mlx-audio-swift STT maturity** | Qwen3-ASR may have gaps | Protocol design allows swapping to WhisperKit (Core ML, proven) as fallback |
| **mlx-audio-swift TTS streaming** | Qwen3-TTS streaming may not work reliably | Keep `AVSpeechSynthesizer` as degraded fallback |
| **LLM tool calling** | mlx-swift-lm may not parse tool calls natively | Implement structured output parsing (JSON in `<tool_call>` tags) ourselves |
| **Pipeline coordinator complexity** | 5,192 lines of state machine | Port incrementally: basic pipeline → echo suppression → barge-in → gate → approval |
| **Skills Python subprocess** | Process management complexity | Port subprocess logic directly; same architecture, different language |
| **Apple Silicon only** | No Intel Mac support | Acceptable — MLX is Apple Silicon only by design. Fae targets modern Macs. |
| **Model download size** | ~3.7GB first launch | Show progress UI (already exists via `ProgressOverlayView.swift`) |

---

## Verification

### Per-Phase Testing

- **Phase 0**: `swift build` compiles all 50 UI files with no Rust dependency
- **Phase 1**: Speak "hello" → hear response. Measure: first-audio latency < 1.5s, tokens/sec > 60
- **Phase 2**: Tell Fae your name → ask "what's my name?" later → correct recall
- **Phase 3**: "What time is it?" → bash tool executes → spoken answer. Approval overlay for dangerous tools.
- **Phase 4**: Morning briefing triggers at 08:00. Scheduled backup runs. Python skill executes.
- **Phase 5**: Full app bundle, codesign, launch, onboarding flow, settings work

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

| Metric | Target | Measurement |
|--------|--------|-------------|
| First audio latency | < 1.5s | Time from speech end to first TTS audio |
| LLM tokens/sec | > 60 (4B model) | Logged in pipeline timing events |
| STT latency | < 500ms | Time from speech segment to transcription |
| TTS first chunk | < 200ms | Time from text to first audio chunk |
| Memory recall | < 50ms | Time for semantic search (10K records) |
| Cold start (models cached) | < 10s | App launch to pipeline ready |

---

## Estimated Effort

| Phase | Weeks | New Swift LOC |
|-------|-------|---------------|
| Phase 0: Foundation | 1 | ~1,500 |
| Phase 1: Voice Pipeline | 4-5 | ~4,000 |
| Phase 2: Memory | 2 | ~2,500 |
| Phase 3: Tools & Agent | 3 | ~3,000 |
| Phase 4: Background Systems | 3 | ~3,500 |
| Phase 5: Polish & Ship | 2 | ~1,500 |
| **Total** | **15-17 weeks** | **~16,000** |

The 106K→16K line reduction comes from: no FFI/serialization layer, no tokio boilerplate, native Apple frameworks replacing complex Rust wrappers, MLX handling model loading/downloading, and Swift concurrency being more concise than Rust channel-based async.
