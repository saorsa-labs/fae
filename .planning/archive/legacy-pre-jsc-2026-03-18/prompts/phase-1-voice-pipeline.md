# Phase 1: Voice Pipeline — Speak to Fae, Hear a Response

## Your Mission

Implement the complete voice pipeline: microphone capture → voice activity detection → speech-to-text → LLM generation → text-to-speech → speaker playback. When done, a user can speak to Fae and hear a spoken response.

**Deliverable**: Say "hello" → hear spoken response. First-audio latency < 1.5s. LLM tokens/sec > 60.

---

## Prerequisites (completed by Phase 0 team)

- `Package.swift` has MLX dependencies (`mlx-swift-lm`, `mlx-audio-swift`, GRDB, TOMLKit)
- `FaeCore.swift` exists as a stub `@MainActor ObservableObject`
- `FaeEventBus.swift` bridges `FaeEvent` → `NotificationCenter`
- `MLProtocols.swift` defines `STTEngine`, `LLMEngine`, `TTSEngine`, `EmbeddingEngine` protocols
- `FaeTypes.swift` defines `ChatMessage`, `AudioChunk`, `SpeechSegment`, `SentenceChunk`
- All 50 UI files compile with `swift build`

You will be **filling in real implementations** behind the stub interfaces.

---

## Context

### Architecture

```
AudioCapture (AVAudioEngine)
  → VoiceActivityDetector (energy-based)
    → STTEngine (Qwen3-ASR via mlx-audio-swift)
      → LLMEngine (Qwen3-4B via mlx-swift-lm)
        → sentence chunking (findClauseBoundary)
          → TTSEngine (Qwen3-TTS via mlx-audio-swift)
            → AudioPlayback (AVAudioPlayerNode)
```

All components are Swift actors communicating via `AsyncStream`. The `PipelineCoordinator` actor orchestrates the flow.

### Rust Source Files to Read

These contain the logic you're porting. Read them to understand behavior, then write idiomatic Swift:

