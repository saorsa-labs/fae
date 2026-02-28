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
    @Published var isOnboarded: Bool
    @Published var isLicenseAccepted: Bool
    @Published var userName: String?
    @Published var toolMode: String = "full"

    /// Rescue mode reference — set by FaeAppDelegate before start().
    weak var rescueMode: RescueMode?

    // MARK: - Subsystems

    private var config: FaeConfig
    private var schedulerObservers: [NSObjectProtocol] = []

    init() {
        let loaded = FaeConfig.load()
        self.config = loaded
        self.isOnboarded = loaded.onboarded
        self.isLicenseAccepted = loaded.licenseAccepted
        self.userName = loaded.userName
        self.toolMode = loaded.toolMode

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        let faeDir = appSupport.appendingPathComponent("fae")
        self.speakerProfileStore = SpeakerProfileStore(
            storePath: faeDir.appendingPathComponent("speakers.json")
        )
    }
    private let sttEngine = MLXSTTEngine()
    private let llmEngine = MLXLLMEngine()
    private let ttsEngine = MLXTTSEngine()
    private let speakerEncoder = CoreMLSpeakerEncoder()
    private let captureManager = AudioCaptureManager()
    private let playbackManager = AudioPlaybackManager()
    private let conversationState = ConversationStateTracker()
    private lazy var modelManager = ModelManager(eventBus: eventBus)
    private lazy var approvalManager = ApprovalManager(eventBus: eventBus)
    private var pipelineCoordinator: PipelineCoordinator?
    private var memoryOrchestrator: MemoryOrchestrator?
    private var memoryStore: SQLiteMemoryStore?
    private var entityStore: EntityStore?
    private var entityLinker: EntityLinker?
    private var neuralEmbedder: NeuralEmbeddingEngine?
    private var vectorStore: VectorStore?
    private let speakerProfileStore: SpeakerProfileStore
    private var scheduler: FaeScheduler?

    /// Pending query continuations keyed by command name.
    private var pendingQueries: [String: CheckedContinuation<[String: Any]?, Never>] = [:]

    // MARK: - Lifecycle

    func start() throws {
        guard pipelineState == .stopped || pipelineState == .error else {
            NSLog("FaeCore: start() ignored — already %@", String(describing: pipelineState))
            return
        }
        eventBus.send(.runtimeState(.starting))
        pipelineState = .starting

        // Ensure user has a copy of SOUL.md on first launch.
        SoulManager.ensureUserCopy()

        // Load models and start pipeline asynchronously.
        Task {
            do {
                try await modelManager.loadAll(
                    stt: sttEngine,
                    llm: llmEngine,
                    tts: ttsEngine,
                    speaker: speakerEncoder,
                    speakerProfileStore: speakerProfileStore,
                    config: config
                )

                // Initialize memory system.
                let memoryStore = try Self.createMemoryStore()
                let entityStore = EntityStore(dbQueue: await memoryStore.sharedDatabaseQueue)

                // Neural embedding engine — load tier in background, non-blocking.
                let neuralEmbedder = NeuralEmbeddingEngine()
                let ramGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
                let embeddingTier = EmbeddingModelTier.recommendedTier(ramGB: ramGB)
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
                self.memoryStore = memoryStore
                self.entityStore = entityStore
                self.entityLinker = entityLinker
                self.memoryOrchestrator = orchestrator

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

                // Wire context-aware history limits from model selection.
                let contextSize = await modelManager.recommendedContextSize
                let maxHistory = FaeConfig.recommendedMaxHistory(
                    contextSize: contextSize, maxTokens: config.llm.maxTokens
                )
                await conversationState.setMaxHistory(maxHistory)
                await conversationState.setContextBudget(
                    contextSize: contextSize,
                    reservedTokens: 5000 + config.llm.maxTokens
                )
                NSLog("FaeCore: context=%d maxHistory=%d", contextSize, maxHistory)

                let isRescue = self.rescueMode?.isActive ?? false

                // In rescue mode, override tool mode to read_only.
                var pipelineConfig = config
                if isRescue {
                    pipelineConfig.toolMode = "read_only"
                    NSLog("FaeCore: rescue mode — tool mode forced to read_only")
                }

                let registry = ToolRegistry.buildDefault()
                let coordinator = PipelineCoordinator(
                    eventBus: eventBus,
                    capture: captureManager,
                    playback: playbackManager,
                    sttEngine: sttEngine,
                    llmEngine: llmEngine,
                    ttsEngine: ttsEngine,
                    config: pipelineConfig,
                    conversationState: conversationState,
                    memoryOrchestrator: isRescue ? nil : orchestrator,
                    approvalManager: approvalManager,
                    registry: registry,
                    speakerEncoder: speakerEncoder,
                    speakerProfileStore: speakerProfileStore,
                    rescueMode: isRescue
                )
                try await coordinator.start()
                pipelineCoordinator = coordinator

                // Skip scheduler in rescue mode.
                if !isRescue {
                    let sched = FaeScheduler(
                        eventBus: eventBus,
                        memoryOrchestrator: orchestrator,
                        memoryStore: memoryStore,
                        entityStore: entityStore,
                        vectorStore: vectorStore,
                        embeddingEngine: neuralEmbedder
                    )

                    // Wire persistence store for scheduler state.
                    if let schedulerStore = try? Self.createSchedulerPersistenceStore() {
                        await sched.configurePersistence(store: schedulerStore)
                    }

                    await sched.setSpeakHandler { [weak coordinator] text in
                        await coordinator?.speakDirect(text)
                    }
                    await sched.start()
                    self.scheduler = sched

                    // Observe scheduler update notifications from SchedulerUpdateTool.
                    self.observeSchedulerUpdates()
                } else {
                    NSLog("FaeCore: rescue mode — scheduler skipped")
                }

                pipelineState = .running
                eventBus.send(.runtimeState(.started))
                NSLog("FaeCore: pipeline started")

                // First launch greeting — Fae introduces herself.
                if !config.onboarded {
                    let greeting: String
                    if let name = config.userName, !name.isEmpty {
                        greeting = "Hello \(name). I'm Fae, your personal AI companion."
                    } else {
                        greeting = "Hello. I'm Fae, your personal AI companion."
                    }
                    await coordinator.speakDirect(greeting)
                }
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
            memoryStore = nil
            entityStore = nil
            entityLinker = nil
            neuralEmbedder = nil
            vectorStore = nil
            pipelineState = .stopped
            eventBus.send(.runtimeState(.stopped))
        }
    }

    /// Cancel the current generation immediately without stopping the pipeline.
    func cancel() {
        Task { await pipelineCoordinator?.cancel() }
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
            if let requestId = payload["request_id"] as? UInt64,
               let approved = payload["approved"] as? Bool
            {
                respondToApproval(requestID: requestId, approved: approved)
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

        case "skills.reload":
            Task {
                await scheduler?.triggerTask(id: "skill_health_check")
            }
            NSLog("FaeCore: skills reloaded")

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
            Task {
                await resetAllData()
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
                    "onboarded": isOnboarded,
                ] as [String: Any],
            ]

        case "config.get":
            let key = payload["key"] as? String ?? ""
            if key == "speaker_profiles" {
                return await speakerProfilesResponse()
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

    // MARK: - Commands

    func injectText(_ text: String) {
        Task { await pipelineCoordinator?.injectText(text) }
    }

    func respondToApproval(requestID: UInt64, approved: Bool) {
        eventBus.send(.approvalResolved(id: requestID, approved: approved, source: "button"))
        Task { await approvalManager.resolve(requestId: requestID, approved: approved) }
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

        case "llm.voice_model_preset":
            guard let value = value as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            config.llm.voiceModelPreset = value
            persistConfig(reason: "config.patch.llm.voice_model_preset")

        case "onboarded":
            guard let value = value as? Bool else { return }
            isOnboarded = value
            config.onboarded = value
            persistConfig(reason: "config.patch.onboarded")

        case "voice_identity.enabled":
            guard let value = value as? Bool else { return }
            config.voiceIdentity.enabled = value
            // Keep speaker gating aligned with identity toggle.
            config.speaker.enabled = value
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

        case "channels.enabled":
            guard let value = value as? Bool else { return }
            config.channels.enabled = value
            persistConfig(reason: "config.patch.channels.enabled")

        case "channels.discord.bot_token":
            config.channels.discord.botToken = sanitizedString(value)
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
            config.channels.whatsapp.accessToken = sanitizedString(value)
            persistConfig(reason: "config.patch.channels.whatsapp.access_token")

        case "channels.whatsapp.phone_number_id":
            config.channels.whatsapp.phoneNumberId = sanitizedString(value)
            persistConfig(reason: "config.patch.channels.whatsapp.phone_number_id")

        case "channels.whatsapp.verify_token":
            config.channels.whatsapp.verifyToken = sanitizedString(value)
            persistConfig(reason: "config.patch.channels.whatsapp.verify_token")

        case "channels.whatsapp.allowed_numbers":
            if let values = parseStringList(value) {
                config.channels.whatsapp.allowedNumbers = values
                persistConfig(reason: "config.patch.channels.whatsapp.allowed_numbers")
            }

        default:
            NSLog("FaeCore: ignoring unknown config key '%@'", key)
        }
    }

    func acceptLicense() {
        isLicenseAccepted = true
        config.licenseAccepted = true
        persistConfig(reason: "license.accept")
        NSLog("FaeCore: AGPL-3.0 license accepted")
    }

    func completeOnboarding() {
        isOnboarded = true
        config.onboarded = true
        persistConfig(reason: "onboarding.complete")
        NSLog("FaeCore: onboarding complete")
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

    private func resetAllData() async {
        await scheduler?.stop()
        scheduler = nil
        await pipelineCoordinator?.stop()
        pipelineCoordinator = nil
        memoryStore = nil

        do {
            let faeDir = try Self.faeDirectory()
            if FileManager.default.fileExists(atPath: faeDir.path) {
                try FileManager.default.removeItem(at: faeDir)
            }

            let customSkillsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".fae/skills", isDirectory: true)
            if FileManager.default.fileExists(atPath: customSkillsDir.path) {
                try FileManager.default.removeItem(at: customSkillsDir)
            }

            config = FaeConfig()
            isOnboarded = false
            isLicenseAccepted = false
            userName = nil
            toolMode = config.toolMode
            try config.save()
            NSLog("FaeCore: data reset complete")
        } catch {
            NSLog("FaeCore: data reset failed: %@", error.localizedDescription)
        }
    }

    private func handleOnboardingGetState(commandName: String) {
        if let continuation = pendingQueries.removeValue(forKey: commandName) {
            continuation.resume(returning: [
                "payload": ["onboarded": isOnboarded] as [String: Any],
            ])
        }
    }

    private func persistConfig(reason: String) {
        do {
            try config.save()
            NSLog("FaeCore: config persisted (%@)", reason)
        } catch {
            NSLog("FaeCore: failed to persist config (%@): %@", reason, error.localizedDescription)
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

        schedulerObservers = [updateObserver, triggerObserver]
    }

    deinit {
        schedulerObservers.forEach { NotificationCenter.default.removeObserver($0) }
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
        case "llm.voice_model_preset":
            return [
                "payload": [
                    "llm": [
                        "voice_model_preset": config.llm.voiceModelPreset,
                    ] as [String: Any],
                ] as [String: Any],
            ]
        case "tool_mode":
            return [
                "payload": [
                    "tool_mode": config.toolMode,
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
