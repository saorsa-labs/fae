# Phase 0: Foundation — Pure Swift Package Structure

## Your Mission

Get the Fae macOS app compiling as a **pure Swift** project with no Rust dependency. Replace the C ABI bridge with stub types. All 50 existing UI files must compile unchanged (or with minimal updates to reference the new bridge type).

**Deliverable**: `cd native/macos/Fae && swift build` exits 0.

---

## Context

Fae is a macOS voice assistant. It currently has:
- **50 Swift UI files** in `native/macos/Fae/Sources/Fae/` — orb, conversation, canvas, settings, onboarding, approval overlay, etc.
- **A Rust core** (`libfae.a`, 106K lines in `src/`) linked via C ABI FFI
- **3 Swift bridge files** that talk to the Rust core: `EmbeddedCoreSender.swift`, `BackendEventRouter.swift`, `HostCommandBridge.swift`
- **A C module** `Sources/CLibFae/` with `fae.h` header and module map

We are eliminating all Rust and replacing with pure Swift + MLX. This phase only creates the scaffolding — later phases fill in real implementations.

### Repository Layout

```
native/macos/Fae/
  Package.swift              ← rewrite this
  Sources/
    Fae/                     ← 50 Swift files live here
      FaeApp.swift           ← app entry point (rewire)
      EmbeddedCoreSender.swift  ← DELETE
      BackendEventRouter.swift  ← DELETE
      HostCommandBridge.swift   ← DELETE
      ContentView.swift
      SettingsView.swift
      ... (47 more UI files)
    CLibFae/                 ← DELETE entire directory
      include/fae.h
      module.modulemap
      shim.c
```

---

## Tasks

### 0.1 — Rewrite `Package.swift`

Read the current `Package.swift` first to understand what exists. Then replace it entirely.

**Remove**:
- CLibFae target
- All `-force_load` and linker flag hacks
- Any reference to `libfae.a` or Rust artifacts

**Add these dependencies**:

| Package | URL | Product Names |
|---------|-----|---------------|
| mlx-swift-lm | `https://github.com/ml-explore/mlx-swift-lm` (branch: `main`) | `MLXLLM`, `MLXVLM` |
| mlx-audio-swift | `https://github.com/Blaizzy/mlx-audio-swift` (branch: `main`) | Check their Package.swift for actual product names |
| GRDB.swift | `https://github.com/groue/GRDB.swift` (from: `7.0.0`) | `GRDB` |
| TOMLKit | `https://github.com/LebJe/TOMLKit` (from: `0.6.0`) | `TOMLKit` |

**Keep existing**:
- Sparkle (`from: "2.6.0"`)
- FaeHandoffKit (local path: `../../apple/FaeHandoffKit`)

**Important**: Before writing the Package.swift, fetch and read the actual `Package.swift` from `mlx-audio-swift` to verify the exact product names they export. The plan assumes `MLXAudioTTS` and `MLXAudioSTT` but these may differ.

Target template:
```swift
.executableTarget(
    name: "Fae",
    dependencies: [
        .product(name: "FaeHandoffKit", package: "FaeHandoffKit"),
        .product(name: "Sparkle", package: "Sparkle"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXVLM", package: "mlx-swift-lm"),
        // mlx-audio products — verify names
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
)
```

Platform: `.macOS(.v14)` minimum.

### 0.2 — Create Core Types and Protocols

Create directory `Sources/Fae/Core/` with these new files:

**`FaeEvent.swift`** — Typed event enum replacing JSON serialization:

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

**Note**: `OrbMode` and `OrbFeeling` already exist in `OrbTypes.swift`. Don't redefine them — import or reference the existing enums. Check what values they have:
- `OrbMode`: idle, listening, thinking, speaking
- `OrbFeeling`: neutral, calm, curiosity, warmth, concern, delight, focus, playful

**`FaeEventBus.swift`** — Combine subject + NotificationCenter compatibility bridge:

```swift
import Combine
import Foundation

final class FaeEventBus: @unchecked Sendable {
    let subject = PassthroughSubject<FaeEvent, Never>()
    private var cancellable: AnyCancellable?

    init() {
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

**Critical**: These NotificationCenter names are consumed by the existing UI files. Grep all Swift files for `.fae` notification names to make sure you cover them all. Known names:
- `.faeBackendEvent`, `.faeOrbStateChanged`, `.faePipelineState`, `.faeRuntimeState`
- `.faeRuntimeProgress`, `.faeAssistantGenerating`, `.faeAudioLevel`
- `.faeApprovalRequested`, `.faeApprovalResolved`, `.faeApprovalRespond`

If these are currently defined as `Notification.Name` extensions somewhere (likely in the existing bridge files), you'll need to keep those extension declarations.

**`MLProtocols.swift`** — ML engine protocols (stubs for now, real implementations in Phase 1):

```swift
import Foundation
import AVFoundation

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
    func synthesize(text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error>
    var isLoaded: Bool { get }
}

