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
    private static let legacyStartupCanvasKey = "fae.hasShownStartupCanvas"

    private struct PendingTextInjection {
        enum Mode {
            case standard
            case desktop
        }

        let text: String
        let mode: Mode
    }

    let eventBus = FaeEventBus()

    @Published var pipelineState: FaePipelineState = .stopped
    @Published var hasOwnerSetUp: Bool = UserDefaults.standard.bool(forKey: "fae.owner.enrolled")
    @Published var isLicenseAccepted: Bool
    @Published var shouldShowStartupIntro: Bool
    @Published var userName: String?
    @Published var toolMode: String = "full"
    @Published var thinkingEnabled: Bool = false
    @Published var thinkingLevel: FaeThinkingLevel = .fast

    var nativeEnrollmentCaptureManager: AudioCaptureManager { enrollmentCaptureManager }
    var nativeEnrollmentSpeakerEncoder: CoreMLSpeakerEncoder { speakerEncoder }
    var nativeEnrollmentSpeakerProfileStore: SpeakerProfileStore { speakerProfileStore }

    /// Whether Fae is currently speaking (TTS playback in progress).
    /// Exposed for the test harness to wait until speech completes.
    func isSpeaking() async -> Bool {
        await pipelineCoordinator?.isSpeaking ?? false
    }

    /// Rescue mode reference — set by FaeAppDelegate before start().
    weak var rescueMode: RescueMode?

    // MARK: - Subsystems

    private var config: FaeConfig
    private var schedulerObservers: [NSObjectProtocol] = []

    init() {
        var loaded = FaeConfig.load()

        // Config migration: enforce minimum maxTokens for tool calls.
        // Early configs persisted maxTokens=512 which is far too low for the LLM
        // to emit speech + <tool_call> JSON. Bump any legacy value below 2048.
        let migratedMaxTokens = loaded.llm.maxTokens < 2048
        if migratedMaxTokens {
            NSLog("FaeCore: migrating maxTokens %d → 4096 (legacy config too low for tool calls)", loaded.llm.maxTokens)
            loaded.llm.maxTokens = 4096
        }

        let migratedBundledFaeReferenceText = loaded.tts.referenceText == "Hello, I'm Fae."
        if migratedBundledFaeReferenceText {
            NSLog("FaeCore: migrating bundled fae.wav reference transcript to the actual recording text")
            loaded.tts.referenceText = FaeConfig.TtsConfig.bundledFaeReferenceText
        }

        // Channel secret migration: move legacy inline channel tokens from config
        // into Keychain, keeping read compatibility for existing installs.
        let migratedSecrets = Self.migrateChannelSecretsToKeychain(&loaded)
        let migratedStartupIntro = Self.migrateStartupIntroState(&loaded)

        if migratedSecrets || migratedMaxTokens || migratedBundledFaeReferenceText || migratedStartupIntro {
            try? loaded.save()
        }

        loaded.llm.normalizeThinkingConfiguration(hasExplicitLevel: true)
        let initialThinkingLevel = loaded.llm.resolvedThinkingLevel
        self.config = loaded
        self.isLicenseAccepted = loaded.licenseAccepted
        self.shouldShowStartupIntro = loaded.licenseAccepted
            && loaded.startupIntroSeenConfigured
            && !loaded.startupIntroSeen
        self.userName = loaded.userName
        self.toolMode = loaded.toolMode
        self.thinkingLevel = initialThinkingLevel
        self.thinkingEnabled = initialThinkingLevel.enablesThinking

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        let faeDir = appSupport.appendingPathComponent("fae")
        self.speakerProfileStore = SpeakerProfileStore(
            storePath: faeDir.appendingPathComponent("speakers.json")
        )
        self.wakeWordProfileStore = WakeWordProfileStore(
            storePath: faeDir.appendingPathComponent("wake_lexicon.json")
        )

        // Seed the UserDefaults enrollment cache synchronously from speakers.json if
        // the key has never been written (first launch with this code, or migration).
        // SpeakerProfileStore.init already loaded profiles from disk — check via the
        // same nonisolated file read so we don't need to await the actor.
        if !UserDefaults.standard.bool(forKey: "fae.owner.enrolled") {
            let speakersURL = faeDir.appendingPathComponent("speakers.json")
            if let data = try? Data(contentsOf: speakersURL),
               let profiles = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               profiles.contains(where: { ($0["role"] as? String) == "owner" })
            {
                UserDefaults.standard.set(true, forKey: "fae.owner.enrolled")
                hasOwnerSetUp = true
            }
        }
    }

    private static func isLowResidentMemoryProfileEnabled() -> Bool {
        CommandLine.arguments.contains("--test-server")
            || ProcessInfo.processInfo.environment["FAE_LOW_MEMORY_TEST_PROFILE"] == "1"
    }

    private let sttEngine = MLXSTTEngine()
    private let llmEngine: any LLMEngine = WorkerLLMEngine(role: .operatorModel)
    private let conciergeLLMEngine: any LLMEngine = WorkerLLMEngine(role: .conciergeModel)
    private let ttsEngine: any TTSEngine = KokoroMLXTTSEngine()
    private let speakerEncoder = CoreMLSpeakerEncoder()
    private let captureManager = AudioCaptureManager()
    private let enrollmentCaptureManager = AudioCaptureManager()
    private let playbackManager = AudioPlaybackManager()
    private let conversationState = ConversationStateTracker()
    private lazy var modelManager = ModelManager(eventBus: eventBus)
    private lazy var approvalManager = ApprovalManager(eventBus: eventBus)
    private var pipelineCoordinator: PipelineCoordinator?
    private var memoryOrchestrator: MemoryOrchestrator?
    private var memoryStore: SQLiteMemoryStore?
    private(set) var memoryInboxService: MemoryInboxService?
    private(set) var memoryDigestService: MemoryDigestService?
    private var entityStore: EntityStore?
    private var entityLinker: EntityLinker?
    private var neuralEmbedder: NeuralEmbeddingEngine?
    private var vectorStore: VectorStore?
    private let speakerProfileStore: SpeakerProfileStore
    private let wakeWordProfileStore: WakeWordProfileStore
    private var skillManagerRef: SkillManager?
    private var scheduler: FaeScheduler?
    private var debugConsoleRef: DebugConsoleController?
    private var vaultManager: GitVaultManager?

    /// Pending query continuations keyed by command name.
    private var pendingQueries: [String: CheckedContinuation<[String: Any]?, Never>] = [:]

    /// Text queued for injection while the pipeline is still loading.
    /// Drained once `pipelineCoordinator` becomes non-nil and pipeline reaches `.running`.
    private var pendingTextInjections: [PendingTextInjection] = []

    // MARK: - Lifecycle

    func start() throws {
        guard pipelineState == .stopped || pipelineState == .error else {
            NSLog("FaeCore: start() ignored — already %@", String(describing: pipelineState))
            return
        }
        eventBus.send(.runtimeState(.starting))
        pipelineState = .starting

        // One-time migrations.
        Self.migrateCustomInstructionsToDirective()
        SkillMigrator.migrateIfNeeded()

        // Ensure user has a copy of SOUL.md on first launch.
        SoulManager.ensureUserCopy()
        HeartbeatManager.ensureUserCopy()

        // Initialize vault (non-blocking — backup failures are logged but not fatal).
        let vault = GitVaultManager()
        self.vaultManager = vault
        Task.detached(priority: .utility) {
            do {
                try await vault.ensureVault()
            } catch {
                NSLog("FaeCore: vault initialization failed: %@", error.localizedDescription)
            }
        }

        // Load models and start pipeline asynchronously.
        Task {
            do {
                let lowResidentMemoryProfileActive = Self.isLowResidentMemoryProfileEnabled()
                var runtimeConfig = config
                if lowResidentMemoryProfileActive {
                    runtimeConfig = runtimeConfig.applyingTestServerMemoryProfile()
                    NSLog("FaeCore: low-resident-memory profile active")
                }

                try await modelManager.loadAll(
                    stt: sttEngine,
                    llm: llmEngine,
                    tts: ttsEngine,
                    speaker: speakerEncoder,
                    speakerProfileStore: speakerProfileStore,
                    config: runtimeConfig
                )

                UserDefaults.standard.set("worker_process", forKey: "fae.runtime.operator_runtime")
                UserDefaults.standard.set("worker_process", forKey: "fae.runtime.concierge_runtime")

                // Initialize memory system.
                let memoryStore = try Self.createMemoryStore()
                let entityStore = EntityStore(dbQueue: await memoryStore.sharedDatabaseQueue)

                // Neural embedding engine — load tier in background, non-blocking.
                let neuralEmbedder = NeuralEmbeddingEngine()
                let ramGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
                let prefersLowResidentMemory = lowResidentMemoryProfileActive
                    || (
                        runtimeConfig.llm.dualModelEnabled
                            && runtimeConfig.llm.keepConciergeHot
                            && FaeConfig.isDualModelEligible(
                                minimumSystemRAMGB: runtimeConfig.llm.dualModelMinSystemRAMGB
                            )
                    )
                let embeddingTier = EmbeddingModelTier.recommendedTier(
                    ramGB: ramGB,
                    prefersLowResidentMemory: prefersLowResidentMemory
                )
                Task.detached(priority: .background) {
                    await neuralEmbedder.loadTier(embeddingTier)
                }
                self.neuralEmbedder = neuralEmbedder

                // Vector store — wraps sqlite-vec virtual tables.
                let vectorStore = VectorStore(dbQueue: await memoryStore.sharedDatabaseQueue)
                self.vectorStore = vectorStore

                // Restore vec0 schema immediately from stored dim so ANN search works on startup.
                if let storedDimStr = try? await memoryStore.readSchemaMeta("embedding_model_dim"),
                   let storedDim = Int(storedDimStr), storedDim > 0
                {
                    try? await vectorStore.ensureSchema(embeddingDim: storedDim)
                }

                let entityLinker = EntityLinker(
                    entityStore: entityStore,
                    vectorStore: vectorStore,
                    embeddingEngine: neuralEmbedder
                )
                let orchestrator = MemoryOrchestrator(
                    store: memoryStore,
                    config: config.memory,
                    entityLinker: entityLinker,
                    entityStore: entityStore,
                    vectorStore: vectorStore,
                    embeddingEngine: neuralEmbedder
                )
                let inboxService = MemoryInboxService(store: memoryStore)
                try? await inboxService.prepareInboxDirectories()
                let digestService = MemoryDigestService(store: memoryStore)
                self.memoryStore = memoryStore
                self.memoryInboxService = inboxService
                self.memoryDigestService = digestService
                self.entityStore = entityStore
                self.entityLinker = entityLinker
                self.memoryOrchestrator = orchestrator

                await self.auditSetupConsistency(memoryStore: memoryStore)

                // One-time background backfill of existing person records → entities.
                EntityBackfillRunner.backfillIfNeeded(
                    memoryStore: memoryStore,
                    entityLinker: entityLinker,
                    entityStore: entityStore
                )

                // Embedding backfill — embeds all records into sqlite-vec (waits for engine load).
                EmbeddingBackfillRunner.backfillIfNeeded(
                    memoryStore: memoryStore,
                    entityStore: entityStore,
                    vectorStore: vectorStore,
                    embeddingEngine: neuralEmbedder
                )

                // Wire context-aware history limits from model selection + user cap.
                let recommendedContext = await modelManager.recommendedContextSize
                // contextSizeTokens == 0 means "auto" — use model-recommended size.
                // Non-zero = user override (capped at recommended to prevent OOM).
                let configuredContext = config.llm.contextSizeTokens
                let contextSize = configuredContext > 0
                    ? min(recommendedContext, configuredContext)
                    : recommendedContext
                // Cap maxTokens to half the context — prevents tiny context tiers
                // (2K/4K) from having a generation budget larger than context itself.
                let effectiveMaxTokens = min(config.llm.maxTokens, contextSize / 2)
                let maxHistory = FaeConfig.recommendedMaxHistory(
                    contextSize: contextSize, maxTokens: effectiveMaxTokens
                )
                await conversationState.setMaxHistory(maxHistory)
                await conversationState.setContextBudget(
                    contextSize: contextSize,
                    reservedTokens: 5000 + effectiveMaxTokens
                )
                NSLog(
                    "FaeCore: context=%d (recommended=%d configured=%d) maxHistory=%d maxTokens=%d",
                    contextSize, recommendedContext, configuredContext, maxHistory, effectiveMaxTokens
                )

                let isRescue = self.rescueMode?.isActive ?? false

                // In rescue mode, override tool mode to read_only.
                var pipelineConfig = runtimeConfig
                if isRescue {
                    pipelineConfig.toolMode = "read_only"
                    NSLog("FaeCore: rescue mode — tool mode forced to read_only")
                }

                let skillManager = SkillManager()
                self.skillManagerRef = skillManager
                await activateAlwaysOnSkills(skillManager: skillManager)
                let registry = ToolRegistry.buildDefault(
                    skillManager: skillManager,
                    speakerEncoder: speakerEncoder,
                    speakerProfileStore: speakerProfileStore,
                    audioCaptureManager: captureManager,
                    audioPlaybackManager: playbackManager,
                    sttEngine: sttEngine,
                    wakeWordProfileStore: wakeWordProfileStore
                )
                let toolAnalytics = try? Self.createToolAnalyticsStore()
                let coordinator = PipelineCoordinator(
                    eventBus: eventBus,
                    capture: captureManager,
                    playback: playbackManager,
                    sttEngine: sttEngine,
                    llmEngine: llmEngine,
                    conciergeEngine: conciergeLLMEngine,
                    ttsEngine: ttsEngine,
                    config: pipelineConfig,
                    conversationState: conversationState,
                    memoryOrchestrator: isRescue ? nil : orchestrator,
                    approvalManager: approvalManager,
                    registry: registry,
                    speakerEncoder: speakerEncoder,
                    speakerProfileStore: speakerProfileStore,
                    wakeWordProfileStore: wakeWordProfileStore,
                    skillManager: skillManager,
                    toolAnalytics: toolAnalytics,
                    modelManager: modelManager,
                    rescueMode: isRescue
                )
                try await coordinator.start()
                pipelineCoordinator = coordinator

                if pipelineConfig.llm.dualModelEnabled && pipelineConfig.llm.keepConciergeHot {
                    Task.detached(priority: .utility) { [weak self] in
                        guard let self else { return }
                        await self.modelManager.loadConciergeIfNeeded(
                            llm: self.conciergeLLMEngine,
                            config: pipelineConfig
                        )
                    }
                } else if pipelineConfig.llm.dualModelEnabled {
                    NSLog("FaeCore: concierge hot-load disabled — leaving concierge cold until explicitly enabled")
                }

                // Sync barge-in setting from AppStorage on startup.
                // bargeInEnabledLive defaults to nil, so we must explicitly
                // set it from the persisted preference.
                let bargeInPref = UserDefaults.standard.object(forKey: "bargeInEnabled") as? Bool
                    ?? config.bargeIn.enabled
                await coordinator.setBargeInEnabled(bargeInPref)
                await coordinator.setPrivacyMode(config.privacy.mode)

                // Wire SelfConfigTool's configPatcher to this FaeCore instance.
                SelfConfigTool.configPatcher = { [weak self] key, value in
                    self?.patchConfig(key: key, payload: ["value": value])
                }

                // Wire debug console if one was set before the coordinator started.
                if let dc = debugConsoleRef {
                    await coordinator.setDebugConsole(dc)
                }

                // Skip scheduler in rescue mode.
                if !isRescue {
                    let sched = FaeScheduler(
                        eventBus: eventBus,
                        memoryOrchestrator: orchestrator,
                        memoryStore: memoryStore,
                        memoryInboxService: inboxService,
                        memoryDigestService: digestService,
                        entityStore: entityStore,
                        vectorStore: vectorStore,
                        embeddingEngine: neuralEmbedder,
                        memoryConfig: config.memory
                    )

                    // Wire persistence store for scheduler state.
                    if let schedulerStore = try? Self.createSchedulerPersistenceStore() {
                        await sched.configurePersistence(store: schedulerStore)
                    }

                    await sched.setVaultManager(vault)
                    await sched.setSpeakHandler { [weak coordinator] text in
                        await coordinator?.speakDirect(text)
                    }
                    await sched.setProactiveQueryHandler { [weak coordinator] prompt, silent, taskId, allowedTools, consentGranted in
                        await coordinator?.injectProactiveQuery(
                            prompt: prompt,
                            silent: silent,
                            taskId: taskId,
                            allowedTools: allowedTools,
                            consentGranted: consentGranted
                        )
                    }
                    await coordinator.setUserInteractionHandler { [weak sched] in
                        await sched?.checkMorningBriefingFallback()
                    }
                    await coordinator.setProactivePresenceHandler { [weak sched] userPresent in
                        guard userPresent else { return }
                        await sched?.recordUserSeen()
                        await sched?.notifyUserDetectedPostQuietHours()
                    }
                    await coordinator.setProactiveScreenContextHandler { [weak sched] hash in
                        await sched?.shouldPersistScreenContext(contentHash: hash) ?? true
                    }

                    await sched.setAwarenessConfig(config.awareness)
                    await sched.setVisionEnabled(config.vision.enabled)
                    await sched.setSpeakerProfileStore(speakerProfileStore)
                    await sched.start()
                    self.scheduler = sched

                    // Observe scheduler update notifications from SchedulerUpdateTool.
                    self.observeSchedulerUpdates()
                } else {
                    NSLog("FaeCore: rescue mode — scheduler skipped")
                }

                // Warm up LLM — first MLX inference compiles Metal shaders.
                // This can take 30–60s on cold start. Running warmup here, before
                // the ready announcement, ensures Fae is actually responsive
                // when she says hello. Subsequent launches are fast because
                // macOS caches the compiled Metal shaders.
                NSLog("FaeCore: warming up LLM...")
                await llmEngine.warmup()
                NSLog("FaeCore: LLM ready for conversation")

                pipelineState = .running
                eventBus.send(.runtimeState(.started))
                NSLog("FaeCore: pipeline started")

                // Drain any text that was queued while models were loading.
                if !pendingTextInjections.isEmpty {
                    NSLog("FaeCore: draining %d queued text injections", pendingTextInjections.count)
                    for injection in pendingTextInjections {
                        switch injection.mode {
                        case .standard:
                            await coordinator.injectText(injection.text)
                        case .desktop:
                            await coordinator.injectDesktopText(injection.text)
                        }
                    }
                    pendingTextInjections.removeAll()
                }

                // Owner enrollment check — hydrate hasOwnerSetUp from the speaker
                // profile store (the single source of truth for owner status).
                // Migration safety: if no owner exists but exactly one non-fae_self
                // profile exists, promote it to owner.
                var hasOwner = await speakerProfileStore.hasOwnerProfile()
                if !hasOwner,
                   let promotedLabel = await speakerProfileStore.promoteSoleHumanProfileToOwnerIfUnambiguous()
                {
                    hasOwner = true
                    NSLog("FaeCore: owner migration promoted label=%@", promotedLabel)
                }

                await MainActor.run {
                    self.hasOwnerSetUp = hasOwner
                    UserDefaults.standard.set(hasOwner, forKey: "fae.owner.enrolled")
                }
                if !hasOwner {
                    NSLog("FaeCore: no owner enrolled — waiting for native enrollment flow")
                }

                // Listen for enrollment_complete to update hasOwnerSetUp.
                self.observeEnrollmentComplete()
                // Listen for mic mute toggle from the UI mic button.
                self.observeMicMuteToggle()
            } catch {
                let errMsg = "FaeCore: failed to start pipeline: \(error.localizedDescription)"
                NSLog("%@", errMsg)
                debugLog(debugConsoleRef, .pipeline, errMsg)
                pipelineState = .error
                eventBus.send(.runtimeState(.error))
            }
        }
    }

    func stop() {
        guard pipelineState == .running || pipelineState == .starting || pipelineState == .stopping else {
            NSLog("FaeCore: stop() ignored — state=%@", String(describing: pipelineState))
            return
        }

        pipelineState = .stopping

        Task {
            // Ensure active generation is interrupted before teardown.
            await pipelineCoordinator?.cancel()

            // Pre-shutdown vault backup.
            if let vault = vaultManager {
                _ = await vault.backup(reason: "pre-shutdown")
            }
            await scheduler?.stop()
            scheduler = nil
            await pipelineCoordinator?.stop()
            pipelineCoordinator = nil
            skillManagerRef = nil
            memoryStore = nil
            memoryInboxService = nil
            memoryDigestService = nil
            entityStore = nil
            entityLinker = nil
            neuralEmbedder = nil
            vectorStore = nil
            pipelineState = .stopped
            eventBus.send(.runtimeState(.stopped))
        }
    }

    /// Stop the pipeline and wait up to `timeoutSeconds` for a clean stopped state.
    @discardableResult
    func stopAndWait(timeoutSeconds: TimeInterval = 8.0) async -> Bool {
        cancel()
        stop()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while pipelineState != .stopped && pipelineState != .error && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let drained = (pipelineState == .stopped || pipelineState == .error)
        if !drained {
            NSLog("FaeCore: stopAndWait timed out in state=%@", String(describing: pipelineState))
        }
        return drained
    }

    /// Cancel the current generation immediately without stopping the pipeline.
    func cancel() {
        Task { await pipelineCoordinator?.cancel() }
    }

    /// Cancel and await full stop — including playback + deferred tools (test harness use).
    func cancelAndWait() async {
        await pipelineCoordinator?.cancelAndWait()
    }

    /// Clear pipeline conversation history (for test harness use).
    func resetConversation() {
        Task { await pipelineCoordinator?.resetConversation() }
    }

    /// Clear pipeline conversation history and await completion (for test harness use).
    func resetConversationAsync() async {
        await pipelineCoordinator?.resetConversation()
    }

    /// Whether any deferred (background) tool jobs are still running (test harness use).
    func hasPendingDeferredTools() async -> Bool {
        await pipelineCoordinator?.hasPendingDeferredTools ?? false
    }

    /// Return raw memory recall context without going through model generation (test harness use).
    func recallMemoryContextForTest(query: String) async -> String? {
        await memoryOrchestrator?.recall(query: query)
    }

    /// Toggle barge-in on/off, persist to config, and update the live pipeline.
    func setBargeInEnabled(_ enabled: Bool) {
        config.bargeIn.enabled = enabled
        persistConfig(reason: "config.patch.barge_in.enabled")
        if let coordinator = pipelineCoordinator {
            Task { await coordinator.setBargeInEnabled(enabled) }
        }
    }

    /// Update the reasoning depth used for future turns.
    func setThinkingLevel(_ level: FaeThinkingLevel) {
        thinkingLevel = level
        thinkingEnabled = level.enablesThinking
        config.llm.thinkingLevel = level.rawValue
        config.llm.thinkingEnabled = level.enablesThinking
        UserDefaults.standard.set(level.rawValue, forKey: "thinkingLevel")
        UserDefaults.standard.set(level.enablesThinking, forKey: "thinkingEnabled")
        persistConfig(reason: "config.patch.thinking_level")
        if let coordinator = pipelineCoordinator {
            Task { await coordinator.setThinkingLevel(level) }
        }
    }

    /// Legacy toggle mapping for older UI surfaces and voice commands.
    func setThinkingEnabled(_ enabled: Bool) {
        setThinkingLevel(enabled ? .balanced : .fast)
    }

    func cycleThinkingLevel() {
        setThinkingLevel(thinkingLevel.next)
    }

    /// Wire the debug console to the pipeline coordinator.
    ///
    /// Must be called from the main actor before or after `start()`. If the
    /// coordinator is already running, the console is wired immediately;
    /// otherwise the reference is stored and applied after the coordinator
    /// is created inside the async `start()` Task.
    func setDebugConsole(_ console: DebugConsoleController?) {
        debugConsoleRef = console
        if let coordinator = pipelineCoordinator {
            Task { await coordinator.setDebugConsole(console) }
        }
    }

    // MARK: - Always-On Skills

    /// Activate built-in skills that should always be available without explicit activation.
    ///
    /// Keeps control-plane behaviors skill.md-driven while preserving low-latency UX.
    private func activateAlwaysOnSkills(skillManager: SkillManager) async {
        _ = await skillManager.activate(skillName: "window-control")
        await syncAwarenessSkills(skillManager: skillManager)
    }

    private func syncAwarenessSkills(skillManager: SkillManager) async {
        let awarenessEnabled = config.awareness.enabled && config.awareness.consentGrantedAt != nil

        if awarenessEnabled, config.awareness.cameraEnabled {
            _ = await skillManager.activate(skillName: "proactive-awareness")
        } else {
            await skillManager.deactivate(skillName: "proactive-awareness")
        }

        if awarenessEnabled, config.awareness.screenEnabled {
            _ = await skillManager.activate(skillName: "screen-awareness")
        } else {
            await skillManager.deactivate(skillName: "screen-awareness")
        }

        if awarenessEnabled, config.awareness.overnightWorkEnabled {
            _ = await skillManager.activate(skillName: "overnight-research")
        } else {
            await skillManager.deactivate(skillName: "overnight-research")
        }

        if awarenessEnabled, config.awareness.enhancedBriefingEnabled {
            _ = await skillManager.activate(skillName: "morning-briefing-v2")
        } else {
            await skillManager.deactivate(skillName: "morning-briefing-v2")
        }
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

        case "tts.preview_voice":
            if let voice = payload["voice"] as? String {
                Task { await pipelineCoordinator?.previewTTSVoice(voice) }
            }

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
            Task { [weak self] in
                guard let self else { return }
                let hasOwnerProfile = await self.speakerProfileStore.hasOwnerProfile()
                let isComplete = VoiceConversationPolicy.shouldCompleteOnboarding(
                    hasOwnerProfile: hasOwnerProfile
                )
                await MainActor.run {
                    self.hasOwnerSetUp = isComplete
                    if isComplete {
                        UserDefaults.standard.set(true, forKey: "fae.owner.enrolled")
                    }
                }
                if isComplete {
                    NSLog("FaeCore: onboarding complete (owner enrolled)")
                } else {
                    NSLog("FaeCore: onboarding completion ignored — owner voice not enrolled yet")
                }
            }

        case "onboarding.reset":
            Task {
                // Clear ALL speaker profiles (owner, fae_self, guests) for clean first-contact.
                await speakerProfileStore.clearAllProfiles()
                await pipelineCoordinator?.setFirstOwnerEnrollmentActive(false)
                hasOwnerSetUp = false
                UserDefaults.standard.set(false, forKey: "fae.owner.enrolled")

                // Reset enrollment-related config to defaults.
                var configChanged = false
                if config.speaker.requireOwnerForTools {
                    config.speaker.requireOwnerForTools = false
                    configChanged = true
                }
                if config.awareness.consentGrantedAt != nil {
                    config.awareness.consentGrantedAt = nil
                    configChanged = true
                }
                if configChanged {
                    persistConfig(reason: "onboarding_reset")
                }

                NSLog("FaeCore: onboarding reset — all profiles cleared, config reset")

                // Restart pipeline so the app returns to the fresh ownerless state.
                NSLog("FaeCore: restarting pipeline for re-enrollment")
                await pipelineCoordinator?.stop()
                pipelineCoordinator = nil
                await scheduler?.stop()
                scheduler = nil
                pipelineState = .stopped
                try? start()
            }

        case "onboarding.advance":
            eventBus.send(.runtimeProgress(stage: "onboarding.advance", progress: 0.0))
            NSLog("FaeCore: onboarding advanced")

        case "onboarding.set_user_name":
            if let name = payload["name"] as? String {
                userName = name
                config.userName = name
                persistConfig(reason: "onboarding.set_user_name")
                NSLog("FaeCore: user name set to '%@'", name)
            }

        case "onboarding.set_contact_info":
            let email = payload["email"] as? String
            let phone = payload["phone"] as? String
            Task {
                await saveOnboardingContactInfo(email: email, phone: phone)
            }

        case "onboarding.set_family_info":
            let relations = payload["relations"] as? [[String: String]] ?? []
            Task {
                await saveOnboardingFamilyInfo(relations: relations)
            }

        case "capability.grant":
            if let cap = payload["capability"] as? String {
                NSLog("FaeCore: capability granted: %@", cap)
            }

        case "capability.deny":
            if let cap = payload["capability"] as? String {
                NSLog("FaeCore: capability denied: %@", cap)
            }

        case "approval.respond":
            // Accept request_id as UInt64, Int, or String (UI button sends String).
            let requestId: UInt64?
            if let id = payload["request_id"] as? UInt64 {
                requestId = id
            } else if let id = payload["request_id"] as? Int {
                requestId = UInt64(id)
            } else if let idStr = payload["request_id"] as? String, let id = UInt64(idStr) {
                requestId = id
            } else {
                requestId = nil
            }
            if let requestId {
                // Check for progressive approval decision (always, approveAllReadOnly, approveAll).
                let decisionStr = payload["decision"] as? String
                let toolName = payload["tool_name"] as? String
                respondToApproval(requestID: requestId, decisionStr: decisionStr, toolName: toolName, payload: payload)
            }

        case "speaker.rename":
            if let label = payload["label"] as? String,
               let displayName = payload["displayName"] as? String
            {
                Task {
                    await speakerProfileStore.rename(label: label, newDisplayName: displayName)
                    NSLog("FaeCore: speaker '%@' renamed to '%@'", label, displayName)
                }
            }

        case "speaker.test":
            Task {
                await pipelineCoordinator?.testSpeakerMatch()
            }

        case "speaker.start_enrollment":
            NotificationCenter.default.post(name: .faeStartNativeEnrollmentRequested, object: nil)

        case "awareness.start_onboarding":
            if let coordinator = pipelineCoordinator,
               let sm = skillManagerRef
            {
                Task {
                    _ = await sm.activate(skillName: "first-launch-onboarding")
                    await coordinator.wake()
                    await coordinator.injectText(
                        "Please guide me through proactive awareness setup now. Follow the first-launch-onboarding skill exactly, ask for explicit consent before any camera use, and explain each step."
                    )
                }
            }

        case "skills.reload":
            Task {
                await scheduler?.triggerTask(id: "skill_health_check")
            }
            NSLog("FaeCore: skills reloaded")

        case "scheduler.create":
            guard let taskName = payload["name"] as? String,
                  !taskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let scheduleType = payload["scheduleType"] as? String ?? payload["schedule_type"] as? String,
                  let action = payload["action"] as? String,
                  !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                NSLog("FaeCore: scheduler.create missing required fields")
                break
            }

            let rawParams = (payload["scheduleParams"] as? [String: Any])
                ?? (payload["schedule_params"] as? [String: Any])
                ?? [:]
            let params = rawParams.compactMapValues { "\($0)" }
            let requestedTools = (payload["allowedTools"] as? [String])
                ?? (payload["allowed_tools"] as? [String])
            let allowedTools = normalizedAutonomousSchedulerTools(from: requestedTools)
            let taskDescription = (payload["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let instructionBody = (payload["instructionBody"] as? String ?? payload["instruction_body"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let id = "user_\(UUID().uuidString.prefix(8).lowercased())"
            var task = SchedulerTask(
                id: id,
                name: taskName.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: "user",
                enabled: true,
                scheduleType: scheduleType,
                scheduleParams: params,
                action: action.trimmingCharacters(in: .whitespacesAndNewlines),
                taskDescription: taskDescription?.isEmpty == true ? nil : taskDescription,
                instructionBody: instructionBody?.isEmpty == true ? nil : instructionBody,
                nextRun: nil,
                allowedTools: allowedTools
            )
            task.nextRun = schedulerNextRunString(for: task, after: Date())
            var tasks = readSchedulerTasks()
            tasks.append(task)
            do {
                try writeSchedulerTasks(tasks)
                NotificationCenter.default.post(
                    name: .faePipelineState,
                    object: nil,
                    userInfo: ["event": "scheduler.created", "id": id]
                )
            } catch {
                NSLog("FaeCore: scheduler.create failed %@", error.localizedDescription)
            }

        case "scheduler.update":
            guard let taskId = payload["id"] as? String else {
                NSLog("FaeCore: scheduler.update missing id")
                break
            }

            var tasks = readSchedulerTasks()
            guard let index = tasks.firstIndex(where: { $0.id == taskId }) else {
                NSLog("FaeCore: scheduler.update unknown task %@", taskId)
                break
            }

            if let name = payload["name"] as? String,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                tasks[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let enabled = payload["enabled"] as? Bool {
                tasks[index].enabled = enabled
                Task { await scheduler?.setTaskEnabled(id: taskId, enabled: enabled) }
            }
            if let scheduleType = payload["scheduleType"] as? String ?? payload["schedule_type"] as? String {
                tasks[index].scheduleType = scheduleType
            }
            let rawParams = (payload["scheduleParams"] as? [String: Any])
                ?? (payload["schedule_params"] as? [String: Any])
            if let rawParams {
                tasks[index].scheduleParams = rawParams.compactMapValues { "\($0)" }
            }
            if let action = payload["action"] as? String,
               !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                tasks[index].action = action.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if payload.keys.contains("description") {
                let description = (payload["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                tasks[index].taskDescription = description?.isEmpty == true ? nil : description
            }
            if payload.keys.contains("instructionBody") || payload.keys.contains("instruction_body") {
                let instructionBody = (payload["instructionBody"] as? String ?? payload["instruction_body"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                tasks[index].instructionBody = instructionBody?.isEmpty == true ? nil : instructionBody
            }
            if payload.keys.contains("allowedTools") || payload.keys.contains("allowed_tools") {
                let requestedTools = (payload["allowedTools"] as? [String])
                    ?? (payload["allowed_tools"] as? [String])
                tasks[index].allowedTools = normalizedAutonomousSchedulerTools(from: requestedTools)
            }
            if payload.keys.contains("scheduleType") || payload.keys.contains("schedule_type")
                || payload.keys.contains("scheduleParams") || payload.keys.contains("schedule_params")
                || (payload["enabled"] as? Bool == true)
            {
                tasks[index].nextRun = schedulerNextRunString(for: tasks[index], after: Date())
            }

            do {
                try writeSchedulerTasks(tasks)
                NotificationCenter.default.post(
                    name: .faePipelineState,
                    object: nil,
                    userInfo: ["event": "scheduler.updated", "id": taskId]
                )
            } catch {
                NSLog("FaeCore: scheduler.update failed %@", error.localizedDescription)
            }

        case "scheduler.delete":
            if let taskId = payload["id"] as? String {
                Task { await scheduler?.deleteUserTask(id: taskId) }
            }

        case "scheduler.trigger_now":
            if let taskId = payload["id"] as? String {
                Task { await scheduler?.triggerTask(id: taskId) }
            }

        case "scheduler.enable":
            if let taskId = payload["id"] as? String {
                Task { await scheduler?.setTaskEnabled(id: taskId, enabled: true) }
            }

        case "scheduler.disable":
            if let taskId = payload["id"] as? String {
                Task { await scheduler?.setTaskEnabled(id: taskId, enabled: false) }
            }

        case "scheduler.set_enabled":
            if let taskId = payload["id"] as? String,
               let enabled = payload["enabled"] as? Bool
            {
                Task { await scheduler?.setTaskEnabled(id: taskId, enabled: enabled) }
            }

        case "scheduler.status":
            if let taskId = payload["id"] as? String {
                Task {
                    let status = await scheduler?.status(taskID: taskId) ?? [:]
                    NSLog("FaeCore: scheduler.status %@", String(describing: status))
                }
            }

        case "scheduler.history":
            if let taskId = payload["id"] as? String {
                Task {
                    let history = await scheduler?.history(taskID: taskId, limit: 20) ?? []
                    NSLog("FaeCore: scheduler.history %@ count=%d", taskId, history.count)
                }
            }

        case "data.delete_all":
            let includeVault = payload["include_vault"] as? Bool ?? false
            Task {
                await resetAllData(includeVault: includeVault)
            }

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
                    "onboarded": hasOwnerSetUp,
                ] as [String: Any],
            ]

        case "config.get":
            let key = payload["key"] as? String ?? ""
            if key == "speaker_profiles" {
                return await speakerProfilesResponse()
            }
            if key == "conversation" {
                return await conversationConfigResponse()
            }
            return configGetResponse(key: key)

        default:
            NSLog("FaeCore: unhandled query '%@'", name)
            return nil
        }
    }

    private func speakerProfilesResponse() async -> [String: Any] {
        let summaries = await speakerProfileStore.profileSummaries()
        let formatter = ISO8601DateFormatter()
        let profiles: [[String: Any]] = summaries.map { s in
            [
                "id": s.id,
                "displayName": s.displayName,
                "role": s.role.rawValue,
                "enrollmentCount": s.enrollmentCount,
                "lastSeen": formatter.string(from: s.lastSeen),
            ]
        }
        return ["payload": ["speaker_profiles": profiles] as [String: Any]]
    }

    private func conversationConfigResponse() async -> [String: Any] {
        let wakeTemplateCount = await wakeWordProfileStore.acousticTemplateCount()
        return [
            "payload": [
                "conversation": [
                    "wake_word": config.conversation.wakeWord,
                    "enabled": config.conversation.enabled,
                    "require_direct_address": config.conversation.requireDirectAddress,
                    "direct_address_followup_s": config.conversation.directAddressFollowupS,
                    "acoustic_wake_enabled": config.conversation.acousticWakeEnabled,
                    "acoustic_wake_threshold": Double(config.conversation.acousticWakeThreshold),
                    "wake_template_count": wakeTemplateCount,
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    func coworkWorkspaceSnapshot() async -> CoworkWorkspaceSnapshot {
        let skillManager = skillManagerRef ?? SkillManager()
        let activeSkillNames = Set(await skillManager.activatedSkillNames())
        let discoveredSkills = await skillManager.discoverSkills()
            .map { metadata in
                CoworkSkillSummary(
                    id: metadata.name,
                    description: metadata.description,
                    type: metadata.type.rawValue,
                    tier: metadata.tier.rawValue,
                    isEnabled: metadata.isEnabled,
                    isActive: activeSkillNames.contains(metadata.name)
                )
            }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive {
                    return lhs.isActive && !rhs.isActive
                }
                return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }

        let registry = ToolRegistry.buildDefault()
        let tools = registry.allTools
            .filter { registry.isToolAllowed($0.name, mode: toolMode, privacyMode: config.privacy.mode) }
            .sorted { $0.name < $1.name }
            .map {
                CoworkToolSummary(
                    name: $0.name,
                    description: $0.description,
                    riskLevel: $0.riskLevel.rawValue
                )
            }

        let schedulerStatuses = await scheduler?.statusAll() ?? []
        let schedulerStatusMap = schedulerStatuses.reduce(into: [String: CoworkSchedulerStatus]()) { result, entry in
            guard let id = entry["id"] as? String else { return }
            let enabled = entry["enabled"] as? Bool ?? true
            let lastRunAt = (entry["last_run_at"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
            result[id] = CoworkSchedulerStatus(enabled: enabled, lastRunAt: lastRunAt)
        }

        return CoworkWorkspaceSnapshot(
            pipelineStateLabel: pipelineState.label,
            toolMode: toolMode,
            thinkingEnabled: thinkingEnabled,
            thinkingLevel: thinkingLevel.rawValue,
            hasOwnerSetUp: hasOwnerSetUp,
            userName: userName,
            tools: tools,
            skills: discoveredSkills,
            schedulerStatusesByID: schedulerStatusMap
        )
    }

    // MARK: - Commands

    func injectText(_ text: String) {
        if let coordinator = pipelineCoordinator {
            Task { await coordinator.injectText(text) }
        } else {
            // Pipeline still loading — queue for delivery when ready.
            pendingTextInjections.append(PendingTextInjection(text: text, mode: .standard))
            NSLog("FaeCore: queued text injection (%d queued) — pipeline not ready", pendingTextInjections.count)
        }
    }

    func injectDesktopText(_ text: String) {
        if let coordinator = pipelineCoordinator {
            Task { await coordinator.injectDesktopText(text) }
        } else {
            pendingTextInjections.append(PendingTextInjection(text: text, mode: .desktop))
            NSLog("FaeCore: queued desktop text injection (%d queued) — pipeline not ready", pendingTextInjections.count)
        }
    }

    /// Speak text directly via TTS without going through the LLM.
    /// Used for system acknowledgments (e.g., "tools enabled").
    func speakDirect(_ text: String) {
        Task { await pipelineCoordinator?.speakDirect(text) }
    }

    func respondToApproval(requestID: UInt64, decisionStr: String?, toolName: String?, payload: [String: Any]) {
        let approved = payload["approved"] as? Bool ?? true
        guard let decision = mapDecision(decisionStr, approved: approved) else { return }
        NSLog(
            "FaeCore: respondToApproval request_id=%llu approved=%@ decision=%@ tool=%@ payload_keys=%@",
            requestID,
            String(describing: approved),
            String(describing: decisionStr),
            String(describing: toolName),
            payload.keys.sorted().joined(separator: ",")
        )

        Task {
            await approvalManager.resolve(requestId: requestID, decision: decision, source: "button")
        }
    }

    func pendingApprovalSnapshots() async -> [[String: Any]] {
        await approvalManager.pendingApprovalSnapshots()
    }

    func mostRecentPendingApprovalID() async -> UInt64? {
        await approvalManager.mostRecentPendingApprovalID()
    }

    func clearPendingApprovalsForTest() async {
        await approvalManager.clearPendingApprovals(source: "test_reset")
    }

    func clearAllToolApprovalsForTest() async {
        await ApprovedToolsStore.shared.revokeAll()
    }

    func clearUserSchedulerTasksForTest() async {
        _ = await scheduler?.deleteAllUserTasksForTest()
    }

    /// Legacy method for simple approved/denied resolution.
    func respondToApproval(requestID: UInt64, approved: Bool) {
        Task {
            let decision: VoiceCommandParser.ApprovalDecision = approved ? .yes : .no
            await approvalManager.resolve(requestId: requestID, decision: decision, source: "button")
        }
    }

    private func mapDecision(_ decisionStr: String?, approved: Bool) -> VoiceCommandParser.ApprovalDecision? {
        guard let decisionStr else {
            return approved ? .yes : .no
        }
        switch decisionStr {
        case "yes": return .yes
        case "no": return .no
        case "always": return .always
        case "approveAllReadOnly": return .approveAllReadOnly
        case "approveAll": return .approveAll
        default: return approved ? .yes : .no
        }
    }

    private func refreshAwarenessRuntime(restartSchedulerTasks: Bool) {
        let awareness = config.awareness
        let schedulerRef = scheduler
        let skillManagerRef = skillManagerRef

        Task {
            if let schedulerRef {
                await schedulerRef.setAwarenessConfig(awareness)
                if restartSchedulerTasks {
                    await schedulerRef.restartAwarenessTasks()
                }
            }
            if let skillManagerRef {
                await syncAwarenessSkills(skillManager: skillManagerRef)
            }
        }
    }

    private func refreshMemoryRuntime() {
        let memory = config.memory
        let orchestratorRef = memoryOrchestrator
        let schedulerRef = scheduler

        Task {
            if let orchestratorRef {
                await orchestratorRef.setConfig(memory)
            }
            if let schedulerRef {
                await schedulerRef.setMemoryConfig(memory)
            }
        }
    }

    func patchConfig(key: String, payload: [String: Any]) {
        NSLog("FaeCore: config.patch key='%@'", key)

        let value = payload["value"]
        switch key {
        case "tool_mode":
            guard let value = value as? String,
                  ["off", "read_only", "read_write", "full", "full_no_approval"].contains(value)
            else { return }
            toolMode = value
            config.toolMode = value
            persistConfig(reason: "config.patch.tool_mode")
            if let coordinator = pipelineCoordinator {
                Task {
                    await coordinator.setToolMode(value)
                }
            }
            // full_no_approval means all tools execute without approval popups.
            // Sync the ApprovedToolsStore so the broker's shouldAutoApprove path
            // short-circuits and bypasses confirmation for every tool in this mode.
            Task {
                await ApprovedToolsStore.shared.setApproveAll(value == "full_no_approval")
            }

        case "privacy.mode":
            guard let value = value as? String,
                  ["strict_local", "local_preferred", "connected"].contains(value)
            else { return }
            config.privacy.mode = value
            persistConfig(reason: "config.patch.privacy.mode")
            if let coordinator = pipelineCoordinator {
                Task {
                    await coordinator.setPrivacyMode(value)
                }
            }

        case "llm.voice_model_preset":
            guard let value = value as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            config.llm.voiceModelPreset = value
            persistConfig(reason: "config.patch.llm.voice_model_preset")

        case "llm.dual_model_enabled":
            guard let enabled = value as? Bool else { return }
            config.llm.dualModelEnabled = enabled
            persistConfig(reason: "config.patch.llm.dual_model_enabled")
            // Reactively stop or start the concierge worker so the change takes
            // effect immediately — no app restart required.
            Task { [weak self] in
                guard let self else { return }
                if enabled {
                    await self.modelManager.loadConciergeIfNeeded(
                        llm: self.conciergeLLMEngine,
                        config: self.config
                    )
                } else {
                    await self.conciergeLLMEngine.shutdown()
                    UserDefaults.standard.set(false, forKey: "fae.runtime.concierge_loaded")
                    UserDefaults.standard.set("dual_model_disabled", forKey: "fae.runtime.fallback_reason")
                    await self.modelManager.publishLocalStackStatus(currentRoute: nil)
                }
            }

        case "llm.concierge_model_preset":
            guard let value = sanitizedString(value), !value.isEmpty else { return }
            let presetChanged = value != config.llm.conciergeModelPreset
            config.llm.conciergeModelPreset = value
            persistConfig(reason: "config.patch.llm.concierge_model_preset")
            // When the preset changes while dual-model is active, reload the
            // concierge worker with the new model — no restart required.
            if presetChanged && config.llm.dualModelEnabled {
                Task { [weak self] in
                    guard let self else { return }
                    await self.conciergeLLMEngine.shutdown()
                    await self.modelManager.loadConciergeIfNeeded(
                        llm: self.conciergeLLMEngine,
                        config: self.config
                    )
                }
            }

        case "llm.remote_provider_preset":
            guard let value = sanitizedString(value), !value.isEmpty else { return }
            config.llm.remoteProviderPreset = value
            persistConfig(reason: "config.patch.llm.remote_provider_preset")

        case "llm.remote_base_url":
            guard let value = sanitizedString(value), !value.isEmpty else { return }
            config.llm.remoteBaseURL = value
            persistConfig(reason: "config.patch.llm.remote_base_url")

        case "llm.remote_model":
            guard let value = sanitizedString(value), !value.isEmpty else { return }
            config.llm.remoteModel = value
            persistConfig(reason: "config.patch.llm.remote_model")

        case "llm.thinking_enabled":
            guard let value = value as? Bool else { return }
            setThinkingEnabled(value)

        case "llm.thinking_level":
            guard let value = sanitizedString(value),
                  let level = FaeThinkingLevel(rawValue: value)
            else { return }
            setThinkingLevel(level)

        case "barge_in.enabled":
            guard let value = value as? Bool else { return }
            setBargeInEnabled(value)

        case "tts.speed":
            let parsedSpeed: Float?
            if let v = value as? Float {
                parsedSpeed = v
            } else if let v = value as? Double {
                parsedSpeed = Float(v)
            } else {
                parsedSpeed = nil
            }
            guard let speed = parsedSpeed else { return }
            config.tts.speed = speed
            persistConfig(reason: "config.patch.tts.speed")
            if let coordinator = pipelineCoordinator {
                Task { await coordinator.setPlaybackSpeed(speed) }
            }

        case "tts.emotional_prosody", "tts.warmth":
            break // Legacy keys — silently ignored (emotional prosody removed in v2.0).

        case "tts.custom_voice_path":
            if let raw = value as? String, raw.lowercased() == "nil" {
                config.tts.customVoicePath = nil
            } else {
                config.tts.customVoicePath = sanitizedString(value)
            }
            persistConfig(reason: "config.patch.tts.custom_voice_path")

        case "tts.custom_reference_text":
            if let raw = value as? String, raw.lowercased() == "nil" {
                config.tts.customReferenceText = nil
            } else {
                config.tts.customReferenceText = sanitizedString(value)
            }
            persistConfig(reason: "config.patch.tts.custom_reference_text")

        case "tts.voice":
            guard let name = sanitizedString(value), !name.isEmpty else { return }
            config.tts.voice = name
            persistConfig(reason: "config.patch.tts.voice")
            if let coordinator = pipelineCoordinator {
                Task { await coordinator.setTTSVoice(name) }
            }

        case "tts.voice_identity_lock":
            guard let lock = value as? Bool else { return }
            config.tts.voiceIdentityLock = lock
            persistConfig(reason: "config.patch.tts.voice_identity_lock")
            if let coordinator = pipelineCoordinator {
                Task { await coordinator.setVoiceIdentityLock(lock) }
            }

        case "tts.default_voice_instruct":
            if let raw = value as? String, raw.lowercased() == "nil" || raw.isEmpty {
                config.tts.defaultVoiceInstruct = nil
            } else {
                config.tts.defaultVoiceInstruct = sanitizedString(value)
            }
            persistConfig(reason: "config.patch.tts.default_voice_instruct")

        case "onboarded":
            break  // Legacy — owner profile presence is now the voice gate

        case "voice_identity.enabled":
            guard let value = value as? Bool else { return }
            config.voiceIdentity.enabled = value
            persistConfig(reason: "config.patch.voice_identity.enabled")

        case "voice_identity.mode":
            guard let value = value as? String,
                  ["assist", "enforce"].contains(value)
            else { return }
            config.voiceIdentity.mode = value
            persistConfig(reason: "config.patch.voice_identity.mode")

        case "voice_identity.approval_requires_match":
            guard let value = value as? Bool else { return }
            config.voiceIdentity.approvalRequiresMatch = value
            config.speaker.requireOwnerForTools = value
            persistConfig(reason: "config.patch.voice_identity.approval_requires_match")

        case "memory.enabled":
            guard let value = value as? Bool else { return }
            config.memory.enabled = value
            persistConfig(reason: "config.patch.memory.enabled")
            refreshMemoryRuntime()

        case "memory.max_recall_results":
            let parsed: Int?
            if let v = value as? Int {
                parsed = v
            } else if let v = value as? Double {
                parsed = Int(v)
            } else {
                parsed = nil
            }
            guard let results = parsed, (1 ... 50).contains(results) else { return }
            config.memory.maxRecallResults = results
            persistConfig(reason: "config.patch.memory.max_recall_results")
            refreshMemoryRuntime()

        case "memory.auto_ingest_inbox":
            guard let enabled = value as? Bool else { return }
            config.memory.autoIngestInbox = enabled
            persistConfig(reason: "config.patch.memory.auto_ingest_inbox")
            refreshMemoryRuntime()

        case "memory.generate_digests":
            guard let enabled = value as? Bool else { return }
            config.memory.generateDigests = enabled
            persistConfig(reason: "config.patch.memory.generate_digests")
            refreshMemoryRuntime()

        case "channels.enabled":
            guard let value = value as? Bool else { return }
            config.channels.enabled = value
            persistConfig(reason: "config.patch.channels.enabled")

        case "channels.discord.bot_token":
            let token = sanitizedString(value)
            updateChannelSecret(key: "channels.discord.bot_token", value: token)
            // Keep inline field cleared after migration to avoid plaintext secrets on disk.
            config.channels.discord.botToken = nil
            persistConfig(reason: "config.patch.channels.discord.bot_token")

        case "channels.discord.guild_id":
            config.channels.discord.guildId = sanitizedString(value)
            persistConfig(reason: "config.patch.channels.discord.guild_id")

        case "channels.discord.allowed_channel_ids":
            if let values = parseStringList(value) {
                config.channels.discord.allowedChannelIds = values
                persistConfig(reason: "config.patch.channels.discord.allowed_channel_ids")
            }

        case "channels.whatsapp.access_token":
            let token = sanitizedString(value)
            updateChannelSecret(key: "channels.whatsapp.access_token", value: token)
            config.channels.whatsapp.accessToken = nil
            persistConfig(reason: "config.patch.channels.whatsapp.access_token")

        case "channels.whatsapp.phone_number_id":
            config.channels.whatsapp.phoneNumberId = sanitizedString(value)
            persistConfig(reason: "config.patch.channels.whatsapp.phone_number_id")

        case "channels.whatsapp.verify_token":
            let token = sanitizedString(value)
            updateChannelSecret(key: "channels.whatsapp.verify_token", value: token)
            config.channels.whatsapp.verifyToken = nil
            persistConfig(reason: "config.patch.channels.whatsapp.verify_token")

        case "channels.whatsapp.allowed_numbers":
            if let values = parseStringList(value) {
                config.channels.whatsapp.allowedNumbers = values
                persistConfig(reason: "config.patch.channels.whatsapp.allowed_numbers")
            }

        case "llm.temperature":
            let parsedTemp: Float?
            if let v = value as? Float {
                parsedTemp = v
            } else if let v = value as? Double {
                parsedTemp = Float(v)
            } else {
                parsedTemp = nil
            }
            guard let temp = parsedTemp, temp >= 0.3, temp <= 1.0 else { return }
            config.llm.temperature = temp
            persistConfig(reason: "config.patch.llm.temperature")

        case "conversation.require_direct_address":
            guard let value = value as? Bool else { return }
            config.conversation.requireDirectAddress = value
            persistConfig(reason: "config.patch.conversation.require_direct_address")
            if let coordinator = pipelineCoordinator {
                Task { await coordinator.setRequireDirectAddress(value) }
            }

        case "conversation.direct_address_followup_s":
            let parsedS: Int?
            if let v = value as? Int {
                parsedS = v
            } else if let v = value as? Double {
                parsedS = Int(v)
            } else {
                parsedS = nil
            }
            guard let seconds = parsedS, seconds >= 5, seconds <= 60 else { return }
            config.conversation.directAddressFollowupS = seconds
            persistConfig(reason: "config.patch.conversation.direct_address_followup_s")

        case "conversation.acoustic_wake_enabled":
            guard let enabled = value as? Bool else { return }
            config.conversation.acousticWakeEnabled = enabled
            persistConfig(reason: "config.patch.conversation.acoustic_wake_enabled")
            if let coordinator = pipelineCoordinator {
                Task { await coordinator.setAcousticWakeEnabled(enabled) }
            }

        case "conversation.acoustic_wake_threshold":
            let parsedThreshold: Float?
            if let v = value as? Float {
                parsedThreshold = v
            } else if let v = value as? Double {
                parsedThreshold = Float(v)
            } else {
                parsedThreshold = nil
            }
            guard let threshold = parsedThreshold, threshold >= 0.50, threshold <= 0.95 else { return }
            config.conversation.acousticWakeThreshold = threshold
            persistConfig(reason: "config.patch.conversation.acoustic_wake_threshold")
            if let coordinator = pipelineCoordinator {
                Task { await coordinator.setAcousticWakeThreshold(threshold) }
            }

        case "vision.enabled":
            guard let enabled = value as? Bool else { return }
            config.vision.enabled = enabled
            persistConfig(reason: "config.patch.vision.enabled")
            if let coordinator = pipelineCoordinator {
                Task { await coordinator.setVisionEnabled(enabled) }
            }
            if let sched = scheduler {
                Task { await sched.setVisionEnabled(enabled) }
            }

        case "vision.model_preset", "vision.modelPreset":
            guard let preset = value as? String,
                  !preset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            let raw = preset.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized: String
            switch raw {
            case "qwen3_vl_8b":
                normalized = "qwen3_vl_4b_8bit"
            case "qwen3_vl_4b":
                normalized = "qwen3_vl_4b_4bit"
            default:
                normalized = raw
            }
            let allowed = ["auto", "qwen3_vl_4b_4bit", "qwen3_vl_4b_8bit"]
            guard allowed.contains(normalized) else { return }
            config.vision.modelPreset = normalized
            persistConfig(reason: "config.patch.vision.model_preset")

        case "awareness.enabled":
            guard let enabled = value as? Bool else { return }
            config.awareness.enabled = enabled
            persistConfig(reason: "config.patch.awareness.enabled")
            refreshAwarenessRuntime(restartSchedulerTasks: true)

        case "awareness.consent_granted":
            guard let granted = value as? Bool else { return }
            config.awareness.consentGrantedAt = granted
                ? ISO8601DateFormatter().string(from: Date())
                : nil
            persistConfig(reason: "config.patch.awareness.consent_granted")
            refreshAwarenessRuntime(restartSchedulerTasks: true)

        case "awareness.camera_enabled":
            guard let enabled = value as? Bool else { return }
            config.awareness.cameraEnabled = enabled
            persistConfig(reason: "config.patch.awareness.camera_enabled")
            refreshAwarenessRuntime(restartSchedulerTasks: true)

        case "awareness.screen_enabled":
            guard let enabled = value as? Bool else { return }
            config.awareness.screenEnabled = enabled
            persistConfig(reason: "config.patch.awareness.screen_enabled")
            refreshAwarenessRuntime(restartSchedulerTasks: true)

        case "awareness.camera_interval_seconds":
            let parsed: Int?
            if let v = value as? Int { parsed = v }
            else if let v = value as? Double { parsed = Int(v) }
            else { parsed = nil }
            guard let interval = parsed, (10 ... 120).contains(interval) else { return }
            config.awareness.cameraIntervalSeconds = interval
            persistConfig(reason: "config.patch.awareness.camera_interval_seconds")
            refreshAwarenessRuntime(restartSchedulerTasks: true)

        case "awareness.screen_interval_seconds":
            let parsed: Int?
            if let v = value as? Int { parsed = v }
            else if let v = value as? Double { parsed = Int(v) }
            else { parsed = nil }
            guard let interval = parsed, (10 ... 120).contains(interval) else { return }
            config.awareness.screenIntervalSeconds = interval
            persistConfig(reason: "config.patch.awareness.screen_interval_seconds")
            refreshAwarenessRuntime(restartSchedulerTasks: true)

        case "awareness.overnight_work":
            guard let enabled = value as? Bool else { return }
            config.awareness.overnightWorkEnabled = enabled
            persistConfig(reason: "config.patch.awareness.overnight_work")
            refreshAwarenessRuntime(restartSchedulerTasks: false)

        case "awareness.enhanced_briefing":
            guard let enabled = value as? Bool else { return }
            config.awareness.enhancedBriefingEnabled = enabled
            persistConfig(reason: "config.patch.awareness.enhanced_briefing")
            refreshAwarenessRuntime(restartSchedulerTasks: false)

        case "awareness.pause_on_battery":
            guard let enabled = value as? Bool else { return }
            config.awareness.pauseOnBattery = enabled
            persistConfig(reason: "config.patch.awareness.pause_on_battery")
            refreshAwarenessRuntime(restartSchedulerTasks: false)

        case "awareness.pause_on_thermal_pressure":
            guard let enabled = value as? Bool else { return }
            config.awareness.pauseOnThermalPressure = enabled
            persistConfig(reason: "config.patch.awareness.pause_on_thermal_pressure")
            refreshAwarenessRuntime(restartSchedulerTasks: false)

        default:
            NSLog("FaeCore: ignoring unknown config key '%@'", key)
        }
    }

    func acceptLicense() {
        isLicenseAccepted = true
        config.licenseAccepted = true
        if !config.startupIntroSeenConfigured {
            config.startupIntroSeen = false
            config.startupIntroSeenConfigured = true
        }
        shouldShowStartupIntro = !config.startupIntroSeen
        persistConfig(reason: "license.accept")
        NSLog("FaeCore: AGPL-3.0 license accepted")
    }

    func markStartupIntroSeen() {
        guard shouldShowStartupIntro else { return }
        shouldShowStartupIntro = false
        config.startupIntroSeen = true
        config.startupIntroSeenConfigured = true
        persistConfig(reason: "startup_intro.seen")
        NSLog("FaeCore: startup intro marked seen")
    }

    /// Listen for voice enrollment completion to update hasOwnerSetUp.
    private var enrollmentCompleteObserver: NSObjectProtocol?

    private func observeEnrollmentComplete() {
        guard enrollmentCompleteObserver == nil else { return }
        enrollmentCompleteObserver = NotificationCenter.default.addObserver(
            forName: .faePipelineState,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?["event"] as? String,
                  event == "pipeline.enrollment_complete"
            else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hasOwnerSetUp = true
                UserDefaults.standard.set(true, forKey: "fae.owner.enrolled")
                Task { await self.pipelineCoordinator?.setFirstOwnerEnrollmentActive(false) }
                var configChanged = false
                if !self.config.voiceIdentity.enabled {
                    self.config.voiceIdentity.enabled = true
                    configChanged = true
                    NSLog("FaeCore: auto-enabled voiceIdentity after enrollment")
                }
                // Owner enrolled — auto-enable owner-only tool gating.
                if !self.config.speaker.requireOwnerForTools {
                    self.config.speaker.requireOwnerForTools = true
                    configChanged = true
                    NSLog("FaeCore: auto-enabled requireOwnerForTools after enrollment")
                }
                if configChanged {
                    self.persistConfig(reason: "owner_enrolled_auto_voice_identity")
                }
                self.refreshAwarenessRuntime(restartSchedulerTasks: false)
                NSLog("FaeCore: owner enrollment complete — hasOwnerSetUp=true")
            }
        }
    }

    /// Observe the mic mute toggle posted by `ConversationController.toggleListening()`.
    ///
    /// Routes the `faeConversationGateSet` notification directly to
    /// `PipelineCoordinator.setMicMuted()` so the audio capture is actually
    /// silenced — the HostCommandBridge path drops it (no backend sender).
    private var micMuteObserver: NSObjectProtocol?
    private func observeMicMuteToggle() {
        guard micMuteObserver == nil else { return }
        micMuteObserver = NotificationCenter.default.addObserver(
            forName: .faeConversationGateSet,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let active = notification.userInfo?["active"] as? Bool else { return }
            Task { [weak self] in
                await self?.pipelineCoordinator?.setMicMuted(!active)
            }
        }
    }

    func completeNativeOwnerEnrollment(displayName: String) {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        userName = trimmedName
        config.userName = trimmedName
        persistConfig(reason: "native_owner_enrollment")

        NotificationCenter.default.post(
            name: .faePipelineState,
            object: nil,
            userInfo: [
                "event": "pipeline.enrollment_complete",
                "payload": [:] as [String: Any],
            ]
        )

        Task { [weak self] in
            await self?.pipelineCoordinator?.wake()
            await self?.pipelineCoordinator?.speakDirect("Thanks, \(trimmedName). I know your voice now.")
        }
    }

    /// Check if an owner voiceprint is enrolled in the speaker profile store.
    func hasOwnerVoiceprint() async -> Bool {
        await speakerProfileStore.hasOwnerProfile()
    }

    /// Mute/unmute the microphone directly without changing conversation gate state.
    ///
    /// Used by the localhost test harness so deterministic injected turns do not
    /// perturb direct-address state or trigger idle/sleep transitions.
    func setMicMutedForTesting(_ muted: Bool) async {
        await pipelineCoordinator?.setMicMuted(muted)
    }

    // MARK: - Audio Injection (for companion relay)

    /// Inject raw PCM audio from a companion device into the speech pipeline.
    func injectAudio(samples: [Float], sampleRate: UInt32 = 16000) {
        Task {
            await pipelineCoordinator?.injectAudio(samples: samples, sampleRate: Int(sampleRate))
        }
        NSLog("FaeCore: injected %d remote audio samples", samples.count)
    }

    // MARK: - Private Helpers

    private func sanitizedString(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseStringList(_ value: Any?) -> [String]? {
        if let arr = value as? [String] {
            return arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let raw = value as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return [] }
            return trimmed
                .split(whereSeparator: { $0 == "," || $0 == "\n" })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return nil
    }

    private func updateChannelSecret(key: String, value: String?) {
        if let value, !value.isEmpty {
            do {
                try CredentialManager.store(key: key, value: value)
            } catch {
                NSLog("FaeCore: failed to store channel secret '%@': %@", key, error.localizedDescription)
            }
        } else {
            CredentialManager.delete(key: key)
        }
    }

    private func auditSetupConsistency(memoryStore: SQLiteMemoryStore) async {
        do {
            let profiles = try await memoryStore.findActiveByKind(.profile, limit: 100)
            let extractedNames = profiles.compactMap { record in
                Self.extractPrimaryName(from: record.text)
            }

            let uniqueNames = Array(Set(extractedNames)).sorted()
            debugLog(debugConsoleRef, .qa, "Setup audit: active_profile_names=\(uniqueNames)")
            if uniqueNames.count > 1 {
                debugLog(debugConsoleRef, .qa, "⚠️ Setup audit conflict: multiple active profile names")
                NSLog("FaeCore: setup audit warning — conflicting active profile names: %@", uniqueNames.joined(separator: ", "))
            }

            if config.userName == nil, uniqueNames.count == 1, let recovered = uniqueNames.first {
                config.userName = recovered
                userName = recovered
                persistConfig(reason: "setup.audit.recover_user_name")
                debugLog(debugConsoleRef, .qa, "Setup audit repaired config.userName from memory: \(recovered)")
                NSLog("FaeCore: setup audit recovered userName from memory profile: %@", recovered)
            }

            let hasOwner = await speakerProfileStore.hasOwnerProfile()
            if config.speaker.requireOwnerForTools && !hasOwner {
                debugLog(debugConsoleRef, .qa, "⚠️ Setup audit: owner required for tools but no owner profile enrolled")
                NSLog("FaeCore: setup audit warning — requireOwnerForTools=true but no owner voice profile is enrolled")
            }

            if hasOwner && !config.voiceIdentity.enabled {
                debugLog(debugConsoleRef, .qa, "Setup audit repair: enabling voice identity because an owner profile exists")
                NSLog("FaeCore: setup audit repair — enabling voice identity because an owner profile exists")
                config.voiceIdentity.enabled = true
                persistConfig(reason: "setup.audit.enable_voice_identity")
            }

            if config.voiceIdentity.approvalRequiresMatch && !config.voiceIdentity.enabled {
                debugLog(debugConsoleRef, .qa, "Setup audit repair: approvalRequiresMatch=true while voiceIdentity.enabled=false — disabling approvalRequiresMatch")
                NSLog("FaeCore: setup audit repair — disabling approvalRequiresMatch because voiceIdentity is disabled")
                config.voiceIdentity.approvalRequiresMatch = false
                persistConfig(reason: "setup.audit.voice_identity.approval_requires_match")
            }
        } catch {
            debugLog(debugConsoleRef, .qa, "⚠️ Setup audit failed: \(error.localizedDescription)")
            NSLog("FaeCore: setup audit failed: %@", error.localizedDescription)
        }
    }

    private static func extractPrimaryName(from text: String) -> String? {
        let prefix = "Primary user name is "
        guard text.hasPrefix(prefix) else { return nil }
        let raw = text.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !raw.isEmpty else { return nil }
        return raw
    }

    private static func migrateStartupIntroState(_ config: inout FaeConfig) -> Bool {
        guard !config.startupIntroSeenConfigured else { return false }

        let defaults = UserDefaults.standard
        let hasLegacyKey = defaults.object(forKey: legacyStartupCanvasKey) != nil

        if config.licenseAccepted {
            // Older installs accepted the license before the startup intro moved
            // into config-backed state. Treat those installs as already seen so
            // the crawl remains first-run only.
            config.startupIntroSeen = true
            config.startupIntroSeenConfigured = true
            if hasLegacyKey {
                defaults.removeObject(forKey: legacyStartupCanvasKey)
            }
            return true
        }

        if hasLegacyKey {
            defaults.removeObject(forKey: legacyStartupCanvasKey)
        }

        return false
    }

    private static func migrateChannelSecretsToKeychain(_ config: inout FaeConfig) -> Bool {
        var migrated = false

        func migrate(_ configValue: inout String?, key: String) {
            guard let secret = configValue?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty else {
                return
            }

            if CredentialManager.retrieve(key: key) == nil {
                try? CredentialManager.store(key: key, value: secret)
            }
            configValue = nil
            migrated = true
        }

        migrate(&config.channels.discord.botToken, key: "channels.discord.bot_token")
        migrate(&config.channels.whatsapp.accessToken, key: "channels.whatsapp.access_token")
        migrate(&config.channels.whatsapp.verifyToken, key: "channels.whatsapp.verify_token")

        if migrated {
            NSLog("FaeCore: migrated legacy channel secrets to Keychain")
        }

        return migrated
    }

    private func saveOnboardingContactInfo(email: String?, phone: String?) async {
        guard let memoryStore else {
            NSLog("FaeCore: onboarding contact info received before memory initialized")
            return
        }

        do {
            if let email, !email.isEmpty {
                _ = try await memoryStore.insertRecord(
                    kind: .profile,
                    text: "User email is \(email).",
                    confidence: 0.95,
                    sourceTurnId: "onboarding",
                    tags: ["contact", "email"],
                    importanceScore: 0.90
                )
            }
            if let phone, !phone.isEmpty {
                _ = try await memoryStore.insertRecord(
                    kind: .profile,
                    text: "User phone number is \(phone).",
                    confidence: 0.95,
                    sourceTurnId: "onboarding",
                    tags: ["contact", "phone"],
                    importanceScore: 0.90
                )
            }
            NSLog("FaeCore: onboarding contact info stored")
        } catch {
            NSLog("FaeCore: failed to store onboarding contact info: %@", error.localizedDescription)
        }
    }

    private func saveOnboardingFamilyInfo(relations: [[String: String]]) async {
        guard !relations.isEmpty else { return }
        guard let memoryStore else {
            NSLog("FaeCore: onboarding family info received before memory initialized")
            return
        }

        do {
            for relation in relations {
                let label = relation["label"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "relation"
                guard let name = relation["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty
                else { continue }

                _ = try await memoryStore.insertRecord(
                    kind: .person,
                    text: "User's \(label.lowercased()) is \(name).",
                    confidence: 0.92,
                    sourceTurnId: "onboarding",
                    tags: ["person", "onboarding"],
                    importanceScore: 0.85
                )
            }
            NSLog("FaeCore: onboarding family info stored (%d relations)", relations.count)
        } catch {
            NSLog("FaeCore: failed to store onboarding family info: %@", error.localizedDescription)
        }
    }

    private func resetAllData(includeVault: Bool) async {
        await scheduler?.stop()
        scheduler = nil
        await pipelineCoordinator?.stop()
        pipelineCoordinator = nil
        memoryOrchestrator = nil
        memoryStore = nil
        memoryInboxService = nil
        memoryDigestService = nil
        entityStore = nil
        entityLinker = nil
        neuralEmbedder = nil
        vectorStore = nil
        skillManagerRef = nil

        do {
            let faeDir = try Self.faeDirectory()
            if FileManager.default.fileExists(atPath: faeDir.path) {
                try FileManager.default.removeItem(at: faeDir)
            }

            let legacySkillsDir = SkillManager.legacySkillsDirectory
            if FileManager.default.fileExists(atPath: legacySkillsDir.path) {
                try FileManager.default.removeItem(at: legacySkillsDir)
            }

            let forgeDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".fae-forge", isDirectory: true)
            if FileManager.default.fileExists(atPath: forgeDir.path) {
                try FileManager.default.removeItem(at: forgeDir)
            }

            if includeVault {
                let vaultDir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".fae-vault", isDirectory: true)
                if FileManager.default.fileExists(atPath: vaultDir.path) {
                    try FileManager.default.removeItem(at: vaultDir)
                }
            }

            // Clear ALL UserDefaults (@AppStorage values survive directory deletion
            // since they live in ~/Library/Preferences/, not in the fae data dir).
            if let bundleId = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleId)
            }
            CredentialManager.deleteAll()

            config = FaeConfig()
            hasOwnerSetUp = false
            isLicenseAccepted = false
            shouldShowStartupIntro = false
            userName = nil
            toolMode = config.toolMode
            try config.save()
            NSLog("FaeCore: data reset complete includeVault=%@", includeVault ? "true" : "false")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .faeDataResetCompleted, object: nil)
            }
        } catch {
            NSLog("FaeCore: data reset failed: %@", error.localizedDescription)
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .faeDataResetFailed,
                    object: nil,
                    userInfo: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func handleOnboardingGetState(commandName: String) {
        if let continuation = pendingQueries.removeValue(forKey: commandName) {
            continuation.resume(returning: [
                "payload": ["onboarded": hasOwnerSetUp] as [String: Any],
            ])
        }
    }

    private func persistConfig(reason: String) {
        do {
            try config.save()
            NSLog("FaeCore: config persisted (%@)", reason)
            // Fast config-only vault backup.
            if let vault = vaultManager {
                Task.detached(priority: .utility) {
                    _ = await vault.backupConfigOnly(changeKey: reason)
                }
            }
        } catch {
            NSLog("FaeCore: failed to persist config (%@): %@", reason, error.localizedDescription)
        }
    }

    /// One-time migration: rename custom_instructions.txt → directive.md.
    private static func migrateCustomInstructionsToDirective() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }

        let oldPath = appSupport.appendingPathComponent("fae/custom_instructions.txt")
        let newPath = appSupport.appendingPathComponent("fae/directive.md")

        if fm.fileExists(atPath: oldPath.path) && !fm.fileExists(atPath: newPath.path) {
            do {
                try fm.moveItem(at: oldPath, to: newPath)
                NSLog("FaeCore: migrated custom_instructions.txt → directive.md")
            } catch {
                NSLog("FaeCore: failed to migrate instructions file: %@", error.localizedDescription)
            }
        }
    }

    private func handleConfigGet(key: String, commandName: String) {
        if let continuation = pendingQueries.removeValue(forKey: commandName) {
            continuation.resume(returning: configGetResponse(key: key))
        }
    }

    private static func appSupportDirectory() throws -> URL {
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            return appSupport
        }

        throw NSError(
            domain: "FaeCore",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Application Support directory unavailable"]
        )
    }

    /// `~/Library/Application Support/fae/` — the root data directory for Fae.
    private static func faeDirectory() throws -> URL {
        try appSupportDirectory().appendingPathComponent("fae")
    }

    /// Memory database path: ~/Library/Application Support/fae/fae.db
    private static func createMemoryStore() throws -> SQLiteMemoryStore {
        let dbPath = try faeDirectory().appendingPathComponent("fae.db").path
        return try SQLiteMemoryStore(path: dbPath)
    }

    /// Scheduler persistence database path.
    private static func createSchedulerPersistenceStore() throws -> SchedulerPersistenceStore {
        let dbPath = try faeDirectory().appendingPathComponent("scheduler.db").path
        return try SchedulerPersistenceStore(path: dbPath)
    }

    /// Tool analytics database path.
    private static func createToolAnalyticsStore() throws -> ToolAnalytics {
        let dbPath = try faeDirectory().appendingPathComponent("tool_analytics.db").path
        return try ToolAnalytics(path: dbPath)
    }

    /// Handle user response from the tool-mode upgrade popup.
    private func handleToolModeUpgradeResponse(action: String, userInfo: [AnyHashable: Any]) {
        switch action {
        case "set_mode":
            guard let mode = userInfo["mode"] as? String else { return }
            patchConfig(key: "tool_mode", payload: ["value": mode])
        case "start_enrollment":
            NotificationCenter.default.post(name: .faeStartNativeEnrollmentRequested, object: nil)
        case "open_settings":
            NotificationCenter.default.post(name: .faeOpenSettingsRequested, object: nil)
        default:
            break
        }
    }

    /// Observe scheduler notifications emitted by scheduler tools.
    private func observeSchedulerUpdates() {
        let updateObserver = NotificationCenter.default.addObserver(
            forName: .faeSchedulerUpdate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let userInfo = notification.userInfo,
                  let taskId = userInfo["id"] as? String,
                  let enabled = userInfo["enabled"] as? Bool
            else { return }
            Task { await self.scheduler?.setTaskEnabled(id: taskId, enabled: enabled) }
        }

        let triggerObserver = NotificationCenter.default.addObserver(
            forName: .faeSchedulerTrigger,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let taskId = notification.userInfo?["id"] as? String
            else { return }
            Task { await self.scheduler?.triggerTask(id: taskId) }
        }

        // Tool-mode upgrade response (user clicked a button on the popup).
        let toolModeObserver = NotificationCenter.default.addObserver(
            forName: .faeToolModeUpgradeRespond,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let action = notification.userInfo?["action"] as? String else { return }
            let userInfo = notification.userInfo ?? [:]
            Task { @MainActor [weak self] in
                self?.handleToolModeUpgradeResponse(action: action, userInfo: userInfo)
            }
        }

        schedulerObservers = [updateObserver, triggerObserver, toolModeObserver]
    }

    deinit {
        schedulerObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let enrollmentCompleteObserver {
            NotificationCenter.default.removeObserver(enrollmentCompleteObserver)
        }
    }

    private func configGetResponse(key: String) -> [String: Any] {
        switch key {
        case "voice_identity":
            return [
                "payload": [
                    "voice_identity": [
                        "enabled": config.voiceIdentity.enabled,
                        "mode": config.voiceIdentity.mode,
                        "approval_requires_match": config.voiceIdentity.approvalRequiresMatch,
                    ] as [String: Any],
                ] as [String: Any],
            ]
        case "speaker_profiles":
            // Build speaker profiles synchronously from the actor.
            // The caller should use queryCommand for async access.
            return ["payload": ["speaker_profiles": [] as [[String: Any]]] as [String: Any]]
        case "llm":
            return [
                "payload": [
                    "llm": [
                        "voice_model_preset": config.llm.voiceModelPreset,
                        "dual_model_enabled": config.llm.dualModelEnabled,
                        "concierge_model_preset": config.llm.conciergeModelPreset,
                        "dual_model_min_system_ram_gb": config.llm.dualModelMinSystemRAMGB,
                        "keep_concierge_hot": config.llm.keepConciergeHot,
                        "allow_concierge_during_voice_turns": config.llm.allowConciergeDuringVoiceTurns,
                        "thinking_enabled": config.llm.thinkingEnabled,
                        "thinking_level": config.llm.resolvedThinkingLevel.rawValue,
                        "kv_quant_bits": config.llm.kvQuantBits as Any,
                        "max_kv_cache_size": config.llm.maxKVCacheSize as Any,
                        "kv_quant_start_tokens": config.llm.kvQuantStartTokens,
                        "repetition_context_size": config.llm.repetitionContextSize,
                        "prefill_step_size": config.llm.prefillStepSize as Any,
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
        case "tts":
            let runtimeSource = UserDefaults.standard.string(forKey: "fae.tts.runtime_voice_source")
            let runtimeLockApplied = UserDefaults.standard.object(forKey: "fae.tts.runtime_voice_lock_applied") as? Bool
            return [
                "payload": [
                    "tts": [
                        "speed": Double(config.tts.speed),
                        "voice": config.tts.voice,
                        "custom_voice_path": config.tts.customVoicePath as Any,
                        "custom_reference_text": config.tts.customReferenceText as Any,
                        "voice_identity_lock": config.tts.voiceIdentityLock,
                        "runtime_voice_source": runtimeSource as Any,
                        "runtime_voice_lock_applied": runtimeLockApplied as Any,
                    ] as [String: Any],
                ] as [String: Any],
            ]
        case "barge_in":
            return [
                "payload": [
                    "barge_in": [
                        "enabled": config.bargeIn.enabled,
                    ] as [String: Any],
                ] as [String: Any],
            ]
        case "vision":
            return [
                "payload": [
                    "vision": [
                        "enabled": config.vision.enabled,
                        "model_preset": config.vision.modelPreset,
                    ] as [String: Any],
                ] as [String: Any],
            ]
        case "tool_mode":
            return [
                "payload": [
                    "tool_mode": config.toolMode,
                ] as [String: Any],
            ]
        case "privacy":
            return [
                "payload": [
                    "privacy": [
                        "mode": config.privacy.mode,
                    ] as [String: Any],
                ] as [String: Any],
            ]
        case "channels":
            return [
                "payload": [
                    "channels": [
                        "enabled": config.channels.enabled,
                    ] as [String: Any],
                ] as [String: Any],
            ]
        default:
            return ["payload": [:] as [String: Any]]
        }
    }
}
