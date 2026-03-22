import AVFoundation
import AppKit
import CryptoKit
import Foundation
import MLXLMCommon

/// Central voice pipeline: AudioCapture → VAD → STT → LLM → TTS → Playback.
///
/// Wires all pipeline stages together with echo suppression, barge-in,
/// gate/sleep system, inline tool execution, and text injection.
///
/// Replaces: `src/pipeline/coordinator.rs` (5,192 lines)
actor PipelineCoordinator {
    // DeterministicEasyTurnAction, PipelineMode, PipelineDegradedMode, and
    // GateState enums moved to PipelineTypes.swift.

    // MARK: - Dependencies

    private let eventBus: FaeEventBus
    private let capture: AudioCaptureManager
    private let playback: AudioPlaybackManager
    private let sttEngine: MLXSTTEngine
    /// Parakeet TDT streaming ASR fast-path engine (optional).
    /// When available, provides low-latency CTC-based partial transcripts
    /// alongside the growing-buffer Qwen3-ASR slow path.
    private var streamingSTTEngine: (any StreamingSTTEngine)?
    private let llmEngine: any LLMEngine
    private let ttsEngine: any TTSEngine
    private var config: FaeConfig
    private let conversationState: ConversationStateTracker
    private let memoryOrchestrator: MemoryOrchestrator?
    private let sessionStore: SessionStore?
    private let workflowTraceStore: WorkflowTraceStore?
    private let approvalManager: ApprovalManager?
    private let registry: ToolRegistry
    private let actionBroker: any TrustedActionBroker
    private let damageControlPolicy = DamageControlPolicy()
    private var modelLocality: ModelLocality = .local
    private let rateLimiter = ToolRateLimiter()
    private let securityLogger = SecurityEventLogger.shared
    private let outboundGuard = OutboundExfiltrationGuard.shared
    private let speakerEncoder: CoreMLSpeakerEncoder?
    private let speakerProfileStore: SpeakerProfileStore?
    private let wakeWordProfileStore: WakeWordProfileStore?
    private let skillManager: SkillManager?
    private let toolAnalytics: ToolAnalytics?
    private let modelManager: ModelManager?
    private let isRescueMode: Bool
    private let toolExecutor: ToolExecutor

    /// CoWork security intercept — routes all external LLM calls through
    /// ToolExecutor's unified security pipeline. Created lazily by
    /// ``makeCoworkToolExecutor()`` and exposed to FaeCore.
    private(set) var coworkToolExecutor: CoworkToolExecutor?

    /// JSC runtime for executing `<tool_program>` script blocks.
    /// Lazily created on first script execution to avoid unnecessary
    /// JSC overhead when no scripts are used.
    private var jscRuntime: JSCRuntime?

    /// Counter for computer-use action steps per conversation turn (click/type/scroll).
    private var computerUseStepCount: Int = 0
    private static let maxComputerUseSteps = 10


    // MARK: - Debug Console

    /// Optional debug console for real-time pipeline visibility.
    /// Set after init via `setDebugConsole(_:)`.
    private var debugConsole: DebugConsoleController?

    /// Wire up the debug console after initialization.
    func setDebugConsole(_ console: DebugConsoleController?) async {
        debugConsole = console
        await toolExecutor.setDebugConsole(console)
    }

    // MARK: - Live Config Overrides

    /// Live override for reasoning depth — set by FaeCore when the user changes the level.
    /// `nil` means fall back to `config.llm.resolvedThinkingLevel`.
    private var thinkingLevelLive: FaeThinkingLevel?

    /// Update the reasoning depth without restarting the pipeline.
    func setThinkingLevel(_ level: FaeThinkingLevel) {
        thinkingLevelLive = level
    }

    /// Legacy compatibility hook for older call sites.
    func setThinkingEnabled(_ enabled: Bool) {
        thinkingLevelLive = enabled ? .balanced : .fast
    }

    // Barge-in is always enabled — no toggle.

    /// Mute or unmute the microphone capture in response to the UI mic button.
    ///
    /// Sets `AudioCaptureManager.isMuted` so incoming chunks are dropped before
    /// reaching the VAD/STT pipeline. This is a live toggle — no pipeline restart needed.
    func setMicMuted(_ muted: Bool) async {
        await capture.setMuted(muted)
        NSLog("PipelineCoordinator: mic %@", muted ? "muted" : "unmuted")
    }

    /// Live override for tool mode — set by FaeCore when the user changes tool settings.
    /// `nil` means fall back to `config.toolMode`.
    private var toolModeLive: String?

    /// Live override for privacy mode.
    private var privacyModeLive: String?

    /// Update the tool mode without restarting the pipeline.
    func setToolMode(_ mode: String) {
        if isRescueMode {
            toolModeLive = "assistant"
            return
        }
        toolModeLive = mode
        // Dismiss any pending tool-mode upgrade popup.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .faeToolModeUpgradeDismiss, object: nil)
        }
    }

    func setPrivacyMode(_ mode: String) {
        privacyModeLive = mode
    }

    // Turn decision helpers (memory recall, tool visibility, easy turns, arithmetic,
    // name declarations, TTS batching, approval, tool aliases, failure messages)
    // moved to TurnHelpers.swift.
    // Forwarding methods below preserve Self.xxx call sites and test API.

    static func shouldRecallMemoryForTurn(
        firstOwnerEnrollmentActive: Bool,
        userText: String,
        availableToolNames: [String]
    ) -> Bool {
        TurnHelpers.shouldRecallMemoryForTurn(firstOwnerEnrollmentActive: firstOwnerEnrollmentActive, userText: userText, availableToolNames: availableToolNames)
    }

    static func memoryTurnGuidance(for userText: String) -> String? {
        TurnHelpers.memoryTurnGuidance(for: userText)
    }

    static func visibleToolNamesForTurn(
        firstOwnerEnrollmentActive: Bool,
        userText: String,
        availableToolNames: [String],
        proactiveAllowedTools: Set<String>?,
        isConversationContinuation: Bool = false
    ) -> Set<String>? {
        TurnHelpers.visibleToolNamesForTurn(firstOwnerEnrollmentActive: firstOwnerEnrollmentActive, userText: userText, availableToolNames: availableToolNames, proactiveAllowedTools: proactiveAllowedTools, isConversationContinuation: isConversationContinuation)
    }

    static func explicitlyMentionedToolNames(
        in userText: String,
        availableToolNames: [String]
    ) -> Set<String> {
        TurnHelpers.explicitlyMentionedToolNames(in: userText, availableToolNames: availableToolNames)
    }

    static func inferredToolNamesForTurn(
        in userText: String,
        availableToolNames: [String]
    ) -> Set<String> {
        TurnHelpers.inferredToolNamesForTurn(in: userText, availableToolNames: availableToolNames)
    }

    static func shouldSuppressEpisodeRecallForToolSensitiveTurn(
        userText: String,
        availableToolNames: [String]
    ) -> Bool {
        TurnHelpers.shouldSuppressEpisodeRecallForToolSensitiveTurn(userText: userText, availableToolNames: availableToolNames)
    }

    static func deterministicEasyTurnAction(
        for text: String,
        rememberedUserName: String?
    ) -> DeterministicEasyTurnAction? {
        TurnHelpers.deterministicEasyTurnAction(for: text, rememberedUserName: rememberedUserName)
    }

    static func batchedTTSSegments(
        from text: String,
        maxCharacters: Int = 420
    ) -> [String] {
        TurnHelpers.batchedTTSSegments(from: text, maxCharacters: maxCharacters)
    }

    static func shouldAcceptVoiceApprovalResponse(
        awaitingApproval: Bool,
        manualOnlyApprovalPending: Bool,
        assistantSpeaking: Bool
    ) -> Bool {
        TurnHelpers.shouldAcceptVoiceApprovalResponse(awaitingApproval: awaitingApproval, manualOnlyApprovalPending: manualOnlyApprovalPending, assistantSpeaking: assistantSpeaking)
    }

    static func llmFailureFallbackMessage(
        firstOwnerEnrollmentActive: Bool,
        proactiveContextPresent: Bool
    ) -> String? {
        TurnHelpers.llmFailureFallbackMessage(firstOwnerEnrollmentActive: firstOwnerEnrollmentActive, proactiveContextPresent: proactiveContextPresent)
    }

    static func prefersLegacyInlineToolPrompt(modelId: String?) -> Bool {
        TurnHelpers.prefersLegacyInlineToolPrompt(modelId: modelId)
    }

    /// Update the model locality (local vs. non-local co-work) for damage-control policy.
    func setModelLocality(_ locality: ModelLocality) {
        modelLocality = locality
    }

    /// Live override for direct-address policy.
    private var requireDirectAddressLive: Bool?

    /// Live override for acoustic wake detector master switch.
    private var acousticWakeEnabledLive: Bool?

    /// Live override for acoustic wake detector similarity threshold.
    private var acousticWakeThresholdLive: Float?

    /// Live override for vision toggle.
    private var visionEnabledLive: Bool?

    /// Live override for voice identity lock status.
    private var voiceIdentityLockLive: Bool?

    func setRequireDirectAddress(_ enabled: Bool) {
        requireDirectAddressLive = enabled
    }

    func setAcousticWakeEnabled(_ enabled: Bool) {
        acousticWakeEnabledLive = enabled
    }

    func setAcousticWakeThreshold(_ threshold: Float) {
        acousticWakeThresholdLive = threshold
    }

    func setVisionEnabled(_ enabled: Bool) {
        visionEnabledLive = enabled
    }

    func setVoiceIdentityLock(_ enabled: Bool) {
        voiceIdentityLockLive = enabled
    }

    func setVoiceIdentityConfig(enabled: Bool, mode: String, approvalRequiresMatch: Bool) {
        config.voiceIdentity.enabled = enabled
        config.voiceIdentity.mode = mode
        config.voiceIdentity.approvalRequiresMatch = approvalRequiresMatch
        config.speaker.requireOwnerForTools = approvalRequiresMatch
        NSLog("PipelineCoordinator: voice identity updated — enabled=%@ mode=%@ approvalMatch=%@",
              enabled ? "true" : "false", mode, approvalRequiresMatch ? "true" : "false")
    }

    /// Switch the TTS voice live without restarting. No-op if TTS engine is not Kokoro.
    func setTTSVoice(_ voice: String) async {
        if let kokoro = ttsEngine as? KokoroMLXTTSEngine {
            await kokoro.switchVoice(to: voice)
        }
    }

    /// Preview a named voice by synthesizing a short phrase and playing it once.
    func previewTTSVoice(_ voice: String) async {
        guard let kokoro = ttsEngine as? KokoroMLXTTSEngine else { return }
        let phrase = "Hiya, I'm Fae. I've just fed the wee birdies, and I'm feeling quietly cheeky today."
        do {
            guard let buffer = try await kokoro.previewSynthesize(voice: voice, text: phrase),
                  let channelData = buffer.floatChannelData?[0]
            else { return }
            let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
            markAssistantSpeechStarted()
            await playback.enqueue(samples: samples, sampleRate: 24_000, isFinal: true)
        } catch {
            NSLog("PipelineCoordinator: voice preview failed: %@", error.localizedDescription)
        }
    }

    /// Update playback speed live without restarting.
    func setPlaybackSpeed(_ speed: Float) async {
        await playback.setSpeed(speed)
    }

    // MARK: - Pipeline State

    private var mode: PipelineMode = .conversation
    private var degradedMode: PipelineDegradedMode?
    private var gateState: GateState = .idle
    private var vad = VoiceActivityDetector()
    private var echoSuppressor = EchoSuppressor()
    private let vocabularyCorrector = DynamicVocabularyCorrector()
    private var thinkTagStripper = TextProcessing.ThinkTagStripper()
    private var voiceTagStripper = VoiceTagStripper()
    private let keywordSpotter: KeywordSpotter

    /// Micro keyword classifier for audio-based interrupt detection.
    /// When available, classifies accumulated barge-in audio to populate
    /// `PendingBargeIn.hasInterruptKeyword` and `partialTranscript`.
    private var keywordClassifier: MLXKeywordClassifier?

    /// Semantic turn detector for adaptive endpointing.
    /// Predicts end-of-utterance probability from streaming partial transcripts.
    private var turnDetector: MLXTurnDetector?

    /// Most recent EOU probability from the turn detector (0-1).
    /// Fed into `silenceThresholdMs()` for adaptive endpointing.
    private var lastEOUProbability: Float?

    /// Post-VAD speech verifier — rejects music/noise segments.
    private var speechVerifier: MLXSpeechVerifier?

    /// Apple SoundAnalysis classifier — filters speech from music/TV/noise.
    /// Uses Apple's built-in 303-category sound classifier as a pre-filter
    /// before speaker verification.
    private let appleSpeechClassifier = AppleSpeechClassifier()

    /// Minimum audio samples before running keyword classification (500ms at 16kHz).
    private static let keywordClassifierMinSamples = 8_000

    /// Single-slot guard for streaming transcription tasks.
    /// Prevents task pile-up when transcription takes longer than the audio chunk interval.
    private var streamingTranscriptionInFlight: Bool = false

    // MARK: - Speculative Prefill

    /// Task running the speculative KV cache prefill.
    private var speculativePrefillTask: Task<Void, Never>?

    /// System prompt from the last successful generation — used for speculative prefill.
    private var cachedGenerationSystemPrompt: String?

    /// Generation options from the last successful generation.
    private var cachedGenerationOptions: GenerationOptions?

    // MARK: - Atomic-like Flags

    private struct PendingGovernanceAction: Sendable {
        let action: String
        let value: AnySendableValue
        let metadata: [String: String]
        let source: String
        let confirmationPrompt: String
        let successSpeech: String
        let cancelledSpeech: String
    }

    private enum AnySendableValue: Sendable {
        case string(String)
        case bool(Bool)
    }

    private var assistantSpeaking: Bool = false
    private var assistantGenerating: Bool = false
    /// Whether the current turn includes explicit user authorization language.
    private var explicitUserAuthorizationForTurn: Bool = false

    /// Whether the assistant is currently speaking (TTS playback in progress).
    /// Exposed for the test harness to wait until speech completes.
    var isSpeaking: Bool { assistantSpeaking }
    /// Active generation scope for streaming-token isolation across interrupted turns.
    private var activeGenerationID: UUID?
    private var interrupted: Bool = false
    private var interruptedGenerationID: UUID?
    private var awaitingApproval: Bool = false
    /// When true, the current pending approval requires a physical button press.
    /// Voice "yes/no" is rejected and Fae speaks an explanation instead.
    /// Set alongside `awaitingApproval` for damage-control disaster/confirmManual verdicts.
    private var manualOnlyApprovalPending: Bool = false
    private var pendingGovernanceAction: PendingGovernanceAction?

    // MARK: - Speaker Identity State (consolidated in SpeakerGateState)

    /// All speaker identity, enrollment, and streaming speaker gate state.
    private var speakerGate = SpeakerGateState()
    private var wakeAliases: [String] = TextProcessing.nameVariants

    // MARK: - Timing & Echo Detection

    private var lastAssistantStart: Date?
    private var engagedUntil: Date?
    private var idleRearmTask: Task<Void, Never>?
    /// Set after an explicit user quiet/sleep request so idle owner speech
    /// does not immediately wake Fae again until a fresh wake phrase arrives.
    private var explicitWakeRequiredFromIdle: Bool = false
    /// Throttle for “currently sleeping” hints so we do not spam spoken nudges.
    private var lastSleepHintAt: Date?
    /// Last assistant response text — used to detect echo (mic picking up speaker output).
    private var lastAssistantResponseText: String = ""
    /// Last detected correction — cleared after memory capture.
    private var pendingCorrection: CorrectionRecord?
    /// Final reply text captured for the active remote relay turn, when present.
    private var relayReplyCaptureText: String?

    // MARK: - Barge-In (consolidated in BargeInState)

    /// All barge-in state: pending candidates, suppression, playback barge-in,
    /// deny cooldown, interruption decider, false-interruption recovery,
    /// and generation takeover candidate.
    private var bargeInState: BargeInState

    // MARK: - Phase 1 Observability

    private var pipelineStartedAt: Date?
    private var firstAudioLatencyEmitted: Bool = false
    private let instrumentation = PipelineInstrumentation()

    // lastStreamingPartialTranscript and streamingEpoch moved to speechInputStage.

    // MARK: - Silent Generation Buffer (Phase 1)

    /// Segments captured while the LLM is generating but not yet speaking.
    /// Drained when generation ends so the user's speech isn't lost.
    private var silentGenerationBuffer: [SpeechSegment] = []
    static let maxSilentGenerationBufferSize = 4

    // Generation takeover candidate (Path C) moved to bargeInState.
    // GenerationTakeoverCandidate type in BargeInTypes.swift.

    // MARK: - Pipeline Tasks

    private var pipelineTask: Task<Void, Never>?
    private var captureStream: AsyncStream<AudioChunk>?

    /// Encapsulates the bounded speech segment queue, streaming STT epoch,
    /// and streaming wake detection state.
    private let speechInputStage = SpeechInputStage()

    /// TTS task chain and TTFA telemetry state.
    private let ttsState = TTSState()
    private var currentTurnID: String?
    private var activeConversationSessionID: String?

    private struct WorkflowTraceContext: Sendable {
        let turnID: String
        let source: String
        let userGoal: String
        var sessionID: String?
        var runID: String?
        var toolSequence: [String] = []
        var userApproved: Bool = false
        var damageControlIntervened: Bool = false
    }

    private var workflowTraceContexts: [String: WorkflowTraceContext] = [:]

    private struct PendingSemanticTurn: Sendable {
        let rawText: String
        let text: String
        let ownerProfileExists: Bool
        let speakerAllowsConversation: Bool
        let rms: Float
        let durationSecs: Float
        let acousticWakeDetection: WakeWordAcousticDetector.Detection?
    }

    private var pendingSemanticTurn: PendingSemanticTurn?
    private var pendingSemanticTurnTask: Task<Void, Never>?
    private static let semanticTurnHoldMs: Int = 1200
    private static let conversationalSilenceFloorMs: Int = 1800

    // streamingWakeSamples, speechInputStage.streamingWakeLastEvaluatedSamples, streamingWakeDetection,
    // and acousticWakeEvalStrideSamples moved to speechInputStage.

    /// Stashed segment from `handleSpeechSegment` for acoustic wake template learning.
    private var lastProcessedSegment: SpeechSegment?
    /// Maximum auto-enrolled acoustic wake templates (leave room for explicit enrollment).
    private static let maxAutoWakeTemplates = 6

    // MARK: - Deferred Tool Jobs

    private struct DeferredToolJob: Sendable {
        let id: UUID
        let userText: String
        let toolCalls: [ToolCall]
        let assistantToolMessage: String
        let forceSuppressThinking: Bool
        let capabilityTicket: CapabilityTicket?
        let explicitUserAuthorization: Bool
        let generationContext: GenerationContext
        let originTurnID: String?
    }

    private struct GenerationContext: Sendable {
        let systemPrompt: String
        let turnContextPrefix: String?
        let nativeTools: [[String: any Sendable]]?
        let actionSource: ActionSource
        let playsThinkingTone: Bool
        let allowsAudibleOutput: Bool
    }

    /// In-flight deferred tool tasks keyed by job ID.
    private var deferredToolTasks: [UUID: Task<Void, Never>] = [:]

    /// Whether any deferred tool jobs are currently running (test harness use).
    var hasPendingDeferredTools: Bool { !deferredToolTasks.isEmpty }

    // MARK: - Capability Tickets

    /// Task-scoped capability grant consumed by the broker.
    private var activeCapabilityTicket: CapabilityTicket?
    private var sessionDeclaredUserName: String?

    /// Tracks tool call signatures (name + args) already executed this user turn.
    /// Prevents the LLM looping on identical web_search / calendar calls.
    /// Reset at the start of each new user turn (turnCount == 0, isToolFollowUp == false).
    private var seenToolCallSignatures: Set<String> = []

    // MARK: - Proactive Awareness

    /// Immutable per-turn context for scheduler-initiated proactive queries.
    /// Passed down the current generation call stack (never stored as shared state)
    /// to avoid source/allowlist leakage across concurrent turns.
    struct ProactiveRequestContext: Sendable {
        let source: ActionSource
        let taskId: String
        let allowedTools: Set<String>
        let consentGranted: Bool
        let conversationTag: String
    }

    struct DeferredProactiveRequest: Sendable {
        let prompt: String
        let silent: Bool
        let taskId: String
        let allowedTools: Set<String>
        let consentGranted: Bool
    }

    private var deferredProactiveRequests: [DeferredProactiveRequest] = []

    /// Called on user-initiated turns to let scheduler run morning fallback checks.
    private var userInteractionHandler: (@Sendable () async -> Void)?

    /// Called after proactive camera observations to update scheduler presence state.
    private var proactivePresenceHandler: (@Sendable (Bool) async -> Void)?

    /// Called after proactive screen observations to decide whether to persist context.
    private var proactiveScreenContextHandler: (@Sendable (String) async -> Bool)?

    // MARK: - Init

    init(
        eventBus: FaeEventBus,
        capture: AudioCaptureManager,
        playback: AudioPlaybackManager,
        sttEngine: MLXSTTEngine,
        streamingSTTEngine: (any StreamingSTTEngine)? = nil,
        llmEngine: any LLMEngine,
        ttsEngine: any TTSEngine,
        config: FaeConfig,
        conversationState: ConversationStateTracker,
        memoryOrchestrator: MemoryOrchestrator? = nil,
        sessionStore: SessionStore? = nil,
        workflowTraceStore: WorkflowTraceStore? = nil,
        approvalManager: ApprovalManager? = nil,
        registry: ToolRegistry,
        speakerEncoder: CoreMLSpeakerEncoder? = nil,
        speakerProfileStore: SpeakerProfileStore? = nil,
        wakeWordProfileStore: WakeWordProfileStore? = nil,
        skillManager: SkillManager? = nil,
        toolAnalytics: ToolAnalytics? = nil,
        modelManager: ModelManager? = nil,
        rescueMode: Bool = false
    ) {
        self.eventBus = eventBus
        self.capture = capture
        self.playback = playback
        self.sttEngine = sttEngine
        self.streamingSTTEngine = streamingSTTEngine
        self.llmEngine = llmEngine
        self.ttsEngine = ttsEngine
        self.config = config
        self.conversationState = conversationState
        self.memoryOrchestrator = memoryOrchestrator
        self.sessionStore = sessionStore
        self.workflowTraceStore = workflowTraceStore
        self.approvalManager = approvalManager
        self.registry = registry
        self.actionBroker = DefaultTrustedActionBroker(
            knownTools: Set(registry.toolNames),
            speakerConfig: config.speaker
        )
        self.speakerEncoder = speakerEncoder
        self.speakerProfileStore = speakerProfileStore
        self.wakeWordProfileStore = wakeWordProfileStore
        self.skillManager = skillManager
        self.toolAnalytics = toolAnalytics
        self.modelManager = modelManager
        self.isRescueMode = rescueMode
        self.toolExecutor = ToolExecutor(
            registry: registry,
            actionBroker: self.actionBroker,
            damageControlPolicy: damageControlPolicy,
            rateLimiter: rateLimiter,
            securityLogger: securityLogger,
            outboundGuard: outboundGuard,
            approvalManager: approvalManager,
            workflowTraceStore: workflowTraceStore,
            toolAnalytics: toolAnalytics
        )

        // Build keyword spotter config from existing sleep phrases + interrupt triggers.
        var interruptPhrases = KeywordBiasConfig.defaultInterruptPhrases
        for phrase in config.conversation.sleepPhrases where !interruptPhrases.contains(phrase.lowercased()) {
            interruptPhrases.append(phrase.lowercased())
        }
        self.keywordSpotter = KeywordSpotter(config: KeywordBiasConfig(
            interruptPhrases: interruptPhrases,
            wakePhrases: KeywordBiasConfig.defaultWakePhrases
        ))

        // Configure VAD from config.
        vad.applyConfiguration(config.vad)

        // Initialize barge-in state with interruption decider and recovery tracker.
        let adaptiveConfig = config.bargeIn.adaptive
        let decider: any InterruptionDeciding
        if adaptiveConfig.enabled {
            decider = AdaptiveInterruptionDecider(
                config: adaptiveConfig,
                sampleRate: config.audio.inputSampleRate,
                assistantStartHoldoffMs: config.bargeIn.assistantStartHoldoffMs,
                minRms: config.bargeIn.minRms
            )
        } else {
            decider = LegacyThresholdInterruptionDecider(
                confirmMs: config.bargeIn.confirmMs,
                minRms: config.bargeIn.minRms,
                sampleRate: config.audio.inputSampleRate,
                assistantStartHoldoffMs: config.bargeIn.assistantStartHoldoffMs
            )
        }
        self.bargeInState = BargeInState(
            interruptionDecider: decider,
            falseInterruptionRecovery: FalseInterruptionRecovery(
                timeoutMs: adaptiveConfig.falseInterruptionTimeoutMs,
                enabled: adaptiveConfig.recoverFalseInterruptions
            )
        )

        // Keyword classifier is loaded by ModelManager — wired up in start().
    }

    // MARK: - CoWork Security Executor

    /// Create and store the ``CoworkToolExecutor`` that routes all external
    /// LLM calls through the shared security pipeline.
    ///
    /// Called once by ``FaeCore`` after the pipeline has started. Subsequent
    /// calls are no-ops (returns the existing instance).
    @discardableResult
    func makeCoworkToolExecutor() -> CoworkToolExecutor {
        if let existing = coworkToolExecutor { return existing }
        let executor = CoworkToolExecutor(
            damageControlPolicy: toolExecutor.damageControlPolicy,
            isReady: true,
            securityLogger: SecurityEventLogger.shared,
            eventBus: eventBus
        )
        coworkToolExecutor = executor
        return executor
    }

    // MARK: - Lifecycle

    /// Restart audio capture after enrollment stole the mic.
    ///
    /// Stops the old capture, starts a new one, and relaunches the pipeline
    /// loop task so it iterates over the fresh audio stream. The old pipeline
    /// task exits naturally when the old stream's continuation finishes.
    func restartCapture() async {
        NSLog("PipelineCoordinator: restarting audio capture")
        await capture.stopCapture()
        do {
            let stream = try await capture.startCapture()
            captureStream = stream

            // The old pipelineTask is iterating the old (now-finished) stream
            // and will exit on its own. Start a new loop with the fresh stream.
            pipelineTask = Task { [weak self] in
                guard let self else { return }
                await self.runPipelineLoop(stream: stream)
            }

            NSLog("PipelineCoordinator: audio capture restarted successfully")
        } catch {
            NSLog("PipelineCoordinator: audio capture restart failed: %@", error.localizedDescription)
        }
    }

    func start() async throws {
        guard pipelineTask == nil else { return }

        debugLog(debugConsole, .qa, "Pipeline start requested")
        await toolExecutor.setDelegate(self)
        eventBus.send(.pipelineStateChanged(.starting))

        // Set up playback event handler and voice speed.
        try await playback.setup()
        await playback.setSpeed(config.tts.speed)
        await setPlaybackEventHandler()

        if let wakeStore = wakeWordProfileStore {
            wakeAliases = await wakeStore.allAliases()
            debugLog(debugConsole, .command, "Wake aliases loaded: \(wakeAliases.joined(separator: ", "))")
        }

        // Build dynamic vocabulary corrections from known names.
        await rebuildVocabularyCorrections()

        // Wire keyword classifier and turn detector from ModelManager (non-critical).
        if let mm = modelManager {
            self.keywordClassifier = await mm.keywordClassifier
            self.turnDetector = await mm.turnDetector
            self.speechVerifier = await mm.speechVerifier
        }

        startSpeechSegmentProcessingLoop()

        // Start audio capture.
        let stream = try await capture.startCapture()
        captureStream = stream

        // Setup Apple SoundAnalysis classifier for speech vs music/noise filtering.
        // Uses 16kHz mono format matching the capture pipeline.
        if let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(AudioCaptureManager.targetSampleRate),
            channels: 1,
            interleaved: false
        ) {
            do {
                try await appleSpeechClassifier.setup(format: audioFormat)
            } catch {
                NSLog("PipelineCoordinator: Apple speech classifier setup failed (non-fatal): %@",
                      error.localizedDescription)
            }
        }

        eventBus.send(.pipelineStateChanged(.running))
        pipelineStartedAt = Date()
        await refreshDegradedModeIfNeeded(context: "startup")
        debugLog(debugConsole, .qa, "Pipeline running mode=\(mode.rawValue) toolMode=\(effectiveToolMode())")
        NSLog("PipelineCoordinator: pipeline started in %@ mode", mode.rawValue)

        // Main pipeline loop.
        pipelineTask = Task { [weak self] in
            guard let self else { return }
            await self.runPipelineLoop(stream: stream)
        }
    }

    /// Stop the pipeline.
    func stop() async {
        debugLog(debugConsole, .qa, "Pipeline stop requested")
        markGenerationInterrupted()
        pendingGovernanceAction = nil
        awaitingApproval = false
        manualOnlyApprovalPending = false
        computerUseStepCount = 0
        silentGenerationBuffer.removeAll()
        bargeInState.generationTakeoverCandidate = nil
        speculativePrefillTask?.cancel()
        speculativePrefillTask = nil
        speechInputStage.incrementStreamingEpoch()
        await sttEngine.resetStreaming()
        await streamingSTTEngine?.reset()

        // Ensure any in-flight TTS synthesis task fully exits before teardown.
        let activeTTSTask = ttsState.pendingTask
        ttsState.pendingTask = nil
        activeTTSTask?.cancel()
        await activeTTSTask?.value

        pipelineTask?.cancel()
        pipelineTask = nil
        cancelDeferredToolJobs()
        await stopSpeechSegmentProcessingLoop()
        await closeConversationSessionIfNeeded(reason: "pipeline_stop")
        await abandonAllWorkflowTraces(reason: "Pipeline stopped before workflow completion.")
        await capture.stopCapture()
        await playback.stop()
        await appleSpeechClassifier.teardown()
        await llmEngine.shutdown()
        currentTurnID = nil
        eventBus.send(.pipelineStateChanged(.stopped))
        NSLog("PipelineCoordinator: pipeline stopped")
    }

    /// Cancel the current generation immediately.
    ///
    /// Sets `interrupted = true` and stops audio playback. The pipeline
    /// loop checks `interrupted` at each step and exits cleanly.
    func cancel() {
        markGenerationInterrupted()
        pendingGovernanceAction = nil
        computerUseStepCount = 0
        silentGenerationBuffer.removeAll()
        bargeInState.generationTakeoverCandidate = nil
        speechInputStage.incrementStreamingEpoch()
        speechInputStage.lastStreamingPartialTranscript = nil
        lastFastPathPartial = nil
        lastEOUProbability = nil

        let activeTTSTask = ttsState.pendingTask
        ttsState.pendingTask = nil
        activeTTSTask?.cancel()
        if let activeTTSTask {
            Task { await activeTTSTask.value }
        }

        speculativePrefillTask?.cancel()
        speculativePrefillTask = nil
        Task { [weak self] in
            await self?.sttEngine.resetStreaming()
            await self?.streamingSTTEngine?.reset()
            await self?.playback.stop()
        }
        // Clear generation flag immediately so the pipeline accepts new segments.
        // Without this, a cancel during multi-tool recursion could leave
        // assistantGenerating=true permanently (liveness lock).
        endAssistantGeneration()
        NSLog("PipelineCoordinator: cancelled by user")
    }

    /// Cancel and await full stop — including playback + deferred tools (test harness use).
    func cancelAndWait() async {
        markGenerationInterrupted()
        pendingGovernanceAction = nil
        awaitingApproval = false
        manualOnlyApprovalPending = false
        computerUseStepCount = 0
        silentGenerationBuffer.removeAll()
        bargeInState.generationTakeoverCandidate = nil
        speechInputStage.incrementStreamingEpoch()
        speechInputStage.lastStreamingPartialTranscript = nil
        lastFastPathPartial = nil
        lastEOUProbability = nil
        speculativePrefillTask?.cancel()
        speculativePrefillTask = nil
        await sttEngine.resetStreaming()
        await streamingSTTEngine?.reset()

        let activeTTSTask = ttsState.pendingTask
        ttsState.pendingTask = nil
        activeTTSTask?.cancel()
        await activeTTSTask?.value

        cancelDeferredToolJobs()
        await playback.stop()
        assistantSpeaking = false
        lastAssistantStart = nil
        echoSuppressor.reset()
        // Ensure generation flag is cleared so the pipeline accepts new injections after reset.
        assistantGenerating = false
        awaitingApproval = false
        manualOnlyApprovalPending = false
        await abandonAllWorkflowTraces(reason: "Generation cancelled before workflow completion.")
        NSLog("PipelineCoordinator: cancelAndWait complete")
    }

    private func cancelDeferredToolJobs() {
        for (_, task) in deferredToolTasks {
            task.cancel()
        }
        deferredToolTasks.removeAll()
    }

    // MARK: - Input Request

    /// Request text input from the user asynchronously.
    ///
    /// Delegates to `InputRequestBridge.shared` which posts `.faeInputRequired`,
    /// shows the input card in the UI, and suspends until the user responds.
    /// The 120s timeout is managed by the bridge.
    ///
    /// - Parameters:
    ///   - prompt: Human-readable description of what input is needed.
    ///   - placeholder: Placeholder text for the input field.
    ///   - isSecure: Whether to obscure the input (for passwords/keys).
    /// - Returns: The user's text, or nil if cancelled or timed out.
    func inputRequired(
        prompt: String,
        placeholder: String = "",
        isSecure: Bool = false
    ) async -> String? {
        await InputRequestBridge.shared.request(
            prompt: prompt,
            placeholder: placeholder,
            isSecure: isSecure
        )
    }

    // MARK: - Text Injection

    /// Inject text directly into the LLM (bypasses STT).
    func injectText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Do NOT run the keyword spotter on typed/pasted text. The spotter uses
        // fuzzy matching designed for misheard voice — it false-positives on normal
        // text (e.g. "discord channel" → "cancel"). Text injection is a deliberate
        // user action that should always reach the LLM.

        // Text input is trusted (physically typed by the user at the device).
        speakerGate.currentSpeakerLabel = "owner"
        speakerGate.currentSpeakerDisplayName = await speakerProfileStore?.ownerDisplayName() ?? "Owner"
        speakerGate.currentSpeakerRole = .owner
        speakerGate.currentSpeakerIsOwner = true
        speakerGate.currentSpeakerIsKnownNonOwner = false

        if gateState == .idle {
            // When direct-address gating is off, any text wakes Fae (she should always respond).
            // When gating is on, require the name to avoid responding to ambient conversation.
            guard isAddressedToFae(trimmed) || !effectiveRequireDirectAddress() else {
                debugLog(debugConsole, .pipeline, "Text ignored while sleeping (not addressed)")
                return
            }
            wake()
        } else if effectiveRequireDirectAddress() {
            // Direct-address gating applies to typed text too: when enabled, non-addressed
            // input is dropped unless we're within the follow-up window.
            let inFollowup = engagedUntil.map { Date() < $0 } ?? false
            if !isAddressedToFae(trimmed) && !inFollowup {
                debugLog(debugConsole, .pipeline, "Text ignored (direct-address required, not addressed): \(trimmed)")
                return
            }
        }

        // If assistant is active, trigger barge-in.
        if assistantSpeaking || assistantGenerating {
            markGenerationInterrupted()
            await playback.stop()
        }

        // Handle governance voice commands from injected text (mirrors voice segment processing).
        // This allows test injection and typed input to trigger governance shortcuts (tool mode,
        // thinking toggle, barge-in toggle) without routing through the LLM, which would require
        // approval for self_config even in full_no_approval mode.
        let voiceCmd = VoiceCommandParser.parse(trimmed)
        if voiceCmd != .none {
            if await handleVoiceCommandIfNeeded(voiceCmd, originalText: trimmed) { return }
        }

        await processTranscription(
            text: trimmed,
            wakeMatch: wakeAddressMatch(in: trimmed),
            rms: nil,
            durationSecs: nil,
            turnSource: .text
        )
    }

    /// Inject a normalised channel message with per-sender conversation isolation.
    ///
    /// The caller provides a `ChannelSession` whose history is temporarily loaded
    /// into the shared `ConversationStateTracker` for the duration of this turn.
    /// After the LLM responds, new messages are captured back into the session
    /// and the shared state is restored. This ensures each channel sender has
    /// an independent conversation history.
    ///
    /// - Parameters:
    ///   - message: The normalised `ChannelMessage` from the gateway.
    ///   - session: The per-sender `ChannelSession` holding this sender's history.
    /// - Returns: The assistant's response text, or nil.
    func injectChannelMessage(_ message: ChannelMessage, session: ChannelSession) async -> String? {
        let channel = message.channel.rawValue
        let sender = message.senderId
        let text = message.text

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Swap in the session's history so the LLM sees per-sender context.
        // NOTE: History is restored at the end of this method, not via defer,
        // because defer cannot be async and the fire-and-forget Task pattern
        // races with concurrent channel messages.
        let savedHistory = await conversationState.swapHistory(session.messages)

        // Remote senders are explicitly non-owner.
        speakerGate.currentSpeakerLabel = "channel:\(channel):\(sender)"
        speakerGate.currentSpeakerDisplayName = message.senderDisplayName ?? sender
        speakerGate.currentSpeakerRole = .guest
        speakerGate.currentSpeakerIsOwner = false
        speakerGate.currentSpeakerIsKnownNonOwner = true
        relayReplyCaptureText = nil
        defer { relayReplyCaptureText = nil }

        let assistantCountBefore = session.messages.lazy.filter { $0.role == .assistant }.count

        await processTranscription(
            text: trimmed,
            rms: nil,
            durationSecs: nil,
            turnSource: .relay,
            playsThinkingTone: false,
            allowsAudibleOutput: false
        )

        // Capture new messages generated during this turn back into the session.
        let historyAfter = await conversationState.history
        let assistantCountAfter = historyAfter.lazy.filter { $0.role == .assistant }.count

        // Restore shared conversation state synchronously (not via defer/Task)
        // to prevent race conditions with concurrent channel messages.
        await conversationState.swapHistory(savedHistory)

        // Sync session with whatever the LLM turn produced.
        session.addUserMessage(trimmed)
        if let reply = Self.resolveRelayReply(
            capturedReply: relayReplyCaptureText,
            assistantCountBefore: assistantCountBefore,
            assistantCountAfter: assistantCountAfter,
            assistantHistoryAfter: historyAfter.last(where: { $0.role == .assistant })?.content
        ) {
            session.addAssistantMessage(reply)
            session.trimHistory(maxMessages: 40)
            return reply
        }

        session.trimHistory(maxMessages: 40)
        return nil
    }

    /// Inject text from a remote channel (Discord, WhatsApp, iMessage).
    ///
    /// Unlike `injectText`, this path does NOT grant owner trust: the speaker is
    /// treated as a remote non-owner.  The generated assistant response text is
    /// captured from conversation state and returned so the channel adapter can
    /// send it back as a reply.
    /// TTS playback is suppressed — the response is text-only for the remote user.
    ///
    /// - Note: This is the legacy entry point used by `ChannelManager`. New code
    ///   should use `injectChannelMessage(_:session:)` via `ChannelGateway` for
    ///   per-sender conversation isolation.
    func injectChannelText(channel: String, sender: String, text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let historyBefore = await conversationState.history
        let assistantCountBefore = historyBefore.lazy.filter { $0.role == .assistant }.count

        // Remote senders are explicitly non-owner.
        speakerGate.currentSpeakerLabel = "channel:\(channel):\(sender)"
        speakerGate.currentSpeakerDisplayName = sender
        speakerGate.currentSpeakerRole = .guest
        speakerGate.currentSpeakerIsOwner = false
        speakerGate.currentSpeakerIsKnownNonOwner = true
        relayReplyCaptureText = nil
        defer { relayReplyCaptureText = nil }

        await processTranscription(
            text: trimmed,
            rms: nil,
            durationSecs: nil,
            turnSource: .relay,
            playsThinkingTone: false,
            allowsAudibleOutput: false
        )

        let historyAfter = await conversationState.history
        let assistantCountAfter = historyAfter.lazy.filter { $0.role == .assistant }.count
        let lastAssistant = historyAfter.last(where: { $0.role == .assistant })?.content
        return Self.resolveRelayReply(
            capturedReply: relayReplyCaptureText,
            assistantCountBefore: assistantCountBefore,
            assistantCountAfter: assistantCountAfter,
            assistantHistoryAfter: lastAssistant
        )
    }

    static func resolveRelayReply(
        capturedReply: String?,
        assistantCountBefore: Int,
        assistantCountAfter: Int,
        assistantHistoryAfter: String?
    ) -> String? {
        if let capturedReply = capturedReply?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !capturedReply.isEmpty
        {
            return capturedReply
        }

        guard assistantCountAfter > assistantCountBefore,
              let assistantHistoryAfter = assistantHistoryAfter?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !assistantHistoryAfter.isEmpty
        else {
            return nil
        }

        return assistantHistoryAfter
    }

    private func sendAssistantText(_ text: String, isFinal: Bool) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal, !cleaned.isEmpty {
            relayReplyCaptureText = cleaned
        }
        eventBus.send(.assistantText(text: text, isFinal: isFinal))
    }

    /// Inject text from the desktop cowork surface.
    ///
    /// This path is intentionally silent: it bypasses wake/direct-address gating,
    /// keeps the turn in text mode, and suppresses thinking tones and audio playback.
    func injectDesktopText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let match = await keywordSpotter.check(partialTranscript: trimmed), match.category == .interrupt {
            await resetConversationSession(trigger: trimmed, source: "desktop_text")
            return
        }

        speakerGate.currentSpeakerLabel = "owner"
        speakerGate.currentSpeakerDisplayName = await speakerProfileStore?.ownerDisplayName() ?? "Owner"
        speakerGate.currentSpeakerRole = .owner
        speakerGate.currentSpeakerIsOwner = true
        speakerGate.currentSpeakerIsKnownNonOwner = false

        await processTranscription(
            text: trimmed,
            rms: nil,
            durationSecs: nil,
            turnSource: .text,
            playsThinkingTone: false,
            allowsAudibleOutput: false
        )
    }

    /// Speak text directly via TTS without going through the LLM.
    ///
    /// Used for system messages like the first-launch greeting, command
    /// acknowledgments, and approval responses. Non-interruptible — barge-in
    /// is suppressed for the duration to prevent background noise from cutting
    /// off short utterances.
    func speakDirect(_ text: String) async {
        bargeInState.isSuppressed = true
        defer { bargeInState.isSuppressed = false }
        await speakText(text, isFinal: true)
    }

    /// Speak text with a specific voice description, bypassing the LLM.
    ///
    /// Used for voice preview in roleplay and settings. Non-interruptible.
    func speakWithVoice(_ text: String, voiceInstruct: String) async {
        bargeInState.isSuppressed = true
        defer { bargeInState.isSuppressed = false }
        await speakText(text, isFinal: true, voiceInstruct: voiceInstruct)
    }

    /// Set/clear the first-owner enrollment active flag.
    func setFirstOwnerEnrollmentActive(_ active: Bool) {
        speakerGate.firstOwnerEnrollmentActive = active
        // Clear any deny cooldown from pre-enrollment barge-in attempts.
        bargeInState.denyCooldownUntil = nil
        vad.reset()
        resetStreamingSpeakerGate()
        resetStreamingWakeDetector()
        clearPendingSemanticTurn()
    }

    /// Register a callback fired on each user-initiated turn.
    func setUserInteractionHandler(_ handler: @escaping @Sendable () async -> Void) {
        userInteractionHandler = handler
    }

    /// Register a callback fired after proactive camera observations.
    func setProactivePresenceHandler(_ handler: @escaping @Sendable (Bool) async -> Void) {
        proactivePresenceHandler = handler
    }

    /// Register a callback fired after proactive screen observations.
    func setProactiveScreenContextHandler(_ handler: @escaping @Sendable (String) async -> Bool) {
        proactiveScreenContextHandler = handler
    }

    // MARK: - Proactive Query Injection

    /// Inject a scheduler-initiated proactive query into the LLM pipeline.
    ///
    /// Modelled after `injectText()` but for scheduler-initiated observations.
    /// Uses a per-request `ProactiveRequestContext` (not a shared mutable field)
    /// so actor isolation guarantees no race with user-initiated actions.
    ///
    /// - Parameters:
    ///   - prompt: The proactive observation prompt (e.g. "[PROACTIVE CAMERA OBSERVATION]").
    ///   - silent: If true, appends instruction to only speak if meaningful.
    ///   - taskId: Scheduler task identifier for per-task tool allowlisting.
    ///   - allowedTools: Tools this task is permitted to use.
    ///   - consentGranted: Whether awareness consent is currently active.
    func injectProactiveQuery(
        prompt: String,
        silent: Bool = true,
        taskId: String,
        allowedTools: Set<String>,
        consentGranted: Bool
    ) async {
        let request = DeferredProactiveRequest(
            prompt: prompt,
            silent: silent,
            taskId: taskId,
            allowedTools: allowedTools,
            consentGranted: consentGranted
        )

        guard !assistantGenerating, !assistantSpeaking else {
            enqueueDeferredProactiveRequest(request)
            NSLog("PipelineCoordinator: proactive query deferred — assistant busy")
            return
        }

        await runProactiveQuery(request)
    }

    private func runProactiveQuery(_ request: DeferredProactiveRequest) async {
        let proactiveTag = "\(request.taskId)-\(Int(Date().timeIntervalSince1970 * 1000))"
        let proactiveContext = ProactiveRequestContext(
            source: .scheduler,
            taskId: request.taskId,
            allowedTools: request.allowedTools,
            consentGranted: request.consentGranted,
            conversationTag: proactiveTag
        )

        // Scheduler acts on behalf of the consented owner.
        speakerGate.currentSpeakerLabel = "owner"
        speakerGate.currentSpeakerDisplayName = "Owner"
        speakerGate.currentSpeakerRole = .owner
        speakerGate.currentSpeakerIsOwner = true
        speakerGate.currentSpeakerIsKnownNonOwner = false

        var fullPrompt = request.prompt
        if request.silent {
            fullPrompt += "\n\n[Respond only if you have something meaningful to say. Otherwise stay silent.]"
        }

        debugLog(debugConsole, .pipeline, "Proactive query: taskId=\(request.taskId) silent=\(request.silent)")

        await processTranscription(
            text: fullPrompt,
            wakeMatch: nil,
            rms: nil,
            durationSecs: nil,
            proactiveContext: proactiveContext
        )

        await conversationState.removeMessages(taggedWith: proactiveTag)
    }

    private func enqueueDeferredProactiveRequest(_ request: DeferredProactiveRequest) {
        let taskIDs = Self.coalescedDeferredProactiveTaskIDs(
            existing: deferredProactiveRequests.map(\.taskId),
            incomingTaskID: request.taskId
        )
        deferredProactiveRequests.removeAll { $0.taskId == request.taskId }
        deferredProactiveRequests.append(request)
        debugLog(debugConsole, .pipeline, "Deferred proactive queue: \(taskIDs.joined(separator: ","))")
    }

    private func scheduleDeferredProactiveDrain() {
        guard !assistantGenerating, !assistantSpeaking, !deferredProactiveRequests.isEmpty else { return }
        Task { await drainDeferredProactiveIfIdle() }
    }

    private func drainDeferredProactiveIfIdle() async {
        guard !assistantGenerating, !assistantSpeaking,
              !deferredProactiveRequests.isEmpty
        else {
            return
        }

        let next = deferredProactiveRequests.removeFirst()
        await runProactiveQuery(next)
    }

    /// Test speaker match: record 2 seconds, embed, match against profiles.
    func testSpeakerMatch() async {
        guard let encoder = speakerEncoder, await encoder.isLoaded,
              let store = speakerProfileStore
        else {
            NSLog("PipelineCoordinator: testSpeakerMatch — speaker system not ready")
            return
        }
        do {
            let samples = try await capture.captureSegment(durationSeconds: 2.0)
            let embedding = try await encoder.embed(
                audio: samples,
                sampleRate: AudioCaptureManager.targetSampleRate
            )
            if let match = await store.match(
                embedding: embedding,
                threshold: config.speaker.threshold
            ) {
                NSLog("PipelineCoordinator: testSpeakerMatch — Match: %@ (%.2f)",
                      match.displayName, match.similarity)
            } else {
                NSLog("PipelineCoordinator: testSpeakerMatch — No match")
            }
        } catch {
            NSLog("PipelineCoordinator: testSpeakerMatch failed: %@", error.localizedDescription)
        }
    }

    /// Set one-shot context to be injected into the next LLM system prompt.
    /// Used by the voice enrollment flow to prime Fae's first response to a new owner.
    /// Cleared automatically after the first use.
    func setFirstOwnerEnrollmentContext(_ context: String) {
        speakerGate.firstOwnerEnrollmentContext = context
    }

    /// Inject remote PCM audio into the speech pipeline (e.g. companion handoff).
    func injectAudio(samples: [Float], sampleRate: Int = 16_000) async {
        guard !samples.isEmpty else { return }
        let sr = max(sampleRate, 1)
        let segment = SpeechSegment(
            samples: samples,
            sampleRate: sr,
            durationSeconds: Double(samples.count) / Double(sr),
            capturedAt: Date()
        )
        await handleSpeechSegment(segment)
    }

    /// Reset conversation history (for test harness use).
    func resetConversation() async {
        sleep()
        currentTurnGenerationContext = nil
        engagedUntil = nil
        lastAssistantResponseText = ""
        activeCapabilityTicket = nil
        awaitingApproval = false
        manualOnlyApprovalPending = false
        pendingGovernanceAction = nil
        computerUseStepCount = 0
        ttsState.cancelPending()
        cancelDeferredToolJobs()
        resetStreamingSpeakerGate()
        resetStreamingWakeDetector()
        clearPendingSemanticTurn()
        await closeConversationSessionIfNeeded(reason: "conversation_reset")
        await abandonAllWorkflowTraces(reason: "Conversation reset before workflow completion.")
        await conversationState.clear()
        await llmEngine.resetSession()
        _ = await RoleplaySessionStore.shared.stop()
        _ = await TillDoneManager.shared.clear()
        currentTurnGenerationContext = nil
        currentTurnID = nil
        sessionDeclaredUserName = nil
        assistantSpeaking = false
        lastAssistantStart = nil
        echoSuppressor.reset()
        NSLog("PipelineCoordinator: conversation fully reset (test harness)")
    }

    private func synchronizeLLMSession() async {
        let history = await conversationState.history
        await llmEngine.synchronizeSession(history: history)
    }

    // MARK: - Gate Control

    func wake() {
        gateState = .active
        explicitWakeRequiredFromIdle = false
        engagedUntil = Date().addingTimeInterval(Double(effectiveIdleRearmSeconds()))
        scheduleIdleRearm()
        NSLog("PipelineCoordinator: gate → active")
    }

    func sleep(requireExplicitWake: Bool = false) {
        gateState = .idle
        explicitWakeRequiredFromIdle = requireExplicitWake
        idleRearmTask?.cancel()
        idleRearmTask = nil
        engagedUntil = nil
        if assistantSpeaking || assistantGenerating {
            markGenerationInterrupted()
            Task { await playback.stop() }
        }
        NSLog("PipelineCoordinator: gate → idle")
    }

    func engage() {
        gateState = .active
        explicitWakeRequiredFromIdle = false
        engagedUntil = Date().addingTimeInterval(Double(effectiveIdleRearmSeconds()))
        scheduleIdleRearm()
    }

    private func effectiveToolMode() -> String {
        if isRescueMode {
            return "assistant"
        }
        return toolModeLive ?? config.toolMode
    }

    private func effectivePrivacyMode() -> String {
        if isRescueMode {
            return "strict_local"
        }
        return privacyModeLive ?? config.privacy.mode
    }

    private func currentModelId() -> String? {
        FaeConfig.recommendedModel(preset: config.llm.voiceModelPreset).modelId
    }

    private func effectiveRequireDirectAddress() -> Bool {
        requireDirectAddressLive ?? config.conversation.requireDirectAddress
    }

    private func effectiveAcousticWakeEnabled() -> Bool {
        acousticWakeEnabledLive ?? config.conversation.acousticWakeEnabled
    }

    private func effectiveAcousticWakeThreshold() -> Float {
        acousticWakeThresholdLive ?? config.conversation.acousticWakeThreshold
    }

    private func postVoiceAttentionEvent(_ payload: [String: Any]) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .faePipelineState,
                object: nil,
                userInfo: [
                    "event": "pipeline.voice_attention",
                    "payload": payload,
                ]
            )
        }
    }

    private func publishVoiceAttention(
        stage: String,
        decision: String,
        reason: String,
        transcript: String? = nil,
        wakeSource: String? = nil,
        wakeScore: Float? = nil,
        semanticState: String? = nil,
        rms: Float? = nil
    ) {
        var payload: [String: Any] = [
            "stage": stage,
            "decision": decision,
            "reason": reason,
            "speaker_role": speakerGate.currentSpeakerRole?.rawValue ?? "unknown",
            "gate_state": gateState == .active ? "active" : "idle",
            "require_direct_address": effectiveRequireDirectAddress(),
            "followup_active": engagedUntil.map { Date() < $0 } ?? false,
            "explicit_wake_required": explicitWakeRequiredFromIdle,
            "acoustic_wake_enabled": effectiveAcousticWakeEnabled(),
            "acoustic_wake_threshold": Double(effectiveAcousticWakeThreshold()),
        ]
        if let transcript, !transcript.isEmpty {
            payload["transcript"] = transcript
        }
        if let wakeSource {
            payload["wake_source"] = wakeSource
        }
        if let wakeScore {
            payload["wake_score"] = Double(wakeScore)
        }
        if let semanticState {
            payload["semantic_state"] = semanticState
        }
        if let rms {
            payload["rms"] = Double(rms)
        }
        postVoiceAttentionEvent(payload)
    }

    // Gate/speaker decision helpers (idle rearm, silence threshold, speaker verification,
    // voice attention, semantic turn deferral) moved to GateHelpers.swift.
    // Forwarding methods below preserve Self.xxx call sites and test API.

    static func idleRearmSeconds(
        requireDirectAddress: Bool,
        idleTimeoutS: Int,
        directAddressFollowupS: Int
    ) -> Int {
        GateHelpers.idleRearmSeconds(requireDirectAddress: requireDirectAddress, idleTimeoutS: idleTimeoutS, directAddressFollowupS: directAddressFollowupS)
    }

    static func silenceThresholdMs(
        assistantSpeaking: Bool,
        gateState: GateState,
        inFollowup: Bool,
        hasPendingSemanticTurn: Bool,
        configMinSilenceMs: Int,
        bargeInSilenceMs: Int,
        lastPartialTranscript: String? = nil,
        emaSuggestedMs: Int? = nil,
        eouProbability: Float? = nil
    ) -> Int {
        GateHelpers.silenceThresholdMs(assistantSpeaking: assistantSpeaking, gateState: gateState, inFollowup: inFollowup, hasPendingSemanticTurn: hasPendingSemanticTurn, configMinSilenceMs: configMinSilenceMs, bargeInSilenceMs: bargeInSilenceMs, lastPartialTranscript: lastPartialTranscript, emaSuggestedMs: emaSuggestedMs, eouProbability: eouProbability, conversationalSilenceFloorMs: Self.conversationalSilenceFloorMs)
    }

    static func shouldSkipSTTAfterSpeakerVerification(
        ownerProfileExists: Bool,
        speakerVerificationCompleted: Bool,
        firstOwnerEnrollmentActive: Bool,
        speakerRole: SpeakerRole?
    ) -> Bool {
        GateHelpers.shouldSkipSTTAfterSpeakerVerification(ownerProfileExists: ownerProfileExists, speakerVerificationCompleted: speakerVerificationCompleted, firstOwnerEnrollmentActive: firstOwnerEnrollmentActive, speakerRole: speakerRole)
    }

    static func streamingSpeakerSimilarityDecision(
        bestHumanSimilarity: Float?,
        acceptThreshold: Float,
        rejectThreshold: Float
    ) -> StreamingSpeakerSimilarityDecision {
        GateHelpers.streamingSpeakerSimilarityDecision(bestHumanSimilarity: bestHumanSimilarity, acceptThreshold: acceptThreshold, rejectThreshold: rejectThreshold)
    }

    static func fusedVoiceAttentionDecision(
        gateState: GateState,
        explicitWakeRequired: Bool,
        requireDirectAddress: Bool,
        addressedToFae: Bool,
        inFollowup: Bool,
        awaitingApproval: Bool,
        firstOwnerEnrollmentActive: Bool,
        speakerAllowsConversation: Bool,
        wordCount: Int
    ) -> VoiceAttentionDecision {
        GateHelpers.fusedVoiceAttentionDecision(gateState: gateState, explicitWakeRequired: explicitWakeRequired, requireDirectAddress: requireDirectAddress, addressedToFae: addressedToFae, inFollowup: inFollowup, awaitingApproval: awaitingApproval, firstOwnerEnrollmentActive: firstOwnerEnrollmentActive, speakerAllowsConversation: speakerAllowsConversation, wordCount: wordCount)
    }

    static func shouldDeferSemanticTurn(
        text: String,
        addressedToFae: Bool,
        inFollowup: Bool,
        awaitingApproval: Bool,
        hasPendingGovernanceAction: Bool,
        firstOwnerEnrollmentActive: Bool
    ) -> Bool {
        GateHelpers.shouldDeferSemanticTurn(text: text, addressedToFae: addressedToFae, inFollowup: inFollowup, awaitingApproval: awaitingApproval, hasPendingGovernanceAction: hasPendingGovernanceAction, firstOwnerEnrollmentActive: firstOwnerEnrollmentActive)
    }

    private enum PreviewSpeakerVerificationDecision {
        case useEmbedding([Float])
        case rejectUnknown
        case echoRejected(Float)
        case fallBackToFullSegment
    }

    // StreamingSpeakerSimilarityDecision and VoiceAttentionDecision enums
    // moved to PipelineTypes.swift.

    private static let previewSpeakerWindowMs: Int = 1200
    private static let previewSpeakerMinWindowMs: Int = 700
    private static let previewSpeakerThresholdRelaxation: Float = 0.08
    private static let previewSpeakerRejectMargin: Float = 0.14
    private static let streamingSpeakerWindowMs: Int = 1400
    private static let streamingSpeakerStepMs: Int = 240

    /// Unified cosine similarity threshold for fae_self echo rejection.
    private static let faeSelfEchoThreshold: Float = 0.55

    private func previewSpeakerVerification(
        segment: SpeechSegment,
        encoder: CoreMLSpeakerEncoder,
        store: SpeakerProfileStore,
        hasOwner: Bool
    ) async -> PreviewSpeakerVerificationDecision {
        guard hasOwner, !speakerGate.firstOwnerEnrollmentActive else {
            return .fallBackToFullSegment
        }

        let minSamples = (Self.previewSpeakerMinWindowMs * segment.sampleRate) / 1000
        guard segment.samples.count >= minSamples else {
            return .fallBackToFullSegment
        }

        let previewSamples = min(
            segment.samples.count,
            (Self.previewSpeakerWindowMs * segment.sampleRate) / 1000
        )

        do {
            let previewEmbedding = try await encoder.embed(
                audio: Array(segment.samples.prefix(previewSamples)),
                sampleRate: segment.sampleRate
            )
            let previewThreshold = max(
                config.speaker.threshold - Self.previewSpeakerThresholdRelaxation,
                0.55
            )
            let rejectThreshold = max(
                previewThreshold - Self.previewSpeakerRejectMargin,
                0.35
            )

            let bestHumanSimilarity = await store.bestMatch(
                embedding: previewEmbedding,
                excludingRoles: [.faeSelf]
            )?.similarity
            switch Self.streamingSpeakerSimilarityDecision(
                bestHumanSimilarity: bestHumanSimilarity,
                acceptThreshold: previewThreshold,
                rejectThreshold: rejectThreshold
            ) {
            case .allow:
                return .useEmbedding(previewEmbedding)
            case .reject:
                return .rejectUnknown
            case .undecided:
                break
            }

            if let faeSelfSim = await store.matchesFaeSelf(
                embedding: previewEmbedding,
                threshold: previewThreshold
            ) {
                if echoSuppressor.isInSuppression {
                    return .echoRejected(faeSelfSim)
                }
                return .fallBackToFullSegment
            }
        } catch {
            debugLog(debugConsole, .speaker, "Preview embed failed: \(error.localizedDescription)")
            return .fallBackToFullSegment
        }

        return .fallBackToFullSegment
    }

    private func resetStreamingSpeakerGate() {
        speakerGate.resetStreamingSpeakerGate()
    }

    private func resetStreamingWakeDetector() {
        speechInputStage.resetStreamingWakeDetector()
    }

    private func acousticWakeDetectionForSegment(_ segment: SpeechSegment) async -> WakeWordAcousticDetector.Detection? {
        if let detection = speechInputStage.streamingWakeDetection {
            return detection
        }

        guard effectiveAcousticWakeEnabled(),
              !speakerGate.firstOwnerEnrollmentActive,
              let wakeStore = wakeWordProfileStore
        else {
            return nil
        }

        let prefixMaxSamples = Int(Float(segment.sampleRate) * WakeWordAcousticDetector.maxDurationSeconds)
        let prefix = Array(segment.samples.prefix(prefixMaxSamples))
        let templates = await wakeStore.acousticTemplates()
        guard let detection = WakeWordAcousticDetector.bestDetection(
            samples: prefix,
            sampleRate: segment.sampleRate,
            templates: templates,
            threshold: effectiveAcousticWakeThreshold()
        ) else {
            return nil
        }

        debugLog(
            debugConsole,
            .command,
            "Acoustic wake detected on segment sim=\(String(format: "%.3f", detection.similarity))"
        )
        publishVoiceAttention(
            stage: "wake",
            decision: "detected",
            reason: "acoustic_segment_match_consensus",
            wakeSource: "acoustic",
            wakeScore: detection.consensusSimilarity,
            rms: VoiceActivityDetector.computeRMS(prefix)
        )
        return detection
    }

    private func updateStreamingWakeDetector(chunk: AudioChunk, vadOutput: VoiceActivityDetector.Output) async {
        if vadOutput.speechStarted {
            resetStreamingWakeDetector()
        }

        if vadOutput.segment != nil || speechInputStage.streamingWakeDetection != nil {
            return
        }

        // During playback, allow wake word detection with a raised threshold.
        // Outside playback, require assistant not speaking/generating.
        let duringPlayback = assistantSpeaking
        guard effectiveAcousticWakeEnabled(),
              !speakerGate.firstOwnerEnrollmentActive,
              vadOutput.isSpeech,
              (duringPlayback || (!assistantSpeaking && !assistantGenerating)),
              let wakeStore = wakeWordProfileStore
        else {
            return
        }

        speechInputStage.streamingWakeSamples.append(contentsOf: chunk.samples)
        let maxPrefixSamples = Int(Float(AudioCaptureManager.targetSampleRate) * WakeWordAcousticDetector.maxDurationSeconds)
        if speechInputStage.streamingWakeSamples.count > maxPrefixSamples {
            speechInputStage.streamingWakeSamples = Array(speechInputStage.streamingWakeSamples.prefix(maxPrefixSamples))
        }

        let minSamples = Int(Float(AudioCaptureManager.targetSampleRate) * WakeWordAcousticDetector.minDurationSeconds)
        guard speechInputStage.streamingWakeSamples.count >= minSamples else { return }

        if speechInputStage.streamingWakeSamples.count - speechInputStage.streamingWakeLastEvaluatedSamples < SpeechInputStage.acousticWakeEvalStrideSamples {
            return
        }
        speechInputStage.streamingWakeLastEvaluatedSamples = speechInputStage.streamingWakeSamples.count

        // Raise threshold during playback to compensate for echo contamination.
        let baseThreshold = effectiveAcousticWakeThreshold()
        let threshold = duringPlayback ? baseThreshold + 0.03 : baseThreshold

        let templates = await wakeStore.acousticTemplates()
        guard let detection = WakeWordAcousticDetector.bestDetection(
            samples: speechInputStage.streamingWakeSamples,
            sampleRate: AudioCaptureManager.targetSampleRate,
            templates: templates,
            threshold: threshold
        ) else {
            return
        }

        // During playback, set the wake word flag for the playback barge-in path
        // instead of the normal streaming wake detection.
        if duringPlayback {
            bargeInState.playbackWakeWordDetected = true
            debugLog(
                debugConsole,
                .command,
                "Playback wake word detected sim=\(String(format: "%.3f", detection.similarity)) consensus=\(String(format: "%.3f", detection.consensusSimilarity))"
            )
            publishVoiceAttention(
                stage: "wake",
                decision: "detected",
                reason: "playback_wake_word",
                wakeSource: "acoustic",
                wakeScore: detection.consensusSimilarity,
                rms: vadOutput.rms
            )
            return
        }

        speechInputStage.streamingWakeDetection = detection
        debugLog(
            debugConsole,
            .command,
            "Acoustic wake detected sim=\(String(format: "%.3f", detection.similarity)) consensus=\(String(format: "%.3f", detection.consensusSimilarity)) support=\(detection.supportCount)/\(detection.templateCount)"
        )
        publishVoiceAttention(
            stage: "wake",
            decision: "detected",
            reason: "acoustic_prefix_match_consensus",
            wakeSource: "acoustic",
            wakeScore: detection.consensusSimilarity,
            rms: vadOutput.rms
        )
    }

    private func updateStreamingSpeakerGate(chunk: AudioChunk, vadOutput: VoiceActivityDetector.Output) async {
        if vadOutput.speechStarted {
            resetStreamingSpeakerGate()
        }

        if vadOutput.segment != nil {
            return
        }

        // Mel-spectral fallback cannot discriminate humans — skip the streaming
        // speaker gate entirely (full-segment echo detection still runs).
        if await isSpeakerEncoderMelFallback() {
            return
        }

        guard vadOutput.isSpeech,
              !assistantSpeaking,
              !assistantGenerating,
              speakerGate.streamingSpeakerVerdict != .rejectUnknown,
              let encoder = speakerEncoder,
              await encoder.isLoaded,
              let store = speakerProfileStore
        else {
            return
        }

        let hasOwner = await store.hasOwnerProfile()
        guard hasOwner, !speakerGate.firstOwnerEnrollmentActive else { return }

        speakerGate.streamingSpeakerVerificationAvailable = true
        if speakerGate.streamingSpeakerVerdict == .allow {
            return
        }

        let maxSamples = (Self.streamingSpeakerWindowMs * chunk.sampleRate) / 1000
        let stepSamples = max((Self.streamingSpeakerStepMs * chunk.sampleRate) / 1000, chunk.samples.count)
        let minSamples = (Self.previewSpeakerMinWindowMs * chunk.sampleRate) / 1000

        if speakerGate.streamingSpeakerSamples.count < maxSamples {
            let remaining = maxSamples - speakerGate.streamingSpeakerSamples.count
            speakerGate.streamingSpeakerSamples.append(contentsOf: chunk.samples.prefix(remaining))
        }

        guard speakerGate.streamingSpeakerSamples.count >= minSamples else { return }
        guard speakerGate.streamingSpeakerSamples.count - speakerGate.streamingSpeakerLastEvaluatedSamples >= stepSamples
                || speakerGate.streamingSpeakerSamples.count == maxSamples
        else {
            return
        }

        speakerGate.streamingSpeakerLastEvaluatedSamples = speakerGate.streamingSpeakerSamples.count

        do {
            let embedding = try await encoder.embed(
                audio: speakerGate.streamingSpeakerSamples,
                sampleRate: chunk.sampleRate
            )
            let previewThreshold = max(
                config.speaker.threshold - Self.previewSpeakerThresholdRelaxation,
                0.55
            )
            let rejectThreshold = max(
                previewThreshold - Self.previewSpeakerRejectMargin,
                0.35
            )
            let bestHumanSimilarity = await store.bestMatch(
                embedding: embedding,
                excludingRoles: [.faeSelf]
            )?.similarity

            switch Self.streamingSpeakerSimilarityDecision(
                bestHumanSimilarity: bestHumanSimilarity,
                acceptThreshold: previewThreshold,
                rejectThreshold: rejectThreshold
            ) {
            case .allow:
                speakerGate.streamingSpeakerVerdict = .allow
                debugLog(debugConsole, .speaker, "Streaming gate allowed speaker before segment close")
            case .reject:
                if let faeSelfSim = await store.matchesFaeSelf(embedding: embedding, threshold: previewThreshold),
                   echoSuppressor.isInSuppression {
                    speakerGate.currentSpeakerRole = .faeSelf
                    debugLog(
                        debugConsole,
                        .pipeline,
                        "Streaming gate echo-rejected sim=\(String(format: "%.3f", faeSelfSim)) before segment close"
                    )
                } else {
                    speakerGate.currentSpeakerRole = nil
                    debugLog(debugConsole, .speaker, "Streaming gate rejected unknown speaker before segment close")
                }
                speakerGate.currentSpeakerLabel = nil
                speakerGate.currentSpeakerDisplayName = nil
                speakerGate.currentSpeakerIsOwner = false
                speakerGate.currentSpeakerIsKnownNonOwner = false
                speakerGate.streamingSpeakerVerdict = .rejectUnknown
            case .undecided:
                break
            }
        } catch {
            debugLog(debugConsole, .speaker, "Streaming gate embed failed: \(error.localizedDescription)")
        }
    }

    private func shouldDropSegmentFromStreamingSpeakerGate() -> Bool {
        speakerGate.streamingSpeakerVerificationAvailable && speakerGate.streamingSpeakerVerdict == .rejectUnknown
    }

    private func evaluateSpeakerEmbedding(
        _ embedding: [Float],
        hasOwner: Bool,
        store: SpeakerProfileStore,
        durationSecs: Float,
        threshold: Float,
        progressiveEnrollment: Bool,
        source: String
    ) async -> Bool {
        if hasOwner, let match = await store.match(
            embedding: embedding,
            threshold: threshold,
            excludingRoles: [.faeSelf]
        ) {
            speakerGate.currentSpeakerLabel = match.label
            speakerGate.currentSpeakerDisplayName = match.displayName
            speakerGate.currentSpeakerRole = match.role
            speakerGate.currentSpeakerIsOwner = match.role == .owner
            speakerGate.currentSpeakerIsKnownNonOwner = match.role != .owner

            if progressiveEnrollment && config.speaker.progressiveEnrollment {
                await store.enrollIfBelowMax(
                    label: match.label,
                    embedding: embedding,
                    max: config.speaker.maxEnrollments
                )
            }

            NSLog(
                "PipelineCoordinator: speaker matched (%@): %@ (%@), similarity: %.3f",
                source,
                match.displayName,
                match.label,
                match.similarity
            )
            debugLog(
                debugConsole,
                .speaker,
                "Matched [\(source)]: \(match.displayName) (\(match.label)) sim=\(String(format: "%.3f", match.similarity)) owner=\(speakerGate.currentSpeakerIsOwner)"
            )
            return true
        }

        if !hasOwner {
            NSLog("PipelineCoordinator: no owner voice enrolled yet — awaiting voice_identity enrollment")
            debugLog(debugConsole, .speaker, "Owner not enrolled yet; speaker left as unknown")
            return true
        }

        // fae_self voice match: ALWAYS reject when owner is enrolled.
        // Fae should never respond to her own voice — whether inside or outside
        // the echo suppression timing window. If the voiceprint matches fae_self,
        // it's Fae hearing herself through the speakers. No exceptions.
        let faeSelfThreshold = echoSuppressor.faeSelfThresholdDuringPlayback(baseThreshold: threshold)
        if let faeSelfSim = await store.matchesFaeSelf(embedding: embedding, threshold: faeSelfThreshold) {
            NSLog(
                "PipelineCoordinator: dropping %.1fs segment (%@ fae_self sim=%.3f threshold=%.3f)",
                durationSecs,
                source,
                faeSelfSim,
                faeSelfThreshold
            )
            debugLog(
                debugConsole,
                .pipeline,
                "Echo rejected [\(source)] (voice match fae_self sim=\(String(format: "%.3f", faeSelfSim)))"
            )
            return false
        } else {
            NSLog("PipelineCoordinator: speaker not recognized (%@)", source)
            debugLog(
                debugConsole,
                .speaker,
                "Not recognized [\(source)] (no match above threshold \(String(format: "%.2f", threshold)))"
            )
        }

        return true
    }

    private func effectiveIdleRearmSeconds() -> Int {
        Self.idleRearmSeconds(
            requireDirectAddress: effectiveRequireDirectAddress(),
            idleTimeoutS: config.conversation.idleTimeoutS,
            directAddressFollowupS: config.conversation.directAddressFollowupS
        )
    }

    private func scheduleIdleRearm() {
        idleRearmTask?.cancel()
        let timeout = effectiveIdleRearmSeconds()
        guard timeout > 0 else { return }

        idleRearmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.sleepAfterIdleTimeout(seconds: timeout)
        }
    }

    private func sleepAfterIdleTimeout(seconds: Int) async {
        guard gateState == .active else { return }
        let inFollowup = engagedUntil.map { Date() < $0 } ?? false
        guard !assistantSpeaking, !assistantGenerating, !awaitingApproval, !inFollowup, deferredToolTasks.isEmpty else {
            scheduleIdleRearm()
            return
        }

        gateState = .idle
        explicitWakeRequiredFromIdle = false
        engagedUntil = nil
        idleRearmTask = nil
        NSLog("PipelineCoordinator: gate → idle (idle timeout %ds)", seconds)
        await closeConversationSessionIfNeeded(reason: "idle_timeout")
    }

    private func effectiveVisionEnabled() -> Bool {
        visionEnabledLive ?? config.vision.enabled
    }

    private func effectiveVoiceIdentityLock() -> Bool {
        voiceIdentityLockLive ?? config.tts.voiceIdentityLock
    }

    private static func normalizeForPhraseMatch(_ text: String) -> String {
        let lower = text.lowercased()
        let mapped = lower.map { ch -> Character in
            if ch.isLetter || ch.isNumber {
                return ch
            }
            return " "
        }
        return String(mapped)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func isConversationStopTrigger(
        text: String,
        configuredPhrases: [String],
        assistantSpeaking: Bool,
        assistantGenerating: Bool,
        gateState: GateState
    ) -> Bool {
        let normalizedText = normalizeForPhraseMatch(text)
        guard !normalizedText.isEmpty else { return false }

        let immediateQuietMode = assistantSpeaking || assistantGenerating || gateState == .active
        if immediateQuietMode, immediateQuietTriggers.contains(normalizedText) {
            return true
        }

        var phrases = configuredPhrases
        // Common apostrophe-less variant missed by strict literal matching.
        phrases.append("thatll do fae")

        for phrase in phrases {
            let normalizedPhrase = normalizeForPhraseMatch(phrase)
            if !normalizedPhrase.isEmpty, normalizedText.contains(normalizedPhrase) {
                return true
            }
        }
        return false
    }

    private static let immediateQuietTriggers: Set<String> = [
        "stop",
        "stop fae",
        "stop speaking",
        "stop speaking fae",
        "stop talking",
        "stop talking fae",
        "be quiet",
        "be quiet fae",
        "quiet",
        "quiet fae",
        "thats enough",
        "thats enough fae",
        "that s enough",
        "that s enough fae",
        "that is enough",
        "that is enough fae",
        "thatll do",
        "thatll do fae",
        "that ll do",
        "that ll do fae",
        "that will do",
        "that will do fae",
    ]

    // Instance wrapper removed — replaced by keywordSpotter.check().
    // Static isConversationStopTrigger retained for backward-compatible tests.

    private func wakeAddressMatch(in text: String, logDecision: Bool = false) -> TextProcessing.WakeAddressMatch? {
        let match = TextProcessing.findWakeAddressMatch(
            in: text,
            aliases: wakeAliases,
            wakeWord: config.conversation.wakeWord
        )

        if logDecision {
            if let match {
                let confidence = String(format: "%.2f", match.confidence)
                debugLog(
                    debugConsole,
                    .command,
                    "Wake match kind=\(match.kind.rawValue) alias=\(match.matchedAlias) token=\(match.matchedToken) conf=\(confidence)"
                )
            } else if let candidate = TextProcessing.extractWakeAliasCandidate(from: text) {
                debugLog(debugConsole, .command, "Wake miss candidate=\(candidate)")
            }
        }

        return match
    }

    private func isAddressedToFae(_ text: String, logDecision: Bool = false) -> Bool {
        wakeAddressMatch(in: text, logDecision: logDecision) != nil
    }

    /// Rebuild the dynamic vocabulary corrector from all known name sources.
    ///
    /// Called at pipeline start and can be called periodically to pick up
    /// new entities from memory captures.
    func rebuildVocabularyCorrections() async {
        var ownerName = config.userName
        if ownerName == nil { ownerName = await memoryOrchestrator?.rememberedUserName() }
        if ownerName == nil { ownerName = await speakerProfileStore?.ownerDisplayName() }

        // Entity names from the knowledge graph.
        let entityNames = await memoryOrchestrator?.entityNamesForVocabulary() ?? []

        // Speaker profile names.
        var speakerNames: [(label: String, displayName: String)] = []
        if let store = speakerProfileStore {
            let summaries = await store.profileSummaries()
            speakerNames = summaries
                .filter { $0.role != .faeSelf }
                .map { (label: $0.id, displayName: $0.displayName) }
        }

        await vocabularyCorrector.rebuild(
            ownerName: ownerName,
            entityNames: entityNames,
            speakerNames: speakerNames
        )
    }

    private func learnWakeAliasIfNeeded(rawText: String) async {
        guard speakerGate.currentSpeakerIsOwner,
              let wakeStore = wakeWordProfileStore,
              let alias = TextProcessing.extractWakeAliasCandidate(from: rawText)
        else {
            return
        }

        if WakeWordProfileStore.baselineAliases.contains(alias) {
            return
        }

        await wakeStore.recordAliasCandidate(alias, source: "owner_runtime")
        wakeAliases = await wakeStore.allAliases()
        debugLog(debugConsole, .command, "Wake alias learned: \(alias)")
    }

    /// Check (with one-shot caching) whether the speaker encoder is in mel-spectral
    /// fallback mode, meaning it can distinguish TTS from human speech but CANNOT
    /// discriminate between different humans.
    private func isSpeakerEncoderMelFallback() async -> Bool {
        if let cached = speakerGate.speakerEncoderMelFallbackCached { return cached }
        guard let encoder = speakerEncoder, await encoder.isLoaded else {
            speakerGate.speakerEncoderMelFallbackCached = false
            return false
        }
        let result = await encoder.usingMelFallback
        speakerGate.speakerEncoderMelFallbackCached = result
        if result {
            NSLog("PipelineCoordinator: speaker encoder using mel-spectral fallback — human speaker discrimination unavailable")
        }
        return result
    }

    /// Auto-enroll an acoustic wake template from the last processed speech segment.
    /// Called after the text-based wake word fires in STT output, confirming the
    /// segment prefix contains a wake phrase. This bootstraps the acoustic detector
    /// so future "Hey Fae" utterances can be detected before STT completes.
    private func learnAcousticWakeTemplateIfNeeded() async {
        guard let segment = lastProcessedSegment,
              let wakeStore = wakeWordProfileStore
        else { return }

        let currentCount = await wakeStore.acousticTemplateCount()
        guard currentCount < Self.maxAutoWakeTemplates else { return }

        let prefixMaxSamples = Int(Float(segment.sampleRate) * WakeWordAcousticDetector.maxDurationSeconds)
        let prefix = Array(segment.samples.prefix(prefixMaxSamples))

        guard let template = WakeWordAcousticDetector.makeTemplate(
            samples: prefix,
            sampleRate: segment.sampleRate
        ) else { return }

        await wakeStore.recordAcousticTemplate(template, source: "auto_text_wake")
        let newCount = await wakeStore.acousticTemplateCount()
        debugLog(debugConsole, .command, "Auto-enrolled acoustic wake template (\(newCount) total)")
        NSLog("PipelineCoordinator: auto-enrolled acoustic wake template (%d total)", newCount)
    }

    private func resetConversationSession(trigger: String, source: String) async {
        // Stop any active speech/generation immediately.
        if assistantSpeaking || assistantGenerating {
            markGenerationInterrupted()
            await playback.stop()
        }
        sleep(requireExplicitWake: true)
        currentTurnGenerationContext = nil
        engagedUntil = nil
        lastAssistantResponseText = ""
        speechInputStage.lastStreamingPartialTranscript = nil
        lastFastPathPartial = nil
        lastEOUProbability = nil
        speculativePrefillTask?.cancel()
        speculativePrefillTask = nil
        speechInputStage.incrementStreamingEpoch()
        silentGenerationBuffer.removeAll()
        bargeInState.generationTakeoverCandidate = nil
        bargeInState.falseInterruptionRecovery.cancel()
        activeCapabilityTicket = nil
        awaitingApproval = false
        manualOnlyApprovalPending = false
        pendingGovernanceAction = nil
        computerUseStepCount = 0
        ttsState.cancelPending()
        cancelDeferredToolJobs()
        resetStreamingSpeakerGate()
        resetStreamingWakeDetector()
        clearPendingSemanticTurn()
        await keywordSpotter.reset()
        await closeConversationSessionIfNeeded(reason: "conversation_reset")
        await conversationState.clear()
        await llmEngine.resetSession()
        _ = await TillDoneManager.shared.clear()
        currentTurnID = nil
        NSLog("PipelineCoordinator: conversation reset via %@ trigger: %@", source, trigger)
        debugLog(debugConsole, .pipeline, "Conversation reset (\(source)): \(trigger)")
    }

    private func ensureConversationSessionIfNeeded(startedAt: Date) async -> String? {
        if let activeConversationSessionID {
            updateWorkflowTraceSessionID(activeConversationSessionID, turnID: currentTurnID)
            return activeConversationSessionID
        }
        guard let sessionStore else { return nil }
        do {
            let session = try await sessionStore.openSession(
                kind: .main,
                speakerId: speakerGate.currentSpeakerLabel,
                startedAt: startedAt
            )
            activeConversationSessionID = session.id
            updateWorkflowTraceSessionID(session.id, turnID: currentTurnID)
            return session.id
        } catch {
            NSLog("PipelineCoordinator: session open error: %@", error.localizedDescription)
            return nil
        }
    }

    private func persistAcceptedUserTurnIfNeeded(_ text: String) async {
        guard let sessionStore, let turnID = currentTurnID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let createdAt = speakerGate.currentUtteranceTimestamp ?? Date()
        guard let sessionID = await ensureConversationSessionIfNeeded(startedAt: createdAt) else { return }
        do {
            _ = try await sessionStore.appendMessage(
                sessionId: sessionID,
                turnId: turnID,
                role: .user,
                content: trimmed,
                speakerId: speakerGate.currentSpeakerLabel,
                createdAt: createdAt
            )
        } catch {
            NSLog("PipelineCoordinator: session user message persist error: %@", error.localizedDescription)
        }
    }

    private func persistFinalAssistantTurnIfNeeded(_ text: String, turnID: String? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let sessionStore, let sessionID = activeConversationSessionID {
            do {
                _ = try await sessionStore.appendMessage(
                    sessionId: sessionID,
                    turnId: turnID ?? currentTurnID,
                    role: .assistant,
                    content: trimmed,
                    createdAt: Date()
                )
            } catch {
                NSLog("PipelineCoordinator: session assistant message persist error: %@", error.localizedDescription)
            }
        }
        await finalizeWorkflowTraceIfNeeded(turnID: turnID ?? currentTurnID, assistantOutcome: trimmed, success: true)
    }

    private func closeConversationSessionIfNeeded(reason: String) async {
        guard let sessionStore, let sessionID = activeConversationSessionID else { return }
        do {
            try await sessionStore.closeSession(id: sessionID, endedAt: Date())
            activeConversationSessionID = nil
            debugLog(debugConsole, .pipeline, "Closed conversation session \(sessionID.prefix(8)) reason=\(reason)")
        } catch {
            NSLog("PipelineCoordinator: session close error (%@): %@", reason, error.localizedDescription)
        }
    }

    private func workflowTraceSource(
        proactiveContext: ProactiveRequestContext?,
        turnSource: ActionSource
    ) -> String {
        if let proactiveContext {
            return "scheduler:\(proactiveContext.taskId)"
        }
        return turnSource.rawValue
    }

    private func prepareWorkflowTraceContextIfNeeded(
        turnID: String?,
        userGoal: String,
        proactiveContext: ProactiveRequestContext?,
        turnSource: ActionSource
    ) {
        guard let turnID else { return }
        workflowTraceContexts[turnID] = WorkflowTraceContext(
            turnID: turnID,
            source: workflowTraceSource(proactiveContext: proactiveContext, turnSource: turnSource),
            userGoal: userGoal,
            sessionID: activeConversationSessionID,
            runID: nil
        )
    }

    private func pruneUnusedWorkflowTraceContexts(keeping activeTurnID: String?) {
        workflowTraceContexts = workflowTraceContexts.filter { turnID, context in
            if turnID == activeTurnID { return true }
            return context.runID != nil
        }
    }

    private func updateWorkflowTraceSessionID(_ sessionID: String?, turnID: String?) {
        guard let turnID, var context = workflowTraceContexts[turnID] else { return }
        context.sessionID = sessionID
        workflowTraceContexts[turnID] = context
    }

    private func ensureWorkflowTraceRun(turnID: String?) async -> String? {
        guard let workflowTraceStore,
              let turnID,
              var context = workflowTraceContexts[turnID]
        else {
            return nil
        }

        if let runID = context.runID {
            return runID
        }

        do {
            let run = try await workflowTraceStore.createRun(
                sessionId: context.sessionID,
                turnId: context.turnID,
                source: context.source,
                userGoal: context.userGoal
            )
            context.runID = run.id
            workflowTraceContexts[turnID] = context
            return run.id
        } catch {
            NSLog("PipelineCoordinator: workflow trace run create error: %@", error.localizedDescription)
            return nil
        }
    }

    private func recordWorkflowPreflightDenied(
        turnID: String?,
        callId: String,
        call: ToolCall,
        reason: String
    ) async {
        guard let workflowTraceStore,
              let runID = await ensureWorkflowTraceRun(turnID: turnID)
        else { return }

        if var context = turnID.flatMap({ workflowTraceContexts[$0] }) {
            context.toolSequence.append(call.name)
            workflowTraceContexts[context.turnID] = context
        }

        do {
            try await workflowTraceStore.appendStep(
                runId: runID,
                toolCallId: callId,
                stepType: .toolCall,
                toolName: call.name,
                sanitizedInputJSON: Self.serializeArguments(call.arguments),
                outputPreview: nil,
                success: nil,
                approved: nil,
                latencyMs: nil
            )
            try await workflowTraceStore.appendStep(
                runId: runID,
                toolCallId: callId,
                stepType: .toolResult,
                toolName: call.name,
                sanitizedInputJSON: nil,
                outputPreview: reason,
                success: false,
                approved: false,
                latencyMs: nil
            )
        } catch {
            NSLog("PipelineCoordinator: workflow preflight trace error: %@", error.localizedDescription)
        }
    }

    private func recordWorkflowToolCall(
        turnID: String?,
        callId: String?,
        call: ToolCall
    ) async {
        guard let workflowTraceStore,
              let runID = await ensureWorkflowTraceRun(turnID: turnID)
        else { return }

        if let turnID, var context = workflowTraceContexts[turnID] {
            context.toolSequence.append(call.name)
            workflowTraceContexts[turnID] = context
        }

        do {
            try await workflowTraceStore.appendStep(
                runId: runID,
                toolCallId: callId,
                stepType: .toolCall,
                toolName: call.name,
                sanitizedInputJSON: Self.serializeArguments(call.arguments),
                outputPreview: nil,
                success: nil,
                approved: nil,
                latencyMs: nil
            )
        } catch {
            NSLog("PipelineCoordinator: workflow tool-call trace error: %@", error.localizedDescription)
        }
    }

    private func recordWorkflowToolResult(
        turnID: String?,
        callId: String?,
        call: ToolCall,
        result: ToolResult,
        approved: Bool?,
        latencyMs: Int?,
        damageControlIntervened: Bool = false
    ) async {
        guard let workflowTraceStore,
              let runID = await ensureWorkflowTraceRun(turnID: turnID)
        else { return }

        if let turnID, var context = workflowTraceContexts[turnID] {
            if approved == true {
                context.userApproved = true
            }
            if damageControlIntervened {
                context.damageControlIntervened = true
            }
            workflowTraceContexts[turnID] = context
        }

        do {
            try await workflowTraceStore.appendStep(
                runId: runID,
                toolCallId: callId,
                stepType: .toolResult,
                toolName: call.name,
                sanitizedInputJSON: nil,
                outputPreview: result.output,
                success: !result.isError,
                approved: approved,
                latencyMs: latencyMs
            )
        } catch {
            NSLog("PipelineCoordinator: workflow tool-result trace error: %@", error.localizedDescription)
        }
    }

    private func finalizeWorkflowTraceIfNeeded(
        turnID: String?,
        assistantOutcome: String,
        success: Bool,
        status: WorkflowRunStatus = .completed
    ) async {
        guard let turnID,
              let context = workflowTraceContexts[turnID],
              let runID = context.runID,
              let workflowTraceStore
        else {
            workflowTraceContexts.removeValue(forKey: turnID ?? "")
            return
        }

        do {
            _ = try await workflowTraceStore.finalizeRun(
                id: runID,
                assistantOutcome: assistantOutcome,
                success: success,
                userApproved: context.userApproved,
                toolSequenceSignature: Self.workflowTraceSignature(for: context.toolSequence),
                damageControlIntervened: context.damageControlIntervened,
                status: status
            )
        } catch {
            NSLog("PipelineCoordinator: workflow trace finalize error: %@", error.localizedDescription)
        }

        workflowTraceContexts.removeValue(forKey: turnID)
    }

    private func abandonWorkflowTraceIfNeeded(turnID: String?, reason: String) async {
        guard let turnID,
              let context = workflowTraceContexts[turnID],
              let runID = context.runID,
              let workflowTraceStore
        else {
            workflowTraceContexts.removeValue(forKey: turnID ?? "")
            return
        }

        do {
            _ = try await workflowTraceStore.finalizeRun(
                id: runID,
                assistantOutcome: reason,
                success: false,
                userApproved: context.userApproved,
                toolSequenceSignature: Self.workflowTraceSignature(for: context.toolSequence),
                damageControlIntervened: context.damageControlIntervened,
                status: .abandoned
            )
        } catch {
            NSLog("PipelineCoordinator: workflow trace abandon error: %@", error.localizedDescription)
        }

        workflowTraceContexts.removeValue(forKey: turnID)
    }

    private func abandonAllWorkflowTraces(reason: String) async {
        let turnIDs = Array(workflowTraceContexts.keys)
        for turnID in turnIDs {
            await abandonWorkflowTraceIfNeeded(turnID: turnID, reason: reason)
        }
    }

    private static func workflowTraceSignature(for toolSequence: [String]) -> String? {
        let normalized = toolSequence
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return nil }
        return normalized.joined(separator: " -> ")
    }

    // MARK: - Speech Segment Queue (delegated to speechInputStage)

    private func startSpeechSegmentProcessingLoop() {
        speechInputStage.startSpeechSegmentProcessingLoop { [weak self] segment in
            guard let self else { return }
            await self.handleSpeechSegment(segment)
        }
    }

    private func stopSpeechSegmentProcessingLoop() async {
        await speechInputStage.stopSpeechSegmentProcessingLoop()
    }

    private func enqueueSpeechSegment(_ segment: SpeechSegment) {
        speechInputStage.enqueueSpeechSegment(
            segment,
            fallbackHandler: { [weak self] segment in
                guard let self else { return }
                await self.handleSpeechSegment(segment)
            },
            debugConsole: debugConsole
        )
    }

    // MARK: - Main Pipeline Loop

    private func runPipelineLoop(stream: AsyncStream<AudioChunk>) async {
        // Detect audio output route for echo suppression tuning.
        echoSuppressor.outputRoute = Self.detectOutputRoute(playback: playback)
        debugLog(debugConsole, .pipeline, "Audio output route: \(echoSuppressor.outputRoute)")

        // Re-detect route periodically during the pipeline loop (every ~5s).
        // macOS does not have AVAudioSession route-change notifications, so we poll.
        var lastRouteCheckAt = Date()
        let routeCheckIntervalSec: TimeInterval = 5.0

        for await chunk in stream {
            guard !Task.isCancelled else { break }

            // Periodic output route re-detection (~every 5s).
            let now = Date()
            if now.timeIntervalSince(lastRouteCheckAt) >= routeCheckIntervalSec {
                lastRouteCheckAt = now
                let currentRoute = Self.detectOutputRoute(playback: playback)
                if currentRoute != echoSuppressor.outputRoute {
                    echoSuppressor.outputRoute = currentRoute
                    debugLog(debugConsole, .pipeline, "Audio output route changed: \(currentRoute)")
                }
            }

            // VAD stage.
            var vadOutput = vad.processChunk(chunk)

            // Tier 1: Spectral tilt pre-filter.
            // Quick DSP check to reject music/noise that Silero misclassifies as
            // speech.  Runs on every chunk where VAD says "speech" — <1ms overhead.
            // Does NOT gate completed segments (Tier 2 handles those).
            if vadOutput.isSpeech,
               !VoiceActivityDetector.spectralTiltLooksSpeechlike(
                   samples: chunk.samples, sampleRate: chunk.sampleRate
               )
            {
                vadOutput.isSpeech = false
                vadOutput.speechStarted = false
            }

            // Emit audio level for orb animation.
            eventBus.send(.audioLevel(vadOutput.rms))

            await updateStreamingSpeakerGate(chunk: chunk, vadOutput: vadOutput)
            await updateStreamingWakeDetector(chunk: chunk, vadOutput: vadOutput)

            // Feed audio to streaming STT during active speech for real-time
            // partial transcripts (Phase 3).
            //
            // Three gates prevent feeding garbage audio:
            // 1. Echo gate: during playback, only feed audio above the playback
            //    baseline (user speech, not Fae's TTS bleeding through the mic).
            // 2. Echo suppression: blocked while echo tail is active.
            // 3. SNR gate: skip low-SNR chunks that would produce bad partials.
            let snrOk = vad.estimatedSNRdB(chunkRms: vadOutput.rms)
                >= VoiceActivityDetector.minStreamingSNRdB
            let streamingAudioSafe = vadOutput.isSpeech
                && (!assistantSpeaking
                    || echoSuppressor.userSpeechLikelyAbovePlayback(rms: vadOutput.rms))
                && !echoSuppressor.isInSuppression
                && snrOk
            if streamingAudioSafe {
                let epoch = speechInputStage.streamingEpoch

                // Fast-path: feed Parakeet TDT (CTC-based, frame-independent).
                // Runs a decode pass when enough audio accumulates, providing
                // low-latency partials without growing-buffer re-transcription.
                if let fastPath = streamingSTTEngine {
                    Task { [weak self] in
                        guard let self else { return }
                        await fastPath.feedAudio(chunk.samples)
                        let partial = await fastPath.getPartialTranscript()
                        if !partial.isEmpty {
                            await self.handleStreamingPartialTranscript(
                                partial, epoch: epoch, source: .parakeet
                            )
                        }
                    }
                }

                // Slow-path: growing-buffer Qwen3-ASR (higher accuracy, higher latency).
                // When Parakeet is available, this still accumulates audio for the
                // final high-accuracy transcription after speech ends.
                await sttEngine.feedStreamingAudio(chunk.samples)
                if await sttEngine.shouldRunStreamingTranscription() {
                    // Single-slot guard: only spawn if no transcription task is in flight.
                    // Prevents task pile-up when transcription takes longer than chunk interval.
                    if !streamingTranscriptionInFlight {
                        streamingTranscriptionInFlight = true
                        Task { [weak self] in
                            guard let self else { return }
                            defer { Task { await self.clearStreamingTranscriptionFlag() } }
                            if let partial = await self.sttEngine.runStreamingTranscription() {
                                // Drop stale partials from a previous streaming session.
                                // When fast-path is active, slow-path partials supplement
                                // with higher accuracy as more audio accumulates.
                                await self.handleStreamingPartialTranscript(
                                    partial, epoch: epoch, source: .qwen3ASR
                                )
                            }
                        }
                    }
                }
            }

            if !firstAudioLatencyEmitted,
               let startedAt = pipelineStartedAt,
               (vadOutput.isSpeech || vadOutput.speechStarted || vadOutput.segment != nil)
            {
                let latencyMs = Date().timeIntervalSince(startedAt) * 1000
                firstAudioLatencyEmitted = true
                NSLog("phase1.first_audio_latency_ms=%.2f", latencyMs)
            }

            // Feed post-playback decay samples when in echo tail but not actively speaking.
            if !assistantSpeaking && echoSuppressor.isInSuppression {
                echoSuppressor.addDecaySample(timestamp: Date(), rms: vadOutput.rms)
            }

            // Track barge-in only while the assistant is audibly speaking.
            // This avoids false interruptions during long LLM decode gaps where
            // assistantGenerating may be true but no speech is playing.
            if Self.shouldTrackBargeIn(assistantSpeaking: assistantSpeaking) {
                // PATH A: Playback barge-in — identity-based detection during active TTS.
                // Update playback baseline RMS (how loud Fae sounds through the mic).
                echoSuppressor.updatePlaybackBaseline(rms: vadOutput.rms)
                // Update per-band energy baseline for spectral discrimination.
                let playbackBandEnergy = EchoSuppressor.computeBandEnergy(samples: chunk.samples, sampleRate: chunk.sampleRate)
                echoSuppressor.updatePlaybackBandBaseline(energy: playbackBandEnergy)

                // Accumulate audio into playback barge-in candidate when speech
                // is detected above the playback baseline and has speech-like spectrum.
                let bandLooksSpeech = echoSuppressor.bandEnergyLooksLikeSpeech(playbackBandEnergy)
                if vadOutput.isSpeech && echoSuppressor.userSpeechLikelyAbovePlayback(rms: vadOutput.rms) && bandLooksSpeech {
                    if vadOutput.speechStarted || bargeInState.playbackCandidate == nil {
                        bargeInState.playbackCandidate = PlaybackBargeInCandidate(
                            capturedAt: Date(),
                            lastRms: vadOutput.rms,
                            peakRms: vadOutput.rms
                        )
                    }
                    if var candidate = bargeInState.playbackCandidate {
                        candidate.speechSamples += chunk.samples.count
                        candidate.lastRms = vadOutput.rms
                        candidate.peakRms = max(candidate.peakRms, vadOutput.rms)
                        candidate.consecutiveSpeechChunks += 1
                        let remaining = max(0, PlaybackBargeInCandidate.maxAudioSamples - candidate.audioSamples.count)
                        if remaining > 0 {
                            candidate.audioSamples.append(contentsOf: chunk.samples.prefix(remaining))
                        }
                        bargeInState.playbackCandidate = candidate

                        // Run keyword classifier on playback candidate (Path A).
                        if candidate.audioSamples.count >= Self.keywordClassifierMinSamples,
                           (!bargeInState.playbackWakeWordDetected || !bargeInState.playbackInterruptKeywordDetected),
                           let classifier = keywordClassifier,
                           await classifier.isLoaded
                        {
                            if let classification = try? await classifier.classify(
                                audio: candidate.audioSamples,
                                sampleRate: config.audio.inputSampleRate
                            ) {
                                if classification.label == .interrupt && classification.confidence > 0.85 {
                                    bargeInState.playbackInterruptKeywordDetected = true
                                    debugLog(debugConsole, .command,
                                             "Keyword classifier (Path A): interrupt (\(classification.keyword ?? "?"), conf=\(String(format: "%.2f", classification.confidence)))")
                                } else if classification.label == .wake && classification.confidence > 0.85 {
                                    bargeInState.playbackWakeWordDetected = true
                                    debugLog(debugConsole, .command,
                                             "Keyword classifier (Path A): wake (\(classification.keyword ?? "?"), conf=\(String(format: "%.2f", classification.confidence)))")
                                }
                            }
                        }

                        // Evaluate once enough audio is collected for identity check.
                        if candidate.audioSamples.count >= PlaybackBargeInCandidate.minSamplesForIdentity {
                            if await evaluatePlaybackBargeIn(candidate: candidate) {
                                await executePlaybackBargeIn(candidate: candidate)
                                // Skip the rest of barge-in processing for this chunk.
                                continue
                            }
                        }
                    }
                } else if !vadOutput.isSpeech, bargeInState.playbackCandidate != nil {
                    // Speech gap — reset consecutive counter but keep candidate.
                    bargeInState.playbackCandidate?.consecutiveSpeechChunks = 0
                }

                // PATH B: Echo-gated barge-in (existing behavior, handles post-playback).
                // Check deny cooldown — skip creating new barge-in candidates during cooldown.
                let inDenyCooldown = bargeInState.isInDenyCooldown

                // Skip when echo suppressor is active or barge-in is suppressed
                // (non-interruptible speakDirect) to prevent false triggers.
                bargeInState.pendingBargeIn = Self.advancePendingBargeIn(
                    pending: bargeInState.pendingBargeIn,
                    speechStarted: vadOutput.speechStarted,
                    isSpeech: vadOutput.isSpeech,
                    chunkSamples: chunk.samples,
                    rms: vadOutput.rms,
                    echoSuppression: echoSuppressor.isInSuppression,
                    bargeInSuppressed: bargeInState.isSuppressed,
                    inDenyCooldown: inDenyCooldown
                )
                // Run keyword classifier on accumulated audio (Path B).
                if var barge = bargeInState.pendingBargeIn,
                   !barge.hasInterruptKeyword,
                   barge.audioSamples.count >= Self.keywordClassifierMinSamples,
                   let classifier = keywordClassifier,
                   await classifier.isLoaded
                {
                    if let classification = try? await classifier.classify(
                        audio: barge.audioSamples,
                        sampleRate: config.audio.inputSampleRate
                    ) {
                        switch classification.label {
                        case .interrupt where classification.confidence > 0.85:
                            barge.hasInterruptKeyword = true
                            barge.partialTranscript = classification.keyword
                            debugLog(debugConsole, .command,
                                     "Keyword classifier: interrupt (\(classification.keyword ?? "?"), conf=\(String(format: "%.2f", classification.confidence)))")
                        case .wake where classification.confidence > 0.85:
                            barge.hasInterruptKeyword = true
                            barge.partialTranscript = classification.keyword
                            bargeInState.playbackWakeWordDetected = true
                            debugLog(debugConsole, .command,
                                     "Keyword classifier: wake (conf=\(String(format: "%.2f", classification.confidence)))")
                        case .speech, .silence, .noise, .interrupt, .wake:
                            break
                        }
                        bargeInState.pendingBargeIn = barge
                    }
                }

                if let barge = bargeInState.pendingBargeIn {
                    // Compute overlap duration from accumulated speech samples.
                    let overlapMs = (barge.speechSamples * 1000) / config.audio.inputSampleRate
                    let assistantElapsedMs: Int
                    if let start = lastAssistantStart {
                        assistantElapsedMs = Int(Date().timeIntervalSince(start) * 1000)
                    } else {
                        assistantElapsedMs = 0
                    }

                    let inDenyCooldown = bargeInState.isInDenyCooldown

                    // Semantic signals from partial transcript (populated by keyword classifier or StreamingSTT).
                    let transcript = barge.partialTranscript
                    let wordCount = transcript?
                        .split(separator: " ")
                        .filter { !$0.isEmpty }
                        .count ?? 0

                    let input = InterruptionInput(
                        assistantSpeaking: assistantSpeaking,
                        speechStarted: vadOutput.speechStarted,
                        isSpeech: vadOutput.isSpeech,
                        rms: vadOutput.rms,
                        chunkSamples: chunk.samples,
                        overlapDurationMs: overlapMs,
                        assistantSpeechElapsedMs: assistantElapsedMs,
                        echoSuppression: echoSuppressor.isInSuppression,
                        bargeInSuppressed: bargeInState.isSuppressed,
                        inDenyCooldown: inDenyCooldown,
                        peakRms: barge.peakRms,
                        consecutiveSpeechChunks: barge.consecutiveSpeechChunks,
                        partialTranscript: transcript,
                        partialWordCount: wordCount,
                        hasInterruptKeyword: barge.hasInterruptKeyword
                    )

                    let decision = bargeInState.interruptionDecider.process(input)
                    switch decision {
                    case .interruptNow(let reason):
                        bargeInState.pendingBargeIn = nil
                        bargeInState.interruptionDecider.reset()
                        NSLog("PipelineCoordinator: interruption decider → interruptNow (%@)", reason)
                        await handleBargeInWithVerification(barge: barge)
                    case .ignore(let reason):
                        bargeInState.pendingBargeIn = nil
                        bargeInState.interruptionDecider.reset()
                        debugLog(debugConsole, .command, "Interruption ignored: \(reason)")
                    case .candidate:
                        break  // Keep collecting.
                    }
                }
            } else {
                bargeInState.pendingBargeIn = nil
            }

            // Be more patient during an active conversation so short hesitations
            // do not prematurely cut the user turn.
            let inFollowup = engagedUntil.map { Date() < $0 } ?? false
            let silenceThresholdMs = Self.silenceThresholdMs(
                assistantSpeaking: assistantSpeaking,
                gateState: gateState,
                inFollowup: inFollowup,
                hasPendingSemanticTurn: pendingSemanticTurn != nil,
                configMinSilenceMs: config.vad.minSilenceDurationMs,
                bargeInSilenceMs: config.bargeIn.bargeInSilenceMs,
                lastPartialTranscript: speechInputStage.lastStreamingPartialTranscript,
                emaSuggestedMs: vad.emaSuggestedSilenceMs,
                eouProbability: lastEOUProbability
            )
            vad.setSilenceThresholdMs(silenceThresholdMs)
            if assistantSpeaking {

                // Watchdog: if assistantSpeaking has been true for an unreasonably
                // long time (>60s), the TTS pipeline is stuck. Force-clear so the
                // mic isn't permanently dead. No single TTS utterance should take
                // more than 60 seconds.
                if let start = lastAssistantStart,
                   Date().timeIntervalSince(start) > 60
                {
                    NSLog("PipelineCoordinator: assistantSpeaking watchdog — stuck for >60s, force-clearing")
                    debugLog(debugConsole, .pipeline, "⚠️ assistantSpeaking watchdog fired (>60s) — force-clearing")
                    ttsState.cancelPending()
                    markAssistantSpeechEnded(reason: "watchdog_timeout")
                    await playback.stop()
                }
            }

            // PATH C: Generation takeover — detect user speech during silent
            // generation (LLM thinking / tool execution) and cancel generation
            // when the signal is strong enough (sustained speech or keyword).
            if Self.shouldTrackGenerationTakeover(
                assistantSpeaking: assistantSpeaking,
                assistantGenerating: assistantGenerating
            ) {
                if vadOutput.isSpeech {
                    if bargeInState.generationTakeoverCandidate == nil {
                        bargeInState.generationTakeoverCandidate = GenerationTakeoverCandidate()
                    }

                    if var candidate = bargeInState.generationTakeoverCandidate {
                        candidate.speechSamples += chunk.samples.count
                        candidate.consecutiveSpeechChunks += 1
                        candidate.peakRms = max(candidate.peakRms, vadOutput.rms)
                        let remaining = max(0, GenerationTakeoverCandidate.maxAudioSamples - candidate.audioSamples.count)
                        if remaining > 0 {
                            candidate.audioSamples.append(contentsOf: chunk.samples.prefix(remaining))
                        }

                        // Run keyword classifier once we have enough audio.
                        if !candidate.hasInterruptKeyword,
                           candidate.audioSamples.count >= GenerationTakeoverCandidate.minSamplesForKeyword,
                           let classifier = keywordClassifier,
                           await classifier.isLoaded
                        {
                            if let classification = try? await classifier.classify(
                                audio: candidate.audioSamples,
                                sampleRate: config.audio.inputSampleRate
                            ), classification.label == .interrupt && classification.confidence > 0.85 {
                                candidate.hasInterruptKeyword = true
                                debugLog(debugConsole, .command,
                                         "PATH C keyword: interrupt (conf=\(String(format: "%.2f", classification.confidence)))")
                            }
                        }

                        bargeInState.generationTakeoverCandidate = candidate

                        // Decide whether to take over generation.
                        let shouldTakeover = candidate.hasInterruptKeyword
                            || (candidate.consecutiveSpeechChunks >= GenerationTakeoverCandidate.minConsecutiveChunksForTakeover
                                && candidate.peakRms >= GenerationTakeoverCandidate.minRmsForTakeover)
                        if shouldTakeover {
                            NSLog("PipelineCoordinator: PATH C generation takeover — keyword=%d chunks=%d peakRms=%.3f",
                                  candidate.hasInterruptKeyword ? 1 : 0,
                                  candidate.consecutiveSpeechChunks,
                                  candidate.peakRms)
                            debugLog(debugConsole, .command,
                                     "Generation takeover: keyword=\(candidate.hasInterruptKeyword) chunks=\(candidate.consecutiveSpeechChunks) peakRms=\(String(format: "%.3f", candidate.peakRms))")
                            markGenerationInterrupted()
                            endAssistantGeneration()
                            // Buffer is drained by endAssistantGeneration → drainSilentGenerationBuffer.
                        }
                    }
                } else {
                    // Speech gap — reset consecutive counter but keep the candidate.
                    bargeInState.generationTakeoverCandidate?.consecutiveSpeechChunks = 0
                }
            } else {
                bargeInState.generationTakeoverCandidate = nil
            }

            // False-interruption recovery: check timeout window.
            if bargeInState.falseInterruptionRecovery.observing {
                let result = bargeInState.falseInterruptionRecovery.checkTimeout()
                switch result {
                case .resumePlayback:
                    // Seamlessly resume paused audio from exact interruption point.
                    let resumed = await playback.resume()
                    if resumed {
                        // Use markAssistantSpeechStarted() instead of setting the flag
                        // directly — this syncs the echo suppressor, resets playback
                        // barge-in state, and updates lastAssistantStart. Without this,
                        // the echo suppressor thinks Fae is silent during resumed playback,
                        // allowing echo audio to leak through to STT.
                        markAssistantSpeechStarted()
                        NSLog("PipelineCoordinator: false interruption → resumed playback")
                        debugLog(debugConsole, .command, "False interruption recovery: resumed playback")
                    } else {
                        // Buffers expired or player not paused — fall back to repair utterance.
                        NSLog("PipelineCoordinator: pause/resume failed — falling back to repair utterance")
                        let repair = FalseInterruptionRecovery.buildRepairUtterance(
                            interruptedText: bargeInState.falseInterruptionRecovery.lastInterruption?.interruptedText
                        )
                        NSLog("PipelineCoordinator: false interruption → resume failed, speaking repair")
                        debugLog(debugConsole, .command, "False interruption recovery (fallback): \(repair)")
                        await speakDirect(repair)
                    }
                case .falseInterruption(let repair):
                    NSLog("PipelineCoordinator: false interruption detected — speaking repair")
                    debugLog(debugConsole, .command, "False interruption recovery: \(repair)")
                    await speakDirect(repair)
                case .noAction, .stillObserving:
                    break
                }
            }

            // Process completed speech segment via bounded queue.
            if let segment = vadOutput.segment {
                defer {
                    resetStreamingSpeakerGate()
                    resetStreamingWakeDetector()
                    // Increment epoch synchronously so any in-flight streaming
                    // transcription result is invalidated immediately.
                    speechInputStage.incrementStreamingEpoch()
                    Task { [weak self] in
                        await self?.sttEngine.resetStreaming()
                        await self?.streamingSTTEngine?.reset()
                    }
                }

                // Confirm follow-up speech for false-interruption detection.
                if bargeInState.falseInterruptionRecovery.observing && segment.durationSeconds > 0.5 {
                    bargeInState.falseInterruptionRecovery.recordFollowUpSpeech()
                }

                // During active TTS playback, discard completed segments — barge-in
                // is handled in-chunk (PATH A/B) before segment completion.
                if assistantSpeaking {
                    debugLog(debugConsole, .pipeline, "Discarded segment while assistant speaking dur=\(String(format: "%.2f", segment.durationSeconds))s")
                    continue
                }

                // During silent generation (LLM thinking / tool execution),
                // buffer segments so user speech isn't lost.  The buffer is
                // drained when generation finishes (see drainSilentGenerationBuffer).
                if assistantGenerating {
                    if silentGenerationBuffer.count < Self.maxSilentGenerationBufferSize {
                        silentGenerationBuffer.append(segment)
                        debugLog(debugConsole, .pipeline, "Buffered segment during silent generation dur=\(String(format: "%.2f", segment.durationSeconds))s (buffer=\(silentGenerationBuffer.count))")
                    } else {
                        debugLog(debugConsole, .pipeline, "Silent generation buffer full — dropped segment dur=\(String(format: "%.2f", segment.durationSeconds))s")
                    }
                    continue
                }
                if shouldDropSegmentFromStreamingSpeakerGate() {
                    debugLog(
                        debugConsole,
                        .speaker,
                        "Dropped segment from streaming speaker gate dur=\(String(format: "%.2f", segment.durationSeconds))s"
                    )
                    publishVoiceAttention(
                        stage: "speaker",
                        decision: "dropped",
                        reason: "streaming_speaker_gate_reject",
                        rms: VoiceActivityDetector.computeRMS(segment.samples)
                    )
                    continue
                }
                ttsState.lastUserTurnEndedAt = Date()

                // Speculative prefill: warm the LLM KV cache with the cached
                // system prompt + conversation history while the segment flows
                // through STT.  The prefill runs in parallel with final STT
                // (different models, brief GPU overlap).
                if let cachedPrompt = cachedGenerationSystemPrompt,
                   !assistantGenerating,
                   !assistantSpeaking,
                   await llmEngine.isLoaded
                {
                    speculativePrefillTask?.cancel()
                    let history = await conversationState.history
                    let options = cachedGenerationOptions ?? GenerationOptions()
                    speculativePrefillTask = Task { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.llmEngine.prefillSession(
                                messages: history,
                                systemPrompt: cachedPrompt,
                                options: options
                            )
                            NSLog("PipelineCoordinator: speculative prefill complete (history=%d)", history.count)
                        } catch {
                            if !Task.isCancelled {
                                NSLog("PipelineCoordinator: speculative prefill failed: %@", error.localizedDescription)
                            }
                        }
                    }
                }

                enqueueSpeechSegment(segment)
            }
        }
    }

    // MARK: - Speech Segment Processing

    private func clearPendingSemanticTurn() {
        pendingSemanticTurnTask?.cancel()
        pendingSemanticTurnTask = nil
        pendingSemanticTurn = nil
    }

    private func flushPendingSemanticTurnIfNeeded() async {
        guard let pending = pendingSemanticTurn else { return }
        pendingSemanticTurn = nil
        pendingSemanticTurnTask = nil
        publishVoiceAttention(
            stage: "semantic",
            decision: "flushed",
            reason: "hold_timeout_elapsed",
            transcript: pending.text,
            wakeSource: pending.acousticWakeDetection != nil ? "acoustic" : nil,
            wakeScore: pending.acousticWakeDetection?.similarity,
            semanticState: "flushed",
            rms: pending.rms
        )
        await processRecognizedVoiceText(
            rawText: pending.rawText,
            text: pending.text,
            ownerProfileExists: pending.ownerProfileExists,
            speakerAllowsConversation: pending.speakerAllowsConversation,
            rms: pending.rms,
            durationSecs: pending.durationSecs,
            acousticWakeDetection: pending.acousticWakeDetection,
            allowSemanticHold: false
        )
    }

    private func processRecognizedVoiceText(
        rawText: String,
        text: String,
        ownerProfileExists: Bool,
        speakerAllowsConversation: Bool,
        rms: Float,
        durationSecs: Float,
        acousticWakeDetection: WakeWordAcousticDetector.Detection?,
        allowSemanticHold: Bool
    ) async {
        var effectiveRawText = rawText
        var effectiveText = text
        var effectiveAcousticWakeDetection = acousticWakeDetection

        if let pending = pendingSemanticTurn {
            effectiveRawText = pending.rawText + " " + rawText
            effectiveText = TextProcessing.correctNameRecognition(effectiveRawText)
            effectiveText = await vocabularyCorrector.correct(effectiveText)
            if effectiveAcousticWakeDetection == nil {
                effectiveAcousticWakeDetection = pending.acousticWakeDetection
            }
            pendingSemanticTurn = nil
            pendingSemanticTurnTask?.cancel()
            pendingSemanticTurnTask = nil
            debugLog(debugConsole, .stt, "Semantic turn merged: \(effectiveText)")
            publishVoiceAttention(
                stage: "semantic",
                decision: "merged",
                reason: "continued_utterance",
                transcript: effectiveText,
                wakeSource: effectiveAcousticWakeDetection != nil ? "acoustic" : nil,
                wakeScore: effectiveAcousticWakeDetection?.similarity,
                semanticState: "merged",
                rms: rms
            )
        }

        if (awaitingApproval || pendingGovernanceAction != nil) && !speakerAllowsConversation {
            debugLog(
                debugConsole,
                .speaker,
                "Ignoring approval/governance reply from non-conversational speaker role=\(speakerGate.currentSpeakerRole?.rawValue ?? "unknown")"
            )
            return
        }

        // Approval gate — while a tool approval is pending, only approval responses
        // are accepted. This prevents unrelated chatter/noise from being routed to the LLM.
        if awaitingApproval {
            if manualOnlyApprovalPending {
                // Damage-control manual-only approval: voice is never accepted.
                // Only a physical button press on the overlay can proceed.
                debugLog(debugConsole, .approval, "Voice rejected for manual-only approval: \(effectiveText)")
                await speakDirect("This operation requires a deliberate button press to confirm. Voice approval is not accepted — please use the overlay.")
            } else if !Self.shouldAcceptVoiceApprovalResponse(
                awaitingApproval: awaitingApproval,
                manualOnlyApprovalPending: manualOnlyApprovalPending,
                assistantSpeaking: assistantSpeaking
            ) {
                debugLog(debugConsole, .approval, "Ignoring voice approval while assistant is still speaking the approval prompt")
            } else if let decision = VoiceCommandParser.parseApprovalResponse(effectiveText),
               let manager = approvalManager,
               await manager.resolveMostRecent(decision: decision, source: "voice")
            {
                debugLog(debugConsole, .approval, "Tool approval decision via voice: \(decision.rawValue)")
                awaitingApproval = false
                manualOnlyApprovalPending = false
                let ack: String
                switch decision {
                case .yes:
                    ack = PersonalityManager.nextApprovalGranted()
                case .no:
                    ack = PersonalityManager.nextApprovalDenied()
                case .always:
                    ack = "Got it, I'll always allow that tool."
                }
                await speakDirect(ack)
            } else {
                let words = effectiveText.split(whereSeparator: { $0.isWhitespace }).count
                if words > 2 {
                    debugLog(debugConsole, .approval, "Ambiguous tool approval response: \(effectiveText)")
                    await speakDirect(PersonalityManager.nextApprovalAmbiguous())
                }
            }
            return
        }

        if let pendingAction = pendingGovernanceAction {
            if let decision = VoiceCommandParser.parseApprovalResponse(effectiveText) {
                pendingGovernanceAction = nil
                debugLog(debugConsole, .approval, "Governance confirmation decision=\(decision.rawValue) action=\(pendingAction.action)")
                if decision != .no {
                    applyGovernanceAction(
                        action: pendingAction.action,
                        value: pendingAction.value,
                        source: "\(pendingAction.source)_confirm",
                        metadata: pendingAction.metadata
                    )
                    await speakDirect(pendingAction.successSpeech)
                } else {
                    await speakDirect(pendingAction.cancelledSpeech)
                }
            } else {
                let words = effectiveText.split(whereSeparator: { $0.isWhitespace }).count
                if words > 2 {
                    debugLog(debugConsole, .approval, "Ambiguous governance confirmation response: \(effectiveText)")
                    await speakDirect(pendingAction.confirmationPrompt)
                }
            }
            return
        }

        // Echo detection — if the transcribed text is a fragment of the last
        // assistant response, the mic picked up speaker output. Drop it.
        if !lastAssistantResponseText.isEmpty {
            let sttLower = effectiveText.lowercased()
            let assistLower = lastAssistantResponseText.lowercased()
            if assistLower.contains(sttLower) || sttLower.contains(assistLower) {
                NSLog("PipelineCoordinator: dropping echo (STT matched last assistant response)")
                debugLog(debugConsole, .pipeline, "Echo dropped (text match): \"\(effectiveText.prefix(60))\"")
                return
            }
            let sttWords = Set(sttLower.split(separator: " ").filter { $0.count > 2 })
            let assistWords = Set(assistLower.split(separator: " ").filter { $0.count > 2 })
            if sttWords.count >= 3, !assistWords.isEmpty {
                let overlap = sttWords.intersection(assistWords)
                if Double(overlap.count) / Double(sttWords.count) >= 0.6 {
                    NSLog("PipelineCoordinator: dropping echo (%.0f%% word overlap with last response)",
                          Double(overlap.count) / Double(sttWords.count) * 100)
                    debugLog(debugConsole, .pipeline, "Echo dropped (\(Int(Double(overlap.count) / Double(sttWords.count) * 100))%% overlap): \"\(effectiveText.prefix(60))\"")
                    return
                }
            }
        }

        let ghostWords = effectiveText.split(whereSeparator: { $0.isWhitespace }).count
        let ghostInFollowup = engagedUntil.map { Date() < $0 } ?? false
        if ghostWords <= 2,
           let lastStart = lastAssistantStart,
           Date().timeIntervalSince(lastStart) < 8.0,
           !effectiveText.lowercased().contains("fae"),
           !ghostInFollowup
        {
            NSLog("PipelineCoordinator: dropping post-speech ghost \"%@\" (%d words, %.1fs after speech start)",
                  effectiveText, ghostWords, Date().timeIntervalSince(lastStart))
            debugLog(debugConsole, .pipeline, "Ghost filtered: \"\(effectiveText)\" (\(ghostWords) words, recent speech)")
            return
        }

        if let wakeStore = wakeWordProfileStore {
            wakeAliases = await wakeStore.allAliases()
        }
        var wakeMatch = wakeAddressMatch(in: effectiveText, logDecision: true)
        var wakeSource: String?
        if wakeMatch != nil {
            wakeSource = "text"
        } else if effectiveAcousticWakeDetection != nil {
            wakeSource = "acoustic"
        }
        let wakeStrength: VoiceConversationWakeStrength? = {
            if effectiveAcousticWakeDetection != nil {
                return .exact
            }
            return wakeMatch.map { match in
                match.kind == .exact ? VoiceConversationWakeStrength.exact : .fuzzy
            }
        }()
        if !VoiceConversationPolicy.shouldHonorWakeMatch(
            ownerProfileExists: ownerProfileExists,
            firstOwnerEnrollmentActive: speakerGate.firstOwnerEnrollmentActive,
            speakerRole: speakerGate.currentSpeakerRole,
            wakeStrength: wakeStrength
        ) {
            if (wakeMatch != nil || effectiveAcousticWakeDetection != nil), ownerProfileExists, !speakerGate.firstOwnerEnrollmentActive {
                debugLog(
                    debugConsole,
                    .speaker,
                    "Ignoring wake match from non-conversational speaker role=\(speakerGate.currentSpeakerRole?.rawValue ?? "unknown")"
                )
            }
            wakeMatch = nil
            effectiveAcousticWakeDetection = nil
            wakeSource = nil
        }
        let addressedToFae = wakeMatch != nil || effectiveAcousticWakeDetection != nil
        if addressedToFae {
            await learnWakeAliasIfNeeded(rawText: effectiveRawText)
            // Auto-enroll acoustic wake template from confirmed wake segments
            // so the acoustic detector can fire before STT in future utterances.
            if effectiveAcousticWakeDetection == nil {
                await learnAcousticWakeTemplateIfNeeded()
            }
        }

        let inFollowup = engagedUntil.map { Date() < $0 } ?? false
        let shouldHoldShortFollowupFragment = allowSemanticHold
            && !addressedToFae
            && inFollowup
            && TextProcessing.isLikelyContinuationCue(effectiveText)
        if allowSemanticHold,
           Self.shouldDeferSemanticTurn(
                text: effectiveText,
                addressedToFae: addressedToFae,
                inFollowup: inFollowup,
                awaitingApproval: awaitingApproval,
                hasPendingGovernanceAction: pendingGovernanceAction != nil,
                firstOwnerEnrollmentActive: speakerGate.firstOwnerEnrollmentActive
           )
            || shouldHoldShortFollowupFragment
        {
            let pending = PendingSemanticTurn(
                rawText: effectiveRawText,
                text: effectiveText,
                ownerProfileExists: ownerProfileExists,
                speakerAllowsConversation: speakerAllowsConversation,
                rms: rms,
                durationSecs: durationSecs,
                acousticWakeDetection: effectiveAcousticWakeDetection
            )
            pendingSemanticTurn = pending
            pendingSemanticTurnTask?.cancel()
            pendingSemanticTurnTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.semanticTurnHoldMs) * 1_000_000)
                guard !Task.isCancelled else { return }
                await self?.flushPendingSemanticTurnIfNeeded()
            }
            debugLog(debugConsole, .pipeline, "Semantic turn hold: \"\(effectiveText)\"")
            publishVoiceAttention(
                stage: "semantic",
                decision: "held",
                reason: shouldHoldShortFollowupFragment ? "short_followup_fragment" : "likely_incomplete_turn",
                transcript: effectiveText,
                wakeSource: wakeSource,
                wakeScore: effectiveAcousticWakeDetection?.similarity,
                semanticState: "held",
                rms: rms
            )
            return
        }

        let wordCount = effectiveText.split(whereSeparator: { $0.isWhitespace }).count
        let attentionDecision = Self.fusedVoiceAttentionDecision(
            gateState: gateState,
            explicitWakeRequired: explicitWakeRequiredFromIdle,
            requireDirectAddress: effectiveRequireDirectAddress(),
            addressedToFae: addressedToFae,
            inFollowup: inFollowup,
            awaitingApproval: awaitingApproval,
            firstOwnerEnrollmentActive: speakerGate.firstOwnerEnrollmentActive,
            speakerAllowsConversation: speakerAllowsConversation,
            wordCount: wordCount
        )

        switch attentionDecision {
        case .ignoreWhileSleeping:
            debugLog(debugConsole, .command, "Ignored while sleeping (not addressed): \(effectiveText)")
            publishVoiceAttention(
                stage: "attention",
                decision: "ignored_sleeping",
                reason: "sleeping_without_address",
                transcript: effectiveText,
                wakeSource: wakeSource,
                wakeScore: effectiveAcousticWakeDetection?.similarity,
                rms: rms
            )
            if !explicitWakeRequiredFromIdle,
               wordCount >= 4,
               VoiceConversationPolicy.shouldOfferSleepHint(
                   ownerProfileExists: ownerProfileExists,
                   firstOwnerEnrollmentActive: speakerGate.firstOwnerEnrollmentActive,
                   speakerRole: speakerGate.currentSpeakerRole
               ),
               (lastSleepHintAt == nil || Date().timeIntervalSince(lastSleepHintAt!) > 20)
            {
                lastSleepHintAt = Date()
                await speakDirect("I’m resting right now—say hey Fae to wake me.")
            }
            return

        case .wakeAndContinue:
            publishVoiceAttention(
                stage: "attention",
                decision: "wake",
                reason: wakeSource == "acoustic" ? "acoustic_wake" : "text_wake",
                transcript: effectiveText,
                wakeSource: wakeSource,
                wakeScore: effectiveAcousticWakeDetection?.similarity,
                rms: rms
            )
            wake()

        case .dropDirectAddress:
            debugLog(debugConsole, .command, "Dropped (direct-address required): \(effectiveText)")
            publishVoiceAttention(
                stage: "attention",
                decision: "dropped_direct_address",
                reason: "direct_address_required",
                transcript: effectiveText,
                wakeSource: wakeSource,
                wakeScore: effectiveAcousticWakeDetection?.similarity,
                rms: rms
            )
            return

        case .dropShortIdle:
            debugLog(debugConsole, .pipeline, "Dropped short idle utterance: \"\(effectiveText)\"")
            publishVoiceAttention(
                stage: "attention",
                decision: "dropped_short_idle",
                reason: "idle_fragment_filter",
                transcript: effectiveText,
                wakeSource: wakeSource,
                wakeScore: effectiveAcousticWakeDetection?.similarity,
                rms: rms
            )
            return

        case .dropSpeaker:
            debugLog(
                debugConsole,
                .speaker,
                "Ignored speech from non-conversational speaker role=\(speakerGate.currentSpeakerRole?.rawValue ?? "unknown")"
            )
            publishVoiceAttention(
                stage: "attention",
                decision: "dropped_speaker",
                reason: "speaker_not_allowed",
                transcript: effectiveText,
                wakeSource: wakeSource,
                wakeScore: effectiveAcousticWakeDetection?.similarity,
                rms: rms
            )
            return

        case .allow:
            publishVoiceAttention(
                stage: "attention",
                decision: "accepted",
                reason: inFollowup ? "followup_window" : (wakeSource == nil ? "open_gate" : "addressed_to_fae"),
                transcript: effectiveText,
                wakeSource: wakeSource,
                wakeScore: effectiveAcousticWakeDetection?.similarity,
                rms: rms
            )
            break
        }

        eventBus.send(.transcription(text: effectiveText, isFinal: true))

        // Update partial transcript for transcript-aware endpointing (Milestone 4).
        speechInputStage.lastStreamingPartialTranscript = effectiveText

        // Keyword spotter: check for interrupt phrases (replaces hardcoded stop triggers).
        if let match = await keywordSpotter.check(partialTranscript: effectiveText) {
            if match.category == .interrupt {
                debugLog(debugConsole, .command, "Keyword spotter interrupt: \"\(match.configuredKeyword)\" (fuzzy=\(match.isFuzzy)) in \"\(effectiveText.prefix(60))\"")
                await resetConversationSession(trigger: effectiveText, source: "voice")
                return
            }
        }

        let voiceCommand = VoiceCommandParser.parse(effectiveText)
        debugLog(debugConsole, .command, "Parsed voice command: \(String(describing: voiceCommand))")
        let voiceCommandStarted = Date()
        let handledVoiceCommand = await handleVoiceCommandIfNeeded(voiceCommand, originalText: effectiveText)
        let voiceCommandLatencyMs = Int(Date().timeIntervalSince(voiceCommandStarted) * 1000)
        recordVoiceCommandMetrics(
            command: String(describing: voiceCommand),
            handled: handledVoiceCommand,
            latencyMs: voiceCommandLatencyMs
        )
        if handledVoiceCommand {
            debugLog(debugConsole, .command, "Handled voice command in \(voiceCommandLatencyMs)ms")
            return
        }

        await processTranscription(
            text: effectiveText,
            wakeMatch: wakeMatch,
            rms: rms,
            durationSecs: durationSecs
        )
    }

    /// Process a streaming partial transcript from the growing-buffer STT.
    /// Updates `lastStreamingPartialTranscript`, runs keyword spotter for early
    /// interrupt detection, and emits a non-final transcription event.
    ///
    /// The `epoch` parameter guards against stale partials: if the streaming
    /// session was reset between transcription start and result delivery, the
    /// epoch will have advanced and the partial is silently dropped.
    /// Source of a streaming partial transcript for diagnostics and disagreement tracking.
    private enum StreamingPartialSource: String {
        /// Parakeet TDT CTC fast-path (low-latency, lower accuracy).
        case parakeet
        /// Qwen3-ASR growing-buffer slow-path (higher latency, higher accuracy).
        case qwen3ASR = "qwen3_asr"
    }

    /// Last fast-path partial for disagreement detection against slow-path.
    private var lastFastPathPartial: String?

    /// Clear the streaming transcription single-slot guard.
    private func clearStreamingTranscriptionFlag() {
        streamingTranscriptionInFlight = false
    }

    private func handleStreamingPartialTranscript(
        _ text: String,
        epoch: UInt64,
        source: StreamingPartialSource = .qwen3ASR
    ) async {
        guard epoch == speechInputStage.streamingEpoch else {
            debugLog(debugConsole, .pipeline, "Dropped stale streaming partial (epoch \(epoch) != \(speechInputStage.streamingEpoch))")
            return
        }

        // Apply vocabulary correction to partials for better keyword matching.
        var correctedText = TextProcessing.correctNameRecognition(text)
        correctedText = await vocabularyCorrector.correct(correctedText)

        // Track fast-path vs. slow-path for disagreement logging.
        if source == .parakeet {
            lastFastPathPartial = correctedText
        } else if let fastPartial = lastFastPathPartial, !fastPartial.isEmpty {
            // Log significant disagreements between fast and slow path for analysis.
            let normalizedFast = fastPartial.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let normalizedSlow = correctedText.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !normalizedSlow.isEmpty, !normalizedFast.isEmpty,
               !normalizedSlow.hasPrefix(normalizedFast),
               !normalizedFast.hasPrefix(normalizedSlow)
            {
                debugLog(
                    debugConsole, .stt,
                    "ASR disagreement — fast: \"\(fastPartial.prefix(60))\" slow: \"\(correctedText.prefix(60))\""
                )
            }
        }

        speechInputStage.lastStreamingPartialTranscript = correctedText
        eventBus.send(.transcription(text: correctedText, isFinal: false))

        // Early interrupt detection via keyword spotter on partial text.
        if let match = await keywordSpotter.check(partialTranscript: correctedText),
           match.category == .interrupt
        {
            debugLog(debugConsole, .command, "Streaming partial interrupt: \"\(match.configuredKeyword)\" in \"\(correctedText.prefix(60))\"")
            await resetConversationSession(trigger: correctedText, source: "voice")
            return
        }

        // Run turn detector on streaming partial for adaptive endpointing.
        if let td = turnDetector {
            let prediction = await td.predictEndOfTurn(lastUserText: correctedText)
            lastEOUProbability = prediction.probability
        }
    }

    private func handleSpeechSegment(_ segment: SpeechSegment) async {
        let rms = VoiceActivityDetector.computeRMS(segment.samples)
        let durationSecs = Float(segment.samples.count) / Float(segment.sampleRate)

        // EMA dynamic endpointing: measure silence gap from last user turn end.
        // This adapts the silence threshold to the user's natural speaking rhythm.
        if let lastEnd = ttsState.lastUserTurnEndedAt, !assistantSpeaking {
            let gapMs = Float(segment.capturedAt.timeIntervalSince(lastEnd) * 1000)
            if gapMs > 0 && gapMs < 10_000 {  // Ignore very long gaps (separate sessions).
                vad.recordObservedSilenceMs(gapMs)
            }
        }

        // Stash segment for acoustic wake template auto-enrollment.
        lastProcessedSegment = segment
        defer { lastProcessedSegment = nil }

        // Capture wall-clock time from VAD onset for memory timestamps.
        speakerGate.currentUtteranceTimestamp = segment.capturedAt

        // Echo suppression check — pass segment onset time so the echo tail is
        // checked against when the speech STARTED, not when it finished processing.
        //
        // Exception: if the acoustic wake detector already fired during streaming
        // capture for this segment, the user is deliberately saying "Hi Fae" shortly
        // after Fae stopped talking. In that case, bypass the echo tail and short
        // utterance guard — the acoustic template match is strong evidence this is
        // real speech, not speaker bleedthrough. We still reject if Fae is actively
        // speaking (layer 1) since that's definitely echo overlap.
        let hasStreamingWake = speechInputStage.streamingWakeDetection != nil
        guard echoSuppressor.shouldAccept(
            durationSecs: durationSecs,
            rms: rms,
            awaitingApproval: awaitingApproval,
            segmentOnset: segment.capturedAt
        ) || (hasStreamingWake && !echoSuppressor.assistantSpeaking) else {
            NSLog("PipelineCoordinator: dropping %.1fs speech segment (echo suppression, onset=%.1fs ago)",
                  durationSecs, Date().timeIntervalSince(segment.capturedAt))
            debugLog(debugConsole, .pipeline, "Echo suppressed: \(String(format: "%.1f", durationSecs))s segment (rms=\(String(format: "%.3f", rms)), onset=\(String(format: "%.1f", Date().timeIntervalSince(segment.capturedAt)))s ago)")
            return
        }
        if hasStreamingWake {
            debugLog(debugConsole, .command, "Acoustic wake override: bypassed echo suppression for wake-detected segment")
        }

        // LLM quality gate — drop ambient noise.
        if rms < 0.008 && durationSecs > 3.0 {
            NSLog("PipelineCoordinator: dropping ambient segment (rms=%.4f, dur=%.1fs)", rms, durationSecs)
            return
        }

        // Apple SoundAnalysis pre-filter — reject music, TV, environmental noise.
        // Uses Apple's 303-category classifier to ensure we only process speech.
        // FAE_DISABLE_APPLE_CLASSIFIER=1 bypasses this for testing.
        let appleClassifierDisabled = ProcessInfo.processInfo.environment["FAE_DISABLE_APPLE_CLASSIFIER"] == "1"
        if !appleClassifierDisabled, await appleSpeechClassifier.isReady {
            if let classification = await appleSpeechClassifier.classify(segment: segment) {
                // Reject if music/TV is dominant over speech
                if classification.isMusic && !classification.isSpeech {
                    NSLog("PipelineCoordinator: dropping %.1fs segment (Apple classifier: music, conf=%.2f)",
                          durationSecs, classification.musicConfidence)
                    debugLog(debugConsole, .pipeline,
                             "Apple classifier rejected: music (conf=\(String(format: "%.2f", classification.musicConfidence)))")
                    return
                }
                // Reject if music confidence exceeds speech confidence (TV with speech+music)
                if classification.musicConfidence > classification.speechConfidence + 0.2 {
                    NSLog("PipelineCoordinator: dropping %.1fs segment (Apple classifier: music>speech, music=%.2f speech=%.2f)",
                          durationSecs, classification.musicConfidence, classification.speechConfidence)
                    debugLog(debugConsole, .pipeline,
                             "Apple classifier rejected: music dominant (music=\(String(format: "%.2f", classification.musicConfidence)) > speech=\(String(format: "%.2f", classification.speechConfidence)))")
                    return
                }
                // Log what we're accepting
                if classification.isSpeech {
                    debugLog(debugConsole, .pipeline,
                             "Apple classifier: speech (conf=\(String(format: "%.2f", classification.speechConfidence)))")
                }
            }
        }

        // Tier 2: Segment-level speech verification.
        // Uses the trained 1D-CNN speech verifier when available (93% accuracy
        // on MUSAN corpus), falls back to spectral tilt heuristic.
        // FAE_DISABLE_SPEECH_VERIFIER=1 bypasses this (for TTS-driven test harnesses
        // where synthetic speech gets misclassified as noise).
        let speechVerifierDisabled = ProcessInfo.processInfo.environment["FAE_DISABLE_SPEECH_VERIFIER"] == "1"
        if !speechVerifierDisabled, let verifier = speechVerifier, await verifier.isLoaded {
            if let result = try? await verifier.verify(
                audio: segment.samples,
                sampleRate: segment.sampleRate
            ), result.label != .speech, result.confidence > 0.80 {
                NSLog("PipelineCoordinator: dropping %.1fs segment (speech verifier: %@, conf=%.2f)",
                      durationSecs, result.label.name, result.confidence)
                debugLog(debugConsole, .pipeline,
                         "Speech verifier rejected: \(result.label.name) (conf=\(String(format: "%.2f", result.confidence)))")
                return
            }
        } else if !VoiceActivityDetector.spectralTiltLooksSpeechlike(
            samples: segment.samples, sampleRate: segment.sampleRate
        ) {
            // Fallback: spectral tilt heuristic when neural verifier not available.
            NSLog("PipelineCoordinator: dropping %.1fs segment (spectral tilt non-speech, rms=%.4f)",
                  durationSecs, rms)
            debugLog(debugConsole, .pipeline,
                     "Spectral tilt rejected segment: \(String(format: "%.1f", durationSecs))s (rms=\(String(format: "%.3f", rms)))")
            return
        }

        // Cross-correlation + spectral echo checks — compare segment against recent TTS playback.
        // Only during echo tail window to avoid unnecessary computation on idle segments.
        if echoSuppressor.isInSuppression {
            if echoSuppressor.isLikelyAcousticEcho(micSamples: segment.samples) {
                NSLog("PipelineCoordinator: dropping %.1fs segment (acoustic echo correlation)", durationSecs)
                debugLog(debugConsole, .pipeline,
                         "Acoustic echo rejected: \(String(format: "%.1f", durationSecs))s (cross-correlation match)")
                return
            }
            // Spectral envelope comparison — cosine similarity between mic and TTS band energies.
            let micBandEnergy = EchoSuppressor.computeBandEnergy(samples: segment.samples, sampleRate: segment.sampleRate)
            let similarity = EchoSuppressor.spectralEnvelopeSimilarity(micEnergy: micBandEnergy, ttsEnergy: echoSuppressor.playbackBandBaseline)
            if similarity >= EchoSuppressor.spectralSimilarityEchoThreshold {
                NSLog("PipelineCoordinator: dropping %.1fs segment (spectral envelope similarity=%.3f)", durationSecs, similarity)
                debugLog(debugConsole, .pipeline,
                         "Spectral echo rejected: \(String(format: "%.1f", durationSecs))s (similarity=\(String(format: "%.3f", similarity)))")
                return
            }
        }

        // Speaker identification (best-effort, non-blocking).
        speakerGate.currentSpeakerLabel = nil
        speakerGate.currentSpeakerDisplayName = nil
        speakerGate.currentSpeakerRole = nil
        speakerGate.currentSpeakerIsOwner = false
        speakerGate.currentSpeakerIsKnownNonOwner = false
        var speakerVerificationCompleted = false
        var speakerVerificationDegraded = false
        // Speaker recognition is always on — no config gate.
        if let encoder = speakerEncoder, await encoder.isLoaded,
           let store = speakerProfileStore
        {
            let melFallback = await isSpeakerEncoderMelFallback()

            if melFallback {
                // Mel-spectral fallback: enhanced 640-dim embedding (mean, std, skewness,
                // kurtosis, delta) provides reasonable speaker discrimination for small
                // household environments (1-3 people). Uses a relaxed threshold since
                // mel-spectral cosine similarity is lower than neural embeddings.
                do {
                    let embedding = try await encoder.embed(
                        audio: segment.samples,
                        sampleRate: segment.sampleRate
                    )
                    // Echo detection: reject if this sounds like Fae's TTS voice.
                    if echoSuppressor.isInSuppression,
                       let faeSelfSim = await store.matchesFaeSelf(
                           embedding: embedding,
                           threshold: config.speaker.threshold
                       )
                    {
                        NSLog(
                            "PipelineCoordinator: dropping %.1fs segment (mel-fallback echo, fae_self sim=%.3f)",
                            durationSecs, faeSelfSim
                        )
                        debugLog(
                            debugConsole,
                            .pipeline,
                            "Echo rejected [mel-fallback]: fae_self sim=\(String(format: "%.3f", faeSelfSim))"
                        )
                        return
                    }

                    // Speaker matching with mel-spectral embeddings.
                    // Use a relaxed threshold (0.15 below neural threshold) since
                    // statistical features have lower cosine similarity range.
                    let hasCompatibleOwner = await store.hasCompatibleOwnerProfile(embeddingDim: embedding.count)
                    let hasAnyOwner = await store.hasOwnerProfile()
                    if !hasCompatibleOwner && hasAnyOwner {
                        // Owner exists but with incompatible embedding dimension (e.g.,
                        // upgraded from 256-dim to 640-dim). Profiles need re-enrollment.
                        debugLog(debugConsole, .speaker, "Owner profile dimension mismatch (stored vs current) — re-enrollment needed")
                        NSLog("PipelineCoordinator: speaker profile dimension mismatch — owner needs re-enrollment")
                    }
                    if hasCompatibleOwner {
                        let relaxedThreshold = max(config.speaker.ownerThreshold - 0.15, 0.45)
                        let isOwner = await store.isOwner(embedding: embedding, threshold: relaxedThreshold)
                        if isOwner {
                            speakerGate.currentSpeakerRole = .owner
                            speakerGate.currentSpeakerIsOwner = true
                            speakerGate.currentSpeakerIsKnownNonOwner = false
                            speakerGate.currentSpeakerLabel = "owner"
                            speakerGate.currentSpeakerDisplayName = await store.ownerDisplayName() ?? "Owner"
                            debugLog(debugConsole, .speaker, "Owner verified (mel-spectral, threshold=\(String(format: "%.2f", relaxedThreshold)))")
                        } else {
                            // Not owner — still allow conversation but flag as unknown.
                            let best = await store.bestMatch(embedding: embedding, excludingRoles: [.faeSelf])
                            debugLog(debugConsole, .speaker, "Speaker not owner (mel-spectral, bestSim=\(String(format: "%.3f", best?.similarity ?? -1)))")
                        }
                    }
                } catch {
                    debugLog(debugConsole, .speaker, "Mel-fallback speaker check failed: \(error.localizedDescription)")
                }
                if speakerGate.currentSpeakerRole == nil {
                    speakerVerificationDegraded = true
                    debugLog(
                        debugConsole,
                        .speaker,
                        "Speaker verification degraded (mel-spectral fallback) — wake-word gating active"
                    )
                }
            } else {
                // Neural speaker encoder available — full speaker verification.
                do {
                    let hasOwner = await store.hasOwnerProfile()
                    let previewDecision = await previewSpeakerVerification(
                        segment: segment,
                        encoder: encoder,
                        store: store,
                        hasOwner: hasOwner
                    )

                    switch previewDecision {
                    case .echoRejected(let faeSelfSim):
                        NSLog(
                            "PipelineCoordinator: dropping %.1fs segment (preview fae_self sim=%.3f, echo suppressor active)",
                            durationSecs,
                            faeSelfSim
                        )
                        debugLog(
                            debugConsole,
                            .pipeline,
                            "Echo rejected [preview] (voice match fae_self sim=\(String(format: "%.3f", faeSelfSim)), suppressor active)"
                        )
                        return

                    case .rejectUnknown:
                        speakerVerificationCompleted = true
                        NSLog("PipelineCoordinator: preview speaker verification rejected unknown speaker")
                        debugLog(debugConsole, .speaker, "Preview rejected unknown speaker before full embed/STT")

                    case .useEmbedding(let embedding):
                        speakerVerificationCompleted = true
                        guard await evaluateSpeakerEmbedding(
                            embedding,
                            hasOwner: hasOwner,
                            store: store,
                            durationSecs: durationSecs,
                            threshold: max(config.speaker.threshold - Self.previewSpeakerThresholdRelaxation, 0.55),
                            progressiveEnrollment: true,
                            source: "preview"
                        ) else {
                            return
                        }

                    case .fallBackToFullSegment:
                        let embedding = try await encoder.embed(
                            audio: segment.samples,
                            sampleRate: segment.sampleRate
                        )
                        speakerVerificationCompleted = true

                        guard await evaluateSpeakerEmbedding(
                            embedding,
                            hasOwner: hasOwner,
                            store: store,
                            durationSecs: durationSecs,
                            threshold: config.speaker.threshold,
                            progressiveEnrollment: true,
                            source: "full"
                        ) else {
                            return
                        }
                    }
                } catch {
                    NSLog("PipelineCoordinator: speaker embed failed: %@", error.localizedDescription)
                    debugLog(debugConsole, .speaker, "Embed failed: \(error.localizedDescription)")
                }
            }
        } else {
            debugLog(debugConsole, .speaker, "Speaker encoder not loaded — owner verification skipped")
        }

        // Liveness enforcement: reject speech with low liveness score in enforce mode.
        // Skip in mel-fallback mode — liveness heuristics assume neural embeddings.
        let ownerProfileExistsForLiveness = await speakerProfileStore?.hasOwnerProfile() ?? false
        if !speakerVerificationDegraded,
           config.voiceIdentity.enabled,
           config.voiceIdentity.mode == "enforce",
           config.speaker.livenessThreshold > 0,
           let encoder = speakerEncoder,
           let liveness = await encoder.lastLivenessResult,
           liveness.score < config.speaker.livenessThreshold
        {
            NSLog("PipelineCoordinator: rejecting speech — liveness score %.3f below threshold %.2f",
                  liveness.score, config.speaker.livenessThreshold)
            if VoiceConversationPolicy.shouldOfferSleepHint(
                ownerProfileExists: ownerProfileExistsForLiveness,
                firstOwnerEnrollmentActive: speakerGate.firstOwnerEnrollmentActive,
                speakerRole: speakerGate.currentSpeakerRole
            ) {
                await speakDirect("I'm not sure that's a live voice. Could you speak directly to me?")
            } else {
                debugLog(debugConsole, .speaker, "Dropping low-liveness speech from non-conversational speaker")
            }
            return
        }

        let ownerProfileExists = await speakerProfileStore?.hasOwnerProfile() ?? false
        let speakerAllowsConversation: Bool
        if speakerVerificationDegraded {
            // Mel-spectral fallback cannot distinguish humans — allow conversation
            // but rely on requireDirectAddress / wake-word gating for access control.
            // Tools remain blocked (speakerGate.currentSpeakerIsOwner = false).
            speakerAllowsConversation = true
        } else {
            speakerAllowsConversation = VoiceConversationPolicy.allowsConversation(
                ownerProfileExists: ownerProfileExists,
                firstOwnerEnrollmentActive: speakerGate.firstOwnerEnrollmentActive,
                speakerRole: speakerGate.currentSpeakerRole
            )
        }

        if Self.shouldSkipSTTAfterSpeakerVerification(
            ownerProfileExists: ownerProfileExists,
            speakerVerificationCompleted: speakerVerificationCompleted,
            firstOwnerEnrollmentActive: speakerGate.firstOwnerEnrollmentActive,
            speakerRole: speakerGate.currentSpeakerRole
        ) {
            debugLog(
                debugConsole,
                .speaker,
                "Skipped STT for non-conversational speaker role=\(speakerGate.currentSpeakerRole?.rawValue ?? "unknown")"
            )
            return
        }

        // Speaker change detection.
        if let prevLabel = speakerGate.previousSpeakerLabel,
           let currLabel = speakerGate.currentSpeakerLabel,
           prevLabel != currLabel
        {
            NSLog("PipelineCoordinator: speaker change detected: %@ → %@", prevLabel, currLabel)
        }
        speakerGate.previousSpeakerLabel = speakerGate.currentSpeakerLabel
        speakerGate.utterancesSinceOwnerVerified = speakerGate.currentSpeakerIsOwner ? 0 : speakerGate.utterancesSinceOwnerVerified + 1

        await refreshDegradedModeIfNeeded(context: "before_stt")

        // STT stage.
        guard await sttEngine.isLoaded else {
            NSLog("PipelineCoordinator: STT not loaded, dropping segment")
            return
        }

        do {
            let sttStartedAt = Date()
            let result = try await sttEngine.transcribe(
                samples: segment.samples,
                sampleRate: segment.sampleRate
            )
            let sttLatencyMs = Date().timeIntervalSince(sttStartedAt) * 1000
            NSLog("phase1.stt_latency_ms=%.2f", sttLatencyMs)

            let rawText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawText.isEmpty else { return }

            // Correct common ASR misrecognitions — first static "Fae" corrections,
            // then dynamic corrections from the user's known vocabulary (names,
            // entities, speaker profiles).
            var text = TextProcessing.correctNameRecognition(rawText)
            text = await vocabularyCorrector.correct(text)

            NSLog("PipelineCoordinator: STT → \"%@\"", text)
            debugLog(debugConsole, .stt, text)

            // Text-overlap echo rejection: if the transcribed text closely matches
            // what Fae recently said, it's almost certainly speaker bleedthrough that
            // survived timing-based and voice-identity echo checks.
            if echoSuppressor.isLikelyEchoText(text) {
                NSLog("PipelineCoordinator: dropping STT text — matches recent assistant speech (text-overlap echo)")
                debugLog(debugConsole, .pipeline, "Text-overlap echo rejected: \"\(text)\"")
                return
            }

            // Short-utterance echo guard: tiny transcriptions (1-2 words, < 2s)
            // that arrive within 5s of Fae's last speech are almost always echo
            // artifacts or ambient noise. Real user interruptions are typically
            // longer ("stop", "wait" are caught by barge-in before STT).
            let wordCount = text.split(separator: " ").count
            if wordCount <= 2 && durationSecs < 2.0 && echoSuppressor.secondsSinceLastSpeech < 5.0 {
                NSLog("PipelineCoordinator: dropping short utterance \"%@\" (echo guard: %d words, %.1fs, %.1fs after speech)", text, wordCount, durationSecs, echoSuppressor.secondsSinceLastSpeech)
                debugLog(debugConsole, .pipeline, "Short-utterance echo guard: \"\(text)\" (\(wordCount) words)")
                return
            }

            let acousticWakeDetection = await acousticWakeDetectionForSegment(segment)

            await processRecognizedVoiceText(
                rawText: rawText,
                text: text,
                ownerProfileExists: ownerProfileExists,
                speakerAllowsConversation: speakerAllowsConversation,
                rms: rms,
                durationSecs: durationSecs,
                acousticWakeDetection: acousticWakeDetection,
                allowSemanticHold: true
            )

        } catch {
            NSLog("PipelineCoordinator: STT error: %@", error.localizedDescription)
        }
    }

    // MARK: - LLM Processing

    private func processTranscription(
        text: String,
        wakeMatch: TextProcessing.WakeAddressMatch? = nil,
        rms: Float?,
        durationSecs: Float?,
        proactiveContext: ProactiveRequestContext? = nil,
        turnSource: ActionSource = .voice,
        playsThinkingTone: Bool = true,
        allowsAudibleOutput: Bool = true
    ) async {
        currentTurnID = UUID().uuidString
        ttsState.resetForNewTurn()
        if proactiveContext != nil {
            ttsState.lastUserTurnEndedAt = nil
        } else if ttsState.lastUserTurnEndedAt == nil {
            // Text injection path has no VAD segment-close marker.
            ttsState.lastUserTurnEndedAt = Date()
        }

        debugLog(debugConsole, .qa, "Process transcription [turn=\(currentTurnID?.prefix(8) ?? "none")]: \(text)")

        // STT repetition guard — drop degenerate ASR output (e.g. "oh oh oh oh..." ×1000).
        if TextProcessing.isRepetitiveHallucination(text) {
            NSLog("PipelineCoordinator: dropping repetitive STT hallucination (%d chars)", text.count)
            debugLog(debugConsole, .pipeline, "⚠️ Dropped repetitive STT hallucination (\(text.count) chars)")
            return
        }

        // Extract query if name-addressed.
        var queryText = text
        if let match = wakeMatch ?? wakeAddressMatch(in: text) {
            queryText = TextProcessing.extractQueryAroundName(in: text, nameRange: match.range)
            debugLog(debugConsole, .command, "Direct-address extraction: \(queryText)")
            // Refresh follow-up window.
            engage()
            if queryText.isEmpty {
                debugLog(debugConsole, .command, "Wake-only utterance ignored after direct-address extraction")
                return
            }
        }

        // Correction detection — check if user is correcting Fae before processing.
        if proactiveContext == nil {
            if let correction = CorrectionDetector.detect(
                in: queryText,
                lastAssistantText: lastAssistantResponseText
            ) {
                let record = CorrectionRecord(
                    correction: correction,
                    lastAssistantText: lastAssistantResponseText.isEmpty ? nil : lastAssistantResponseText,
                    speakerLabel: nil,
                    timestamp: Date()
                )
                pendingCorrection = record
                debugLog(debugConsole, .pipeline, "Correction detected: \(correction.kind.rawValue)")
            }
        }

        // Barge-in: if assistant is still active, interrupt and process the new input.
        if assistantSpeaking || assistantGenerating {
            markGenerationInterrupted()
            ttsState.cancelPending()
            await playback.stop()
        }

        let forceFastCommandPath = shouldForceThinkingSuppression(for: queryText)
        if forceFastCommandPath {
            debugLog(debugConsole, .command, "Force thinking suppression for short control-style utterance: \(queryText)")
        }

        explicitUserAuthorizationForTurn = Self.detectExplicitUserAuthorization(in: queryText)
        if explicitUserAuthorizationForTurn {
            debugLog(debugConsole, .approval, "Explicit user authorization detected for turn")
        }

        if proactiveContext == nil {
            await userInteractionHandler?()
        }

        if proactiveContext == nil,
           await handleDeterministicEasyTurnIfNeeded(
                originalUserText: text,
                queryText: queryText,
                allowsAudibleOutput: allowsAudibleOutput,
                tag: proactiveContext?.conversationTag
           )
        {
            return
        }

        // Unified pipeline: LLM decides when to use tools via <tool_call> markup.
        await generateWithTools(
            userText: queryText,
            isToolFollowUp: false,
            turnCount: 0,
            forceSuppressThinking: forceFastCommandPath,
            proactiveContext: proactiveContext,
            turnSource: turnSource,
            playsThinkingTone: playsThinkingTone,
            allowsAudibleOutput: allowsAudibleOutput
        )
    }

    private func handleDeterministicEasyTurnIfNeeded(
        originalUserText: String,
        queryText: String,
        allowsAudibleOutput: Bool,
        tag: String?
    ) async -> Bool {
        let rememberedName = await resolvedRememberedUserName()
        guard let action = Self.deterministicEasyTurnAction(
            for: queryText,
            rememberedUserName: rememberedName
        ) else {
            return false
        }

        let responseText: String
        switch action {
        case .arithmetic(let reply):
            responseText = reply
        case .rememberUserName(let name, let reply):
            sessionDeclaredUserName = name
            responseText = reply
        case .recallUserName(let reply):
            responseText = reply
        }

        assistantGenerating = true
        eventBus.send(.assistantGenerating(true))
        await conversationState.addUserMessage(
            queryText,
            speakerDisplayName: speakerGate.currentSpeakerDisplayName,
            speakerId: speakerGate.currentSpeakerLabel,
            tag: tag
        )
        await persistAcceptedUserTurnIfNeeded(queryText)
        lastAssistantResponseText = responseText
        if allowsAudibleOutput {
            await speakText(responseText, isFinal: true)
        } else {
            sendAssistantText(responseText, isFinal: true)
        }
        await conversationState.addAssistantMessage(responseText, tag: tag)
        await synchronizeLLMSession()
        await persistFinalAssistantTurnIfNeeded(responseText)

        let ownerProfileExists = await speakerProfileStore?.hasOwnerProfile() ?? false
        if VoiceConversationPolicy.shouldPersistSpeechMemory(
            ownerProfileExists: ownerProfileExists,
            firstOwnerEnrollmentActive: speakerGate.firstOwnerEnrollmentActive,
            speakerRole: speakerGate.currentSpeakerRole
        ) {
            let turnId = newMemoryId(prefix: "turn")
            _ = await memoryOrchestrator?.capture(
                turnId: turnId,
                userText: originalUserText,
                assistantText: responseText,
                speakerId: speakerGate.currentSpeakerLabel,
                utteranceTimestamp: speakerGate.currentUtteranceTimestamp
            )
            await capturePendingCorrection()
        }

        endAssistantGeneration()
        engage()
        return true
    }

    private func resolvedRememberedUserName() async -> String? {
        if let sessionDeclaredUserName,
           !sessionDeclaredUserName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return sessionDeclaredUserName
        }

        if let displayName = speakerGate.currentSpeakerDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty,
           displayName.caseInsensitiveCompare("Owner") != .orderedSame
        {
            return displayName
        }

        if let storedName = await memoryOrchestrator?.rememberedUserName()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !storedName.isEmpty
        {
            return storedName
        }

        if let ownerName = await speakerProfileStore?.ownerDisplayName()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ownerName.isEmpty,
           ownerName.caseInsensitiveCompare("Owner") != .orderedSame
        {
            return ownerName
        }

        return nil
    }

    private func shouldForceThinkingSuppression(for text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return false }

        let words = lower.split(whereSeparator: { $0.isWhitespace }).count
        if words <= 4 && lower.contains("settings") {
            return true
        }
        guard words <= 10 else { return false }

        let controlTargets = [
            "settings", "preferences", "canvas", "conversation", "discussions",
            "permissions", "tool mode", "tools", "vision", "thinking", "barge", "direct address",
        ]
        guard controlTargets.contains(where: { lower.contains($0) }) else {
            return false
        }

        let controlVerbs = [
            "open", "close", "hide", "show", "enable", "disable", "turn on", "turn off",
            "set", "switch", "bring up", "pull up", "dismiss",
        ]
        return controlVerbs.contains(where: { lower.contains($0) })
            || lower.hasPrefix("can you")
            || lower.hasPrefix("could you")
            || lower.hasPrefix("please")
    }

    private static func detectExplicitUserAuthorization(in text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return false }

        let directPhrases = [
            "go ahead", "do it", "please do", "please run", "run it", "yes do", "you can",
            "i approve", "approved", "confirm this", "proceed", "that is fine",
            "run the command", "execute this bash command", "in the terminal, run",
        ]
        if directPhrases.contains(where: { lower.contains($0) }) {
            return true
        }

        // Compact imperative requests are usually explicit enough.
        let tokens = lower.split(whereSeparator: { $0.isWhitespace })
        if tokens.count <= 4 {
            let starts = ["read", "write", "edit", "search", "fetch", "open", "close", "list", "show", "run"]
            if let first = tokens.first, starts.contains(String(first)) {
                return true
            }
        }

        return false
    }

    // MARK: - Voice Commands

    private func handleVoiceCommandIfNeeded(
        _ command: VoiceCommandParser.VoiceCommand,
        originalText: String
    ) async -> Bool {
        debugLog(debugConsole, .command, "Evaluate command: \(String(describing: command))")
        switch command {
        case .showCanvas:
            eventBus.send(.voiceCommandRecognized("show_canvas"))
            eventBus.send(.canvasVisibility(true))
            await speakDirect("Opening the canvas.")
            return true

        case .hideCanvas:
            eventBus.send(.voiceCommandRecognized("hide_canvas"))
            eventBus.send(.canvasVisibility(false))
            await speakDirect("Hiding the canvas.")
            return true

        case .showConversation:
            eventBus.send(.voiceCommandRecognized("show_conversation"))
            eventBus.send(.conversationVisibility(true))
            await speakDirect("Opening the conversation.")
            return true

        case .hideConversation:
            eventBus.send(.voiceCommandRecognized("hide_conversation"))
            eventBus.send(.conversationVisibility(false))
            await speakDirect("Hiding the conversation.")
            return true

        case .showSettings:
            eventBus.send(.voiceCommandRecognized("show_settings"))
            let openResult: (primary: Bool, fallback: Bool) = await MainActor.run {
                let primary = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                let fallback = !primary
                    ? NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    : false
                NotificationCenter.default.post(name: .faeOpenSettingsRequested, object: nil)
                return (primary: primary, fallback: fallback)
            }
            debugLog(
                debugConsole,
                .command,
                "Show settings direct open primary=\(openResult.primary) fallback=\(openResult.fallback)"
            )
            await speakDirect("Opening settings.")
            return true

        case .hideSettings:
            eventBus.send(.voiceCommandRecognized("hide_settings"))
            await MainActor.run {
                NotificationCenter.default.post(name: .faeCloseSettingsRequested, object: nil)
            }
            await speakDirect("Closing settings.")
            return true

        case .showPermissionsCanvas:
            eventBus.send(.voiceCommandRecognized("show_permissions_canvas"))
            let html = await buildToolsAndPermissionsCanvasHTML(triggerText: originalText)
            eventBus.send(.canvasContent(html: html, append: false))
            eventBus.send(.canvasVisibility(true))
            await speakDirect("Here are your current tools and permission levels.")
            return true

        case .setToolMode(let requestedMode):
            eventBus.send(.voiceCommandRecognized("set_tool_mode:\(requestedMode)"))
            guard await canRunGovernanceVoiceTransaction(originalText) else { return true }

            let normalized = requestedMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let currentMode = effectiveToolMode()
            if currentMode == normalized {
                await speakDirect("Tool mode is already \(displayToolMode(normalized)).")
                return true
            }

            // No governance confirmation needed — only two modes now (assistant/full).

            applyGovernanceAction(action: "set_tool_mode", value: .string(normalized), source: "voice")
            await speakDirect("Done. Tool mode is now \(displayToolMode(normalized)).")
            return true

        case .setThinking(let enabled):
            return await handleBooleanGovernanceCommand(
                originalText: originalText,
                key: "llm.thinking_enabled",
                enabled: enabled,
                currentValue: (thinkingLevelLive ?? config.llm.resolvedThinkingLevel).enablesThinking,
                voiceTag: "set_thinking",
                highRiskWhenEnabled: false,
                onApplied: "Done. Thinking mode is now \(enabled ? "on" : "off")."
            )

        case .setBargeIn:
            // Barge-in is always on — acknowledge but do nothing.
            await speakDirect("Barge-in is always enabled—you can interrupt me any time.")
            return true

        case .setDirectAddress(let enabled):
            return await handleBooleanGovernanceCommand(
                originalText: originalText,
                key: "conversation.require_direct_address",
                enabled: enabled,
                currentValue: effectiveRequireDirectAddress(),
                voiceTag: "set_direct_address",
                highRiskWhenEnabled: false,
                onApplied: "Done. Direct-address requirement is now \(enabled ? "on" : "off")."
            )

        case .setVision(let enabled):
            return await handleBooleanGovernanceCommand(
                originalText: originalText,
                key: "vision.enabled",
                enabled: enabled,
                currentValue: effectiveVisionEnabled(),
                voiceTag: "set_vision",
                highRiskWhenEnabled: enabled,
                onApplied: "Done. Vision is now \(enabled ? "enabled" : "disabled")."
            )

        case .setVoiceIdentityLock(let enabled):
            return await handleBooleanGovernanceCommand(
                originalText: originalText,
                key: "tts.voice_identity_lock",
                enabled: enabled,
                currentValue: effectiveVoiceIdentityLock(),
                voiceTag: "set_voice_identity_lock",
                highRiskWhenEnabled: !enabled,
                onApplied: enabled
                    ? "Done. Voice identity lock is now on."
                    : "Done. Voice identity lock is now off."
            )

        case .requestPermission(let capability):
            eventBus.send(.voiceCommandRecognized("request_permission:\(capability)"))
            guard await canRunGovernanceVoiceTransaction(originalText) else { return true }
            await requestPermissionFlow(capability: capability, source: "voice")
            return true

        case .runDiagnostics:
            eventBus.send(.voiceCommandRecognized("run_diagnostics"))
            debugLog(debugConsole, .command, "Activating self-diagnostic skill via voice command")
            await activateDiagnosticSkill()
            return true

        case .switchModel, .approvalResponse, .none:
            return false
        }
    }

    private func canRunGovernanceVoiceTransaction(_ originalText: String) async -> Bool {
        let inFollowup = engagedUntil.map { Date() < $0 } ?? false
        let addressed = isAddressedToFae(originalText)
        if !addressed && !inFollowup {
            debugLog(debugConsole, .governance, "Rejected governance command (not addressed): \(originalText)")
            await speakDirect("Please say my name when changing governance or permission settings.")
            return false
        }
        debugLog(debugConsole, .governance, "Accepted governance command (addressed=\(addressed), followup=\(inFollowup))")
        return true
    }

    private func handleBooleanGovernanceCommand(
        originalText: String,
        key: String,
        enabled: Bool,
        currentValue: Bool,
        voiceTag: String,
        highRiskWhenEnabled: Bool,
        onApplied: String
    ) async -> Bool {
        eventBus.send(.voiceCommandRecognized("\(voiceTag):\(enabled ? "on" : "off")"))
        guard await canRunGovernanceVoiceTransaction(originalText) else { return true }

        if currentValue == enabled {
            debugLog(debugConsole, .governance, "No-op setting change: \(key)=\(enabled)")
            await speakDirect("\(displaySettingName(key)) is already \(enabled ? "on" : "off").")
            return true
        }

        if highRiskWhenEnabled {
            debugLog(debugConsole, .approval, "Queued confirmation for high-risk setting: \(key)=\(enabled)")
            pendingGovernanceAction = PendingGovernanceAction(
                action: "set_setting",
                value: .bool(enabled),
                metadata: ["key": key],
                source: "voice",
                confirmationPrompt: "Please say yes or no to confirm the setting change.",
                successSpeech: onApplied,
                cancelledSpeech: "Okay, I won't change that setting."
            )
            await speakDirect("This setting can reduce safeguards. Are you sure? Say yes or no.")
            return true
        }

        debugLog(debugConsole, .governance, "Apply setting via voice: \(key)=\(enabled)")
        applyGovernanceAction(
            action: "set_setting",
            value: .bool(enabled),
            source: "voice",
            metadata: ["key": key]
        )
        await speakDirect(onApplied)
        return true
    }

    /// Activate the self-diagnostic skill and inject a diagnostic prompt.
    private func activateDiagnosticSkill() async {
        if let sm = skillManager {
            _ = await sm.activate(skillName: "self-diagnostic")
        }
        let prompt = "Run a full self-diagnostic check now. Work through each section of the diagnostic checklist."
        await injectText(prompt)
    }

    /// Capture a pending correction as a memory record and feed name corrections
    /// into the dynamic vocabulary corrector.
    private func capturePendingCorrection() async {
        guard let record = pendingCorrection else { return }
        pendingCorrection = nil

        // Store correction as memory record.
        if let memory = memoryOrchestrator {
            let turnId = newMemoryId(prefix: "correction")
            do {
                _ = try await memory.storeCorrection(record, turnId: turnId)
                debugLog(debugConsole, .memory, "Stored correction record: \(record.correction.kind.rawValue)")
            } catch {
                debugLog(debugConsole, .memory, "Failed to store correction: \(error)")
            }
        }

        // Feed name corrections into DynamicVocabularyCorrector.
        if record.correction.kind == .nameError,
           let correct = record.correction.correctedValue
        {
            await vocabularyCorrector.addCorrectionPair(
                wrong: record.correction.originalValue,
                correct: correct
            )
            debugLog(debugConsole, .pipeline, "Fed name correction to vocabulary corrector: \(correct)")
        }
    }

    private func requestPermissionFlow(capability: String, source: String) async {
        let label = capability.replacingOccurrences(of: "_", with: " ")
        debugLog(debugConsole, .governance, "Permission request via \(source): \(capability)")
        applyGovernanceAction(
            action: "request_permission",
            value: .string(capability),
            source: source,
            metadata: ["capability": capability]
        )
        await speakDirect("Okay. Requesting \(label) permission now.")

        let trigger = "permission refresh: \(capability)"
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            await self.logGovernanceDebug("Refreshing permissions snapshot after request: \(capability)")
            let html = await self.buildToolsAndPermissionsCanvasHTML(triggerText: trigger)
            self.eventBus.send(.canvasContent(html: html, append: false))
            self.eventBus.send(.canvasVisibility(true))
        }
    }

    private func buildToolsAndPermissionsCanvasHTML(triggerText: String) async -> String {
        let snapshot = await buildToolsAndPermissionsSnapshot(triggerText: triggerText)
        return snapshot.toCanvasHTML()
    }

    private func buildToolsAndPermissionsSnapshot(triggerText: String) async -> ToolPermissionSnapshot {
        let mode = effectiveToolMode()
        let permissions = await MainActor.run { PermissionStatusProvider.current() }
        let ownerProfileExists = await speakerProfileStore?.hasOwnerProfile() ?? false
        let approvalSnapshot = await ApprovedToolsStore.shared.approvalSnapshot()

        let speakerState: String = {
            if speakerGate.currentSpeakerIsOwner { return "Owner verified" }
            if speakerGate.currentSpeakerIsKnownNonOwner { return "Known non-owner speaker" }
            if speakerGate.currentSpeakerLabel != nil { return "Recognized speaker" }
            return "Speaker unknown"
        }()

        return CapabilitySnapshotService.buildSnapshot(
            triggerText: triggerText,
            toolMode: mode,
            privacyMode: effectivePrivacyMode(),
            speakerState: speakerState,
            ownerGateEnabled: config.speaker.requireOwnerForTools,
            ownerProfileExists: ownerProfileExists,
            permissions: permissions,
            thinkingEnabled: (thinkingLevelLive ?? config.llm.resolvedThinkingLevel).enablesThinking,
            requireDirectAddress: effectiveRequireDirectAddress(),
            visionEnabled: effectiveVisionEnabled(),
            voiceIdentityLock: effectiveVoiceIdentityLock(),
            approvalSnapshot: approvalSnapshot,
            registry: registry
        )
    }

    private func applyGovernanceAction(
        action: String,
        value: AnySendableValue,
        source: String,
        metadata: [String: String] = [:]
    ) {
        var userInfo: [String: Any] = [
            "action": action,
            "source": source,
        ]

        switch value {
        case .string(let text):
            userInfo["value"] = text
        case .bool(let bool):
            userInfo["value"] = bool
        }

        for (key, val) in metadata {
            userInfo[key] = val
        }

        let metadataSummary = metadata.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        debugLog(debugConsole, .governance, "Apply governance action=\(action) source=\(source) value=\(String(describing: userInfo["value"])) meta=[\(metadataSummary)]")

        eventBus.send(.voiceCommandRecognized("governance_applied:\(action):\(source)"))

        Task { @MainActor in
            NotificationCenter.default.post(
                name: .faeGovernanceActionRequested,
                object: nil,
                userInfo: userInfo
            )
        }
    }

    private func displaySettingName(_ key: String) -> String {
        switch key {
        case "llm.thinking_enabled":
            return "Thinking mode"
        case "barge_in.enabled":
            return "Barge-in (always on)"
        case "conversation.require_direct_address":
            return "Direct-address requirement"
        case "vision.enabled":
            return "Vision"
        case "tts.voice_identity_lock":
            return "Voice identity lock"
        default:
            return key
        }
    }

    private func recordVoiceCommandMetrics(command: String, handled: Bool, latencyMs: Int) {
        let defaults = FaeEnvironment.defaults
        defaults.set(defaults.integer(forKey: "fae.voice.commands.total") + 1, forKey: "fae.voice.commands.total")
        if handled {
            defaults.set(defaults.integer(forKey: "fae.voice.commands.handled") + 1, forKey: "fae.voice.commands.handled")
        }
        defaults.set(latencyMs, forKey: "fae.voice.commands.last_latency_ms")
        defaults.set(Date().timeIntervalSince1970, forKey: "fae.voice.commands.last_ts")
        NSLog("phase1.voice_command trace command=%@ handled=%d latency_ms=%d", command, handled ? 1 : 0, latencyMs)
    }

    private func logGovernanceDebug(_ text: String) {
        debugLog(debugConsole, .governance, text)
    }

    private func displayToolMode(_ mode: String) -> String {
        switch mode {
        case "assistant":
            return "read only"
        case "full":
            return "everything with approval"
        default:
            return mode
        }
    }

    private static func shouldShowCapabilitiesCanvas(triggerText: String, modelResponse: String) -> Bool {
        let lowerTrigger = triggerText.lowercased()
        let lowerResponse = stripThinkContent(modelResponse).lowercased()

        if lowerResponse.contains("<show_capabilities/>") || lowerResponse.contains("<show_capabilities>") {
            return true
        }

        let queryPhrases = [
            "what can you do",
            "what are your capabilities",
            "what are your skills",
            "show me your skills",
            "show your skills",
            "show capabilities",
            "help me understand what you can do",
        ]
        return queryPhrases.contains { lowerTrigger.contains($0) }
    }

    private func trustedCapabilitiesCanvasHTML() -> String {
        let toolCount = registry.toolNames.count
        return """
        <html>
        <head>
          <meta name='viewport' content='width=device-width, initial-scale=1' />
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #0f1015; color: #e9e9ef; padding: 18px; line-height: 1.45; }
            .panel { border: 1px solid #2a2d38; border-radius: 10px; padding: 12px; margin-bottom: 10px; background: #171a23; }
            .chips { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 8px; }
            .chip { font-size: 11px; text-decoration: none; color: #e9e9ef; border: 1px solid #3d4354; padding: 5px 9px; border-radius: 999px; background: #202533; }
            ul { margin: 8px 0 0 18px; padding: 0; }
            li { margin: 4px 0; }
            .hint { color: #99a0b6; font-size: 12px; }
          </style>
        </head>
        <body>
          <div class='panel'>
            <p><strong>What I can do for you</strong></p>
            <ul>
              <li>Voice identity + owner-aware safety</li>
              <li>Persistent memory and relationship context</li>
              <li>\(toolCount) built-in tools (read/write/edit/bash, web, calendar, reminders, contacts, mail, notes)</li>
              <li>Vision tools (camera, screenshot, read_screen)</li>
              <li>Scheduler + proactive morning/overnight workflows</li>
              <li>Skill system (activate, run, create, update)</li>
              <li>Self-configuration of behavior and preferences</li>
            </ul>
            <div class='chips'>
              <a class='chip' href='fae-action://open_settings?source=canvas'>Open settings</a>
              <a class='chip' href='fae-action://start_owner_enrollment?source=canvas'>Voice enrollment</a>
            </div>
            <p class='hint'>Tip: ask “show tools and permissions” for a live policy snapshot.</p>
          </div>
        </body>
        </html>
        """
    }

    private func maybeShowCapabilitiesCanvas(triggerText: String, modelResponse: String) {
        guard Self.shouldShowCapabilitiesCanvas(triggerText: triggerText, modelResponse: modelResponse) else {
            return
        }
        let html = trustedCapabilitiesCanvasHTML()
        eventBus.send(.canvasContent(html: html, append: false))
        eventBus.send(.canvasVisibility(true))
        debugLog(debugConsole, .qa, "Capabilities canvas opened from trusted template")
    }

    /// Unified LLM generation with inline tool execution.
    ///
    /// Streams tokens to TTS. If the model outputs `<tool_call>` markup, executes the
    /// tools and re-generates with the results. Recurses up to `maxToolTurns` times.
    private func generateWithTools(
        userText: String,
        isToolFollowUp: Bool,
        turnCount: Int,
        forceSuppressThinking: Bool = false,
        generationContext providedGenerationContext: GenerationContext? = nil,
        generationID providedGenerationID: UUID? = nil,
        proactiveContext: ProactiveRequestContext? = nil,
        turnSource: ActionSource = .voice,
        playsThinkingTone: Bool = true,
        allowsAudibleOutput: Bool = true
    ) async {
        let tillDoneListActive = await TillDoneManager.shared.isListActive
        let maxToolTurns = tillDoneListActive ? 25 : 5

        let generationID: UUID
        if let providedGenerationID {
            generationID = providedGenerationID
            // If this recursion belongs to an old turn, drop it immediately.
            if activeGenerationID != generationID {
                debugLog(debugConsole, .pipeline, "Drop stale generation recursion id=\(generationID.uuidString.prefix(8))")
                endAssistantGeneration(for: generationID)
                return
            }
        } else {
            generationID = UUID()
            activeGenerationID = generationID
            debugLog(debugConsole, .pipeline, "Generation started id=\(generationID.uuidString.prefix(8))")
        }

        // Reset computer-use step counter and duplicate-tool guard at the start of each user turn.
        if !isToolFollowUp {
            computerUseStepCount = 0
            seenToolCallSignatures = []
            pruneUnusedWorkflowTraceContexts(keeping: currentTurnID)
            prepareWorkflowTraceContextIfNeeded(
                turnID: currentTurnID,
                userGoal: userText,
                proactiveContext: proactiveContext,
                turnSource: turnSource
            )
        }

        await refreshDegradedModeIfNeeded(context: "before_generation")

        let generationContext: GenerationContext
        if !isToolFollowUp {
            debugLog(debugConsole, .qa, "=== TURN START user=\(userText.prefix(160)) ===")
            interrupted = false
            interruptedGenerationID = nil
            // Ensure no stale TTS tasks from a previous turn can block this one.
            ttsState.cancelPending()
            lastAssistantResponseText = ""
            assistantGenerating = true
            eventBus.send(.assistantGenerating(true))

            // Play thinking tone.
            if playsThinkingTone {
                await playback.playThinkingTone()
            }

            // Add user message to history.
            await conversationState.addUserMessage(
                userText,
                speakerDisplayName: speakerGate.currentSpeakerDisplayName,
                speakerId: speakerGate.currentSpeakerLabel,
                tag: proactiveContext?.conversationTag
            )
            if proactiveContext == nil {
                await persistAcceptedUserTurnIfNeeded(userText)
            }

            if proactiveContext == nil,
               let forgetReply = await memoryOrchestrator?.handleForgetCommandIfNeeded(userText: userText)
            {
                sendAssistantText(forgetReply, isFinal: true)
                if allowsAudibleOutput {
                    await speakText(forgetReply, isFinal: true)
                }
                await conversationState.addAssistantMessage(
                    forgetReply,
                    tag: proactiveContext?.conversationTag
                )
                await persistFinalAssistantTurnIfNeeded(forgetReply)
                endAssistantGeneration(for: generationID)
                engage()
                activeCapabilityTicket = nil
                debugLog(debugConsole, .qa, "=== TURN END deterministic_forget ===")
                return
            }

            if proactiveContext == nil,
               let directRecallReply = await memoryOrchestrator?.handleDirectPersonalRecallIfNeeded(userText: userText)
            {
                sendAssistantText(directRecallReply, isFinal: true)
                if allowsAudibleOutput {
                    await speakText(directRecallReply, isFinal: true)
                }
                await conversationState.addAssistantMessage(
                    directRecallReply,
                    tag: proactiveContext?.conversationTag
                )
                await persistFinalAssistantTurnIfNeeded(directRecallReply)
                endAssistantGeneration(for: generationID)
                engage()
                activeCapabilityTicket = nil
                debugLog(debugConsole, .qa, "=== TURN END deterministic_personal_recall ===")
                return
            }

            // Issue a short-lived capability ticket for this turn.
            let toolMode = effectiveToolMode()
            let privacyMode = effectivePrivacyMode()
            activeCapabilityTicket = CapabilityTicketIssuer.issue(
                mode: toolMode,
                privacyMode: privacyMode,
                registry: registry
            )

            if proactiveContext == nil,
               let inferredToolCall = Self.repairedToolCallForSkippedTurn(userText),
               let preflightDenial = Self.preflightToolDenial(
                    for: [inferredToolCall],
                    registry: registry,
                    toolMode: toolMode,
                    privacyMode: privacyMode
               )
            {
                debugLog(
                    debugConsole,
                    .approval,
                    "Blocked requested tool before generation: \(inferredToolCall.name) — \(preflightDenial)"
                )
                let msg = "I can't do that in the current mode: \(preflightDenial)"
                sendAssistantText(msg, isFinal: true)
                if allowsAudibleOutput {
                    await speakText(msg, isFinal: true)
                }
                await conversationState.addAssistantMessage(
                    msg,
                    tag: proactiveContext?.conversationTag
                )
                await persistFinalAssistantTurnIfNeeded(msg)
                endAssistantGeneration(for: generationID)
                activeCapabilityTicket = nil
                debugLog(debugConsole, .qa, "=== TURN END blocked_before_generation tool=\(inferredToolCall.name) ===")
                return
            }

            // Memory recall — inject context before generation.
            let memoryContext: String?
            if Self.shouldRecallMemoryForTurn(
                firstOwnerEnrollmentActive: speakerGate.firstOwnerEnrollmentActive,
                userText: userText,
                availableToolNames: registry.toolNames
            ) {
                memoryContext = await memoryOrchestrator?.recall(
                    query: userText,
                    proactiveTaskId: proactiveContext?.taskId
                )
            } else {
                memoryContext = nil
            }
            if let ctx = memoryContext, !ctx.isEmpty {
                let preview = String(ctx.prefix(120)).replacingOccurrences(of: "\n", with: " ")
                debugLog(debugConsole, .memory, "Recalled: \(preview)…")
            }

            // Build system prompt with tool schemas.
            let ownerProfileExists = await speakerProfileStore?.hasOwnerProfile() ?? false
            let ownerEnrollmentRequired = config.speaker.requireOwnerForTools
                && !ownerProfileExists
            // Detect conversation continuation: the last assistant message must have
            // been within 45 seconds. This gates the "show all tools on follow-up"
            // heuristic so it doesn't over-trigger on new topics after long pauses.
            let lastAssistantAt = await conversationState.lastAssistantMessageAt
            let continuationWindowSeconds: TimeInterval = 45
            let isRecentContinuation = lastAssistantAt.map {
                Date().timeIntervalSince($0) <= continuationWindowSeconds
            } ?? false
            let visibleToolNames = Self.visibleToolNamesForTurn(
                firstOwnerEnrollmentActive: speakerGate.firstOwnerEnrollmentActive,
                userText: userText,
                availableToolNames: registry.toolNames,
                proactiveAllowedTools: proactiveContext?.allowedTools,
                isConversationContinuation: isRecentContinuation
            )
            if let visibleToolNames {
                debugLog(
                    debugConsole,
                    .pipeline,
                    "Visible tools for turn: \(visibleToolNames.sorted().joined(separator: ", "))"
                )
            }
            // Guests (voiceprinted but not promoted to trusted) can converse
            // but do not see tools. The owner can grant tool access by saying
            // "Fae, let Alice use tools" which promotes guest → trusted.
            let guestToolBlock = speakerGate.currentSpeakerRole == .guest
            let toolsAvailableForTurn = toolMode != "off"
                && !ownerEnrollmentRequired
                && !guestToolBlock
            let includeTools = toolsAvailableForTurn
            let activeModelId = currentModelId()
            let preferLegacyInlineToolPrompt = Self.prefersLegacyInlineToolPrompt(
                modelId: activeModelId
            )

            let hiddenToolsReason: String? = {
                guard !includeTools else { return nil }
                if toolMode == "off" {
                    return "toolMode=off"
                }
                if ownerEnrollmentRequired {
                    return "owner_enrollment_required"
                }
                if guestToolBlock {
                    return "guest_speaker_no_tools"
                }
                return "unknown"
            }()

            // Diagnostic logging — critical for debugging tool use failures.
            if let hiddenToolsReason {
                debugLog(debugConsole, .pipeline, "⚠️ Tools HIDDEN from LLM: \(hiddenToolsReason)")
                NSLog("PipelineCoordinator: tools hidden — %@", hiddenToolsReason)
                if !isToolFollowUp && Self.shouldShowToolModeUpgradePopup(reasonCode: hiddenToolsReason) {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .faeToolModeUpgradeRequested,
                            object: nil,
                            userInfo: ["reason": hiddenToolsReason]
                        )
                    }
                }
            } else {
                let ownerDetail: String
                if speakerGate.currentSpeakerIsOwner {
                    ownerDetail = "ownerVerified=true"
                } else if speakerGate.currentSpeakerIsKnownNonOwner {
                    ownerDetail = "speakerNonOwner=\(speakerGate.currentSpeakerLabel ?? "?")"
                } else if speakerGate.currentSpeakerLabel == nil {
                    ownerDetail = "speakerUnknown"
                } else {
                    ownerDetail = "speaker=\(speakerGate.currentSpeakerLabel ?? "?")"
                }
                debugLog(debugConsole, .pipeline, "Tools enabled (mode=\(toolMode), \(ownerDetail))")
            }

            let skillDescs: [(name: String, description: String, type: SkillType)]
            let legacySkills: [String]
            if includeTools, let sm = skillManager {
                skillDescs = await sm.promptMetadata()
                legacySkills = []
            } else if includeTools {
                skillDescs = []
                legacySkills = SkillManager.installedSkillNames()
            } else {
                skillDescs = []
                legacySkills = []
            }
            // Build native tool specs for MLX tool calling.
            let nativeTools = includeTools && !preferLegacyInlineToolPrompt
                ? registry.nativeToolSpecs(
                    for: toolMode,
                    privacyMode: privacyMode,
                    limitedTo: visibleToolNames
                )
                : nil

            let toolSchemas: String? = {
                guard includeTools else { return nil }
                if nativeTools != nil {
                    let compact = registry.compactToolSummary(
                        for: toolMode,
                        privacyMode: privacyMode,
                        limitedTo: visibleToolNames
                    )
                    return compact.isEmpty ? nil : compact
                }
                let full = registry.toolSchemas(
                    for: toolMode,
                    privacyMode: privacyMode,
                    limitedTo: visibleToolNames
                )
                return full.isEmpty ? nil : full
            }()

            if let specs = nativeTools {
                debugLog(debugConsole, .pipeline, "Native tool specs: \(specs.count) tools")
            } else if includeTools, preferLegacyInlineToolPrompt {
                debugLog(
                    debugConsole,
                    .pipeline,
                    "Using legacy inline tool prompt for model=\(activeModelId ?? "unknown")"
                )
            }

            if let schemas = toolSchemas {
                let lineCount = schemas.split(separator: "\n").count
                debugLog(debugConsole, .pipeline, "Tool prompt summary: lines=\(lineCount) chars=\(schemas.count)")
            }

            let soul = isRescueMode ? SoulManager.defaultSoul() : SoulManager.loadSoul()
            let heartbeat = isRescueMode
                ? HeartbeatManager.defaultHeartbeat()
                : HeartbeatManager.loadHeartbeat()
            let nativeToolsAvailable = nativeTools != nil
            var systemPrompt = PersonalityManager.assemblePrompt(
                voiceOptimized: true,
                visionCapable: effectiveVisionEnabled(),
                userName: config.userName,
                speakerDisplayName: speakerGate.currentSpeakerDisplayName,
                speakerRole: speakerGate.currentSpeakerRole,
                soulContract: soul,
                heartbeatContract: heartbeat,
                directiveOverride: isRescueMode ? "" : nil,
                nativeToolsAvailable: nativeToolsAvailable,
                toolSchemas: toolSchemas,
                installedSkills: legacySkills,
                skillDescriptions: skillDescs,
                includeEphemeralContext: false,
                lightweight: config.isLightweightContext
            )
            // Inject activated skill instructions into the stable prompt.
            if let activatedCtx = await skillManager?.activatedContext() {
                systemPrompt += "\n\n" + activatedCtx
            }

            var turnContextExtras: [String] = []
            if let enrollCtx = speakerGate.firstOwnerEnrollmentContext {
                turnContextExtras.append(enrollCtx)
                speakerGate.firstOwnerEnrollmentContext = nil
            }
            if let memoryTurnGuidance = Self.memoryTurnGuidance(for: userText) {
                turnContextExtras.append(memoryTurnGuidance)
            }
            let turnContextPrefix = PersonalityManager.assembleEphemeralTurnContext(
                speakerDisplayName: speakerGate.currentSpeakerDisplayName,
                speakerRole: speakerGate.currentSpeakerRole,
                memoryContext: memoryContext,
                extraSections: turnContextExtras
            )

            generationContext = GenerationContext(
                systemPrompt: systemPrompt,
                turnContextPrefix: turnContextPrefix,
                nativeTools: nativeTools,
                actionSource: proactiveContext?.source ?? turnSource,
                playsThinkingTone: playsThinkingTone,
                allowsAudibleOutput: allowsAudibleOutput
            )
            currentTurnGenerationContext = generationContext
            // Cache for speculative prefill on next turn.
            cachedGenerationSystemPrompt = systemPrompt
        } else if let providedGenerationContext {
            generationContext = providedGenerationContext
        } else if let currentTurnGenerationContext {
            generationContext = currentTurnGenerationContext
        } else {
            return
        }

        let systemPrompt = generationContext.systemPrompt
        let baseTurnContextPrefix = generationContext.turnContextPrefix ?? ""
        let history = await conversationState.history

        // Fast mode disables explicit reasoning on all turns, including tool
        // follow-ups. This keeps "thinking off" behavior consistent and avoids
        // silent/suppressed follow-up answers when a model emits plain text
        // instead of well-formed think tags.
        let effectiveThinkingLevel = thinkingLevelLive ?? config.llm.resolvedThinkingLevel
        let suppressThinking = Self.shouldSuppressThinking(
            forceSuppressThinking: forceSuppressThinking,
            thinkingLevel: effectiveThinkingLevel,
            isToolFollowUp: isToolFollowUp
        )

        // Auto-tune prefill step size based on loaded model if not explicitly configured.
        var prefillStep = config.llm.prefillStepSize ?? 512
        if prefillStep == 512, let mm = modelManager, let modelId = await mm.loadedModelId {
            prefillStep = FaeConfig.recommendedPrefillStepSize(modelId: modelId)
        }

        let contextLimitTokens = await conversationState.currentContextBudget()
        let effectiveTurnContextPrefix: String? = {
            guard let directive = effectiveThinkingLevel.localReasoningDirective,
                  !suppressThinking
            else {
                return generationContext.turnContextPrefix
            }
            if let existing = generationContext.turnContextPrefix,
               !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return directive + "\n\n" + existing
            }
            return directive
        }()
        let localMaxTokens = min(config.llm.maxTokens + effectiveThinkingLevel.additionalLocalMaxTokens, 8_192)

        // On tool follow-up turns, pass tools=nil to disable the streaming tool
        // call parser. The parser intercepts <-prefixed tokens looking for <tool_call>,
        // which can interfere with think blocks and cause 0-token generation on some
        // models. Tool calls in follow-up responses are still detected by the text-based
        // parseToolCalls() fallback on fullResponse after generation completes.
        let effectiveTools = isToolFollowUp ? nil : generationContext.nativeTools

        // Estimate tool schema tokens — each tool spec adds ~100-200 tokens.
        // Without this, the context budget calculation ignores tool schemas,
        // which can cause overflow when many tools are visible (36 tools ≈ 5K tokens).
        let toolSchemaTokens: Int = {
            guard let tools = effectiveTools else { return 0 }
            // Approximate: each tool spec ≈ 140 tokens average.
            return tools.count * 140
        }()

        let dynamicReservedTokens = max(
            1024,
            Self.estimateTokenCount(for: systemPrompt)
                + Self.estimateTokenCount(for: effectiveTurnContextPrefix ?? baseTurnContextPrefix)
                + toolSchemaTokens
                + localMaxTokens
        )
        await conversationState.setReservedTokens(dynamicReservedTokens)

        // Pre-generation overflow guard: verify estimated total fits in context.
        // If history is still too large after trimHistory(), aggressively reduce
        // to prevent 0-token stalls from context overflow.
        if contextLimitTokens > 0 {
            let historyTokens = await conversationState.history.reduce(0) {
                $0 + Self.estimateTokenCount(for: $1.content) + 4  // +4 for role/framing
            }
            let estimatedTotal = dynamicReservedTokens + historyTokens
            if estimatedTotal > contextLimitTokens {
                let overflow = estimatedTotal - contextLimitTokens
                NSLog("PipelineCoordinator: context overflow guard — estimated=%d limit=%d overflow=%d, trimming history", estimatedTotal, contextLimitTokens, overflow)
                debugLog(debugConsole, .pipeline, "⚠️ Context overflow guard: \(estimatedTotal) > \(contextLimitTokens) (overflow=\(overflow) tokens) — aggressive trim")
                // Trim history aggressively: keep only last 4 messages (2 turns).
                await conversationState.truncateHistory(keep: 4)
            }
        }
        let options = GenerationOptions(
            temperature: config.llm.temperature,
            topP: config.llm.topP,
            maxTokens: localMaxTokens,
            repetitionPenalty: config.llm.repeatPenalty,
            suppressThinking: suppressThinking,
            tools: effectiveTools,
            turnContextPrefix: effectiveTurnContextPrefix,
            contextLimitTokens: contextLimitTokens,
            // KV Cache Optimization (Phase 1) - based on Ollama/mistral.rs/LM Studio research
            maxKVSize: config.llm.maxKVCacheSize,
            kvBits: config.llm.kvQuantBits,
            kvGroupSize: config.llm.kvGroupSize,
            quantizedKVStart: config.llm.kvQuantStartTokens,
            repetitionContextSize: config.llm.repetitionContextSize,
            prefillStepSize: prefillStep
        )

        // Cache options for speculative prefill on next turn.
        if !isToolFollowUp {
            cachedGenerationOptions = options
        }

        // Stream tokens.
        thinkTagStripper = TextProcessing.ThinkTagStripper()
        voiceTagStripper = VoiceTagStripper()
        let roleplayActive = await RoleplaySessionStore.shared.isActive
        var roleplayChunker = RoleplaySpeechChunker()
        var fullResponse = ""
        var sentenceBuffer = ""
        var detectedToolCall = false
        // Qwen3 emits <think> as a special token (decoded to empty string by mlx-swift-lm)
        // but </think> as regular literal text. Suppress all TTS until </think> is seen.
        // When thinking is disabled, mark think as already seen so tokens route to TTS.
        // NOTE: tool follow-up turns DO produce think blocks (model reasons about tool
        // results before responding), so we must NOT skip the buffer for them.
        var thinkEndSeen = options.suppressThinking
        var thinkAccum = ""
        // Clear any previous thinking bubble when a new generation starts.
        if !thinkEndSeen {
            eventBus.send(.thinkingText(text: "", isActive: true))
        }
        var firstTtsSent = false
        var firstTtsEnqueuedAt: Date?
        let suppressProvisionalOutputForLikelyToolTurn = !isToolFollowUp && (
            Self.isToolBackedLookupRequest(userText)
                || Self.isScreenIntentRequest(userText)
                || Self.isCameraIntentRequest(userText)
                || Self.repairedToolCallForSkippedTurn(userText) != nil
        )
        let llmStartedAt = Date()
        var llmTokenCount = 0
        var firstTokenAt: Date?
        var spokenTextThisTurn = ""
        var visibleTextThisTurn = ""
        // TTS streaming mode: when `false` (default), synthesise sentence-by-sentence
        // as the LLM streams tokens — first audio plays while generation continues.
        // When `true` (batched fallback), defer all TTS until the turn completes.
        // Kokoro is stateless per call, so per-sentence synthesis preserves prosody.
        let preferFinalOnlySpeech = config.tts.preferFinalOnly
        debugLog(debugConsole, .pipeline, "TTS: \(preferFinalOnlySpeech ? "batched (final-only)" : "sentence-streaming") mode active")
        var deferredSentenceQueue: [String] = []
        var streamedToolCalls: [ToolCall] = []
        var completionInfo: GenerateCompletionInfo?
        var llmFailureDescription: String?

        if turnCount == 0 {
            // Keep echo matching aligned with what we actually speak this turn.
            lastAssistantResponseText = ""
        }

        func recordSpokenText(_ text: String) {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            if spokenTextThisTurn.isEmpty {
                spokenTextThisTurn = cleaned
            } else {
                spokenTextThisTurn += " " + cleaned
            }
            if lastAssistantResponseText.isEmpty {
                lastAssistantResponseText = cleaned
            } else {
                lastAssistantResponseText += " " + cleaned
            }
        }

        func recordVisibleText(_ text: String) {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            if visibleTextThisTurn.isEmpty {
                visibleTextThisTurn = cleaned
            } else {
                visibleTextThisTurn += " " + cleaned
            }
        }

        // Streaming chunk smoothing: prioritize sentence-sized chunks, and only use
        // clause fallback when enough text has accumulated and cadence allows it.
        let minSentenceChunkChars = 40
        let minSentenceFlushIntervalSec: TimeInterval = 0.24
        let minClauseChunkChars = 55
        let minClauseFlushIntervalSec: TimeInterval = 0.55
        let maxCharsBeforeClauseFlush = 280
        let maxSilenceBeforeClauseFallbackSec: TimeInterval = 3.0
        var lastStreamingFlushAt: Date?
        var streamingChunkCount = 0
        var streamingChunkCharsTotal = 0
        var streamingShortChunkCount = 0

        func emitStreamingChunk(_ cleaned: String) {
            guard !cleaned.isEmpty else { return }
            // Safety gate: suppress content that looks like code/JSON/tool output.
            if TextProcessing.looksLikeNonProse(cleaned) {
                debugLog(debugConsole, .pipeline, "[suppressed non-prose TTS] \(String(cleaned.prefix(80)))")
                // Still show in conversation UI, just don't speak it.
                recordVisibleText(cleaned)
                sendAssistantText(cleaned, isFinal: false)
                return
            }
            // Suppress UI self-narration at any position (model describing its own interface).
            if TextProcessing.isUISelfNarration(cleaned) {
                debugLog(debugConsole, .pipeline, "[suppressed UI self-narration] \(String(cleaned.prefix(80)))")
                recordVisibleText(cleaned)
                sendAssistantText(cleaned, isFinal: false)
                return
            }

            // Explicit tool-backed turns often emit provisional prose before the
            // actual repair/approval path runs. Hide those chunks entirely so the
            // user sees the real tool/approval state rather than a fake success.
            if suppressProvisionalOutputForLikelyToolTurn {
                debugLog(debugConsole, .pipeline, "[suppressed provisional tool-turn text] \(String(cleaned.prefix(80)))")
                return
            }

            // Conservative mode: keep text streaming to UI, but defer audio until
            // turn completion so TTS receives larger coherent text context.
            if preferFinalOnlySpeech {
                recordVisibleText(cleaned)
                sendAssistantText(cleaned, isFinal: false)
                deferredSentenceQueue.append(cleaned)
                return
            }

            let now = Date()
            let intervalMs = Int((lastStreamingFlushAt.map { now.timeIntervalSince($0) } ?? 0) * 1000)
            firstTtsSent = true
            lastStreamingFlushAt = now
            streamingChunkCount += 1
            streamingChunkCharsTotal += cleaned.count
            if cleaned.count < 30 {
                streamingShortChunkCount += 1
            }
            debugLog(debugConsole, .pipeline, "Stream chunk #\(streamingChunkCount) chars=\(cleaned.count) interval_ms=\(intervalMs)")
            NSLog("PipelineCoordinator: TTS chunk → \"%@\"", String(cleaned.prefix(120)))
            recordVisibleText(cleaned)
            sendAssistantText(cleaned, isFinal: false)
            if generationContext.allowsAudibleOutput {
                if firstTtsEnqueuedAt == nil {
                    firstTtsEnqueuedAt = Date()
                    let ttfa = firstTtsEnqueuedAt!.timeIntervalSince(llmStartedAt)
                    debugLog(debugConsole, .pipeline, String(format: "TTS: time-to-first-audio=%.2fs (sentence chars=%d)", ttfa, cleaned.count))
                }
                recordSpokenText(cleaned)
                enqueueTTS(cleaned, isFinal: false, generationID: generationID)
            }
        }

        func voiceInstruct(for character: String?) async -> String? {
            guard let character else { return nil }

            var matched = await RoleplaySessionStore.shared.voiceForCharacter(character)
            if matched == nil {
                let globalEntry = await CharacterVoiceLibrary.shared.find(name: character)
                matched = globalEntry?.voiceInstruct
            }
            if matched == nil {
                NSLog("PipelineCoordinator: unassigned character '%@' — using narrator voice", character)
            }
            return matched
        }

        func emitRoleplayChunk(_ chunk: RoleplaySpeechChunk, isFinal: Bool) async {
            let cleaned = TextProcessing.stripNonSpeechChars(chunk.text)
            guard !cleaned.isEmpty else { return }

            if TextProcessing.looksLikeNonProse(cleaned) {
                debugLog(debugConsole, .pipeline, "[suppressed non-prose roleplay TTS] \(String(cleaned.prefix(80)))")
                recordVisibleText(cleaned)
                sendAssistantText(cleaned, isFinal: isFinal)
                return
            }

            if suppressProvisionalOutputForLikelyToolTurn {
                debugLog(debugConsole, .pipeline, "[suppressed provisional roleplay tool-turn text] \(String(cleaned.prefix(80)))")
                return
            }

            let voice = await voiceInstruct(for: chunk.character)
            recordVisibleText(cleaned)
            sendAssistantText(cleaned, isFinal: isFinal)
            if generationContext.allowsAudibleOutput {
                recordSpokenText(cleaned)
                enqueueTTS(cleaned, isFinal: isFinal, voiceInstruct: voice, generationID: generationID)
            }
        }

        let systemPromptTokens = Self.estimateTokenCount(for: systemPrompt)
        if forceSuppressThinking {
            debugLog(debugConsole, .pipeline, "Retrying turn with thinking suppression forced")
        }
        debugLog(debugConsole, .pipeline, "LLM generating (maxTokens=\(options.maxTokens), history=\(history.count) msgs, turn=\(turnCount), sysPrompt≈\(systemPromptTokens) tok, ctx=\(config.llm.contextSizeTokens), suppressThinking=\(options.suppressThinking))")
        if options.maxTokens < 1024 {
            debugLog(debugConsole, .pipeline, "⚠️ maxTokens=\(options.maxTokens) is very low — tool call JSON needs ~200-500 tokens")
        }

        let activeLLMEngine = llmEngine
        guard await activeLLMEngine.isLoaded else {
            NSLog("PipelineCoordinator: LLM not loaded — cannot generate")
            debugLog(debugConsole, .pipeline, "⚠️ LLM not loaded — cannot generate")
            return
        }

        let tokenStream = await activeLLMEngine.generate(
            messages: history,
            systemPrompt: systemPrompt,
            options: options
        )

        var staleGenerationDetected = false
        await instrumentation.markLLMStart()

        do {
            for try await event in tokenStream {
                if activeGenerationID != generationID {
                    staleGenerationDetected = true
                    debugLog(debugConsole, .pipeline, "Drop stale token stream id=\(generationID.uuidString.prefix(8))")
                    break
                }

                guard !isGenerationInterrupted(generationID) else {
                    NSLog("PipelineCoordinator: generation interrupted")
                    break
                }

                switch event {
                case .info(let info):
                    completionInfo = info
                    continue

                case .toolCall(let nativeCall):
                    detectedToolCall = true
                    streamedToolCalls.append(
                        ToolCall(
                            name: nativeCall.function.name,
                            arguments: nativeCall.function.arguments.mapValues { $0.anyValue }
                        )
                    )
                    deferredSentenceQueue = []
                    sentenceBuffer = ""
                    continue

                case .text(let token):
                    llmTokenCount += 1
                    if firstTokenAt == nil {
                        firstTokenAt = Date()
                        await instrumentation.markLLMFirstToken(
                            latencyMs: Date().timeIntervalSince(llmStartedAt) * 1000
                        )
                    }

                    let visible = thinkTagStripper.process(token)
                    // For Qwen3.5-35B-A3B: <think> is literal text, so ThinkTagStripper
                    // consumes it natively. When it exits the think block, signal thinkEndSeen
                    // so the pipeline doesn't wait for </think> in thinkAccum (which never arrives
                    // because ThinkTagStripper already consumed it).
                    // Emit live think chunks from ThinkTagStripper (Qwen3.5 path).
                    if !thinkTagStripper.thinkChunk.isEmpty {
                        eventBus.send(.thinkingText(text: thinkTagStripper.thinkChunk, isActive: true))
                        debugLog(debugConsole, .llmThink, thinkTagStripper.thinkChunk)
                    }
                    if thinkTagStripper.hasExitedThinkBlock && !thinkEndSeen {
                        thinkEndSeen = true
                        eventBus.send(.thinkingText(text: "", isActive: false))
                    }
                    guard !visible.isEmpty else {
                        continue
                    }

                    fullResponse += visible

                    if detectedToolCall {
                        continue
                    }

                    // Think block suppression: Qwen3's <think> is a special token decoded to ""
                    // so ThinkTagStripper never sees it. </think> IS emitted as literal text.
                    // Buffer everything until </think>, then discard the think block.
                    if !thinkEndSeen {
                        debugLog(debugConsole, .llmThink, visible)
                        thinkAccum += visible
                        eventBus.send(.thinkingText(text: visible, isActive: true))
                        if let endRange = thinkAccum.range(of: "</think>") {
                            let afterThink = String(thinkAccum[endRange.upperBound...])
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            thinkAccum = ""
                            thinkEndSeen = true
                            eventBus.send(.thinkingText(text: "", isActive: false))
                            if !afterThink.isEmpty && !roleplayActive {
                                sentenceBuffer = afterThink
                            }
                            continue
                        }
                        if thinkAccum.count > 80_000 {
                            thinkAccum = ""
                            thinkEndSeen = true
                            eventBus.send(.thinkingText(text: "", isActive: false))
                        } else {
                            continue
                        }
                    }
                    debugLog(debugConsole, .llmToken, visible)

                    // Roleplay mode: route through voice tag parser for per-character TTS.
                    if roleplayActive {
                        let segments = voiceTagStripper.process(visible)
                        let readyChunks = roleplayChunker.process(segments)
                        for chunk in readyChunks {
                            await emitRoleplayChunk(chunk, isFinal: false)
                        }
                    } else {
                    // Standard sentence-boundary streaming flow.
                    sentenceBuffer += visible

                    if let boundary = TextProcessing.findSentenceBoundary(in: sentenceBuffer) {
                        let sentence = String(sentenceBuffer[..<boundary])
                        let stripped = TextProcessing.stripNonSpeechChars(sentence)
                        let cleaned = TextProcessing.stripReasoningPreface(stripped)
                        // Safety filter: if this is the very first TTS sentence and it looks
                        // like the model is narrating/describing what the user said (leaked
                        // reasoning), discard it and log to debug console instead.
                        let isMetaCommentary = !firstTtsSent && !stripped.isEmpty && cleaned.isEmpty
                        if !cleaned.isEmpty && !isMetaCommentary {
                            let now = Date()
                            let interval = lastStreamingFlushAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
                            // Flush the first sentence immediately for instant acknowledgment,
                            // regardless of size. Subsequent sentences respect the minimum
                            // to maintain prosody quality.
                            let isFirstSentence = !firstTtsSent
                            let shouldHoldForCoalesce = !isFirstSentence
                                && cleaned.count < minSentenceChunkChars
                                && interval < minSentenceFlushIntervalSec

                            if shouldHoldForCoalesce {
                                // Keep buffering until we have a bigger chunk or enough cadence spacing.
                            } else {
                                emitStreamingChunk(cleaned)
                                sentenceBuffer = String(sentenceBuffer[boundary...])
                            }
                        } else {
                            if isMetaCommentary {
                                debugLog(debugConsole, .llmThink, "[suppressed meta-commentary] \(cleaned)")
                            }
                            sentenceBuffer = String(sentenceBuffer[boundary...])
                        }
                    } else if sentenceBuffer.count >= maxCharsBeforeClauseFlush
                              || (sentenceBuffer.count >= minClauseChunkChars
                                  && (lastStreamingFlushAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude) >= maxSilenceBeforeClauseFallbackSec) {
                        if let clause = TextProcessing.findClauseBoundary(in: sentenceBuffer) {
                            let text = String(sentenceBuffer[..<clause])
                            let stripped = TextProcessing.stripNonSpeechChars(text)
                            let cleaned = TextProcessing.stripReasoningPreface(stripped)
                            if !cleaned.isEmpty {
                                let now = Date()
                                let interval = lastStreamingFlushAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
                                let canFlushClause = cleaned.count >= minClauseChunkChars
                                    && interval >= minClauseFlushIntervalSec
                                if canFlushClause {
                                    emitStreamingChunk(cleaned)
                                    sentenceBuffer = String(sentenceBuffer[clause...])
                                }
                            }
                        }
                    }
                }
            }
        }
        } catch {
            llmFailureDescription = error.localizedDescription
            NSLog("PipelineCoordinator: LLM error: %@", error.localizedDescription)
            debugLog(debugConsole, .pipeline, "⚠️ LLM error: \(error.localizedDescription)")
        }

        if staleGenerationDetected {
            // A newer generation has taken over. Clean up this generation's state
            // using the ID-scoped variant so we don't accidentally clear the new
            // generation's assistantGenerating flag.
            endAssistantGeneration(for: generationID)
            return
        }

        let llmEndedAt = Date()
        let llmElapsed = llmEndedAt.timeIntervalSince(llmStartedAt)
        if let completionInfo {
            debugLog(
                debugConsole,
                .pipeline,
                "LLM metrics prompt=\(completionInfo.promptTokenCount)tok prompt_tps=\(String(format: "%.1f", completionInfo.promptTokensPerSecond)) decode_tps=\(String(format: "%.1f", completionInfo.tokensPerSecond)) stop=\(completionInfo.stopReason)"
            )
            await instrumentation.markLLMEnd(
                durationMs: (completionInfo.promptTime + completionInfo.generateTime) * 1000,
                tokenCount: completionInfo.generationTokenCount
            )
        } else {
            await instrumentation.markLLMEnd(durationMs: llmElapsed * 1000, tokenCount: llmTokenCount)
        }
        if llmElapsed > 0 {
            let throughput = Double(llmTokenCount) / llmElapsed
            NSLog("phase1.llm_token_throughput_tps=%.2f", throughput)

            if let firstTokenAt {
                let firstTokenLatency = firstTokenAt.timeIntervalSince(llmStartedAt)
                let decodeElapsed = max(llmEndedAt.timeIntervalSince(firstTokenAt), 0.001)
                let decodeTps = Double(llmTokenCount) / decodeElapsed
                debugLog(
                    debugConsole,
                    .pipeline,
                    "LLM done: \(llmTokenCount) tokens total=\(String(format: "%.1f", llmElapsed))s first_token=\(String(format: "%.1f", firstTokenLatency))s decode=\(String(format: "%.1f", decodeElapsed))s decode_tps=\(String(format: "%.1f", decodeTps))"
                )

                if llmTokenCount == 0 {
                    debugLog(debugConsole, .pipeline, "⚠️ 0 tokens generated — possible model stall or context overflow")
                    if llmFailureDescription == nil {
                        llmFailureDescription = "0 tokens generated (model stall or context overflow)"
                    }
                } else if llmTokenCount >= 128 && decodeTps < 2.0 {
                    debugLog(debugConsole, .pipeline, "⚠️ Low decode throughput (\(String(format: "%.1f", decodeTps)) t/s) during long generation")
                } else if llmTokenCount < 128 && firstTokenLatency > 8.0 {
                    debugLog(debugConsole, .pipeline, "ℹ️ Turn was prefill-heavy (long first-token latency) — decode speed itself was normal")
                }
            } else {
                debugLog(debugConsole, .pipeline, "LLM done: \(llmTokenCount) tokens in \(String(format: "%.1f", llmElapsed))s (\(String(format: "%.1f", throughput)) t/s)")
                if llmTokenCount == 0 {
                    debugLog(debugConsole, .pipeline, "⚠️ 0 tokens generated — possible model stall or context overflow")
                    if llmFailureDescription == nil {
                        llmFailureDescription = "0 tokens generated (model stall or context overflow)"
                    }
                }
            }
        }

        if streamingChunkCount > 0 {
            let avgChunk = Double(streamingChunkCharsTotal) / Double(streamingChunkCount)
            let shortRatio = Double(streamingShortChunkCount) / Double(streamingChunkCount)
            debugLog(
                debugConsole,
                .pipeline,
                "TTS stream chunks: count=\(streamingChunkCount) avg_chars=\(String(format: "%.1f", avgChunk)) short_ratio=\(String(format: "%.2f", shortRatio))"
            )
        }

        // Flush remaining text.
        let remaining = thinkTagStripper.flush()
        fullResponse += remaining
        let responsePreview = fullResponse
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(180)
        debugLog(debugConsole, .qa, "Model raw response preview: \(responsePreview)")

        // Prefer structured MLX tool calls; fall back to legacy text parsing.
        let toolCalls: [ToolCall] = {
            return streamedToolCalls.isEmpty
                ? Self.parseToolCalls(from: fullResponse)
                : streamedToolCalls
        }()

        // When native MLX tool calls were captured (not accumulated as text),
        // serialize them back into fullResponse so the assistant history message
        // contains the tool call XML. Without this, the follow-up turn sees an
        // empty assistant message and the Jinja template renders a malformed
        // prompt that causes the model to produce 0 tokens.
        //
        // IMPORTANT: Use Qwen3.5's XML function format (not JSON), because
        // that is what the chat template renders and what the model was trained on:
        //   <tool_call><function=name><parameter=key>value</parameter></function></tool_call>
        if !streamedToolCalls.isEmpty && !fullResponse.contains("<tool_call>") {
            for call in streamedToolCalls {
                var xml = "\n<tool_call>\n<function=\(call.name)>\n"
                for (key, value) in call.arguments {
                    let valueStr: String
                    if let s = value as? String {
                        valueStr = s
                    } else if let data = try? JSONSerialization.data(
                        withJSONObject: value,
                        options: [.fragmentsAllowed]
                    ), let s = String(data: data, encoding: .utf8) {
                        valueStr = s
                    } else {
                        valueStr = "\(value)"
                    }
                    xml += "<parameter=\(key)>\n\(valueStr)\n</parameter>\n"
                }
                xml += "</function>\n</tool_call>"
                fullResponse += xml
            }
        }
        if !toolCalls.isEmpty {
            debugLog(debugConsole, .pipeline, "Found \(toolCalls.count) tool call(s): \(toolCalls.map(\.name).joined(separator: ", "))")
        } else if fullResponse.contains("<tool_call>") {
            debugLog(debugConsole, .qa, "⚠️ Model emitted tool_call markup but no valid calls parsed")
        }

        // Parse script blocks from the response.
        let scriptBlocks = Self.parseScriptBlocks(from: fullResponse)
        if !scriptBlocks.isEmpty {
            debugLog(debugConsole, .pipeline, "Found \(scriptBlocks.count) script block(s)")
        }

        if turnCount == 0,
           toolCalls.isEmpty,
           proactiveContext == nil,
           let repairCall = Self.repairedToolCallForSkippedTurn(userText),
           effectiveToolMode() != "off",
           Self.shouldAttemptRepairToolCall(
                repairCall,
                registry: registry,
                toolMode: effectiveToolMode(),
                privacyMode: effectivePrivacyMode()
           )
        {
            debugLog(debugConsole, .qa, "Tool repair fallback: forcing \(repairCall.name) tool call")
            if Self.canRunDeferredToolCalls([repairCall], registry: registry),
               !Self.shouldPreferInlineToolExecution(userText: userText, toolCalls: [repairCall])
            {
                let ack = "I’ll check that in the background and report back as soon as it’s ready."
                sendAssistantText(ack, isFinal: true)
                if generationContext.allowsAudibleOutput {
                    enqueueTTS(ack, isFinal: true, generationID: generationID)
                }

                await awaitPendingTTS()
                if generationContext.allowsAudibleOutput {
                    await awaitSpeechDrain(timeoutMs: 8_000, reason: "before_repaired_deferred_tools")
                }

                await startDeferredToolJob(
                    userText: userText,
                    toolCalls: [repairCall],
                    assistantToolMessage: "I'll check that with the \(repairCall.name) tool.",
                    forceSuppressThinking: forceSuppressThinking,
                    capabilityTicket: activeCapabilityTicket,
                    explicitUserAuthorization: explicitUserAuthorizationForTurn,
                    generationContext: generationContext,
                    originTurnID: currentTurnID
                )

                endAssistantGeneration(for: generationID)
                engage()
                activeCapabilityTicket = nil
                debugLog(debugConsole, .qa, "=== TURN END repaired_deferred_tools count=1 ===")
                return
            }

            let repairCallID = UUID().uuidString
            let inputJSON = Self.serializeArguments(repairCall.arguments)
            eventBus.send(.toolCall(id: repairCallID, name: repairCall.name, inputJSON: inputJSON))

            let repairResult = await executeTool(
                repairCall,
                proactiveContext: proactiveContext,
                generationContextOverride: generationContext,
                traceTurnID: currentTurnID,
                traceToolCallID: repairCallID
            )

            eventBus.send(.toolResult(
                id: repairCallID,
                name: repairCall.name,
                success: !repairResult.isError,
                output: String(repairResult.output.prefix(200))
            ))

            if !repairResult.isError {
                if let directReply = Self.directToolReplyText(for: repairCall, result: repairResult)
                {
                    sendAssistantText(directReply, isFinal: true)
                    if generationContext.allowsAudibleOutput {
                        await speakText(directReply, isFinal: true, emitAssistantText: false)
                    }
                    await conversationState.addAssistantMessage(
                        directReply,
                        tag: proactiveContext?.conversationTag
                    )
                    await synchronizeLLMSession()
                    await persistFinalAssistantTurnIfNeeded(directReply)
                    endAssistantGeneration(for: generationID)
                    engage()
                    activeCapabilityTicket = nil
                    debugLog(debugConsole, .qa, "=== TURN END repaired_direct_tool_reply name=\(repairCall.name) ===")
                    return
                }

                await conversationState.addAssistantMessage(
                    "I checked that with the \(repairCall.name) tool.",
                    tag: proactiveContext?.conversationTag
                )
                await conversationState.addToolResult(
                    id: repairCallID,
                    name: repairCall.name,
                    content: repairResult.output
                )

                await generateWithTools(
                    userText: userText,
                    isToolFollowUp: true,
                    turnCount: turnCount + 1,
                    forceSuppressThinking: true,
                    generationContext: generationContext,
                    generationID: generationID,
                    proactiveContext: proactiveContext
                )
                return
            }

            debugLog(debugConsole, .qa, "Tool repair fallback failed: \(repairResult.output)")
        }

        // Agentic continuation: if the LLM described an intention to use a tool
        // ("let me check", "I'll look into", etc.) but didn't emit any tool calls,
        // re-prompt once so the model actually performs the action instead of just
        // describing it. This is a common failure mode with smaller local models.
        if toolCalls.isEmpty,
           turnCount == 0,
           !isToolFollowUp,
           proactiveContext == nil,
           effectiveToolMode() != "off",
           effectiveToolMode() != "assistant",
           Self.responseImpliesToolIntent(fullResponse)
        {
            debugLog(debugConsole, .qa, "Agentic nudge: LLM described tool intent but emitted 0 calls — re-prompting")

            // Add the LLM's partial response to conversation history so the re-prompt
            // has context, then inject a continuation nudge as a follow-up user message.
            let visibleResponse = Self.stripThinkContent(fullResponse)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !visibleResponse.isEmpty {
                await conversationState.addAssistantMessage(visibleResponse, tag: nil)
            }

            let nudge = "You said you would check, but you didn't use any tool. Please go ahead and use the appropriate tool now to complete the action."
            await conversationState.addUserMessage(nudge, speakerDisplayName: nil, speakerId: nil, tag: nil)

            await generateWithTools(
                userText: nudge,
                isToolFollowUp: true,
                turnCount: turnCount + 1,
                forceSuppressThinking: true,
                generationContext: generationContext,
                generationID: generationID,
                proactiveContext: proactiveContext,
                turnSource: .text
            )
            return
        }

        if toolCalls.isEmpty && scriptBlocks.isEmpty {
            // No tool calls or script blocks — flush remaining speech and finish.
            if roleplayActive {
                // Flush voice tag stripper with remaining think-tag text.
                let roleplaySegments = voiceTagStripper.process(remaining) + voiceTagStripper.flush()
                let voiceRemaining = roleplayChunker.process(roleplaySegments, isFinal: true)
                var spokeSomething = false
                for (index, chunk) in voiceRemaining.enumerated() {
                    await emitRoleplayChunk(chunk, isFinal: index == voiceRemaining.count - 1)
                    let cleaned = TextProcessing.stripNonSpeechChars(chunk.text)
                    if generationContext.allowsAudibleOutput, !cleaned.isEmpty {
                        spokeSomething = true
                    }
                }
                // Wait for all TTS (streaming + final) to complete.
                await awaitPendingTTS()
                if !spokeSomething && assistantSpeaking {
                    await playback.markEnd()
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if assistantSpeaking {
                        debugLog(debugConsole, .pipeline, "No roleplay TTS produced this turn — force-clearing speech state")
                        markAssistantSpeechEnded(reason: "no_tts_this_turn")
                    }
                }
            } else {
                sentenceBuffer += remaining
                let finalText = TextProcessing.stripReasoningPreface(
                    TextProcessing.stripNonSpeechChars(sentenceBuffer)
                )
                // In streaming mode (preferFinalOnlySpeech=false), sentences were already
                // sent to TTS during generation. Only the buffer remainder needs synthesis.
                // In batched mode, deferredSentenceQueue holds all deferred sentences.
                var sentences = deferredSentenceQueue
                if !finalText.isEmpty, !suppressProvisionalOutputForLikelyToolTurn {
                    sentences.append(finalText)
                }
                let filteredSentences = sentences.filter {
                    !$0.isEmpty && !TextProcessing.looksLikeNonProse($0)
                }
                let shouldSpeak = generationContext.allowsAudibleOutput && !filteredSentences.isEmpty
                if !preferFinalOnlySpeech {
                    let llmElapsed = Date().timeIntervalSince(llmStartedAt)
                    let ttfaStr: String
                    if let ttfaDate = firstTtsEnqueuedAt {
                        ttfaStr = String(format: "%.2fs", ttfaDate.timeIntervalSince(llmStartedAt))
                    } else {
                        ttfaStr = "n/a"
                    }
                    debugLog(
                        debugConsole,
                        .pipeline,
                        String(format: "TTS streaming summary: TTFA=%@, LLM=%.2fs, sentences=%d (%d chars), remainder=%d chars",
                               ttfaStr, llmElapsed, streamingChunkCount, streamingChunkCharsTotal, finalText.count)
                    )
                }
                if !finalText.isEmpty {
                    if suppressProvisionalOutputForLikelyToolTurn {
                        debugLog(
                            debugConsole,
                            .pipeline,
                            "[suppressed provisional tool-turn final text] \(String(finalText.prefix(80)))"
                        )
                    } else {
                        recordVisibleText(finalText)
                        sendAssistantText(finalText, isFinal: true)
                    }
                }
                if shouldSpeak {
                    let fullText = filteredSentences.joined(separator: " ")
                    let segments = Self.batchedTTSSegments(from: fullText)
                    NSLog(
                        "PipelineCoordinator: TTS full response → \"%@\" (from %d parts, batched=%d)",
                        String(fullText.prefix(120)),
                        filteredSentences.count,
                        segments.count
                    )
                    for (index, segment) in segments.enumerated() {
                        recordSpokenText(segment)
                        enqueueTTS(
                            segment,
                            isFinal: index == segments.count - 1,
                            generationID: generationID
                        )
                    }
                }
                // Wait for all TTS (streaming + final) to complete.
                await awaitPendingTTS()
                if !shouldSpeak && assistantSpeaking {
                    // No TTS was enqueued for the final chunk (empty or non-prose).
                    // In streaming mode this is expected when the response ended at a
                    // sentence boundary — all audio was already enqueued with isFinal=false.
                    // Signal playback end so the finished event fires.
                    await playback.markEnd()
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if assistantSpeaking,
                       spokenTextThisTurn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        debugLog(debugConsole, .pipeline, "No TTS this turn — force-clearing assistantSpeaking")
                        markAssistantSpeechEnded(reason: "no_tts_this_turn")
                    }
                }
            }

            let spokenText = spokenTextThisTurn.trimmingCharacters(in: .whitespacesAndNewlines)
            let visibleText = visibleTextThisTurn.trimmingCharacters(in: .whitespacesAndNewlines)
            let assistantTextForStorage = generationContext.allowsAudibleOutput ? spokenText : visibleText
            let visibleResponse = Self.stripThinkContent(fullResponse)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if assistantTextForStorage.isEmpty,
               visibleResponse.isEmpty,
               let llmFailureDescription,
               let fallback = Self.llmFailureFallbackMessage(
                    firstOwnerEnrollmentActive: speakerGate.firstOwnerEnrollmentActive,
                    proactiveContextPresent: proactiveContext != nil
               )
            {
                debugLog(debugConsole, .pipeline, "Deterministic LLM failure fallback: \(llmFailureDescription)")
                sendAssistantText(fallback, isFinal: true)
                if generationContext.allowsAudibleOutput {
                    recordSpokenText(fallback)
                    enqueueTTS(fallback, isFinal: true, generationID: generationID)
                }
                await awaitPendingTTS()
                await conversationState.addAssistantMessage(fallback, tag: proactiveContext?.conversationTag)
                await synchronizeLLMSession()
                await persistFinalAssistantTurnIfNeeded(fallback)
                endAssistantGeneration(for: generationID)
                engage()
                activeCapabilityTicket = nil
                debugLog(debugConsole, .qa, "=== TURN END fallback reason=llm_error ===")
                return
            }
            if assistantTextForStorage.isEmpty,
               !forceSuppressThinking,
               !options.suppressThinking,
               proactiveContext == nil
            {
                let retryReason = visibleResponse.isEmpty
                    ? "No visible response after thinking block"
                    : "Only suppressed non-spoken output after thinking block"
                debugLog(debugConsole, .pipeline, "\(retryReason) — retrying with thinking disabled")
                await generateWithTools(
                    userText: userText,
                    isToolFollowUp: true,
                    turnCount: turnCount,
                    forceSuppressThinking: true,
                    generationContext: generationContext,
                    generationID: generationID,
                    proactiveContext: proactiveContext
                )
                return
            }

            if turnCount == 0,
               toolCalls.isEmpty,
               proactiveContext == nil,
               Self.isCameraIntentRequest(userText)
            {
                if effectiveToolMode() == "off" {
                    debugLog(debugConsole, .qa, "Camera intent fallback skipped — tools are off")
                } else {
                    debugLog(debugConsole, .qa, "Camera intent fallback: forcing camera tool call")
                    let repairCall = ToolCall(name: "camera", arguments: ["prompt": userText])
                    let repairCallID = UUID().uuidString
                    let inputJSON = Self.serializeArguments(repairCall.arguments)
                    eventBus.send(.toolCall(id: repairCallID, name: repairCall.name, inputJSON: inputJSON))

                    let repairResult = await executeTool(
                        repairCall,
                        proactiveContext: proactiveContext,
                        generationContextOverride: generationContext,
                        traceTurnID: currentTurnID,
                        traceToolCallID: repairCallID
                    )

                    eventBus.send(.toolResult(
                        id: repairCallID,
                        name: repairCall.name,
                        success: !repairResult.isError,
                        output: String(repairResult.output.prefix(200))
                    ))

                    if !repairResult.isError {
                        await conversationState.addAssistantMessage(
                            "I checked the camera.",
                            tag: proactiveContext?.conversationTag
                        )
                        await conversationState.addToolResult(
                            id: repairCallID,
                            name: repairCall.name,
                            content: repairResult.output
                        )

                        await generateWithTools(
                            userText: userText,
                            isToolFollowUp: true,
                            turnCount: turnCount + 1,
                            forceSuppressThinking: true,
                            generationContext: generationContext,
                            generationID: generationID,
                            proactiveContext: proactiveContext
                        )
                        return
                    }

                    debugLog(debugConsole, .qa, "Camera intent fallback failed: \(repairResult.output)")
                }
            }

            if turnCount == 0,
               toolCalls.isEmpty,
               proactiveContext == nil,
               Self.isScreenIntentRequest(userText)
            {
                if effectiveToolMode() == "off" {
                    debugLog(debugConsole, .qa, "Screen intent fallback skipped — tools are off")
                } else {
                    let repairCall = Self.screenRepairToolCall(for: userText)
                    debugLog(debugConsole, .qa, "Screen intent fallback: forcing \(repairCall.name) tool call")
                    let repairCallID = UUID().uuidString
                    let inputJSON = Self.serializeArguments(repairCall.arguments)
                    eventBus.send(.toolCall(id: repairCallID, name: repairCall.name, inputJSON: inputJSON))

                    let repairResult = await executeTool(
                        repairCall,
                        proactiveContext: proactiveContext,
                        generationContextOverride: generationContext,
                        traceTurnID: currentTurnID,
                        traceToolCallID: repairCallID
                    )

                    eventBus.send(.toolResult(
                        id: repairCallID,
                        name: repairCall.name,
                        success: !repairResult.isError,
                        output: String(repairResult.output.prefix(200))
                    ))

                    if !repairResult.isError {
                        await conversationState.addAssistantMessage(
                            "I checked the screen.",
                            tag: proactiveContext?.conversationTag
                        )
                        await conversationState.addToolResult(
                            id: repairCallID,
                            name: repairCall.name,
                            content: repairResult.output
                        )

                        await generateWithTools(
                            userText: userText,
                            isToolFollowUp: true,
                            turnCount: turnCount + 1,
                            forceSuppressThinking: true,
                            generationContext: generationContext,
                            generationID: generationID,
                            proactiveContext: proactiveContext
                        )
                        return
                    }

                    debugLog(debugConsole, .qa, "Screen intent fallback failed: \(repairResult.output)")
                }
            }

            if turnCount == 0,
               toolCalls.isEmpty,
               Self.isToolBackedLookupRequest(userText)
            {
                let ownerProfileExists = await speakerProfileStore?.hasOwnerProfile() ?? false
                let ownerEnrollmentRequired = config.speaker.requireOwnerForTools
                    && !ownerProfileExists

                let fallback: String
                let reasonCode: String
                let currentMode = effectiveToolMode()
                if currentMode == "assistant" {
                    reasonCode = "toolMode=assistant"
                    fallback = "I’m in read-only mode right now — I can search and read but I can’t run that tool. Switch to ‘Everything’ to let me help with this."
                } else if ownerEnrollmentRequired {
                    reasonCode = "owner_enrollment_required"
                    fallback = "I need to enroll your primary voice before I can run tools for that. Please complete voice enrollment, then ask me again."
                } else {
                    reasonCode = "tool_not_called"
                    fallback = "I need to check that with a tool before I answer, and I couldn’t run one this turn. Please ask me to try again."
                }

                debugLog(debugConsole, .qa, "Tool-backed lookup fallback reason=\(reasonCode)")
                if Self.shouldShowToolModeUpgradePopup(reasonCode: reasonCode) {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .faeToolModeUpgradeRequested,
                            object: nil,
                            userInfo: ["reason": reasonCode]
                        )
                    }
                }

                sendAssistantText(fallback, isFinal: true)
                if generationContext.allowsAudibleOutput {
                    enqueueTTS(fallback, isFinal: true, generationID: generationID)
                }
                await awaitPendingTTS()
                endAssistantGeneration(for: generationID)
                await finalizeWorkflowTraceIfNeeded(turnID: currentTurnID, assistantOutcome: fallback, success: false)
                engage()
                activeCapabilityTicket = nil
                debugLog(debugConsole, .qa, "=== TURN END fallback reason=\(reasonCode) ===")
                return
            }

            if !assistantTextForStorage.isEmpty {
                await conversationState.addAssistantMessage(assistantTextForStorage, tag: proactiveContext?.conversationTag)
                await synchronizeLLMSession()
                if proactiveContext == nil {
                    await persistFinalAssistantTurnIfNeeded(assistantTextForStorage)
                } else {
                    await finalizeWorkflowTraceIfNeeded(turnID: currentTurnID, assistantOutcome: assistantTextForStorage, success: true)
                }

                let ownerProfileExists = await speakerProfileStore?.hasOwnerProfile() ?? false
                if VoiceConversationPolicy.shouldPersistSpeechMemory(
                    ownerProfileExists: ownerProfileExists,
                    firstOwnerEnrollmentActive: speakerGate.firstOwnerEnrollmentActive,
                    speakerRole: speakerGate.currentSpeakerRole
                ) {
                    let turnId = newMemoryId(prefix: "turn")
                    _ = await memoryOrchestrator?.capture(
                        turnId: turnId,
                        userText: userText,
                        assistantText: assistantTextForStorage,
                        speakerId: speakerGate.currentSpeakerLabel,
                        utteranceTimestamp: speakerGate.currentUtteranceTimestamp
                    )
                    await capturePendingCorrection()
                } else {
                    debugLog(
                        debugConsole,
                        .memory,
                        "Skipped speech memory capture for non-conversational speaker role=\(speakerGate.currentSpeakerRole?.rawValue ?? "unknown")"
                    )
                }

                // Sentiment → orb feeling.
                if let feeling = SentimentClassifier.classify(assistantTextForStorage) {
                    eventBus.send(.orbStateChanged(mode: "idle", feeling: feeling.rawValue, palette: nil))
                }
            } else if let proactiveContext,
                      !visibleResponse.isEmpty
            {
                let turnId = newMemoryId(prefix: "proactive")
                _ = await memoryOrchestrator?.captureProactiveRecord(
                    turnId: turnId,
                    taskId: proactiveContext.taskId,
                    prompt: userText,
                    responseText: visibleResponse,
                    speakerId: speakerGate.currentSpeakerLabel
                )
                await finalizeWorkflowTraceIfNeeded(turnID: currentTurnID, assistantOutcome: visibleResponse, success: true)
                debugLog(debugConsole, .memory, "Captured silent proactive memory for task \(proactiveContext.taskId)")
            } else if !visibleResponse.isEmpty {
                await finalizeWorkflowTraceIfNeeded(turnID: currentTurnID, assistantOutcome: visibleResponse, success: true)
                debugLog(debugConsole, .llmThink, "[suppressed non-spoken output] \(String(fullResponse.prefix(160)))")
            }

            maybeShowCapabilitiesCanvas(triggerText: userText, modelResponse: fullResponse)

            // TillDone nudge: if the LLM stopped generating but there are incomplete
            // tasks on the TillDone list, nudge it to continue working.
            // Nudges are tagged so they can be cleaned up after the turn, preventing
            // history eviction of the original prompt on long runs.
            // The nudge escalates based on consecutive nudges and task attempt count,
            // explicitly telling the LLM to try different approaches.
            if proactiveContext == nil,
               turnCount < maxToolTurns,
               await TillDoneManager.shared.hasIncompleteTasks
            {
                await TillDoneManager.shared.recordNudge()
                let summary = await TillDoneManager.shared.incompleteSummary
                let progress = await TillDoneManager.shared.progressSummary
                let taskCtx = await TillDoneManager.shared.currentTaskContext
                let stalled = await TillDoneManager.shared.currentTaskStalled
                let nudgeCount = await TillDoneManager.shared.consecutiveNudges
                let nudgeTag = "tilldone_nudge"
                debugLog(debugConsole, .qa, "TillDone nudge #\(nudgeCount): \(progress)")

                // Remove previous nudge messages to avoid accumulating history entries.
                await conversationState.removeMessages(taggedWith: nudgeTag)

                var nudge = """
                    You still have incomplete tasks on your TillDone list:
                    \(summary)

                    \(taskCtx)
                    """

                if stalled {
                    nudge += """

                        This task has been attempted 3+ times. You MUST change strategy:
                        - Break it into smaller sub-tasks (till_done add)
                        - Try a completely different tool or approach
                        - Search the web for a solution (web_search)
                        - Write code to solve it (bash + Python/uv)
                        - Delegate to an agent (delegate_agent)
                        - If truly impossible, skip it (till_done skip) with a reason
                        Do NOT repeat anything from the failure log above.
                        """
                } else if nudgeCount > 1 {
                    nudge += """

                        You have been nudged \(nudgeCount) times without completing a task.
                        If a tool call failed, use till_done log_failure to record what \
                        you tried, then try a DIFFERENT approach. Do not repeat the same \
                        command. Read error messages carefully and fix the root cause.
                        """
                } else {
                    nudge += """

                        Continue working. Use till_done start to begin the next task, \
                        then do the work, then till_done complete when done. \
                        If something fails, log it with till_done log_failure and try \
                        a different approach. Do not stop until all tasks are complete.
                        """
                }

                await conversationState.addUserMessage(nudge, speakerDisplayName: nil, speakerId: nil, tag: nudgeTag)

                await generateWithTools(
                    userText: nudge,
                    isToolFollowUp: true,
                    turnCount: turnCount + 1,
                    forceSuppressThinking: true,
                    generationContext: generationContext,
                    generationID: generationID,
                    proactiveContext: proactiveContext
                )
                return
            }

            endAssistantGeneration(for: generationID)

            // Refresh follow-up window.
            engage()
            activeCapabilityTicket = nil
            debugLog(debugConsole, .qa, "=== TURN END spoken_chars=\(assistantTextForStorage.count) tool_calls=0 ===")
            return
        }

        // ── Script block execution ────────────────────────────────────────
        // Script blocks run without the prefix(5) cap. Each block executes
        // through JSCRuntime with its own budget and governance. Results are
        // added to conversation history as tool results so the LLM can see
        // them in the follow-up turn.
        if !scriptBlocks.isEmpty {
            // Add the assistant's response (including script markup) to history.
            await conversationState.addAssistantMessage(fullResponse, tag: proactiveContext?.conversationTag)
            await synchronizeLLMSession()

            // Speak a brief acknowledgement if no text was spoken yet.
            if turnCount == 0,
               !isToolFollowUp,
               spokenTextThisTurn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                let filler = "Let me run that for you."
                sendAssistantText(filler, isFinal: false)
                if generationContext.allowsAudibleOutput {
                    recordSpokenText(filler)
                    enqueueTTS(filler, isFinal: false, generationID: generationID)
                }
            }

            // Wait for any queued speech to finish before starting script execution.
            if assistantSpeaking || ttsState.pendingTask != nil {
                await awaitPendingTTS()
                await awaitSpeechDrain(timeoutMs: 8_000, reason: "before_script_execution")
            }

            var scriptSuccessCount = 0
            var scriptFailureCount = 0

            for (index, block) in scriptBlocks.enumerated() {
                let scriptId = "script-\(index)"
                debugLog(debugConsole, .toolCall, "Executing script block \(index + 1)/\(scriptBlocks.count)")

                let (output, success) = await executeScriptBlock(
                    block,
                    proactiveContext: proactiveContext
                )

                if success {
                    scriptSuccessCount += 1
                } else {
                    scriptFailureCount += 1
                }

                await conversationState.addToolResult(
                    id: scriptId,
                    name: "tool_program",
                    content: output,
                    tag: proactiveContext?.conversationTag
                )
            }

            debugLog(debugConsole, .qa, "Script execution summary: success=\(scriptSuccessCount) failure=\(scriptFailureCount)")
            await synchronizeLLMSession()

            // Now execute any tool calls that were alongside the script blocks
            // (using the normal prefix(5) cap for tool calls).
            if !toolCalls.isEmpty {
                for call in toolCalls.prefix(5) {
                    let callId = UUID().uuidString
                    let result = await executeTool(
                        call,
                        capabilityTicketOverride: activeCapabilityTicket,
                        explicitUserAuthorizationOverride: explicitUserAuthorizationForTurn,
                        proactiveContext: proactiveContext,
                        generationContextOverride: generationContext,
                        traceTurnID: currentTurnID,
                        traceToolCallID: callId
                    )
                    await conversationState.addToolResult(
                        id: callId,
                        name: call.name,
                        content: result.output,
                        tag: proactiveContext?.conversationTag
                    )
                }
                await synchronizeLLMSession()
            }

            // Trigger a follow-up LLM turn to synthesize the script results.
            await generateWithTools(
                userText: userText,
                isToolFollowUp: true,
                turnCount: turnCount + 1,
                forceSuppressThinking: true,
                generationContext: generationContext,
                generationID: generationID,
                proactiveContext: proactiveContext
            )
            return
        }

        // Tool calls found — execute them.
        if turnCount == 0,
           !isToolFollowUp,
           proactiveContext == nil,
           Self.canRunDeferredToolCalls(toolCalls, registry: registry),
           !Self.shouldPreferInlineToolExecution(userText: userText, toolCalls: toolCalls)
        {
            // Preserve think content for deferred tool messages (same reason as inline path).
            let assistantToolMessage = fullResponse

            let ack = "I’ll check that in the background and report back as soon as it’s ready."
            sendAssistantText(ack, isFinal: true)
            if generationContext.allowsAudibleOutput {
                enqueueTTS(ack, isFinal: true, generationID: generationID)
            }

            // Prevent audio stutter: do not launch background tool execution while
            // the acknowledgement is still being spoken.
            await awaitPendingTTS()
            if generationContext.allowsAudibleOutput {
                await awaitSpeechDrain(timeoutMs: 8_000, reason: "before_deferred_tools")
            }

            await startDeferredToolJob(
                userText: userText,
                toolCalls: Array(toolCalls.prefix(5)),
                assistantToolMessage: assistantToolMessage,
                forceSuppressThinking: forceSuppressThinking,
                capabilityTicket: activeCapabilityTicket,
                explicitUserAuthorization: explicitUserAuthorizationForTurn,
                generationContext: generationContext,
                originTurnID: currentTurnID
            )

            endAssistantGeneration(for: generationID)
            engage()
            activeCapabilityTicket = nil
            debugLog(debugConsole, .qa, "=== TURN END deferred_tools count=\(toolCalls.count) ===")
            return
        }

        guard turnCount < maxToolTurns else {
            debugLog(debugConsole, .qa, "Exceeded max tool turns (\(maxToolTurns))")
            await conversationState.removeMessages(taggedWith: "tilldone_nudge")
            let msg = "I've used several tools but couldn't complete that. Could you try rephrasing?"
            sendAssistantText(msg, isFinal: true)
            if generationContext.allowsAudibleOutput {
                await speakText(msg, isFinal: true)
            }
            endAssistantGeneration(for: generationID)
            await finalizeWorkflowTraceIfNeeded(turnID: currentTurnID, assistantOutcome: msg, success: false)
            activeCapabilityTicket = nil
            return
        }

        // Fallback filler: if the model emitted a bare tool call with no natural
        // preamble, speak a short acknowledgement so users don't hear dead air
        // while tools execute.
        var didEnqueueToolFiller = false
        let preflightToolDenial = Self.preflightToolDenial(
            for: Array(toolCalls.prefix(5)),
            registry: registry,
            toolMode: effectiveToolMode(),
            privacyMode: effectivePrivacyMode()
        )
        if turnCount == 0,
           !isToolFollowUp,
           spokenTextThisTurn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           preflightToolDenial == nil
        {
            let filler = Self.toolCallAcknowledgement(for: toolCalls)
            if !filler.isEmpty {
                sendAssistantText(filler, isFinal: false)
                if generationContext.allowsAudibleOutput {
                    recordSpokenText(filler)
                    enqueueTTS(filler, isFinal: false, generationID: generationID)
                    didEnqueueToolFiller = true
                }
            }
        }

        // Add the assistant's tool-calling message to history.
        //
        // When tool calls are present, PRESERVE think content — the </think>
        // marker is needed by Qwen3.5's Jinja template to properly close the
        // think block before rendering tool calls. Stripping think content
        // triggers a known template bug where <think> is left unclosed,
        // corrupting every subsequent turn and causing 0-token generation.
        //
        // This is model-agnostic: any model that uses <think> blocks benefits
        // from having the closing marker preserved. Models without thinking
        // are unaffected (no <think> content to preserve).
        let assistantHistoryText = toolCalls.isEmpty
            ? Self.stripThinkContent(fullResponse)
            : fullResponse
        await conversationState.addAssistantMessage(assistantHistoryText, tag: proactiveContext?.conversationTag)
        await synchronizeLLMSession()

        let capabilityTicketForToolTurn = activeCapabilityTicket
        let explicitAuthorizationForToolTurn = explicitUserAuthorizationForTurn

        // Prevent synthesis/playback jitter: avoid starting tool execution while
        // filler/pre-tool speech is still active.
        if didEnqueueToolFiller || assistantSpeaking || ttsState.pendingTask != nil {
            debugLog(debugConsole, .pipeline, "Delaying tool execution until speech drains")
            await awaitPendingTTS()
            await awaitSpeechDrain(timeoutMs: 8_000, reason: "before_tool_execution")
        }

        var toolSuccessCount = 0
        var toolFailureCount = 0
        var preflightDenialCount = 0
        var firstToolError: String?
        var directToolReply: String?

        for call in toolCalls.prefix(5) {
            let callId = UUID().uuidString
            let inputJSON = Self.serializeArguments(call.arguments)
            let preflightDenial = Self.preflightToolDenial(
                for: [call],
                registry: registry,
                toolMode: effectiveToolMode(),
                privacyMode: effectivePrivacyMode()
            )

            if let preflightDenial {
                debugLog(debugConsole, .approval, "Blocked tool call before execution: \(call.name) — \(preflightDenial)")
                toolFailureCount += 1
                preflightDenialCount += 1
                if firstToolError == nil {
                    firstToolError = preflightDenial
                }
                await recordWorkflowPreflightDenied(
                    turnID: currentTurnID,
                    callId: callId,
                    call: call,
                    reason: preflightDenial
                )
                await conversationState.addToolResult(
                    id: callId,
                    name: call.name,
                    content: preflightDenial,
                    tag: proactiveContext?.conversationTag
                )
                continue
            }

            if assistantSpeaking {
                debugLog(debugConsole, .pipeline, "⚠️ Tool start while assistantSpeaking=true (\(call.name))")
            }
            eventBus.send(.toolCall(id: callId, name: call.name, inputJSON: inputJSON))
            NSLog("PipelineCoordinator: executing tool '%@'", call.name)
            let inputPreview = String(inputJSON.prefix(220))
            debugLog(debugConsole, .toolCall, "id=\(callId.prefix(8)) name=\(call.name) args=\(inputPreview)")

            let callSignature = "\(call.name)|\(inputJSON)"
            var result: ToolResult
            if seenToolCallSignatures.contains(callSignature) {
                debugLog(debugConsole, .toolCall, "⚠️ Duplicate tool call blocked: \(call.name) — returning cached notice")
                result = .success("You already retrieved these results earlier in this conversation. Please synthesize your response using the data already provided rather than repeating the same search.")
                await recordWorkflowPreflightDenied(
                    turnID: currentTurnID,
                    callId: callId,
                    call: call,
                    reason: result.output
                )
            } else {
                seenToolCallSignatures.insert(callSignature)
                result = await executeTool(
                    call,
                    capabilityTicketOverride: capabilityTicketForToolTurn,
                    explicitUserAuthorizationOverride: explicitAuthorizationForToolTurn,
                    proactiveContext: proactiveContext,
                    generationContextOverride: generationContext,
                    traceTurnID: currentTurnID,
                    traceToolCallID: callId
                )
            }
            if call.name == "camera", proactiveContext?.taskId == "camera_presence_check", !result.isError {
                let userPresent = Self.inferUserPresentFromCameraOutput(result.output)
                await proactivePresenceHandler?(userPresent)
            }
            if call.name == "screenshot", proactiveContext?.taskId == "screen_activity_check", !result.isError {
                let hash = Self.contentHash(result.output)
                if let shouldPersist = await proactiveScreenContextHandler?(hash), !shouldPersist {
                    result = .success("Screen context unchanged recently. Do not store a new screen context memory record; keep the existing context.")
                }
            }
            let outputPreview = result.output.replacingOccurrences(of: "\n", with: " ").prefix(220)
            debugLog(debugConsole, .toolResult, "id=\(callId.prefix(8)) name=\(call.name) status=\(result.isError ? "error" : "ok") output=\(outputPreview)")
            if result.isError {
                toolFailureCount += 1
                if firstToolError == nil {
                    firstToolError = result.output
                }
            } else {
                toolSuccessCount += 1
                if toolCalls.count == 1,
                   let reply = Self.directToolReplyText(for: call, result: result)
                {
                    directToolReply = reply
                }
            }

            eventBus.send(.toolResult(
                id: callId,
                name: call.name,
                success: !result.isError,
                output: String(result.output.prefix(200))
            ))

            // Check for audio file output from skills — play WAV files automatically.
            if call.name == "run_skill", !result.isError,
               let audioPath = Self.extractAudioFilePath(from: result.output)
            {
                let audioURL = URL(fileURLWithPath: audioPath)
                if generationContext.allowsAudibleOutput,
                   FileManager.default.fileExists(atPath: audioPath)
                {
                    NSLog("PipelineCoordinator: playing skill audio output: %@", audioURL.lastPathComponent)
                    await playback.playFile(url: audioURL)
                }
            }

            await conversationState.addToolResult(
                id: callId,
                name: call.name,
                content: result.output,
                tag: proactiveContext?.conversationTag
            )
        }

        debugLog(debugConsole, .qa, "Tool execution summary: success=\(toolSuccessCount) failure=\(toolFailureCount)")

        await synchronizeLLMSession()

        // TillDone: clean up nudge history and push canvas report when workflow ends.
        let tillDoneListStillActive = await TillDoneManager.shared.isListActive
        if tillDoneListStillActive, await TillDoneManager.shared.allDone {
            let htmlReport = await TillDoneManager.shared.generateHTMLReport()
            if !htmlReport.isEmpty {
                debugLog(debugConsole, .qa, "TillDone: all tasks complete — pushing report to canvas")
                eventBus.send(.canvasContent(html: htmlReport, append: false))
                eventBus.send(.canvasVisibility(true))
            }
            await conversationState.removeMessages(taggedWith: "tilldone_nudge")
        } else if !tillDoneListStillActive {
            // List was cleared mid-conversation — remove any leftover nudge messages.
            await conversationState.removeMessages(taggedWith: "tilldone_nudge")
        }

        if toolFailureCount > 0 && toolSuccessCount == 0 {
            // Distinguish unrecoverable denials from recoverable tool errors.
            // Preflight denials (tool blocked by mode/policy) can't be retried.
            // Tool execution errors (wrong params, validation) should be fed back
            // to the LLM so it can self-correct with the right arguments.
            let allFailuresAreDenials = preflightDenialCount == toolFailureCount
            if allFailuresAreDenials || turnCount >= 4 {
                await conversationState.removeMessages(taggedWith: "tilldone_nudge")
                let reason = firstToolError ?? "the tool call was denied or failed"
                let msg = "I couldn't complete that because the required tool didn't run: \(reason)"
                sendAssistantText(msg, isFinal: true)
                if generationContext.allowsAudibleOutput {
                    await speakText(msg, isFinal: true)
                }
                endAssistantGeneration(for: generationID)
                await finalizeWorkflowTraceIfNeeded(turnID: currentTurnID, assistantOutcome: msg, success: false)
                activeCapabilityTicket = nil
                return
            }
            // Recoverable tool error — let LLM see the error and retry.
            debugLog(debugConsole, .qa, "Tool error is recoverable (turn \(turnCount)) — feeding back to LLM for self-correction")
        }

        if turnCount == 0,
           toolFailureCount == 0,
           toolCalls.count == 1,
           let directToolReply
        {
            sendAssistantText(directToolReply, isFinal: true)
            if generationContext.allowsAudibleOutput {
                await speakText(directToolReply, isFinal: true, emitAssistantText: false)
            }
            await conversationState.addAssistantMessage(
                directToolReply,
                tag: proactiveContext?.conversationTag
            )
            await synchronizeLLMSession()
            await persistFinalAssistantTurnIfNeeded(directToolReply)
            endAssistantGeneration(for: generationID)
            engage()
            activeCapabilityTicket = nil
            debugLog(debugConsole, .qa, "=== TURN END direct_tool_reply name=\(toolCalls[0].name) ===")
            return
        }

        // If activate_skill ran, the LLM now has skill instructions in context and
        // needs tool access to act on them. Rather than expanding to ALL tools
        // (which adds ~30 tool schemas / thousands of tokens and invalidates the
        // session KV cache), expand to a focused set: the skill execution tools
        // plus the tools from the original turn. This keeps the prompt compact
        // and avoids the Qwen3.5 0-token stall caused by massive tool schemas
        // in follow-up turns.
        let executedToolNames = Set(toolCalls.prefix(5).map(\.name))
        var followUpContext = generationContext
        if executedToolNames.contains("activate_skill") {
            let activeModelId = currentModelId()
            let preferLegacy = Self.prefersLegacyInlineToolPrompt(modelId: activeModelId)
            if !preferLegacy {
                // Skill execution core tools + common action tools.
                let skillTools: Set<String> = [
                    "run_skill", "bash", "read", "write", "edit",
                    "channel_setup", "input_request", "self_config",
                    "activate_skill", "manage_skill", "web_search", "fetch_url",
                ]
                // Merge with the original turn's tools so nothing is lost.
                let originalToolNames = Set(
                    (generationContext.nativeTools ?? []).compactMap { spec -> String? in
                        (spec["function"] as? [String: Any])?["name"] as? String
                    }
                )
                let expandedSet = skillTools.union(originalToolNames)
                let expandedTools = registry.nativeToolSpecs(
                    for: effectiveToolMode(),
                    privacyMode: effectivePrivacyMode(),
                    limitedTo: expandedSet
                )
                // Rebuild system prompt with the newly activated skill body.
                // The original generationContext.systemPrompt was assembled BEFORE
                // activate_skill ran, so it does NOT contain the skill instructions.
                // Without this, the LLM sees "use the skill instructions" in the nudge
                // but the instructions aren't in context → Qwen3.5 0-token stall.
                var updatedSystemPrompt = generationContext.systemPrompt
                if let activatedCtx = await skillManager?.activatedContext() {
                    updatedSystemPrompt += "\n\n" + activatedCtx
                    debugLog(debugConsole, .pipeline, "Injected activated skill body into follow-up system prompt (\(activatedCtx.count) chars)")
                }

                followUpContext = GenerationContext(
                    systemPrompt: updatedSystemPrompt,
                    turnContextPrefix: generationContext.turnContextPrefix,
                    nativeTools: expandedTools,
                    actionSource: generationContext.actionSource,
                    playsThinkingTone: generationContext.playsThinkingTone,
                    allowsAudibleOutput: generationContext.allowsAudibleOutput
                )
                debugLog(debugConsole, .pipeline, "Expanded tool set after activate_skill to \(expandedSet.count) tools (was \(originalToolNames.count))")
            }
        }

        // Qwen3.5 stalls (0 tokens) on tool follow-up turns when the tool
        // result is in context but there's no clear user signal to continue.
        // Inject a follow-up nudge so the model knows to interpret the tool
        // results and respond. The nudge is tailored: activate_skill gets a
        // skill-specific nudge; other tools get a generic continuation signal.
        if toolSuccessCount > 0 {
            let nudge: String
            if executedToolNames.contains("activate_skill") {
                nudge = "The skill is now active. Use the skill instructions to help with my request."
            } else {
                nudge = "Use the tool results above to continue helping with my request."
            }
            await conversationState.addUserMessage(
                nudge,
                speakerDisplayName: speakerGate.currentSpeakerDisplayName,
                speakerId: speakerGate.currentSpeakerLabel,
                tag: proactiveContext?.conversationTag
            )
            debugLog(debugConsole, .pipeline, "Injected follow-up nudge after tool execution (\(executedToolNames.sorted().joined(separator: ", ")))")
        }

        // Recurse: generate again with tool results in context.
        await generateWithTools(
            userText: userText,
            isToolFollowUp: true,
            turnCount: turnCount + 1,
            forceSuppressThinking: forceSuppressThinking,
            generationContext: followUpContext,
            generationID: generationID,
            proactiveContext: proactiveContext
        )
    }

    /// Snapshot of the current foreground turn's prompt/tool context.
    private var currentTurnGenerationContext: GenerationContext?

    // MARK: - Speech State

    /// Clear the generation-in-progress flag.
    ///
    /// When called with a `generationID`, only clears if that generation is still
    /// the active one. This prevents an interrupted/stale generation from clearing
    /// state that belongs to a newer generation (race after barge-in).
    private func endAssistantGeneration(for generationID: UUID? = nil) {
        if let generationID, activeGenerationID != generationID {
            return
        }
        assistantGenerating = false
        bargeInState.generationTakeoverCandidate = nil
        eventBus.send(.assistantGenerating(false))
        drainSilentGenerationBuffer()
        scheduleDeferredProactiveDrain()
    }

    /// Re-enqueue segments that were buffered while the LLM was generating
    /// silently.  Stale segments (>30s old) are dropped.
    private func drainSilentGenerationBuffer() {
        guard !silentGenerationBuffer.isEmpty else { return }
        let buffered = silentGenerationBuffer
        silentGenerationBuffer.removeAll()
        let now = Date()
        for segment in buffered {
            let age = now.timeIntervalSince(segment.capturedAt)
            if age > 30 {
                debugLog(debugConsole, .pipeline, "Dropped stale buffered segment age=\(String(format: "%.1f", age))s")
                continue
            }
            debugLog(debugConsole, .pipeline, "Draining buffered segment dur=\(String(format: "%.2f", segment.durationSeconds))s age=\(String(format: "%.1f", age))s")
            enqueueSpeechSegment(segment)
        }
    }

    static func shouldShowToolModeUpgradePopup(reasonCode: String) -> Bool {
        switch reasonCode {
        case "owner_enrollment_required", "non-owner", "tool_not_called", "toolMode=assistant":
            return true
        default:
            return false
        }
    }

    /// Detect audio output route from the playback engine for echo suppression tuning.
    ///
    /// Maps the system default output device name to an `EchoSuppressor.OutputRoute`.
    /// Headphones get relaxed echo windows; external speakers get aggressive windows.
    private nonisolated static func detectOutputRoute(playback: AudioPlaybackManager) -> EchoSuppressor.OutputRoute {
        #if canImport(CoreAudio)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return .unknown }

        // Get device name.
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        let nameStatus = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
        guard nameStatus == noErr else { return .unknown }

        let deviceName = (name as String).lowercased()
        if deviceName.contains("headphone") || deviceName.contains("airpod")
            || deviceName.contains("earpod") || deviceName.contains("beats") {
            return .headphones
        } else if deviceName.contains("macbook") || deviceName.contains("built-in")
                    || deviceName.contains("internal") {
            return .builtInSpeaker
        } else {
            return .externalSpeaker
        }
        #else
        return .unknown
        #endif
    }

    private func markAssistantSpeechStarted() {
        guard !assistantSpeaking else { return }
        assistantSpeaking = true
        lastAssistantStart = Date()
        bargeInState.lastAssistantTextBuffer = ""
        echoSuppressor.onAssistantSpeechStart()
        // Reset playback barge-in state for the new playback session.
        bargeInState.resetPlaybackState()
    }

    private func markAssistantSpeechEnded(reason: String, resetVAD: Bool = false) {
        if assistantSpeaking {
            let speechDuration = lastAssistantStart.map { Date().timeIntervalSince($0) } ?? 0
            debugLog(debugConsole, .pipeline, "Speech state → idle (\(reason), dur=\(String(format: "%.1f", speechDuration))s)")
            assistantSpeaking = false
            echoSuppressor.onAssistantSpeechEnd(speechDurationSecs: speechDuration)
            echoSuppressor.beginDecayMeasurement(currentRms: echoSuppressor.playbackBaselineRms)
            echoSuppressor.resetPlaybackBaseline()
            bargeInState.interruptionDecider.reset()
            // Clear playback barge-in state.
            bargeInState.resetPlaybackState()
        }
        if resetVAD {
            vad.reset()
            resetStreamingSpeakerGate()
            resetStreamingWakeDetector()
            clearPendingSemanticTurn()
        }
        scheduleDeferredProactiveDrain()
    }

    // MARK: - TTS

    /// Non-blocking TTS enqueue — chains onto `ttsState.pendingTask` so sentences synthesize
    /// in order without blocking the LLM token stream.
    ///
    /// Call this from inside the token generation loop. The LLM keeps producing tokens
    /// while TTS runs concurrently on the actor (re-entrant at `await` points).
    private func enqueueTTS(_ text: String, isFinal: Bool, voiceInstruct: String? = nil, generationID: UUID? = nil) {
        // Track assistant text for false-interruption recovery.
        bargeInState.lastAssistantTextBuffer += text

        // Record TTS text for text-overlap echo rejection.
        echoSuppressor.recordAssistantText(text)

        // Set speaking state immediately so echo suppressor and barge-in work correctly.
        markAssistantSpeechStarted()

        let previous = ttsState.pendingTask
        ttsState.pendingTask = Task {
            await previous?.value  // Ensure sentence ordering
            guard !isGenerationInterrupted(generationID) else {
                // If this was the final chunk and we're interrupted, ensure speaking
                // state is cleared. The barge-in path calls playback.stop() which
                // fires .stopped → clears assistantSpeaking, but there's a race
                // window where that hasn't fired yet. Belt-and-suspenders.
                if isFinal && assistantSpeaking {
                    NSLog("PipelineCoordinator: interrupted final TTS chunk — clearing speaking state")
                    markAssistantSpeechEnded(reason: "interrupted_final_chunk")
                }
                return
            }
            await synthesizeSentence(text, isFinal: isFinal, voiceInstruct: voiceInstruct)
            // Yield after synthesis to reduce GPU contention with the LLM token loop.
            // Both Kokoro TTS and the LLM share the MLX Metal command queue; yielding
            // gives the LLM token generation priority between TTS sentences.
            await Task.yield()
        }
    }

    /// Wait for all pending TTS work to complete. Call after the token loop ends.
    private func awaitPendingTTS() async {
        await ttsState.awaitPending()
    }

    /// Wait until playback state reports idle (assistantSpeaking=false), or timeout.
    ///
    /// Useful before tool execution so heavy work doesn't contend with active speech
    /// synthesis/playback and cause audible jitter.
    private func awaitSpeechDrain(timeoutMs: Int, reason: String) async {
        guard assistantSpeaking else { return }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)

        while assistantSpeaking, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if assistantSpeaking {
            debugLog(debugConsole, .pipeline, "⚠️ Speech drain timeout (\(reason)) after \(timeoutMs)ms — force-stopping playback")
            // Cancel any queued TTS work to prevent re-triggering assistantSpeaking
            // after we clear it. Without this, a queued sentence could start playing
            // immediately after stop(), re-setting the flag.
            ttsState.cancelPending()
            markGenerationInterrupted()
            await playback.stop()
            markAssistantSpeechEnded(reason: "speech_drain_timeout")
        }
    }

    /// Blocking TTS — used by `speakDirect`, `speakWithVoice`, and other non-streaming paths
    /// where we want to wait for speech to finish before continuing.
    private func speakText(
        _ text: String,
        isFinal: Bool,
        voiceInstruct: String? = nil,
        emitAssistantText: Bool = true
    ) async {
        markAssistantSpeechStarted()

        let cleaned = TextProcessing.stripNonSpeechChars(text)
        if emitAssistantText, !cleaned.isEmpty {
            sendAssistantText(cleaned, isFinal: isFinal)
        }

        // Use cleaned text for TTS — stripping self-introductions, markup, etc.
        let ttsText = cleaned.isEmpty ? text : cleaned
        let segments = Self.batchedTTSSegments(from: ttsText)
        guard !segments.isEmpty else {
            if isFinal {
                markAssistantSpeechEnded(reason: "tts_empty_after_clean")
            }
            return
        }

        for (index, segment) in segments.enumerated() {
            let segmentIsFinal = isFinal && index == segments.count - 1
            await synthesizeSentence(segment, isFinal: segmentIsFinal, voiceInstruct: voiceInstruct)
        }
    }

    // ttsSynthesisTimeoutSeconds moved to TTSState.synthesisTimeoutSeconds.

    /// Core TTS synthesis — shared by both `enqueueTTS` and `speakText`.
    ///
    /// Uses a task group with a timeout child so that if the TTS async stream
    /// blocks before yielding its first buffer (model hang), the timeout task
    /// cancels the stream consumer and we fall through to cleanup.
    private func synthesizeSentence(_ text: String, isFinal: Bool, voiceInstruct: String? = nil) async {
        guard await ttsEngine.isLoaded else {
            NSLog("PipelineCoordinator: TTS not loaded, skipping speech")
            debugLog(debugConsole, .pipeline, "⚠️ TTS not loaded — skipping speech")
            if isFinal {
                markAssistantSpeechEnded(reason: "tts_not_loaded")
            }
            return
        }
        debugLog(debugConsole, .pipeline, "TTS: \"\(String(text.prefix(80)))\"\(text.count > 80 ? "…" : "") (final=\(isFinal))")

        let effectiveVoiceInstruct = voiceInstruct ?? config.tts.defaultVoiceInstruct
        var didProduceAudio = false

        var ttsSamplesForEcho: [Float] = []
        var ttsSampleRate = 24_000

        do {
            didProduceAudio = try await withThrowingTaskGroup(of: (Bool, [Float], Int).self) { group in
                // Child 1: consume the TTS stream.
                // Uses Task.checkCancellation() for interruption — the timeout
                // child or external cancellation (barge-in) cancels this task.
                group.addTask { [ttsEngine, playback] in
                    let ttsStartedAt = Date()
                    var firstChunkEmitted = false
                    var produced = false
                    let audioStream = await ttsEngine.synthesize(
                        text: text, voiceInstruct: effectiveVoiceInstruct
                    )
                    // Accumulate TTS chunks before scheduling on the player.
                    // The TTS model (Qwen3-TTS 12Hz) yields small chunks — scheduling
                    // each individually causes actor-hop overhead and risks player underruns.
                    // ~500ms of audio (12 000 samples at 24kHz) per enqueue gives the
                    // player a comfortable rolling buffer without inflating TTFA.
                    var accum: [Float] = []
                    var allSamples: [Float] = []  // For echo suppressor playback ring buffer
                    var accumRate = 24_000
                    let accumTarget = 12_000  // ~500ms at 24kHz
                    for try await buffer in audioStream {
                        try Task.checkCancellation()
                        if !firstChunkEmitted {
                            let latencyMs = Date().timeIntervalSince(ttsStartedAt) * 1000
                            firstChunkEmitted = true
                            NSLog("phase1.tts_first_chunk_latency_ms=%.2f", latencyMs)
                        }
                        produced = true
                        accumRate = Int(buffer.format.sampleRate)
                        let samples = Self.extractSamples(from: buffer)
                        accum.append(contentsOf: samples)
                        allSamples.append(contentsOf: samples)
                        if accum.count >= accumTarget {
                            await playback.enqueue(samples: accum, sampleRate: accumRate, isFinal: false)
                            accum = []
                        }
                    }
                    // Flush any remaining samples; isFinal is handled by markEnd() below.
                    if !accum.isEmpty {
                        await playback.enqueue(samples: accum, sampleRate: accumRate, isFinal: false)
                    }
                    return (produced, allSamples, accumRate)
                }

                // Child 2: timeout watchdog — cancels the group if TTS hangs.
                group.addTask {
                    try await Task.sleep(nanoseconds: TTSState.synthesisTimeoutSeconds * 1_000_000_000)
                    // If we reach here, the timeout expired before the stream finished.
                    return (false, [], 24_000)
                }

                // Wait for whichever finishes first.
                if let result = try await group.next() {
                    // Cancel the remaining child (either the timeout or the stalled stream).
                    group.cancelAll()
                    if !result.0 {
                        NSLog("PipelineCoordinator: TTS synthesis timeout or produced no audio")
                        debugLog(debugConsole, .pipeline, "⚠️ TTS timeout/no-audio — forcing completion")
                    }
                    ttsSamplesForEcho = result.1
                    ttsSampleRate = result.2
                    return result.0
                }
                return false
            }

            // Record TTS audio for cross-correlation echo detection.
            if !ttsSamplesForEcho.isEmpty {
                echoSuppressor.recordPlaybackAudio(samples: ttsSamplesForEcho, sampleRate: ttsSampleRate)
            }

            if isFinal {
                await playback.markEnd()
            }
            if isFinal && !didProduceAudio && assistantSpeaking {
                NSLog("PipelineCoordinator: TTS produced no audio for final chunk — clearing speaking state")
                debugLog(debugConsole, .pipeline, "⚠️ TTS final chunk produced no audio — force-clearing assistantSpeaking")
                markAssistantSpeechEnded(reason: "tts_final_no_audio")
            }
        } catch is CancellationError {
            NSLog("PipelineCoordinator: TTS cancelled")
            if isFinal {
                markAssistantSpeechEnded(reason: "tts_cancelled")
            }
        } catch {
            NSLog("PipelineCoordinator: TTS error: %@", error.localizedDescription)
            markAssistantSpeechEnded(reason: "tts_error")
            await playback.stop()
        }
    }

    // MARK: - Barge-In Decision Forwarding
    //
    // Pure decision functions moved to BargeInDecisions enum.
    // Forwarding methods preserve PipelineCoordinator.xxx() call sites and test compatibility.

    static func shouldTrackBargeIn(assistantSpeaking: Bool) -> Bool {
        BargeInDecisions.shouldTrackBargeIn(assistantSpeaking: assistantSpeaking)
    }

    static func shouldTrackGenerationTakeover(
        assistantSpeaking: Bool,
        assistantGenerating: Bool
    ) -> Bool {
        BargeInDecisions.shouldTrackGenerationTakeover(
            assistantSpeaking: assistantSpeaking,
            assistantGenerating: assistantGenerating
        )
    }

    static func advancePendingBargeIn(
        pending: PendingBargeIn?,
        speechStarted: Bool,
        isSpeech: Bool,
        chunkSamples: [Float],
        rms: Float,
        echoSuppression: Bool,
        bargeInSuppressed: Bool,
        inDenyCooldown: Bool
    ) -> PendingBargeIn? {
        BargeInDecisions.advancePendingBargeIn(
            pending: pending,
            speechStarted: speechStarted,
            isSpeech: isSpeech,
            chunkSamples: chunkSamples,
            rms: rms,
            echoSuppression: echoSuppression,
            bargeInSuppressed: bargeInSuppressed,
            inDenyCooldown: inDenyCooldown
        )
    }

    static func shouldAllowBargeInInterrupt(
        assistantSpeaking: Bool,
        assistantGenerating: Bool
    ) -> Bool {
        BargeInDecisions.shouldAllowBargeInInterrupt(
            assistantSpeaking: assistantSpeaking,
            assistantGenerating: assistantGenerating
        )
    }

    static func shouldStartDeferredFollowUp(
        originTurnID: String?,
        currentTurnID: String?,
        assistantSpeaking: Bool,
        assistantGenerating: Bool
    ) -> Bool {
        BargeInDecisions.shouldStartDeferredFollowUp(
            originTurnID: originTurnID,
            currentTurnID: currentTurnID,
            assistantSpeaking: assistantSpeaking,
            assistantGenerating: assistantGenerating
        )
    }

    static func coalescedDeferredProactiveTaskIDs(
        existing: [String],
        incomingTaskID: String
    ) -> [String] {
        BargeInDecisions.coalescedDeferredProactiveTaskIDs(
            existing: existing,
            incomingTaskID: incomingTaskID
        )
    }

    /// Owner-verified barge-in: only the owner's voice can interrupt Fae mid-speech.
    /// Fail-closed after enrollment: if owner exists but verification fails, barge-in is DENIED.
    private func handleBargeInWithVerification(barge: PendingBargeIn) async {
        guard !bargeInState.isSuppressed else { return }
        guard Self.shouldAllowBargeInInterrupt(
            assistantSpeaking: assistantSpeaking,
            assistantGenerating: assistantGenerating
        ) else { return }
        // Use peakRms (max over the accumulation window) instead of lastRms
        // (most recent chunk). A user who trails off at the end of "stop..."
        // would fail a lastRms check even though their peak was clearly audible.
        guard barge.peakRms >= config.bargeIn.minRms else { return }

        // Check holdoff — don't interrupt immediately after playback starts.
        if let start = lastAssistantStart {
            let elapsed = Date().timeIntervalSince(start) * 1000
            if elapsed < Double(config.bargeIn.assistantStartHoldoffMs) {
                return
            }
        }

        // Echo rejection — if audio matches Fae's own voice profile, it's
        // speaker bleedthrough that survived the echo suppressor timing window.
        if barge.audioSamples.count >= 5600,
           let encoder = speakerEncoder, await encoder.isLoaded,
           let store = speakerProfileStore {
            if let embedding = try? await encoder.embed(
                audio: barge.audioSamples,
                sampleRate: AudioCaptureManager.targetSampleRate
            ) {
                    let faeSelfThreshold = echoSuppressor.faeSelfThresholdDuringPlayback(baseThreshold: Self.faeSelfEchoThreshold)
                    if let _ = await store.matchesFaeSelf(embedding: embedding, threshold: faeSelfThreshold) {
                    debugLog(debugConsole, .command, "Barge-in blocked (fae_self echo, threshold=\(String(format: "%.3f", faeSelfThreshold)))")
                    NSLog("PipelineCoordinator: barge-in rejected — audio matches fae_self (echo)")
                    return
                }
            }
        }

        // Speaker verification — owner check with graceful degradation.
        let isOwner = await verifyBargeInSpeaker(audio: barge.audioSamples)
        guard isOwner else {
            debugLog(debugConsole, .command, "Barge-in blocked (not owner)")
            bargeInState.startDenyCooldown()
            return
        }

        interrupted = true
        interruptedGenerationID = activeGenerationID
        ttsState.cancelPending()
        // Clear generation flag so the pipeline accepts the user's follow-up speech.
        // The generation-ID-scoped endAssistantGeneration prevents the interrupted
        // async generation from accidentally clearing a future generation's flag.
        endAssistantGeneration()

        // Pause playback (preserves buffer queue for potential resume on false-interrupt).
        // If resume isn't triggered within the recovery window, buffers drain naturally.
        Task { await playback.pause() }
        debugLog(debugConsole, .command, "Barge-in (owner verified) rms=\(String(format: "%.4f", barge.lastRms))")
        NSLog("PipelineCoordinator: barge-in triggered (owner verified, rms=%.4f)", barge.lastRms)

        // Record for false-interruption recovery.
        let outcome = InterruptionOutcome(
            interruptedAt: Date(),
            generationID: activeGenerationID,
            interruptedText: bargeInState.lastAssistantTextBuffer.isEmpty ? nil : bargeInState.lastAssistantTextBuffer,
            spokenFraction: 0  // Approximate — exact tracking deferred.
        )
        bargeInState.recordInterruption(outcome: outcome, paused: true)
    }

    private func markGenerationInterrupted() {
        interrupted = true
        interruptedGenerationID = activeGenerationID
    }

    /// Evaluate a playback barge-in candidate using speaker identity.
    /// This is Path A — runs DURING active playback to detect user speech
    /// over Fae's TTS output using identity checks rather than echo timing.
    ///
    /// Decision matrix:
    /// - Wake word + fae_self rejected → interrupt (fastest path, ~350ms)
    /// - Owner verified + sustained energy above baseline → interrupt (~400ms)
    /// - Mel fallback + fae_self rejected + extreme energy (4x baseline, 500ms, 6 chunks) → interrupt
    /// - Otherwise → keep collecting
    private func evaluatePlaybackBargeIn(candidate: PlaybackBargeInCandidate) async -> Bool {
        guard !bargeInState.isSuppressed else { return false }
        guard assistantSpeaking else { return false }

        // Holdoff — don't interrupt immediately after playback starts.
        if let start = lastAssistantStart {
            let elapsed = Date().timeIntervalSince(start) * 1000
            if elapsed < Double(config.bargeIn.assistantStartHoldoffMs) {
                return false
            }
        }

        // Deny cooldown check.
        if bargeInState.isInDenyCooldown {
            return false
        }

        // Mandatory fae_self check — hard gate. Audio matching Fae's voice
        // is speaker bleedthrough, not the user.
        guard let encoder = speakerEncoder, await encoder.isLoaded,
              let store = speakerProfileStore else {
            // No encoder available — cannot verify identity, do not interrupt
            // during playback (too risky for self-interruption).
            return false
        }

        guard candidate.audioSamples.count >= PlaybackBargeInCandidate.minSamplesForIdentity else {
            return false
        }

        guard let embedding = try? await encoder.embed(
            audio: candidate.audioSamples,
            sampleRate: AudioCaptureManager.targetSampleRate
        ) else {
            return false
        }

        // fae_self rejection — if audio matches Fae's TTS voice, it's echo.
        // Use enhanced threshold during playback (more aggressive).
        let playbackFaeSelfThreshold = echoSuppressor.faeSelfThresholdDuringPlayback(baseThreshold: Self.faeSelfEchoThreshold)
        if let _ = await store.matchesFaeSelf(embedding: embedding, threshold: playbackFaeSelfThreshold) {
            debugLog(debugConsole, .command, "Playback barge-in: fae_self match — echo (threshold=\(String(format: "%.3f", playbackFaeSelfThreshold)))")
            return false
        }

        let melFallback = await encoder.usingMelFallback

        // Layer 1: explicit semantic interrupt intent + not fae_self + owner verified → interrupt.
        // Owner check prevents bystanders from interrupting Fae on shared Macs.
        if bargeInState.playbackInterruptKeywordDetected {
            if !melFallback {
                let compatible = await store.hasCompatibleOwnerProfile(embeddingDim: embedding.count)
                if compatible {
                    let relaxed = max(config.speaker.ownerThreshold - 0.10, 0.40)
                    let isOwner = await store.isOwner(embedding: embedding, threshold: relaxed)
                    if isOwner {
                        debugLog(debugConsole, .command, "Playback barge-in: interrupt keyword + owner → interrupt")
                        NSLog("PipelineCoordinator: playback barge-in triggered (interrupt_keyword + owner)")
                        return true
                    }
                }
            } else {
                // Mel fallback: can't verify owner, but keyword + not-fae_self is strong evidence.
                debugLog(debugConsole, .command, "Playback barge-in: interrupt keyword + not-fae (mel fallback) → interrupt")
                NSLog("PipelineCoordinator: playback barge-in triggered (interrupt_keyword + mel_fallback)")
                return true
            }
        }

        // Layer 1b: Wake word detected + not fae_self → interrupt immediately.
        // Wake words are less likely from bystanders (they know the wake word).
        if bargeInState.playbackWakeWordDetected {
            debugLog(debugConsole, .command, "Playback barge-in: wake word + not-fae → interrupt")
            NSLog("PipelineCoordinator: playback barge-in triggered (wake_word + identity)")
            return true
        }

        // Layer 2: Owner verification + sustained energy above playback baseline.
        if !melFallback {
            let compatible = await store.hasCompatibleOwnerProfile(embeddingDim: embedding.count)
            if compatible {
                let relaxation: Float = 0.10
                let relaxed = max(config.speaker.ownerThreshold - relaxation, 0.40)
                let isOwner = await store.isOwner(embedding: embedding, threshold: relaxed)
                if isOwner && echoSuppressor.userSpeechLikelyAbovePlayback(rms: candidate.peakRms) {
                    debugLog(debugConsole, .command, "Playback barge-in: owner + energy spike → interrupt")
                    NSLog("PipelineCoordinator: playback barge-in triggered (owner + energy rms=%.4f baseline=%.4f)", candidate.peakRms, echoSuppressor.playbackBaselineRms)
                    return true
                }
            }
        }

        // Layer 2b: Mel fallback — can't verify owner, but can reject fae_self.
        // Require extreme energy (4x baseline), 500ms of speech, and 6+ consecutive chunks.
        if melFallback {
            let extremeMultiplier: Float = 4.0
            let minDurationSamples = 8_000  // 500ms at 16kHz
            let minConsecutiveChunks = 6
            let extremeEnergy = echoSuppressor.playbackBaselineRms > 0
                && candidate.peakRms > echoSuppressor.playbackBaselineRms * extremeMultiplier
            if extremeEnergy
                && candidate.speechSamples >= minDurationSamples
                && candidate.consecutiveSpeechChunks >= minConsecutiveChunks
            {
                debugLog(debugConsole, .command, "Playback barge-in: mel fallback + extreme energy → interrupt")
                NSLog("PipelineCoordinator: playback barge-in triggered (mel_fallback rms=%.4f baseline=%.4f)", candidate.peakRms, echoSuppressor.playbackBaselineRms)
                return true
            }
        }

        return false
    }

    /// Execute the playback barge-in — pause playback and mark as interrupted.
    private func executePlaybackBargeIn(candidate: PlaybackBargeInCandidate) async {
        interrupted = true
        interruptedGenerationID = activeGenerationID
        ttsState.cancelPending()
        endAssistantGeneration()
        Task { await playback.pause() }
        debugLog(debugConsole, .command, "Playback barge-in executed rms=\(String(format: "%.4f", candidate.lastRms))")
        NSLog("PipelineCoordinator: playback barge-in executed (rms=%.4f peak=%.4f)", candidate.lastRms, candidate.peakRms)

        let outcome = InterruptionOutcome(
            interruptedAt: Date(),
            generationID: activeGenerationID,
            interruptedText: bargeInState.lastAssistantTextBuffer.isEmpty ? nil : bargeInState.lastAssistantTextBuffer,
            spokenFraction: 0
        )
        bargeInState.recordInterruption(outcome: outcome, paused: true)

        // Clear playback barge-in state.
        bargeInState.resetPlaybackState()
    }

    private func isGenerationInterrupted(_ generationID: UUID?) -> Bool {
        guard interrupted else { return false }
        guard let generationID else { return true }
        if let interruptedGenerationID {
            return interruptedGenerationID == generationID
        }
        return true
    }

    /// Verify the barge-in speaker is the owner. Degrades gracefully when
    /// verification is unavailable — allows interruption rather than silently
    /// blocking the owner from ever interrupting Fae.
    ///
    /// Degradation hierarchy:
    /// 1. Encoder loaded + enough audio → full cosine similarity check
    /// 2. Encoder loaded + short audio → allow (collect more next time)
    /// 3. Encoder not loaded → allow (degrade to acoustic-only interruption)
    /// 4. Embed fails → allow (transient error, don't punish user)
    /// 5. No speaker store → allow during enrollment, allow otherwise
    private func verifyBargeInSpeaker(audio: [Float]) async -> Bool {
        // During enrollment (no owner yet) — allow all barge-in.
        guard let store = speakerProfileStore else { return true }
        let hasOwner = await store.hasOwnerProfile()
        guard hasOwner else { return true }  // No owner enrolled yet — allow

        // Degrade gracefully if encoder unavailable — allow interruption.
        // A false positive (non-owner interrupts) is far less harmful than
        // the owner being unable to interrupt at all.
        guard let encoder = speakerEncoder, await encoder.isLoaded else {
            NSLog("PipelineCoordinator: speaker encoder unavailable — allowing barge-in (degraded)")
            return true
        }

        // Short audio: allow the interruption but log it. The adaptive decider
        // already filters noise/echo, so reaching here means genuine speech.
        // Minimum for reasonable embedding is ~350ms (5600 samples at 16kHz).
        guard audio.count >= 5600 else {
            NSLog("PipelineCoordinator: barge-in audio too short (%d samples) — allowing (degraded)", audio.count)
            return true
        }

        do {
            let embedding = try await encoder.embed(
                audio: audio,
                sampleRate: AudioCaptureManager.targetSampleRate
            )

            // Check dimension compatibility — if owner's profile was enrolled with
            // a different embedding dimension (e.g., old 256-dim vs new 640-dim),
            // allow barge-in since verification is impossible until re-enrollment.
            let compatible = await store.hasCompatibleOwnerProfile(embeddingDim: embedding.count)
            if !compatible {
                return true  // Can't verify — allow (will prompt re-enrollment)
            }

            // Relaxed threshold compensates for shorter/noisier barge-in audio.
            // Extra relaxation for mel-spectral mode since statistical embeddings
            // have a narrower similarity range than neural embeddings.
            let melFallback = await encoder.usingMelFallback
            let relaxation: Float = melFallback ? 0.20 : 0.10
            let relaxed = max(config.speaker.ownerThreshold - relaxation, 0.40)
            return await store.isOwner(embedding: embedding, threshold: relaxed)
        } catch {
            // Embed failed — allow interruption rather than silently blocking.
            NSLog("PipelineCoordinator: speaker embed failed — allowing barge-in (degraded)")
            return true
        }
    }

    // MARK: - Playback Events

    private func setPlaybackEventHandler() async {
        await playback.setEventHandler { [weak self] event in
            Task { await self?.handlePlaybackEvent(event) }
        }
    }

    private func handlePlaybackEvent(_ event: AudioPlaybackManager.PlaybackEvent) {
        switch event {
        case .finished:
            markAssistantSpeechEnded(reason: "playback_finished", resetVAD: true)
            NSLog("PipelineCoordinator: playback finished")

        case .stopped:
            markAssistantSpeechEnded(reason: "playback_stopped", resetVAD: true)

        case .level(let rms):
            if assistantSpeaking,
               !ttsState.ttfaEmittedForCurrentTurn,
               rms > 0.0005,
               let turnEndedAt = ttsState.lastUserTurnEndedAt
            {
                let ttfaMs = Date().timeIntervalSince(turnEndedAt) * 1000
                ttsState.ttfaEmittedForCurrentTurn = true
                NSLog("phase1.ttfa_ms=%.2f turn_id=%@", ttfaMs, currentTurnID ?? "none")
                debugLog(debugConsole, .pipeline, "TTFA=\(String(format: "%.1f", ttfaMs))ms turn=\(currentTurnID?.prefix(8) ?? "none")")
            }
            eventBus.send(.audioLevel(rms))
        }
    }

    // MARK: - Degraded Mode Helpers

    private func evaluateDegradedMode() async -> PipelineDegradedMode {
        let sttLoaded = await sttEngine.isLoaded
        let llmLoaded = await llmEngine.isLoaded
        let ttsLoaded = await ttsEngine.isLoaded

        if sttLoaded && llmLoaded && ttsLoaded {
            return .full
        }
        if !sttLoaded && !llmLoaded && !ttsLoaded {
            return .unavailable
        }
        if !sttLoaded {
            return .noSTT
        }
        if !llmLoaded {
            return .noLLM
        }
        if !ttsLoaded {
            return .noTTS
        }
        return .unavailable
    }

    private func refreshDegradedModeIfNeeded(context: String) async {
        let current = await evaluateDegradedMode()
        guard degradedMode != current else { return }
        degradedMode = current
        NSLog("phase1.degraded_mode=%@ context=%@", current.rawValue, context)
        debugLog(debugConsole, .qa, "Degraded mode -> \(current.rawValue) (context=\(context))")
        eventBus.send(.degradedModeChanged(mode: current.rawValue, context: context))
    }

    // MARK: - Tool Call Parsing

    // ToolCall, ScriptBlock types and parsing moved to ToolCallParsing.swift.
    // Forwarding methods preserve the PipelineCoordinator.parseToolCalls() call sites.

    static func parseToolCalls(from text: String) -> [ToolCall] {
        ToolCallParser.parseToolCalls(from: text)
    }

    static func parseScriptBlocks(from text: String) -> [ScriptBlock] {
        ToolCallParser.parseScriptBlocks(from: text)
    }

    private static func toolCallAcknowledgement(for calls: [ToolCall]) -> String {
        ToolRoutingHelpers.toolCallAcknowledgement(for: calls)
    }

    /// Strip tool call markup from response text, leaving only human-readable content.
    static func stripToolCallMarkup(_ text: String) -> String {
        ToolCallParser.stripToolCallMarkup(text)
    }

    // Tool routing helpers (acknowledgements, markup stripping, deferred tool logic,
    // intent detection, tool call repair, preflight checks, extraction helpers,
    // and result processing) moved to ToolRoutingHelpers.swift.
    // Forwarding methods below preserve internal Self.xxx call sites and test API.

    private static func stripVoiceTagMarkup(_ text: String) -> String {
        ToolRoutingHelpers.stripVoiceTagMarkup(text)
    }

    private static func stripThinkContent(_ text: String) -> String {
        ToolRoutingHelpers.stripThinkContent(text)
    }

    private static func canRunDeferredToolCalls(_ calls: [ToolCall], registry: ToolRegistry) -> Bool {
        ToolRoutingHelpers.canRunDeferredToolCalls(calls, registry: registry)
    }

    static func shouldPreferInlineToolExecution(userText: String, toolCalls: [ToolCall]) -> Bool {
        ToolRoutingHelpers.shouldPreferInlineToolExecution(userText: userText, toolCalls: toolCalls)
    }

    static func responseImpliesToolIntent(_ response: String) -> Bool {
        ToolRoutingHelpers.responseImpliesToolIntent(response)
    }

    private static func isCameraIntentRequest(_ text: String) -> Bool {
        ToolRoutingHelpers.isCameraIntentRequest(text)
    }

    private static func isScreenIntentRequest(_ text: String) -> Bool {
        ToolRoutingHelpers.isScreenIntentRequest(text)
    }

    private static func screenRepairToolCall(for text: String) -> ToolCall {
        ToolRoutingHelpers.screenRepairToolCall(for: text)
    }

    private static func extractReferencedAppName(from text: String) -> String? {
        ToolRoutingHelpers.extractReferencedAppName(from: text)
    }

    private static func isToolBackedLookupRequest(_ text: String) -> Bool {
        ToolRoutingHelpers.isToolBackedLookupRequest(text)
    }

    static func repairedToolCallForSkippedTurn(_ text: String) -> ToolCall? {
        ToolRoutingHelpers.repairedToolCallForSkippedTurn(text)
    }

    private static func extractSessionSearchQuery(from text: String) -> String? {
        ToolRoutingHelpers.extractSessionSearchQuery(from: text)
    }

    static func shouldAttemptRepairToolCall(
        _ call: ToolCall,
        registry: ToolRegistry,
        toolMode: String,
        privacyMode: String
    ) -> Bool {
        ToolRoutingHelpers.shouldAttemptRepairToolCall(call, registry: registry, toolMode: toolMode, privacyMode: privacyMode)
    }

    static func preflightToolDenial(
        for calls: [ToolCall],
        registry: ToolRegistry,
        toolMode: String,
        privacyMode: String
    ) -> String? {
        ToolRoutingHelpers.preflightToolDenial(for: calls, registry: registry, toolMode: toolMode, privacyMode: privacyMode)
    }

    static func shouldSuppressThinking(
        forceSuppressThinking: Bool,
        thinkingLevel: FaeThinkingLevel,
        isToolFollowUp: Bool
    ) -> Bool {
        ToolRoutingHelpers.shouldSuppressThinking(forceSuppressThinking: forceSuppressThinking, thinkingLevel: thinkingLevel, isToolFollowUp: isToolFollowUp)
    }

    static func directToolReplyText(for call: ToolCall, result: ToolResult) -> String? {
        ToolRoutingHelpers.directToolReplyText(for: call, result: result)
    }

    private static func serializeArguments(_ args: [String: Any]) -> String {
        ToolRoutingHelpers.serializeArguments(args)
    }

    private static func estimateTokenCount(for text: String) -> Int {
        ToolRoutingHelpers.estimateTokenCount(for: text)
    }

    private static func inferUserPresentFromCameraOutput(_ output: String) -> Bool {
        ToolRoutingHelpers.inferUserPresentFromCameraOutput(output)
    }

    private static func extractAudioFilePath(from output: String) -> String? {
        ToolRoutingHelpers.extractAudioFilePath(from: output)
    }

    private static func contentHash(_ text: String) -> String {
        ToolRoutingHelpers.contentHash(text)
    }

    // MARK: - Tool Execution

    private func startDeferredToolJob(
        userText: String,
        toolCalls: [ToolCall],
        assistantToolMessage: String,
        forceSuppressThinking: Bool,
        capabilityTicket: CapabilityTicket?,
        explicitUserAuthorization: Bool,
        generationContext: GenerationContext,
        originTurnID: String?
    ) async {
        let job = DeferredToolJob(
            id: UUID(),
            userText: userText,
            toolCalls: toolCalls,
            assistantToolMessage: assistantToolMessage,
            forceSuppressThinking: forceSuppressThinking,
            capabilityTicket: capabilityTicket,
            explicitUserAuthorization: explicitUserAuthorization,
            generationContext: generationContext,
            originTurnID: originTurnID
        )

        await conversationState.addAssistantMessage(job.assistantToolMessage)
        debugLog(debugConsole, .pipeline, "Deferred tool job queued: \(job.id.uuidString.prefix(8)) (\(job.toolCalls.count) call(s))")

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDeferredToolJob(job)
        }
        deferredToolTasks[job.id] = task
    }

    private func runDeferredToolJob(_ job: DeferredToolJob) async {
        defer { deferredToolTasks[job.id] = nil }
        guard !Task.isCancelled else { return }

        debugLog(debugConsole, .pipeline, "Deferred tool job started: \(job.id.uuidString.prefix(8))")

        var toolSuccessCount = 0
        var toolFailureCount = 0
        var preflightDenialCount = 0
        var firstToolError: String?
        var directToolReply: String?

        for call in job.toolCalls {
            guard !Task.isCancelled else { return }

            let callId = UUID().uuidString
            let inputJSON = Self.serializeArguments(call.arguments)
            let preflightDenial = Self.preflightToolDenial(
                for: [call],
                registry: registry,
                toolMode: effectiveToolMode(),
                privacyMode: effectivePrivacyMode()
            )

            if let preflightDenial {
                debugLog(debugConsole, .approval, "Blocked deferred tool call before execution: \(call.name) — \(preflightDenial)")
                toolFailureCount += 1
                preflightDenialCount += 1
                if firstToolError == nil {
                    firstToolError = preflightDenial
                }
                await recordWorkflowPreflightDenied(
                    turnID: job.originTurnID,
                    callId: callId,
                    call: call,
                    reason: preflightDenial
                )
                await conversationState.addToolResult(id: callId, name: call.name, content: preflightDenial)
                continue
            }

            let inputPreview = String(inputJSON.prefix(100))
            debugLog(debugConsole, .toolCall, "id=\(callId.prefix(8)) name=\(call.name) args=\(inputPreview) [deferred]")
            eventBus.send(.toolCall(id: callId, name: call.name, inputJSON: inputJSON))

            let result = await executeTool(
                call,
                capabilityTicketOverride: job.capabilityTicket,
                explicitUserAuthorizationOverride: job.explicitUserAuthorization,
                generationContextOverride: job.generationContext,
                traceTurnID: job.originTurnID,
                traceToolCallID: callId
            )
            if result.isError {
                toolFailureCount += 1
                if firstToolError == nil {
                    firstToolError = result.output
                }
            } else {
                toolSuccessCount += 1
                if job.toolCalls.count == 1,
                   let reply = Self.directToolReplyText(for: call, result: result)
                {
                    directToolReply = reply
                }
            }

            let outputPreview = String(result.output.prefix(100))
            debugLog(debugConsole, .toolResult, "id=\(callId.prefix(8)) name=\(call.name) status=\(result.isError ? "error" : "ok") output=\(outputPreview) [deferred]")
            eventBus.send(.toolResult(
                id: callId,
                name: call.name,
                success: !result.isError,
                output: String(result.output.prefix(200))
            ))

            await conversationState.addToolResult(
                id: callId,
                name: call.name,
                content: result.output
            )
        }

        guard !Task.isCancelled else { return }

        debugLog(debugConsole, .qa, "Deferred tool summary: success=\(toolSuccessCount) failure=\(toolFailureCount)")

        if toolFailureCount > 0 && toolSuccessCount == 0 {
            // Only short-circuit when all failures are preflight denials (unrecoverable).
            // Tool execution errors (wrong params) are fed back to the LLM via follow-up.
            let allFailuresAreDenials = preflightDenialCount == toolFailureCount
            if allFailuresAreDenials {
                let reason = firstToolError ?? "the tool call was denied or failed"
                let msg = "I couldn't complete that background check because the required tool didn't run: \(reason)"
                sendAssistantText(msg, isFinal: true)
                if job.generationContext.allowsAudibleOutput {
                    await speakText(msg, isFinal: true)
                }
                await finalizeWorkflowTraceIfNeeded(turnID: job.originTurnID, assistantOutcome: msg, success: false)
                return
            }
            debugLog(debugConsole, .qa, "Deferred tool error is recoverable — feeding back to LLM for self-correction")
        }

        // Wait for any in-progress speech to finish before starting the
        // follow-up generation.  Without this, the tool-result LLM response
        // can interrupt the acknowledgment message mid-sentence.
        for _ in 0..<60 {
            guard !Task.isCancelled else { return }
            if !assistantSpeaking, !assistantGenerating { break }
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }

        guard Self.shouldStartDeferredFollowUp(
            originTurnID: job.originTurnID,
            currentTurnID: currentTurnID,
            assistantSpeaking: assistantSpeaking,
            assistantGenerating: assistantGenerating
        ) else {
            debugLog(debugConsole, .pipeline, "Deferred tool follow-up dropped: origin turn no longer active")
            await abandonWorkflowTraceIfNeeded(
                turnID: job.originTurnID,
                reason: "Deferred follow-up dropped because the originating turn was no longer active."
            )
            return
        }

        if let directToolReply {
            sendAssistantText(directToolReply, isFinal: true)
            if job.generationContext.allowsAudibleOutput {
                await speakText(directToolReply, isFinal: true, emitAssistantText: false)
            }
            await conversationState.addAssistantMessage(directToolReply)
            await synchronizeLLMSession()
            await persistFinalAssistantTurnIfNeeded(directToolReply, turnID: job.originTurnID)
            debugLog(debugConsole, .qa, "=== TURN END deferred_direct_tool_reply name=\(job.toolCalls[0].name) ===")
            return
        }

        explicitUserAuthorizationForTurn = job.explicitUserAuthorization
        assistantGenerating = true
        eventBus.send(.assistantGenerating(true))
        if job.generationContext.playsThinkingTone {
            await playback.playThinkingTone()
        }

        // Re-issue a capability ticket for the follow-up turn so the LLM
        // can make additional tool calls (e.g. a second web_search).
        activeCapabilityTicket = CapabilityTicketIssuer.issue(
            mode: effectiveToolMode(),
            privacyMode: effectivePrivacyMode(),
            registry: registry
        )

        await generateWithTools(
            userText: job.userText,
            isToolFollowUp: true,
            turnCount: 1,
            forceSuppressThinking: job.forceSuppressThinking,
            generationContext: job.generationContext
        )
    }

    static func toolTimeoutSeconds(for toolName: String) -> TimeInterval {
        ToolExecutor.toolTimeoutSeconds(for: toolName)
    }

    private func executeTool(
        _ call: ToolCall,
        capabilityTicketOverride: CapabilityTicket? = nil,
        explicitUserAuthorizationOverride: Bool? = nil,
        proactiveContext: ProactiveRequestContext? = nil,
        generationContextOverride: GenerationContext? = nil,
        traceTurnID: String? = nil,
        traceToolCallID: String? = nil
    ) async -> ToolResult {
        let workflowTurnID = traceTurnID ?? currentTurnID

        // Build per-call context from coordinator state.
        let livenessScore: Float? = await speakerEncoder?.lastLivenessResult?.score
        let effectiveTicket = capabilityTicketOverride ?? activeCapabilityTicket
        let currentToolMode = effectiveToolMode()
        let hasCapabilityTicket = currentToolMode == "full"
            ? true
            : (effectiveTicket?.allows(toolName: call.name) ?? false)
        let explicitAuthorization = explicitUserAuthorizationOverride ?? explicitUserAuthorizationForTurn
        let effectiveGenerationContext = generationContextOverride ?? currentTurnGenerationContext

        let context = ToolExecutorContext(
            toolMode: currentToolMode,
            privacyMode: effectivePrivacyMode(),
            modelLocality: modelLocality,
            capabilityTicket: effectiveTicket,
            hasCapabilityTicketForTool: hasCapabilityTicket,
            explicitUserAuthorization: explicitAuthorization,
            isOwner: speakerGate.currentSpeakerIsOwner,
            livenessScore: livenessScore,
            actionSource: proactiveContext?.source ?? effectiveGenerationContext?.actionSource ?? .voice,
            proactiveContext: proactiveContext,
            visionEnabled: effectiveVisionEnabled(),
            firstOwnerEnrollmentActive: speakerGate.firstOwnerEnrollmentActive,
            workflowTurnID: workflowTurnID,
            traceToolCallID: traceToolCallID,
            workflowRunID: nil // Workflow trace is managed by PipelineCoordinator
        )

        let callbacks = ToolExecutorCallbacks(
            onApprovalPending: { [weak self] awaiting, manualOnly in
                guard let self else { return }
                await self.setApprovalState(awaiting: awaiting, manualOnly: manualOnly)
            },
            onVisionAutoEnabled: { [weak self] in
                guard let self else { return }
                await self.autoEnableVision()
            },
            onComputerUseStep: { [weak self] in
                guard let self else { return 0 }
                return await self.incrementComputerUseStep()
            }
        )

        // Record tool call in workflow trace (PipelineCoordinator manages run lifecycle).
        await recordWorkflowToolCall(
            turnID: workflowTurnID,
            callId: traceToolCallID,
            call: call
        )

        let outcome = await toolExecutor.execute(call, context: context, callbacks: callbacks)

        // Record tool result in workflow trace.
        await recordWorkflowToolResult(
            turnID: workflowTurnID,
            callId: traceToolCallID,
            call: call,
            result: outcome.result,
            approved: outcome.approvedByUser,
            latencyMs: outcome.latencyMs,
            damageControlIntervened: outcome.damageControlIntervened
        )

        return outcome.result
    }

    // MARK: - ToolExecutor Callback Helpers

    private func setApprovalState(awaiting: Bool, manualOnly: Bool) {
        awaitingApproval = awaiting
        manualOnlyApprovalPending = manualOnly
    }

    private func autoEnableVision() {
        visionEnabledLive = true
        Task { @MainActor in
            SelfConfigTool.configPatcher?("vision.enabled", true)
        }
    }

    private func incrementComputerUseStep() -> Int {
        computerUseStepCount += 1
        return computerUseStepCount
    }

    // MARK: - JSC Script Execution

    /// Lazily create or return the shared ``JSCRuntime`` for script execution.
    ///
    /// The runtime is wired to the same ``ToolExecutor`` that handles normal
    /// tool calls, so all governance, approval, and audit layers apply.
    private func ensureJSCRuntime() -> JSCRuntime {
        if let existing = jscRuntime {
            return existing
        }

        let runtime = JSCRuntime(
            executor: toolExecutor,
            contextFactory: { [weak self] in
                // Build a fresh context snapshot from the coordinator's current state.
                // If the coordinator is gone, return a restrictive default.
                guard self != nil else {
                    return .restrictedFallback()
                }

                // NOTE: This is the @Sendable fallback — used only when run()
                // is called without an explicit context parameter (e.g. from
                // tests or the developer harness). Production calls via
                // executeScriptBlock() always pass the real per-turn context.
                // Default to restrictive so harness/test callers without
                // explicit context can't escalate.
                return .restrictedFallback()
            },
            callbacksFactory: { [weak self] in
                let weakSelf = self
                return ToolExecutorCallbacks(
                    onApprovalPending: { awaiting, manualOnly in
                        guard let s = weakSelf else { return }
                        await s.setApprovalState(awaiting: awaiting, manualOnly: manualOnly)
                    },
                    onVisionAutoEnabled: {
                        guard let s = weakSelf else { return }
                        await s.autoEnableVision()
                    },
                    onComputerUseStep: {
                        guard let s = weakSelf else { return 0 }
                        return await s.incrementComputerUseStep()
                    }
                )
            },
            ticketManager: ScriptScopedTicketManager()
        )

        jscRuntime = runtime
        return runtime
    }

    /// Execute a ``ScriptBlock`` through the JSC runtime and return the result
    /// as a tool-result-style string for inclusion in conversation history.
    ///
    /// - Parameters:
    ///   - block: The parsed script block from the LLM response.
    ///   - proactiveContext: Optional proactive context for scheduler tasks.
    /// - Returns: A tuple of (result text, success flag).
    func executeScriptBlock(
        _ block: ScriptBlock,
        proactiveContext: ProactiveRequestContext? = nil
    ) async -> (output: String, success: Bool) {
        let runtime = ensureJSCRuntime()
        let budget = block.budget ?? .default

        // Enter script mode on the approval manager so first-tool-approval
        // auto-grants batch credits for the remaining budget.
        await approvalManager?.enterScriptMode(budgetToolCalls: budget.maxToolCalls)
        defer {
            // Inline Task so the actor-isolated exitScriptMode runs after await returns.
            let mgr = approvalManager
            Task { await mgr?.exitScriptMode() }
        }

        debugLog(debugConsole, .toolCall, "Script execution started (budget: \(budget.maxToolCalls) calls, \(Int(budget.maxWallClockSeconds))s)")
        eventBus.send(.toolCall(
            id: "script-\(UUID().uuidString.prefix(8))",
            name: "tool_program",
            inputJSON: "{\"source_length\":\(block.source.count)}"
        ))

        // Build real per-turn context from coordinator state.
        let livenessScore: Float? = await speakerEncoder?.lastLivenessResult?.score
        let effectiveTicket = activeCapabilityTicket
        let currentToolMode = effectiveToolMode()
        // For scripts, per-tool capability is checked by the bridge's
        // ScriptScopedTicketManager on each fae.tool() call. The broker's
        // hasCapabilityTicket check is a supplementary signal — set true here
        // so the broker doesn't hard-deny script tool calls. The ticket
        // manager provides the real access control.
        let hasCapabilityTicket = true
        let effectiveGenerationContext = currentTurnGenerationContext

        let scriptContext = ToolExecutorContext(
            toolMode: currentToolMode,
            privacyMode: effectivePrivacyMode(),
            modelLocality: modelLocality,
            capabilityTicket: effectiveTicket,
            hasCapabilityTicketForTool: hasCapabilityTicket,
            explicitUserAuthorization: explicitUserAuthorizationForTurn,
            isOwner: speakerGate.currentSpeakerIsOwner,
            livenessScore: livenessScore,
            actionSource: proactiveContext?.source ?? effectiveGenerationContext?.actionSource ?? .voice,
            proactiveContext: proactiveContext,
            visionEnabled: effectiveVisionEnabled(),
            firstOwnerEnrollmentActive: speakerGate.firstOwnerEnrollmentActive,
            workflowTurnID: currentTurnID,
            traceToolCallID: nil,
            workflowRunID: nil
        )

        let scriptCallbacks = ToolExecutorCallbacks(
            onApprovalPending: { [weak self] awaiting, manualOnly in
                guard let self else { return }
                await self.setApprovalState(awaiting: awaiting, manualOnly: manualOnly)
            },
            onVisionAutoEnabled: { [weak self] in
                guard let self else { return }
                await self.autoEnableVision()
            },
            onComputerUseStep: { [weak self] in
                guard let self else { return 0 }
                return await self.incrementComputerUseStep()
            }
        )

        // Dry-run: record intended tool calls without executing them.
        if block.dryRun {
            let plan = await runtime.runDryRun(script: block.source, budget: budget)
            let dryOutput = plan.summary()
            let drySuccess = plan.scriptResult.status == .success
            debugLog(debugConsole, .toolResult, "Dry-run finished: \(plan.intendedCalls.count) intended calls, success=\(drySuccess)")
            eventBus.send(.toolResult(
                id: "script-\(UUID().uuidString.prefix(8))",
                name: "tool_program_dry_run",
                success: drySuccess,
                output: String(dryOutput.prefix(200))
            ))
            return (dryOutput, drySuccess)
        }

        let result = await runtime.run(
            script: block.source,
            budget: budget,
            allowedTools: block.allowedTools,
            context: scriptContext,
            callbacks: scriptCallbacks
        )

        let output: String
        let success: Bool
        switch result.status {
        case .success:
            output = result.value ?? "(script completed with no output)"
            success = true
        case .failure:
            output = "Script error: \(result.error ?? "unknown error")"
            success = false
        case .cancelled:
            output = "Script was cancelled: \(result.error ?? "cancelled")"
            success = false
        case .budgetExceeded:
            output = "Script budget exceeded: \(result.error ?? "budget limit reached")"
            success = false
        }

        debugLog(debugConsole, .toolResult, "Script execution finished: success=\(success) output_length=\(output.count)")
        eventBus.send(.toolResult(
            id: "script-\(UUID().uuidString.prefix(8))",
            name: "tool_program",
            success: success,
            output: String(output.prefix(200))
        ))

        return (output, success)
    }

    /// Forward to ``ToolExecutor/isSafeSkillName(_:)`` for call sites outside executeTool.
    private static func isSafeSkillName(_ name: String) -> Bool {
        ToolExecutor.isSafeSkillName(name)
    }

    /// Forward to ``ToolExecutor/toolRequiresApproval(toolName:arguments:defaultRequiresApproval:)``.
    static func toolRequiresApproval(
        toolName: String,
        arguments: [String: Any],
        defaultRequiresApproval: Bool
    ) -> Bool {
        ToolExecutor.toolRequiresApproval(
            toolName: toolName,
            arguments: arguments,
            defaultRequiresApproval: defaultRequiresApproval
        )
    }

    /// Forward to ``ToolExecutor/isSelfConfigReadAction(arguments:)``.
    static func isSelfConfigReadAction(arguments: [String: Any]) -> Bool {
        ToolExecutor.isSelfConfigReadAction(arguments: arguments)
    }

    private static func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frameCount = Int(buffer.frameLength)
        guard let channelData = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
    }
}

// MARK: - ToolExecutorDelegate

extension PipelineCoordinator: ToolExecutorDelegate {

    /// Load the VLM engine if vision is enabled and return a provider closure.
    func toolExecutorVLMProvider() async -> VLMProvider? {
        guard let mm = modelManager else { return nil }
        var vlmConfigMut = config
        vlmConfigMut.vision.enabled = effectiveVisionEnabled()
        let vlmConfig = vlmConfigMut
        return { try await mm.loadVLMIfNeeded(config: vlmConfig) }
    }

    /// Speak text directly through the playback pipeline (used for non-manual approval prompts).
    func toolExecutorSpeakDirect(_ text: String) async {
        await speakDirect(text)
    }
}