protocol EmbeddingEngine: Actor {
    func load(modelID: String) async throws
    func embed(text: String) async throws -> [Float]
    var isLoaded: Bool { get }
}

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
```

**`FaeTypes.swift`** — Shared types:

```swift
import Foundation

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
```

### 0.3 — Create Stub `FaeCore.swift`

This is the **central replacement** for `EmbeddedCoreSender`. Read `EmbeddedCoreSender.swift` first to understand what interface the UI expects, then create a stub that satisfies those call sites:

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
        // TODO: Phase 1
    }

    func respondToApproval(requestID: UInt64, approved: Bool) {
        eventBus.send(.approvalResolved(id: requestID, approved: approved))
    }

    func patchConfig(key: String, value: String) {
        switch key {
        case "tool_mode": toolMode = value
        default: break
        }
    }

    func getOnboardingState() -> Bool { isOnboarded }
    func completeOnboarding() { isOnboarded = true }

    func startPipeline() async {
        pipelineState = .starting
        eventBus.send(.pipelineStateChanged(.starting))
        pipelineState = .running
        eventBus.send(.pipelineStateChanged(.running))
    }

    func stopPipeline() async {
        pipelineState = .stopping
        eventBus.send(.pipelineStateChanged(.stopping))
        pipelineState = .stopped
        eventBus.send(.pipelineStateChanged(.stopped))
    }
}
```

**Important**: Read `EmbeddedCoreSender.swift` to find ALL methods/properties that the UI calls. The stub above covers the known ones, but there may be more. Add stubs for everything.

### 0.4 — Rewire All Swift Files

This is the bulk of the work. You need to:

1. **Grep for all references** to the old bridge across all 50 Swift files:
   - `EmbeddedCoreSender` (type name)
   - `commandSender` (property name used in many views)
   - `sendCommand` (method call pattern)
   - `BackendEventRouter` (type name)
   - `HostCommandBridge` (type name)
   - `import CLibFae` or `CLibFae` (C module import)

2. **Update `FaeApp.swift`** (the most changes):
   - `private let commandSender: EmbeddedCoreSender?` → `@StateObject private var faeCore = FaeCore()`
   - Remove `BackendEventRouter` setup
   - `sender.sendCommand(name: "runtime.start", payload: [:])` → `Task { try? await faeCore.start() }`
   - `restoreOnboardingState(sender:)` → `faeCore.isOnboarded`
   - Pass `faeCore` as `.environmentObject(faeCore)` to child views

3. **Update every view** that receives `commandSender`:
   - Change parameter type from `EmbeddedCoreSender?` to `FaeCore`
   - Change `.sendCommand(name:payload:)` calls to direct method calls
   - If a view uses `@EnvironmentObject`, add `FaeCore` as the expected type

4. **Key files that likely need changes** (verify by grepping):
   - `ContentView.swift` — main view
   - `SettingsView.swift` — passes sender to tabs
   - `SettingsModelsTab.swift`, `SettingsToolsTab.swift`, `SettingsChannelsTab.swift`, `SettingsDeveloperTab.swift`
   - `OnboardingController.swift` — queries onboarding state
   - `ApprovalOverlayController.swift` — sends approval responses
   - `AuxiliaryWindowManager.swift` — window management
   - `PipelineAuxBridgeController.swift` — routes commands
   - `ConversationController.swift` — conversation state
   - `ProcessCommandSender.swift` — may wrap the old sender
   - `FaeRelayServer.swift` (if it exists in this directory)

5. **Preserve NotificationCenter observation patterns** — the UI files that observe `.faePipelineState` etc. should continue working unchanged since `FaeEventBus` posts to the same notification names.

### 0.5 — Delete Old Bridge Files

After everything compiles with the new types:

- Delete `native/macos/Fae/Sources/Fae/EmbeddedCoreSender.swift`
- Delete `native/macos/Fae/Sources/Fae/BackendEventRouter.swift`
- Delete `native/macos/Fae/Sources/Fae/HostCommandBridge.swift`
- Delete `native/macos/Fae/Sources/CLibFae/` (entire directory)

**Do this AFTER the rewiring**, not before, so you can reference the old files while updating.

### 0.6 — Verify Compilation

```bash
cd native/macos/Fae && swift build
```

Must exit 0. Fix every error. Common issues:

- Missing `Notification.Name` extensions — add them if the old bridge files defined them
- Type mismatches — `EmbeddedCoreSender?` (optional) vs `FaeCore` (non-optional)
- Missing `sendCommand` method — replace with direct `faeCore.method()` calls
- `CLibFae` imports — remove them
- Conflicting type names — `PipelineState` etc. may already exist somewhere

---

## What You Produce (for later phases)

Later phases depend on these interfaces:

1. **`FaeCore`** — `@MainActor final class FaeCore: ObservableObject` with `start()`, `stop()`, `injectText()`, `respondToApproval()`, `patchConfig()` methods
2. **`FaeEventBus`** — sends `FaeEvent` enum values, bridges to `NotificationCenter`
3. **`MLProtocols`** — `STTEngine`, `LLMEngine`, `TTSEngine`, `EmbeddingEngine` protocol definitions
4. **`FaeTypes`** — `ChatMessage`, `AudioChunk`, `SpeechSegment`, `SentenceChunk`, `ConversationTurn`
5. **All 50 UI files compiling** against the new types

---

## Do NOT Do

- Do NOT implement real ML inference (that's Phase 1)
- Do NOT delete the Rust `src/` directory yet (other teams reference it for porting)
- Do NOT change UI behavior — only change what types/methods the UI calls
- Do NOT add new UI features
- Do NOT modify `Prompts/`, `SOUL.md`, or any behavioral content
