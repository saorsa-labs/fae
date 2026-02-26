import Combine
import Foundation

/// Central coordinator replacing the embedded Rust core (`EmbeddedCoreSender`).
///
/// Conforms to `HostCommandSender` so all existing Settings tabs, relay server,
/// and `HostCommandBridge` work without changes.
///
/// Owns the ML engines and pipeline coordinator. Commands are dispatched
/// to the appropriate subsystem.
@MainActor
final class FaeCore: ObservableObject, HostCommandSender {
    let eventBus = FaeEventBus()

    @Published var pipelineState: FaePipelineState = .stopped
    @Published var isOnboarded: Bool = false
    @Published var userName: String? = nil
    @Published var toolMode: String = "full"

    // MARK: - Subsystems

    private var config = FaeConfig.load()
    private let sttEngine = MLXSTTEngine()
    private let llmEngine = MLXLLMEngine()
    private let ttsEngine = MLXTTSEngine()
    private let captureManager = AudioCaptureManager()
    private let playbackManager = AudioPlaybackManager()
    private let conversationState = ConversationStateTracker()
    private lazy var modelManager = ModelManager(eventBus: eventBus)
    private var pipelineCoordinator: PipelineCoordinator?
    private var memoryOrchestrator: MemoryOrchestrator?
    private var scheduler: FaeScheduler?

    /// Pending query continuations keyed by command name.
    private var pendingQueries: [String: CheckedContinuation<[String: Any]?, Never>] = [:]

    // MARK: - Lifecycle

    func start() throws {
        eventBus.send(.runtimeState(.starting))
        pipelineState = .starting

        // Load models and start pipeline asynchronously.
        Task {
            do {
                try await modelManager.loadAll(
                    stt: sttEngine,
                    llm: llmEngine,
                    tts: ttsEngine,
                    config: config
                )

                // Initialize memory system.
                let memoryStore = try Self.createMemoryStore()
                let orchestrator = MemoryOrchestrator(
                    store: memoryStore,
                    config: config.memory
                )
                self.memoryOrchestrator = orchestrator

                let coordinator = PipelineCoordinator(
                    eventBus: eventBus,
                    capture: captureManager,
                    playback: playbackManager,
                    sttEngine: sttEngine,
                    llmEngine: llmEngine,
                    ttsEngine: ttsEngine,
                    config: config,
                    conversationState: conversationState,
                    memoryOrchestrator: orchestrator
                )
                try await coordinator.start()
                pipelineCoordinator = coordinator

                // Start scheduler.
                let sched = FaeScheduler(
                    eventBus: eventBus,
                    memoryOrchestrator: orchestrator,
                    memoryStore: memoryStore
                )
                await sched.start()
                self.scheduler = sched

                pipelineState = .running
                eventBus.send(.runtimeState(.started))
                NSLog("FaeCore: pipeline started")
            } catch {
                NSLog("FaeCore: failed to start pipeline: %@", error.localizedDescription)
                pipelineState = .error
                eventBus.send(.runtimeState(.error))
            }
        }
    }

    func stop() {
        pipelineState = .stopping

        Task {
            await scheduler?.stop()
            scheduler = nil
            await pipelineCoordinator?.stop()
            pipelineCoordinator = nil
        }

        pipelineState = .stopped
        eventBus.send(.runtimeState(.stopped))
    }

    // MARK: - HostCommandSender Conformance

    /// Handles commands from `HostCommandBridge`, Settings tabs, and relay server.
    nonisolated func sendCommand(name: String, payload: [String: Any]) {
        Task { @MainActor in
            self.handleCommand(name: name, payload: payload)
        }
    }