| File | Lines | What to port |
|------|-------|-------------|
| `src/pipeline/coordinator.rs` | 5,192 | Main state machine, echo suppression, barge-in, gate |
| `src/audio/capture.rs` | ~400 | Audio input setup (you'll use AVAudioEngine instead of cpal) |
| `src/audio/playback.rs` | ~400 | Audio output (AVAudioPlayerNode instead of cpal) |
| `src/audio/tone.rs` | ~200 | Thinking/listening tone generation |
| `src/vad/mod.rs` | ~100 | Energy-based VAD |
| `src/llm/mod.rs` | 804 | LLM loading, generation, think-tag stripping |
| `src/personality.rs` | 1,308 | Prompt assembly, SOUL contract, ack arrays |
| `src/config.rs` | 2,292 | Config struct, TOML loading, model selection |
| `src/intent.rs` | 325 | Intent classification (tool routing) |

---

## Tasks

### 1.1 — Audio I/O

Create `Sources/Fae/Audio/` directory.

**`AudioCaptureManager.swift`**:
- `AVAudioEngine` with input tap
- 16kHz mono Float32 format
- Use `kAudioUnitSubType_VoiceProcessingIO` for built-in echo cancellation
- Expose audio as `AsyncStream<AudioChunk>`
- Monitor device changes via `NotificationCenter` (`.AVAudioEngineConfigurationChange`)
- Start/stop methods

**`AudioPlaybackManager.swift`**:
- `AVAudioPlayerNode` attached to `AVAudioEngine`
- Accept `AVAudioPCMBuffer` for playback
- `interruptPlayback()` — immediately stop (for barge-in when user speaks)
- Track `isPlaying` state
- Signal when playback completes (for pipeline timing)

**`AudioToneGenerator.swift`**:
- Thinking tone: A3 (220 Hz) → C4 (262 Hz), 300ms duration, volume 0.05, 40% fade-out
- Listening tone (subtle confirmation beep)
- Generate `AVAudioPCMBuffer` programmatically using sine waves
- Play via `AudioPlaybackManager`

### 1.2 — Voice Activity Detection

**`Sources/Fae/Pipeline/VoiceActivityDetector.swift`**:

Port from `src/vad/mod.rs`. Pure arithmetic, no ML:

- Compute RMS energy of each audio chunk
- Speech onset threshold (configurable, ~0.01-0.02 RMS)
- Silence timeout: 700ms of below-threshold → segment complete
- Hysteresis to prevent rapid on/off toggling
- Output: `AsyncStream<SpeechSegment>` — emits accumulated audio when speech ends
- `reset()` method — flush any buffered audio (used by echo suppressor)

### 1.3 — STT Engine (Qwen3-ASR)

**`Sources/Fae/ML/MLXSTTEngine.swift`**:

```swift
actor MLXSTTEngine: STTEngine {
    // Load Qwen3-ASR-0.6B via mlx-audio-swift
    // Transcribe Float32 audio samples → text
}
```

**Important**: Read the `mlx-audio-swift` source code to understand the actual API:
- How to load an ASR model
- How to pass audio samples for transcription
- What format the output is in
- Whether streaming transcription is supported

The model ID should be configurable (default: `"mlx-community/Qwen3-ASR-0.6B"`).

### 1.4 — LLM Engine (Qwen3 via mlx-swift-lm)

**`Sources/Fae/ML/MLXLLMEngine.swift`**:

```swift
import MLXLLM

actor MLXLLMEngine: LLMEngine {
    private var container: ModelContainer?

    func load(modelID: String) async throws {
        let config = ModelConfiguration(id: modelID)
        container = try await LLMModelFactory.shared.loadContainer(configuration: config)
    }

    func generate(messages: [ChatMessage], systemPrompt: String, options: GenerationOptions)
        -> AsyncThrowingStream<String, Error> {
        // 1. Convert ChatMessage array to mlx-swift-lm's expected format
        // 2. Prepend /no_think to suppress thinking in voice mode
        // 3. Stream tokens via container.generate()
        // 4. Strip <think>...</think> blocks from output
        // 5. Support cancellation via Task.cancel()
    }
}
```

Read the `mlx-swift-lm` examples and source to understand:
- `ModelContainer` and `ModelConfiguration` API
- How to pass chat messages (system + user + assistant history)
- How streaming generation works
- How to set temperature, top_p, max_tokens

**`Sources/Fae/ML/ThinkTagStripper.swift`**:

Pure string logic that processes a stream of tokens and removes `<think>...</think>` blocks:
- Buffer tokens until `<think>` is fully seen → suppress until `</think>`
- Pass through all other tokens immediately
- Handle partial tag matches (e.g., `<thi` might be start of `<think>` or literal text)

Port from the Rust implementation — check `src/pipeline/coordinator.rs` for the think-stripping logic.

### 1.5 — TTS Engine (Qwen3-TTS)

**`Sources/Fae/ML/MLXTTSEngine.swift`**:

```swift
actor MLXTTSEngine: TTSEngine {
    // Load Qwen3-TTS-0.6B via mlx-audio-swift
    // Synthesize text → streaming AVAudioPCMBuffer chunks
}
```

Read `mlx-audio-swift` source to understand:
- How to load a TTS model
- How to synthesize text to audio
- Whether streaming synthesis is supported (generating audio before full text is processed)
- Audio format (sample rate, channels)

If streaming is not available, synthesize complete sentences and buffer.

**Fallback**: If Qwen3-TTS proves unreliable, `AVSpeechSynthesizer` is a viable degraded fallback — it's built into macOS, sounds robotic but works.

### 1.6 — Pipeline Coordinator

**`Sources/Fae/Pipeline/PipelineCoordinator.swift`** — This is the **largest and most critical** component.

```swift
actor PipelineCoordinator {
    private let audioCapture: AudioCaptureManager
    private let audioPlayback: AudioPlaybackManager
    private let vad: VoiceActivityDetector
    private let stt: any STTEngine
    private let llm: any LLMEngine
    private let tts: any TTSEngine
    private let eventBus: FaeEventBus
    private let personality: PersonalityManager

    func run() async { /* main loop */ }
    func stop() { /* cancel all tasks */ }
    func injectText(_ text: String) { /* bypass VAD/STT, go to LLM */ }
}
```

**Port incrementally** from `src/pipeline/coordinator.rs` (5,192 lines). Build in this order:

**Step 1 — Basic pipeline flow**:
1. AudioCapture produces `AsyncStream<AudioChunk>`
2. VAD accumulates chunks → emits `SpeechSegment` when speech ends
3. STT transcribes segment → text
4. Emit `.transcription(text:isFinal:)` event
5. LLM generates response (streaming tokens)
6. Sentence chunking: split token stream at sentence boundaries
7. TTS synthesizes each sentence chunk
8. AudioPlayback plays synthesized audio
9. Emit pipeline timing events at each stage boundary

**Step 2 — Echo suppression** (`EchoSuppressor.swift`):
- Track when assistant is speaking (`assistantSpeaking` flag)
- After assistant stops speaking, maintain 1000ms "echo tail"
- During echo tail: either suppress VAD entirely or `vad.reset()` to flush buffered playback audio
- Log: `"dropping N.Ns speech segment (echo suppression)"`
- Duration cap: ignore segments > 15s
- RMS ceiling: ignore segments with RMS > 0.15

**Step 3 — Barge-in**:
- When user starts speaking while assistant is playing audio:
  - Cancel the LLM generation `Task`
  - Call `audioPlayback.interruptPlayback()`
  - Process user's speech normally

**Step 4 — Gate system** (sleep/wake):
- Gate phrases: "Fae go to sleep", "Fae wake up" (and variants)
- When gated (sleeping): only listen for wake phrase, ignore everything else
- Visual feedback via orb state events

**Step 5 — Name detection**:
- `FAE_NAME_VARIANTS`: ["fae", "fay", "faye", "hey fae", etc.]
- Optional name-activation mode: only respond when name is detected in transcription

**Step 6 — Text injection**:
- `injectText(_ text:)` bypasses AudioCapture/VAD/STT
- Creates a synthetic speech segment with the provided text
- Feeds directly into LLM generation

**Step 7 — Degraded modes**:
- If STT fails to load: TextOnly mode (only text injection works)
- If TTS fails to load: LlmOnly mode (text responses, no speech)
- If LLM fails to load: Error state

Supporting files:

**`Sources/Fae/Pipeline/TextProcessing.swift`**:
- `findClauseBoundary(_ text: String) -> Int?` — find position to split text for TTS pipelining (at `. `, `? `, `! `, `, `, `: `, `; `)
- `findSentenceBoundary(_ text: String) -> Int?` — stricter, only sentence-ending punctuation
- `stripNonSpeechChars(_ text: String) -> String` — remove markdown, URLs, code blocks from TTS input

**`Sources/Fae/Pipeline/EchoSuppressor.swift`**:
- Encapsulates echo suppression logic
- Tracks assistant speaking state + echo tail timer
- `shouldSuppressSegment(segment:) -> Bool`

**`Sources/Fae/Pipeline/ConversationState.swift`**:
- Manages conversation history (array of `ChatMessage`)
- Trim to max N messages (configurable, default ~20)
- Track current turn for memory capture

### 1.7 — Personality & Prompts

**`Sources/Fae/Core/PersonalityManager.swift`**:

Port from `src/personality.rs` (1,308 lines):

```swift
struct PersonalityManager {
    // Load prompts from bundle resources
    func loadCorePrompt() -> String  // from Prompts/system_prompt.md
    func loadSoulContract() -> String  // from SOUL.md

    // Prompt assembly (non-voice)
    func assembleSystemPrompt(
        userName: String?,
        memoryContext: String?,
        visionCapable: Bool,
        skills: [String],
        capabilities: [String]
    ) -> String

    // Voice-optimized prompt (~2KB, strips tool schemas)
    func assembleVoicePrompt(userName: String?, memoryContext: String?) -> String

    // Background agent prompt (task-focused, spoken-friendly)
    func backgroundAgentPrompt() -> String

    // Canned responses
    func randomToolAcknowledgment() -> String
    func randomThinkingAcknowledgment() -> String
    func formatApprovalPrompt(toolName: String, input: String) -> String
}
```

The key constants to port:
- `VOICE_CORE_PROMPT` (~2KB) — read from `src/personality.rs`
- `BACKGROUND_AGENT_PROMPT` — read from `src/personality.rs`
- `TOOL_ACKNOWLEDGMENTS` array — ["Let me check that", "On it", "Looking into that", ...]
- `THINKING_ACKNOWLEDGMENTS` array — ["Hmm", "Let me think", ...]

### 1.8 — Config

**`Sources/Fae/Core/FaeConfig.swift`**:

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

    static let configDir: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("fae")
    }()

    static let configFile: URL = configDir.appendingPathComponent("config.toml")

    static func load() throws -> FaeConfig { /* read + decode TOML */ }
    func save() throws { /* encode + write TOML */ }

    /// RAM-based model auto-selection
    static func recommendedLocalModel() -> (modelID: String, contextSize: Int) {
        let totalRAM = ProcessInfo.processInfo.physicalMemory
        let ramGiB = totalRAM / (1024 * 1024 * 1024)

        if ramGiB >= 48 {
            return ("mlx-community/Qwen3-8B-4bit", 32768)
        } else if ramGiB >= 32 {
            return ("mlx-community/Qwen3-4B-4bit", 16384)
        } else {
            return ("mlx-community/Qwen3-1.7B-4bit", 8192)
        }
    }
}
```

**Note**: Verify the exact HuggingFace model IDs for MLX quantized Qwen3 models. They may be under `mlx-community/` or elsewhere.

Port sub-config structs from `src/config.rs`:
- `AudioConfig` — sample rate, channels, VAD thresholds
- `LLMConfig` — model_id, temperature, top_p, max_tokens, context_size
- `STTConfig` — model_id, language
- `TTSConfig` — model_id, voice, speed
- `MemoryConfig` — db path, embedding model
- `IntelligenceConfig` — noise budget, briefing time
- `PermissionStore` — tool mode, individual tool permissions
- `ChannelsConfig` — Discord/WhatsApp settings

### 1.9 — Intent Classifier

**`Sources/Fae/Core/IntentClassifier.swift`**:

Direct port from `src/intent.rs` (325 lines):

```swift
struct IntentClassification {
    let needsTools: Bool
    let detectedTools: [String]  // ["bash", "web_search", etc.]
    let confidence: Float
}

func classifyIntent(_ text: String) -> IntentClassification {
    // Keyword matching arrays (port from Rust):
    // "what time" / "date" → bash
    // "search" / "look up" / "find" → web_search, fetch_url
    // "calendar" / "schedule" / "meeting" → calendar tools
    // "read" / "open file" → read tool
    // "write" / "save" / "create file" → write tool
    // "remind" / "reminder" → reminders tool
    // etc.
}
```

When `needsTools == true`: play a canned acknowledgment ("Let me check that"), spawn background agent with tools. When `needsTools == false`: voice engine responds directly.

### 1.10 — Model Download & Progress

**`Sources/Fae/ML/ModelManager.swift`**:

```swift
actor ModelManager {
    private let eventBus: FaeEventBus

    func loadAll(
        stt: any STTEngine,
        llm: any LLMEngine,
        tts: any TTSEngine,
        config: FaeConfig
    ) async throws {
        eventBus.send(.runtimeProgress(stage: "stt", progress: 0))
        try await stt.load(modelID: config.stt.modelID)

        eventBus.send(.runtimeProgress(stage: "llm", progress: 0.33))
        try await llm.load(modelID: config.llm.modelID)

        eventBus.send(.runtimeProgress(stage: "tts", progress: 0.66))
        try await tts.load(modelID: config.tts.modelID)

        eventBus.send(.runtimeProgress(stage: "ready", progress: 1.0))
    }
}
```

MLX libraries handle HuggingFace Hub downloads internally. Wire their progress callbacks (if available) to the event bus so the existing `ProgressOverlayView.swift` shows download progress.

### 1.11 — Wire `FaeCore` to Real Components

Update the stub `FaeCore.swift` to create and wire all components:

```swift
@MainActor
final class FaeCore: ObservableObject {
    let eventBus = FaeEventBus()
    private var pipeline: PipelineCoordinator?
    private var config: FaeConfig