    private func handleCommand(name: String, payload: [String: Any]) {
        switch name {
        case "runtime.start":
            try? start()

        case "runtime.stop":
            stop()

        case "conversation.inject_text":
            if let text = payload["text"] as? String {
                injectText(text)
            }

        case "conversation.gate_set":
            if let active = payload["active"] as? Bool {
                Task {
                    if active {
                        await pipelineCoordinator?.wake()
                    } else {
                        await pipelineCoordinator?.sleep()
                    }
                }
            }

        case "conversation.engage":
            Task { await pipelineCoordinator?.engage() }

        case "config.patch":
            if let key = payload["key"] as? String {
                patchConfig(key: key, payload: payload)
            }

        case "config.get":
            if let key = payload["key"] as? String {
                handleConfigGet(key: key, commandName: name)
            }

        case "onboarding.get_state":
            handleOnboardingGetState(commandName: name)

        case "onboarding.complete":
            completeOnboarding()

        case "onboarding.advance":
            NSLog("FaeCore: onboarding.advance — stub")

        case "onboarding.set_user_name":
            if let name = payload["name"] as? String {
                userName = name
                config.userName = name
                NSLog("FaeCore: user name set to '%@'", name)
            }

        case "onboarding.set_contact_info":
            NSLog("FaeCore: set_contact_info — stub")

        case "onboarding.set_family_info":
            NSLog("FaeCore: set_family_info — stub")

        case "capability.grant":
            if let cap = payload["capability"] as? String {
                NSLog("FaeCore: capability granted: %@", cap)
            }

        case "capability.deny":
            if let cap = payload["capability"] as? String {
                NSLog("FaeCore: capability denied: %@", cap)
            }

        case "approval.respond":
            if let requestId = payload["request_id"] as? UInt64,
               let approved = payload["approved"] as? Bool
            {
                respondToApproval(requestID: requestId, approved: approved)
            }

        case "skills.reload":
            NSLog("FaeCore: skills.reload — stub")

        case "scheduler.delete":
            NSLog("FaeCore: scheduler.delete — stub")

        case "scheduler.trigger_now":
            NSLog("FaeCore: scheduler.trigger_now — stub")

        case "data.delete_all":
            NSLog("FaeCore: data.delete_all — stub")

        default:
            NSLog("FaeCore: unhandled command '%@'", name)
        }
    }

    // MARK: - Query Command

    /// Async query interface for commands that expect a response.
    func queryCommand(name: String, payload: [String: Any]) async -> [String: Any]? {
        switch name {
        case "onboarding.get_state":
            return [
                "payload": [
                    "onboarded": isOnboarded,
                ] as [String: Any],
            ]

        case "config.get":
            let key = payload["key"] as? String ?? ""
            return configGetResponse(key: key)

        default:
            NSLog("FaeCore: unhandled query '%@'", name)
            return nil
        }
    }

    // MARK: - Commands

    func injectText(_ text: String) {
        Task { await pipelineCoordinator?.injectText(text) }
    }

    func respondToApproval(requestID: UInt64, approved: Bool) {
        eventBus.send(.approvalResolved(id: requestID, approved: approved, source: "button"))
        // TODO: Phase 3 — route to ApprovalManager
    }

    func patchConfig(key: String, payload: [String: Any]) {
        NSLog("FaeCore: config.patch key='%@'", key)
        switch key {
        case "tool_mode":
            if let value = payload["value"] as? String {
                toolMode = value
            }
        default:
            // TODO: persist to config.toml via TOMLKit
            break
        }
    }

    func completeOnboarding() {
        isOnboarded = true
        config.onboarded = true
        NSLog("FaeCore: onboarding complete")
        // TODO: persist to config.toml
    }

    // MARK: - Audio Injection (for companion relay)

    /// Inject raw PCM audio from a companion device into the speech pipeline.
    func injectAudio(samples: [Float], sampleRate: UInt32 = 16000) {
        // TODO: forward companion audio into capture pipeline
        NSLog("FaeCore: injectAudio %d samples", samples.count)
    }

    // MARK: - Private Helpers

    private func handleOnboardingGetState(commandName: String) {
        if let continuation = pendingQueries.removeValue(forKey: commandName) {
            continuation.resume(returning: [
                "payload": ["onboarded": isOnboarded] as [String: Any],
            ])
        }
    }

    private func handleConfigGet(key: String, commandName: String) {
        if let continuation = pendingQueries.removeValue(forKey: commandName) {
            continuation.resume(returning: configGetResponse(key: key))
        }
    }

    /// Memory database path: ~/Library/Application Support/fae/fae.db
    private static func createMemoryStore() throws -> SQLiteMemoryStore {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let faeDir = appSupport.appendingPathComponent("fae")
        let dbPath = faeDir.appendingPathComponent("fae.db").path
        return try SQLiteMemoryStore(path: dbPath)
    }

    private func configGetResponse(key: String) -> [String: Any] {
        switch key {
        case "voice_identity":
            return [
                "payload": [
                    "voice_identity": [
                        "enabled": false,
                        "mode": "assist",
                        "approval_requires_match": true,
                    ] as [String: Any],
                ] as [String: Any],
            ]
        case "llm.voice_model_preset":
            return [
                "payload": [
                    "llm": [
                        "voice_model_preset": config.llm.voiceModelPreset,
                    ] as [String: Any],
                ] as [String: Any],
            ]
        default:
            return ["payload": [:] as [String: Any]]
        }
    }
}