    init() {
        self.config = (try? FaeConfig.load()) ?? FaeConfig.default
        self.isOnboarded = config.onboarded
    }

    func start() async throws {
        eventBus.send(.runtimeState(.starting))

        let stt = MLXSTTEngine()
        let llm = MLXLLMEngine()
        let tts = MLXTTSEngine()
        let personality = PersonalityManager()

        let modelManager = ModelManager(eventBus: eventBus)
        try await modelManager.loadAll(stt: stt, llm: llm, tts: tts, config: config)

        pipeline = PipelineCoordinator(
            stt: stt, llm: llm, tts: tts,
            personality: personality, config: config, eventBus: eventBus
        )

        Task { await pipeline?.run() }

        eventBus.send(.runtimeState(.started))
        pipelineState = .running
        eventBus.send(.pipelineStateChanged(.running))
    }

    func stop() async {
        pipeline?.stop()
        pipeline = nil
        pipelineState = .stopped
        eventBus.send(.pipelineStateChanged(.stopped))
    }

    func injectText(_ text: String) {
        Task { await pipeline?.injectText(text) }
    }
}
```

---

## Verification

1. Build: `cd native/macos/Fae && swift build` — zero errors
2. Launch app, complete onboarding
3. Speak "Hello Fae" → hear spoken response
4. Check `/tmp/fae-test.log` for pipeline timing events:
   - `pipeline_timing: VAD segment complete` — `vad_ms`, `duration_s`
   - `pipeline_timing: STT completed` — `stt_ms`
   - `pipeline_timing: LLM generation completed` — `llm_ms`, tokens/sec
   - `pipeline_timing: TTS synthesis completed` — `tts_ms`
   - `pipeline_timing: playback completed` — `playback_ms`
5. First-audio latency (speech end → first TTS audio) < 1.5s
6. LLM tokens/sec > 60 on M-series chip with 4B model
7. Echo suppression: Fae does not trigger on her own voice
8. Barge-in: speaking while Fae talks stops her response

---

## Performance Targets

| Metric | Target |
|--------|--------|
| First audio latency | < 1.5s |
| LLM tokens/sec | > 60 (4B model) |
| STT latency | < 500ms |
| TTS first chunk | < 200ms |
| Cold start (models cached) | < 10s |

---

## Do NOT Do

- Do NOT implement memory/recall (Phase 2)
- Do NOT implement tools or agent loop (Phase 3)
- Do NOT implement scheduler (Phase 4)
- Do NOT change UI files beyond what Phase 0 already changed
- Do NOT delete the Rust `src/` directory (other teams reference it)
