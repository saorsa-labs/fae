import AVFoundation
import AppKit
import CryptoKit
import Foundation

/// Central voice pipeline: AudioCapture → VAD → STT → LLM → TTS → Playback.
///
/// Wires all pipeline stages together with echo suppression, barge-in,
/// gate/sleep system, inline tool execution, and text injection.
///
/// Replaces: `src/pipeline/coordinator.rs` (5,192 lines)
actor PipelineCoordinator {

    // MARK: - Pipeline Mode

    enum PipelineMode: String, Sendable {
        case conversation     // Full pipeline
        case transcribeOnly   // Capture → VAD → STT → print
        case textOnly         // Text injection → LLM → TTS → playback
        case llmOnly          // Capture → VAD → STT → LLM (no TTS)
    }

    // MARK: - Degraded Mode

    enum PipelineDegradedMode: String, Sendable {
        case full
        case noSTT
        case noLLM
        case noTTS
        case unavailable
    }

    // MARK: - Gate State

    enum GateState: Sendable {
        case idle     // Discard all transcriptions
        case active   // Forward to LLM
    }

    // MARK: - Dependencies

    private let eventBus: FaeEventBus
    private let capture: AudioCaptureManager
    private let playback: AudioPlaybackManager
    private let sttEngine: MLXSTTEngine
    private let llmEngine: MLXLLMEngine
    private let ttsEngine: MLXTTSEngine
    private let config: FaeConfig
    private let conversationState: ConversationStateTracker
    private let memoryOrchestrator: MemoryOrchestrator?
    private let approvalManager: ApprovalManager?
    private let registry: ToolRegistry
    private let actionBroker: any TrustedActionBroker
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

    /// Counter for computer-use action steps per conversation turn (click/type/scroll).
    private var computerUseStepCount: Int = 0
    private static let maxComputerUseSteps = 10


    // MARK: - Debug Console

    /// Optional debug console for real-time pipeline visibility.
    /// Set after init via `setDebugConsole(_:)`.
    private var debugConsole: DebugConsoleController?

    /// Wire up the debug console after initialization.
    func setDebugConsole(_ console: DebugConsoleController?) {
        debugConsole = console
    }

    // MARK: - Live Config Overrides

    /// Live override for thinking mode — set by FaeCore when the user toggles the button.
    /// `nil` means fall back to `config.llm.thinkingEnabled`.
    private var thinkingEnabledLive: Bool?

    /// Update the thinking-mode flag without restarting the pipeline.
    func setThinkingEnabled(_ enabled: Bool) {
        thinkingEnabledLive = enabled
    }

    /// Live override for barge-in — set by FaeCore when the user toggles the setting.
    /// `nil` means fall back to `config.bargeIn.enabled`.
    private var bargeInEnabledLive: Bool?

    /// Update the barge-in flag without restarting the pipeline.
    func setBargeInEnabled(_ enabled: Bool) {
        bargeInEnabledLive = enabled
    }

    /// Live override for tool mode — set by FaeCore when the user changes tool settings.
    /// `nil` means fall back to `config.toolMode`.
    private var toolModeLive: String?

    /// Update the tool mode without restarting the pipeline.
    func setToolMode(_ mode: String) {
        if isRescueMode {
            toolModeLive = "read_only"
            return
        }
        toolModeLive = mode
        // Dismiss any pending tool-mode upgrade popup.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .faeToolModeUpgradeDismiss, object: nil)
        }
    }

    /// Live override for direct-address policy.
    private var requireDirectAddressLive: Bool?

    /// Live override for vision toggle.
    private var visionEnabledLive: Bool?

    /// Live override for voice identity lock status.
    private var voiceIdentityLockLive: Bool?

    func setRequireDirectAddress(_ enabled: Bool) {
        requireDirectAddressLive = enabled
    }

    func setVisionEnabled(_ enabled: Bool) {
        visionEnabledLive = enabled
    }

    func setVoiceIdentityLock(_ enabled: Bool) {
        voiceIdentityLockLive = enabled
    }

    /// Update playback speed live without restarting.
    func setPlaybackSpeed(_ speed: Float) async {
        await playback.setSpeed(speed)
    }

    // MARK: - Pipeline State

    private var mode: PipelineMode = .conversation
    private var degradedMode: PipelineDegradedMode?
    private var gateState: GateState = .active
    private var vad = VoiceActivityDetector()
    private var echoSuppressor = EchoSuppressor()
    private var thinkTagStripper = TextProcessing.ThinkTagStripper()
    private var voiceTagStripper = VoiceTagStripper()

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
    private var awaitingApproval: Bool = false
    private var pendingGovernanceAction: PendingGovernanceAction?

    // MARK: - Speaker Identity State

    private var currentSpeakerLabel: String?
    private var currentSpeakerDisplayName: String?
    private var currentSpeakerRole: SpeakerRole?
    private var currentSpeakerIsOwner: Bool = false
    private var wakeAliases: [String] = TextProcessing.nameVariants
    /// True when speaker verification ran and matched a non-owner profile.
    /// Distinguished from "not matched at all" (unknown/degraded) — only this
    /// flag should hard-block tools when `requireOwnerForTools` is enabled.
    private var currentSpeakerIsKnownNonOwner: Bool = false
    private var previousSpeakerLabel: String?
    private var utterancesSinceOwnerVerified: Int = 0
    /// Wall-clock time when the current utterance was captured by the VAD.
    private var currentUtteranceTimestamp: Date?

    // MARK: - Enrollment State

    /// True while first-owner enrollment is actively running.
    /// Set by FaeCore when enrollment starts, cleared on enrollment_complete.
    /// Bypasses direct-address gating and allows barge-in from anyone (no owner yet).
    private var firstOwnerEnrollmentActive: Bool = false

    /// One-shot system prompt addition for the LLM's first response after owner enrollment.
    /// Set by FaeCore during the voice enrollment flow; cleared after first use.
    private var firstOwnerEnrollmentContext: String?

    // MARK: - Timing & Echo Detection

    private var lastAssistantStart: Date?
    private var engagedUntil: Date?
    /// Throttle for “currently sleeping” hints so we do not spam spoken nudges.
    private var lastSleepHintAt: Date?
    /// Last assistant response text — used to detect echo (mic picking up speaker output).
    private var lastAssistantResponseText: String = ""

    // MARK: - Barge-In

    private var pendingBargeIn: PendingBargeIn?

    /// When true, barge-in is suppressed. Set during short non-interruptible
    /// utterances (speakDirect) to prevent background noise from interrupting
    /// command acknowledgments and approval responses.
    private var bargeInSuppressed: Bool = false

    // MARK: - Phase 1 Observability

    private var pipelineStartedAt: Date?
    private var firstAudioLatencyEmitted: Bool = false
    private let instrumentation = PipelineInstrumentation()

    struct PendingBargeIn {
        var capturedAt: Date
        var speechSamples: Int = 0
        var lastRms: Float = 0
        var audioSamples: [Float] = []
    }

    /// Cooldown after non-owner barge-in denial — prevents repeated embedding churn from TV/noise.
    private var bargeInDenyCooldownUntil: Date?
    private static let bargeInDenyCooldownSeconds: TimeInterval = 5.0

    // MARK: - Pipeline Tasks

    private var pipelineTask: Task<Void, Never>?
    private var captureStream: AsyncStream<AudioChunk>?

    /// Speech-segment processing runs on a dedicated bounded queue so capture/VAD
    /// stay responsive even while STT/LLM/TTS are busy.
    private var speechSegmentTask: Task<Void, Never>?
    private var speechSegmentContinuation: AsyncStream<SpeechSegment>.Continuation?
    private static let speechSegmentQueueDepth = 6
    private var speechSegmentsDroppedForBackpressure: Int = 0

    /// Chained TTS task — each sentence enqueues onto this so TTS runs in order
    /// without blocking the LLM token stream.
    private var pendingTTSTask: Task<Void, Never>?

    /// Timestamp captured when the user turn ended (post-VAD segment close).
    /// Used for TTFA (time-to-first-audio) telemetry.
    private var lastUserTurnEndedAt: Date?
    private var ttfaEmittedForCurrentTurn: Bool = false
    private var currentTurnID: String?

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
        let nativeTools: [[String: any Sendable]]?
    }

    /// In-flight deferred tool tasks keyed by job ID.
    private var deferredToolTasks: [UUID: Task<Void, Never>] = [:]

    /// Whether any deferred tool jobs are currently running (test harness use).
    var hasPendingDeferredTools: Bool { !deferredToolTasks.isEmpty }

    // MARK: - Capability Tickets

    /// Task-scoped capability grant consumed by the broker.
    private var activeCapabilityTicket: CapabilityTicket?

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
        llmEngine: MLXLLMEngine,
        ttsEngine: MLXTTSEngine,
        config: FaeConfig,
        conversationState: ConversationStateTracker,
        memoryOrchestrator: MemoryOrchestrator? = nil,
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
        self.llmEngine = llmEngine
        self.ttsEngine = ttsEngine
        self.config = config
        self.conversationState = conversationState
        self.memoryOrchestrator = memoryOrchestrator
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

        // Configure VAD from config.
        vad.applyConfiguration(config.vad)
    }

    // MARK: - Lifecycle

    /// Start the voice pipeline.
    func start() async throws {
        guard pipelineTask == nil else { return }

        debugLog(debugConsole, .qa, "Pipeline start requested")
        eventBus.send(.pipelineStateChanged(.starting))

        // Set up playback event handler and voice speed.
        try await playback.setup()
        await playback.setSpeed(config.tts.speed)
        await setPlaybackEventHandler()

        if let wakeStore = wakeWordProfileStore {
            wakeAliases = await wakeStore.allAliases()
            debugLog(debugConsole, .command, "Wake aliases loaded: \(wakeAliases.joined(separator: ", "))")
        }

        startSpeechSegmentProcessingLoop()

        // Start audio capture.
        let stream = try await capture.startCapture()
        captureStream = stream

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
        interrupted = true
        pendingGovernanceAction = nil
        awaitingApproval = false
        computerUseStepCount = 0

        // Ensure any in-flight TTS synthesis task fully exits before teardown.
        let activeTTSTask = pendingTTSTask
        pendingTTSTask = nil
        activeTTSTask?.cancel()
        await activeTTSTask?.value

        pipelineTask?.cancel()
        pipelineTask = nil
        cancelDeferredToolJobs()
        await stopSpeechSegmentProcessingLoop()
        await capture.stopCapture()
        await playback.stop()
        eventBus.send(.pipelineStateChanged(.stopped))
        NSLog("PipelineCoordinator: pipeline stopped")
    }

    /// Cancel the current generation immediately.
    ///
    /// Sets `interrupted = true` and stops audio playback. The pipeline
    /// loop checks `interrupted` at each step and exits cleanly.
    func cancel() {
        interrupted = true
        pendingGovernanceAction = nil
        computerUseStepCount = 0

        let activeTTSTask = pendingTTSTask
        pendingTTSTask = nil
        activeTTSTask?.cancel()
        if let activeTTSTask {
            Task { await activeTTSTask.value }
        }

        Task { await playback.stop() }
        NSLog("PipelineCoordinator: cancelled by user")
    }

    /// Cancel and await full stop — including playback + deferred tools (test harness use).
    func cancelAndWait() async {
        interrupted = true
        pendingGovernanceAction = nil
        computerUseStepCount = 0

        let activeTTSTask = pendingTTSTask
        pendingTTSTask = nil
        activeTTSTask?.cancel()
        await activeTTSTask?.value

        cancelDeferredToolJobs()
        await playback.stop()
        assistantSpeaking = false
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

        if isConversationStopTrigger(trimmed) {
            await resetConversationSession(trigger: trimmed, source: "text")
            return
        }

        // Text input is trusted (physically typed by the user at the device).
        currentSpeakerLabel = "owner"
        currentSpeakerDisplayName = await speakerProfileStore?.ownerDisplayName() ?? "Owner"
        currentSpeakerRole = .owner
        currentSpeakerIsOwner = true
        currentSpeakerIsKnownNonOwner = false

        if gateState == .idle {
            guard isAddressedToFae(trimmed) else {
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
            interrupted = true
            await playback.stop()
        }

        await processTranscription(
            text: trimmed,
            wakeMatch: wakeAddressMatch(in: trimmed),
            rms: nil,
            durationSecs: nil
        )
    }

    /// Speak text directly via TTS without going through the LLM.
    ///
    /// Used for system messages like the first-launch greeting, command
    /// acknowledgments, and approval responses. Non-interruptible — barge-in
    /// is suppressed for the duration to prevent background noise from cutting
    /// off short utterances.
    func speakDirect(_ text: String) async {
        bargeInSuppressed = true
        defer { bargeInSuppressed = false }
        await speakText(text, isFinal: true)
    }

    /// Speak text with a specific voice description, bypassing the LLM.
    ///
    /// Used for voice preview in roleplay and settings. Non-interruptible.
    func speakWithVoice(_ text: String, voiceInstruct: String) async {
        bargeInSuppressed = true
        defer { bargeInSuppressed = false }
        await speakText(text, isFinal: true, voiceInstruct: voiceInstruct)
    }

    /// Set/clear the first-owner enrollment active flag.
    func setFirstOwnerEnrollmentActive(_ active: Bool) {
        firstOwnerEnrollmentActive = active
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
        // Never interrupt an active conversation or generation.
        guard !assistantGenerating, !assistantSpeaking else {
            NSLog("PipelineCoordinator: proactive query skipped — assistant busy")
            return
        }

        let proactiveTag = "\(taskId)-\(Int(Date().timeIntervalSince1970 * 1000))"
        let proactiveContext = ProactiveRequestContext(
            source: .scheduler,
            taskId: taskId,
            allowedTools: allowedTools,
            consentGranted: consentGranted,
            conversationTag: proactiveTag
        )

        // Scheduler acts on behalf of the consented owner.
        currentSpeakerLabel = "owner"
        currentSpeakerDisplayName = "Owner"
        currentSpeakerRole = .owner
        currentSpeakerIsOwner = true
        currentSpeakerIsKnownNonOwner = false

        // Build the prompt, optionally appending silence instruction.
        var fullPrompt = prompt
        if silent {
            fullPrompt += "\n\n[Respond only if you have something meaningful to say. Otherwise stay silent.]"
        }

        debugLog(debugConsole, .pipeline, "Proactive query: taskId=\(taskId) silent=\(silent)")

        await processTranscription(
            text: fullPrompt,
            wakeMatch: nil,
            rms: nil,
            durationSecs: nil,
            proactiveContext: proactiveContext
        )

        await conversationState.removeMessages(taggedWith: proactiveTag)
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
        firstOwnerEnrollmentContext = context
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
        await conversationState.clear()
        currentTurnGenerationContext = nil
        NSLog("PipelineCoordinator: conversation history cleared (test reset)")
    }

    // MARK: - Gate Control

    func wake() {
        gateState = .active
        engagedUntil = Date().addingTimeInterval(
            Double(config.conversation.directAddressFollowupS)
        )
        NSLog("PipelineCoordinator: gate → active")
    }

    func sleep() {
        gateState = .idle
        if assistantSpeaking || assistantGenerating {
            interrupted = true
            Task { await playback.stop() }
        }
        NSLog("PipelineCoordinator: gate → idle")
    }

    func engage() {
        engagedUntil = Date().addingTimeInterval(
            Double(config.conversation.directAddressFollowupS)
        )
    }

    private func effectiveToolMode() -> String {
        if isRescueMode {
            return "read_only"
        }
        return toolModeLive ?? config.toolMode
    }

    private func effectiveRequireDirectAddress() -> Bool {
        requireDirectAddressLive ?? config.conversation.requireDirectAddress
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

    private func isConversationStopTrigger(_ text: String) -> Bool {
        let normalizedText = Self.normalizeForPhraseMatch(text)
        var phrases = config.conversation.sleepPhrases
        // Common apostrophe-less variant missed by strict literal matching.
        phrases.append("thatll do fae")

        for phrase in phrases {
            let normalizedPhrase = Self.normalizeForPhraseMatch(phrase)
            if !normalizedPhrase.isEmpty, normalizedText.contains(normalizedPhrase) {
                return true
            }
        }
        return false
    }

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

    private func learnWakeAliasIfNeeded(rawText: String) async {
        guard currentSpeakerIsOwner,
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

    private func resetConversationSession(trigger: String, source: String) async {
        sleep()
        currentTurnGenerationContext = nil
        engagedUntil = nil
        lastAssistantResponseText = ""
        activeCapabilityTicket = nil
        awaitingApproval = false
        pendingGovernanceAction = nil
        computerUseStepCount = 0
        pendingTTSTask?.cancel()
        pendingTTSTask = nil
        cancelDeferredToolJobs()
        await conversationState.clear()
        NSLog("PipelineCoordinator: conversation reset via %@ trigger: %@", source, trigger)
        debugLog(debugConsole, .pipeline, "Conversation reset (\(source)): \(trigger)")
    }

    // MARK: - Speech Segment Queue

    private func startSpeechSegmentProcessingLoop() {
        guard speechSegmentTask == nil else { return }

        NSLog("PipelineCoordinator: speech segment queue started (depth=%d)", Self.speechSegmentQueueDepth)

        let stream = AsyncStream<SpeechSegment>(bufferingPolicy: .bufferingNewest(Self.speechSegmentQueueDepth)) {
            continuation in
            self.speechSegmentContinuation = continuation
        }

        speechSegmentTask = Task { [weak self] in
            guard let self else { return }
            for await segment in stream {
                guard !Task.isCancelled else { break }
                await self.handleSpeechSegment(segment)
            }
        }
    }

    private func stopSpeechSegmentProcessingLoop() async {
        speechSegmentContinuation?.finish()
        speechSegmentContinuation = nil
        speechSegmentTask?.cancel()
        await speechSegmentTask?.value
        speechSegmentTask = nil
        NSLog("PipelineCoordinator: speech segment queue stopped")
    }

    private func enqueueSpeechSegment(_ segment: SpeechSegment) {
        guard let continuation = speechSegmentContinuation else {
            // Queue not initialized — process synchronously as a safe fallback.
            Task { await self.handleSpeechSegment(segment) }
            return
        }

        let result = continuation.yield(segment)
        switch result {
        case .enqueued:
            debugLog(debugConsole, .pipeline, "Speech segment enqueued dur=\(String(format: "%.2f", segment.durationSeconds))s")
        case .dropped:
            speechSegmentsDroppedForBackpressure += 1
            NSLog("PipelineCoordinator: dropped speech segment due to backpressure (count=%d)", speechSegmentsDroppedForBackpressure)
            NSLog("phase1.audio_backpressure_drop_count=%d", speechSegmentsDroppedForBackpressure)
            debugLog(debugConsole, .pipeline, "⚠️ Speech segment dropped (backpressure) count=\(speechSegmentsDroppedForBackpressure)")
        case .terminated:
            NSLog("PipelineCoordinator: speech segment queue terminated — processing synchronously")
            Task { await self.handleSpeechSegment(segment) }
        @unknown default:
            Task { await self.handleSpeechSegment(segment) }
        }
    }

    // MARK: - Main Pipeline Loop

    private func runPipelineLoop(stream: AsyncStream<AudioChunk>) async {
        for await chunk in stream {
            guard !Task.isCancelled else { break }

            // VAD stage.
            let vadOutput = vad.processChunk(chunk)

            // Emit audio level for orb animation.
            eventBus.send(.audioLevel(vadOutput.rms))

            if !firstAudioLatencyEmitted,
               let startedAt = pipelineStartedAt,
               (vadOutput.isSpeech || vadOutput.speechStarted || vadOutput.segment != nil)
            {
                let latencyMs = Date().timeIntervalSince(startedAt) * 1000
                firstAudioLatencyEmitted = true
                NSLog("phase1.first_audio_latency_ms=%.2f", latencyMs)
            }

            // Track barge-in only while the assistant is audibly speaking.
            // This avoids false interruptions during long LLM decode gaps where
            // assistantGenerating may be true but no speech is playing.
            if Self.shouldTrackBargeIn(assistantSpeaking: assistantSpeaking) {
                // Check deny cooldown — skip creating new barge-in candidates during cooldown.
                let inDenyCooldown = bargeInDenyCooldownUntil.map { Date() < $0 } ?? false

                // Skip when echo suppressor is active or barge-in is suppressed
                // (non-interruptible speakDirect) to prevent false triggers.
                pendingBargeIn = Self.advancePendingBargeIn(
                    pending: pendingBargeIn,
                    speechStarted: vadOutput.speechStarted,
                    isSpeech: vadOutput.isSpeech,
                    chunkSamples: chunk.samples,
                    rms: vadOutput.rms,
                    echoSuppression: echoSuppressor.isInSuppression,
                    bargeInSuppressed: bargeInSuppressed,
                    inDenyCooldown: inDenyCooldown
                )
                if vadOutput.isSpeech {
                    // Check barge-in confirmation.
                    let bargeInEnabled = bargeInEnabledLive ?? config.bargeIn.enabled
                    let confirmSamples = (config.bargeIn.confirmMs * config.audio.inputSampleRate) / 1000
                    if let barge = pendingBargeIn,
                       barge.speechSamples >= confirmSamples,
                       bargeInEnabled
                    {
                        pendingBargeIn = nil
                        await handleBargeInWithVerification(barge: barge)
                    }
                }
            } else {
                pendingBargeIn = nil
            }

            // Adjust VAD silence threshold based on assistant state.
            if assistantSpeaking {
                vad.setSilenceThresholdMs(config.bargeIn.bargeInSilenceMs)

                // Watchdog: if assistantSpeaking has been true for an unreasonably
                // long time (>60s), the TTS pipeline is stuck. Force-clear so the
                // mic isn't permanently dead. No single TTS utterance should take
                // more than 60 seconds.
                if let start = lastAssistantStart,
                   Date().timeIntervalSince(start) > 60
                {
                    NSLog("PipelineCoordinator: assistantSpeaking watchdog — stuck for >60s, force-clearing")
                    debugLog(debugConsole, .pipeline, "⚠️ assistantSpeaking watchdog fired (>60s) — force-clearing")
                    pendingTTSTask?.cancel()
                    pendingTTSTask = nil
                    markAssistantSpeechEnded(reason: "watchdog_timeout")
                    await playback.stop()
                }
            } else {
                vad.setSilenceThresholdMs(config.vad.minSilenceDurationMs)
            }

            // Process completed speech segment via bounded queue.
            if let segment = vadOutput.segment {
                // Avoid stale-segment backlog during assistant generation/speech.
                // Barge-in is already handled in-chunk before segment completion.
                if assistantGenerating || assistantSpeaking {
                    debugLog(debugConsole, .pipeline, "Discarded segment while assistant busy dur=\(String(format: "%.2f", segment.durationSeconds))s")
                    continue
                }
                lastUserTurnEndedAt = Date()
                enqueueSpeechSegment(segment)
            }
        }
    }

    // MARK: - Speech Segment Processing

    private func handleSpeechSegment(_ segment: SpeechSegment) async {
        let rms = VoiceActivityDetector.computeRMS(segment.samples)
        let durationSecs = Float(segment.samples.count) / Float(segment.sampleRate)

        // Capture wall-clock time from VAD onset for memory timestamps.
        currentUtteranceTimestamp = segment.capturedAt

        // Echo suppression check — pass segment onset time so the echo tail is
        // checked against when the speech STARTED, not when it finished processing.
        guard echoSuppressor.shouldAccept(
            durationSecs: durationSecs,
            rms: rms,
            awaitingApproval: awaitingApproval,
            segmentOnset: segment.capturedAt
        ) else {
            NSLog("PipelineCoordinator: dropping %.1fs speech segment (echo suppression, onset=%.1fs ago)",
                  durationSecs, Date().timeIntervalSince(segment.capturedAt))
            debugLog(debugConsole, .pipeline, "Echo suppressed: \(String(format: "%.1f", durationSecs))s segment (rms=\(String(format: "%.3f", rms)), onset=\(String(format: "%.1f", Date().timeIntervalSince(segment.capturedAt)))s ago)")
            return
        }

        // LLM quality gate — drop ambient noise.
        if rms < 0.008 && durationSecs > 3.0 {
            NSLog("PipelineCoordinator: dropping ambient segment (rms=%.4f, dur=%.1fs)", rms, durationSecs)
            return
        }

        // Speaker identification (best-effort, non-blocking).
        currentSpeakerLabel = nil
        currentSpeakerDisplayName = nil
        currentSpeakerRole = nil
        currentSpeakerIsOwner = false
        currentSpeakerIsKnownNonOwner = false
        // Speaker recognition is always on — no config gate.
        if let encoder = speakerEncoder, await encoder.isLoaded,
           let store = speakerProfileStore
        {
            do {
                let embedding = try await encoder.embed(
                    audio: segment.samples,
                    sampleRate: segment.sampleRate
                )

                let hasOwner = await store.hasOwnerProfile()

                // Two-pass matching: human profiles first, then fae_self echo check.
                // fae_self is excluded from general matching because voice cloning
                // makes its embeddings nearly identical to the owner's voice — it
                // would always win the match and prevent the owner from being recognized.

                // Pass 1: match against human profiles (exclude fae_self).
                if hasOwner, let match = await store.match(
                    embedding: embedding,
                    threshold: config.speaker.threshold,
                    excludingRoles: [.faeSelf]
                ) {
                    currentSpeakerLabel = match.label
                    currentSpeakerDisplayName = match.displayName
                    currentSpeakerRole = match.role
                    currentSpeakerIsOwner = match.role == .owner
                    currentSpeakerIsKnownNonOwner = match.role != .owner

                    // Progressive enrollment: strengthen known profiles.
                    if config.speaker.progressiveEnrollment {
                        await store.enrollIfBelowMax(
                            label: match.label,
                            embedding: embedding,
                            max: config.speaker.maxEnrollments
                        )
                    }

                    NSLog("PipelineCoordinator: speaker matched: %@ (%@), similarity: %.3f",
                          match.displayName, match.label, match.similarity)
                    debugLog(debugConsole, .speaker, "Matched: \(match.displayName) (\(match.label)) sim=\(String(format: "%.3f", match.similarity)) owner=\(currentSpeakerIsOwner)")
                } else if !hasOwner {
                    NSLog("PipelineCoordinator: no owner voice enrolled yet — awaiting voice_identity enrollment")
                    debugLog(debugConsole, .speaker, "Owner not enrolled yet; speaker left as unknown")
                } else {
                    // Pass 2: no human match — check fae_self for echo detection.
                    // Only reject if echo suppressor is still active (duration-proportional).
                    if let faeSelfSim = await store.matchesFaeSelf(embedding: embedding, threshold: config.speaker.threshold) {
                        if echoSuppressor.isInSuppression {
                            NSLog("PipelineCoordinator: dropping %.1fs segment (fae_self sim=%.3f, echo suppressor active)", durationSecs, faeSelfSim)
                            debugLog(debugConsole, .pipeline, "Echo rejected (voice match fae_self sim=\(String(format: "%.3f", faeSelfSim)), suppressor active)")
                            return
                        }
                        // Echo suppressor expired — real person with voice similar to TTS.
                        NSLog("PipelineCoordinator: fae_self match sim=%.3f ignored (echo suppressor expired)", faeSelfSim)
                        debugLog(debugConsole, .speaker, "fae_self sim=\(String(format: "%.3f", faeSelfSim)) outside echo window — passing as unknown")
                    } else {
                        NSLog("PipelineCoordinator: speaker not recognized")
                        debugLog(debugConsole, .speaker, "Not recognized (no match above threshold \(String(format: "%.2f", config.speaker.threshold)))")
                    }
                }
            } catch {
                NSLog("PipelineCoordinator: speaker embed failed: %@", error.localizedDescription)
                debugLog(debugConsole, .speaker, "Embed failed: \(error.localizedDescription)")
            }
        } else {
            debugLog(debugConsole, .speaker, "Speaker encoder not loaded — owner verification skipped")
        }

        // Liveness enforcement: reject speech with low liveness score in enforce mode.
        if config.voiceIdentity.enabled,
           config.voiceIdentity.mode == "enforce",
           config.speaker.livenessThreshold > 0,
           let encoder = speakerEncoder,
           let liveness = await encoder.lastLivenessResult,
           liveness.score < config.speaker.livenessThreshold
        {
            NSLog("PipelineCoordinator: rejecting speech — liveness score %.3f below threshold %.2f",
                  liveness.score, config.speaker.livenessThreshold)
            await speakDirect("I'm not sure that's a live voice. Could you speak directly to me?")
            return
        }

        // Speaker change detection.
        if let prevLabel = previousSpeakerLabel,
           let currLabel = currentSpeakerLabel,
           prevLabel != currLabel
        {
            NSLog("PipelineCoordinator: speaker change detected: %@ → %@", prevLabel, currLabel)
        }
        previousSpeakerLabel = currentSpeakerLabel
        utterancesSinceOwnerVerified = currentSpeakerIsOwner ? 0 : utterancesSinceOwnerVerified + 1

        // Owner-only listening: when requireOwnerForTools is active, known
        // non-owner profiles are silently dropped before STT. Unknown speakers
        // (no match above threshold) still pass — physical device access implies trust.
        if config.speaker.requireOwnerForTools, currentSpeakerIsKnownNonOwner {
            NSLog("PipelineCoordinator: dropping %.1fs segment from known non-owner '%@'",
                  durationSecs, currentSpeakerLabel ?? "?")
            debugLog(debugConsole, .speaker,
                     "Dropped: known non-owner \(currentSpeakerLabel ?? "?") — owner-only mode")
            return
        }

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

            // Correct common ASR misrecognitions of "Fae".
            let text = TextProcessing.correctNameRecognition(rawText)

            NSLog("PipelineCoordinator: STT → \"%@\"", text)
            debugLog(debugConsole, .stt, text)

            // Approval gate — while a tool approval is pending, only approval responses
            // are accepted. This prevents unrelated chatter/noise from being routed to the LLM.
            if awaitingApproval {
                if let decision = VoiceCommandParser.parseApprovalResponse(text),
                   let manager = approvalManager,
                   await manager.resolveMostRecent(decision: decision, source: "voice")
                {
                    debugLog(debugConsole, .approval, "Tool approval decision via voice: \(decision.rawValue)")
                    awaitingApproval = false
                    let ack: String
                    switch decision {
                    case .yes:
                        ack = PersonalityManager.nextApprovalGranted()
                    case .no:
                        ack = PersonalityManager.nextApprovalDenied()
                    case .always:
                        ack = "Got it, I'll always allow that tool."
                    case .approveAllReadOnly:
                        ack = "Okay, all read-only tools are now approved."
                    case .approveAll:
                        ack = "Understood, all tools are now approved."
                    }
                    await speakDirect(ack)
                } else {
                    let words = text.split(whereSeparator: { $0.isWhitespace }).count
                    if words > 2 {
                        debugLog(debugConsole, .approval, "Ambiguous tool approval response: \(text)")
                        await speakDirect(PersonalityManager.nextApprovalAmbiguous())
                    }
                }
                return
            }

            if let pendingAction = pendingGovernanceAction {
                if let decision = VoiceCommandParser.parseApprovalResponse(text) {
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
                    let words = text.split(whereSeparator: { $0.isWhitespace }).count
                    if words > 2 {
                        debugLog(debugConsole, .approval, "Ambiguous governance confirmation response: \(text)")
                        await speakDirect(pendingAction.confirmationPrompt)
                    }
                }
                return
            }

            // Echo detection — if the transcribed text is a fragment of the last
            // assistant response, the mic picked up speaker output. Drop it.
            if !lastAssistantResponseText.isEmpty {
                let sttLower = text.lowercased()
                let assistLower = lastAssistantResponseText.lowercased()
                if assistLower.contains(sttLower) || sttLower.contains(assistLower) {
                    NSLog("PipelineCoordinator: dropping echo (STT matched last assistant response)")
                    debugLog(debugConsole, .pipeline, "Echo dropped (text match): \"\(text.prefix(60))\"")
                    return
                }
                // Check for significant overlap via shared words.
                let sttWords = Set(sttLower.split(separator: " ").filter { $0.count > 2 })
                let assistWords = Set(assistLower.split(separator: " ").filter { $0.count > 2 })
                if sttWords.count >= 3, !assistWords.isEmpty {
                    let overlap = sttWords.intersection(assistWords)
                    if Double(overlap.count) / Double(sttWords.count) >= 0.6 {
                        NSLog("PipelineCoordinator: dropping echo (%.0f%% word overlap with last response)",
                              Double(overlap.count) / Double(sttWords.count) * 100)
                        debugLog(debugConsole, .pipeline, "Echo dropped (\(Int(Double(overlap.count) / Double(sttWords.count) * 100))%% overlap): \"\(text.prefix(60))\"")
                        return
                    }
                }
            }

            // Post-speech ghost filter — short single-word transcriptions within
            // 8 seconds of assistant speech are almost always mic bleed or ambient noise
            // ("Oh.", "Come.", "Okay.") that shouldn't trigger a new LLM turn.
            // Exception: during the follow-up window (Fae just asked a question), accept
            // short responses like "David", "yes", "no" — these are conversational answers.
            let ghostWords = text.split(whereSeparator: { $0.isWhitespace }).count
            let ghostInFollowup = engagedUntil.map { Date() < $0 } ?? false
            if ghostWords <= 2,
               let lastStart = lastAssistantStart,
               Date().timeIntervalSince(lastStart) < 8.0,
               !text.lowercased().contains("fae"),
               !ghostInFollowup
            {
                NSLog("PipelineCoordinator: dropping post-speech ghost \"%@\" (%d words, %.1fs after speech start)",
                      text, ghostWords, Date().timeIntervalSince(lastStart))
                debugLog(debugConsole, .pipeline, "Ghost filtered: \"\(text)\" (\(ghostWords) words, recent speech)")
                return
            }

            eventBus.send(.transcription(text: text, isFinal: true))

            if isConversationStopTrigger(text) {
                await resetConversationSession(trigger: text, source: "voice")
                return
            }

            let voiceCommand = VoiceCommandParser.parse(text)
            debugLog(debugConsole, .command, "Parsed voice command: \(String(describing: voiceCommand))")
            let voiceCommandStarted = Date()
            let handledVoiceCommand = await handleVoiceCommandIfNeeded(voiceCommand, originalText: text)
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

            if let wakeStore = wakeWordProfileStore {
                wakeAliases = await wakeStore.allAliases()
            }
            let wakeMatch = wakeAddressMatch(in: text, logDecision: true)
            let addressedToFae = wakeMatch != nil
            if addressedToFae {
                await learnWakeAliasIfNeeded(rawText: rawText)
            }

            if gateState != .active {
                guard addressedToFae else {
                    debugLog(debugConsole, .command, "Ignored while sleeping (not addressed): \(text)")
                    let words = text.split(whereSeparator: { $0.isWhitespace }).count
                    if words >= 4,
                       (lastSleepHintAt == nil || Date().timeIntervalSince(lastSleepHintAt!) > 20)
                    {
                        lastSleepHintAt = Date()
                        await speakDirect("I’m resting right now—say hey Fae to wake me.")
                    }
                    return
                }
                wake()
            }

            // Conversation gate — direct address check.
            let inFollowup = engagedUntil.map { Date() < $0 } ?? false
            if effectiveRequireDirectAddress() {
                if !addressedToFae && !inFollowup && !awaitingApproval && !firstOwnerEnrollmentActive {
                    debugLog(debugConsole, .command, "Dropped (direct-address required): \(text)")
                    return // Drop — not addressed to Fae.
                }
            }

            // Noise gate for idle periods: ignore very short, out-of-context utterances
            // after silence (clicks, accidental mic hits, tiny fragments).
            let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
            if !awaitingApproval && !inFollowup && !addressedToFae && wordCount <= 2 {
                debugLog(debugConsole, .pipeline, "Dropped short idle utterance: \"\(text)\"")
                return
            }

            // Process through LLM.
            await processTranscription(
                text: text,
                wakeMatch: wakeMatch,
                rms: rms,
                durationSecs: durationSecs
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
        proactiveContext: ProactiveRequestContext? = nil
    ) async {
        currentTurnID = UUID().uuidString
        ttfaEmittedForCurrentTurn = false
        if proactiveContext != nil {
            lastUserTurnEndedAt = nil
        } else if lastUserTurnEndedAt == nil {
            // Text injection path has no VAD segment-close marker.
            lastUserTurnEndedAt = Date()
        }

        debugLog(debugConsole, .qa, "Process transcription [turn=\(currentTurnID?.prefix(8) ?? "none")]: \(text)")

        // Extract query if name-addressed.
        var queryText = text
        if let match = wakeMatch ?? wakeAddressMatch(in: text) {
            queryText = TextProcessing.extractQueryAroundName(in: text, nameRange: match.range)
            debugLog(debugConsole, .command, "Direct-address extraction: \(queryText)")
            // Refresh follow-up window.
            engagedUntil = Date().addingTimeInterval(
                Double(config.conversation.directAddressFollowupS)
            )
        }

        // If assistant is still active, handle based on barge-in setting.
        if assistantSpeaking || assistantGenerating {
            let bargeInEnabled = bargeInEnabledLive ?? config.bargeIn.enabled
            if bargeInEnabled {
                // Barge-in: interrupt speech and process the new transcription.
                interrupted = true
                pendingTTSTask?.cancel()
                pendingTTSTask = nil
                await playback.stop()
            } else {
                // Barge-in disabled: drop the transcription entirely — do NOT
                // interrupt active speech. Stray noise / echo that slipped through
                // the echo suppressor should never cut off the assistant mid-sentence.
                NSLog("PipelineCoordinator: dropping transcription while assistant active (barge-in disabled): \"%@\"", text)
                debugLog(debugConsole, .pipeline, "Dropped transcription (barge-in off, assistant active): \"\(text.prefix(60))\"")
                return
            }
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

        // Unified pipeline: LLM decides when to use tools via <tool_call> markup.
        await generateWithTools(
            userText: queryText,
            isToolFollowUp: false,
            turnCount: 0,
            forceSuppressThinking: forceFastCommandPath,
            proactiveContext: proactiveContext
        )
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

            if normalized == "full_no_approval" {
                pendingGovernanceAction = PendingGovernanceAction(
                    action: "set_tool_mode",
                    value: .string(normalized),
                    metadata: [:],
                    source: "voice",
                    confirmationPrompt: "Please say yes or no to confirm the tool mode change.",
                    successSpeech: "Done. Tool mode is now \(displayToolMode(normalized)).",
                    cancelledSpeech: "Okay, I won't change tool mode."
                )
                await speakDirect("This removes confirmation prompts for risky actions. Are you sure? Say yes or no.")
                return true
            }

            applyGovernanceAction(action: "set_tool_mode", value: .string(normalized), source: "voice")
            await speakDirect("Done. Tool mode is now \(displayToolMode(normalized)).")
            return true

        case .setThinking(let enabled):
            return await handleBooleanGovernanceCommand(
                originalText: originalText,
                key: "llm.thinking_enabled",
                enabled: enabled,
                currentValue: thinkingEnabledLive ?? config.llm.thinkingEnabled,
                voiceTag: "set_thinking",
                highRiskWhenEnabled: false,
                onApplied: "Done. Thinking mode is now \(enabled ? "on" : "off")."
            )

        case .setBargeIn(let enabled):
            return await handleBooleanGovernanceCommand(
                originalText: originalText,
                key: "barge_in.enabled",
                enabled: enabled,
                currentValue: bargeInEnabledLive ?? config.bargeIn.enabled,
                voiceTag: "set_barge_in",
                highRiskWhenEnabled: false,
                onApplied: "Done. Barge-in is now \(enabled ? "enabled" : "disabled")."
            )

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

        let speakerState: String = {
            if currentSpeakerIsOwner { return "Owner verified" }
            if currentSpeakerIsKnownNonOwner { return "Known non-owner speaker" }
            if currentSpeakerLabel != nil { return "Recognized speaker" }
            return "Speaker unknown"
        }()

        return CapabilitySnapshotService.buildSnapshot(
            triggerText: triggerText,
            toolMode: mode,
            speakerState: speakerState,
            ownerGateEnabled: config.speaker.requireOwnerForTools,
            ownerProfileExists: ownerProfileExists,
            permissions: permissions,
            thinkingEnabled: thinkingEnabledLive ?? config.llm.thinkingEnabled,
            bargeInEnabled: bargeInEnabledLive ?? config.bargeIn.enabled,
            requireDirectAddress: effectiveRequireDirectAddress(),
            visionEnabled: effectiveVisionEnabled(),
            voiceIdentityLock: effectiveVoiceIdentityLock(),
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
            return "Barge-in"
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
        let defaults = UserDefaults.standard
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
        case "off":
            return "off"
        case "read_only":
            return "read only"
        case "read_write":
            return "read write"
        case "full":
            return "full"
        case "full_no_approval":
            return "full no approval"
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
        proactiveContext: ProactiveRequestContext? = nil
    ) async {
        let maxToolTurns = 5

        let generationID: UUID
        if let providedGenerationID {
            generationID = providedGenerationID
            // If this recursion belongs to an old turn, drop it immediately.
            if activeGenerationID != generationID {
                debugLog(debugConsole, .pipeline, "Drop stale generation recursion id=\(generationID.uuidString.prefix(8))")
                return
            }
        } else {
            generationID = UUID()
            activeGenerationID = generationID
            debugLog(debugConsole, .pipeline, "Generation started id=\(generationID.uuidString.prefix(8))")
        }

        // Reset computer-use step counter at the start of each user turn.
        if !isToolFollowUp {
            computerUseStepCount = 0
        }

        await refreshDegradedModeIfNeeded(context: "before_generation")

        guard await llmEngine.isLoaded else {
            NSLog("PipelineCoordinator: LLM not loaded")
            debugLog(debugConsole, .pipeline, "⚠️ LLM not loaded — cannot generate")
            return
        }

        let generationContext: GenerationContext
        if !isToolFollowUp {
            debugLog(debugConsole, .qa, "=== TURN START user=\(userText.prefix(160)) ===")
            interrupted = false
            // Ensure no stale TTS tasks from a previous turn can block this one.
            pendingTTSTask?.cancel()
            pendingTTSTask = nil
            lastAssistantResponseText = ""
            assistantGenerating = true
            eventBus.send(.assistantGenerating(true))

            // Play thinking tone.
            await playback.playThinkingTone()

            // Add user message to history.
            await conversationState.addUserMessage(
                userText,
                speakerDisplayName: currentSpeakerDisplayName,
                speakerId: currentSpeakerLabel,
                tag: proactiveContext?.conversationTag
            )

            // Issue a short-lived capability ticket for this turn.
            let toolMode = effectiveToolMode()
            activeCapabilityTicket = CapabilityTicketIssuer.issue(
                mode: toolMode,
                registry: registry
            )

            // Memory recall — inject context before generation.
            let memoryContext = await memoryOrchestrator?.recall(query: userText)
            if let ctx = memoryContext, !ctx.isEmpty {
                let preview = String(ctx.prefix(120)).replacingOccurrences(of: "\n", with: " ")
                debugLog(debugConsole, .memory, "Recalled: \(preview)…")
            }

            // Build system prompt with tool schemas.
            let ownerProfileExists = await speakerProfileStore?.hasOwnerProfile() ?? false
            let ownerEnrollmentRequired = config.speaker.requireOwnerForTools
                && !ownerProfileExists
            let includeTools = toolMode != "off"
                && !(config.speaker.requireOwnerForTools && currentSpeakerIsKnownNonOwner)
                && !ownerEnrollmentRequired

            let hiddenToolsReason: String? = {
                guard !includeTools else { return nil }
                if toolMode == "off" {
                    return "toolMode=off"
                }
                if ownerEnrollmentRequired {
                    return "owner_enrollment_required"
                }
                if config.speaker.requireOwnerForTools && currentSpeakerIsKnownNonOwner {
                    return "requireOwnerForTools=true and speaker matched as non-owner (\(currentSpeakerLabel ?? "unknown"))"
                }
                return "unknown"
            }()

            // Diagnostic logging — critical for debugging tool use failures.
            if let hiddenToolsReason {
                debugLog(debugConsole, .pipeline, "⚠️ Tools HIDDEN from LLM: \(hiddenToolsReason)")
                NSLog("PipelineCoordinator: tools hidden — %@", hiddenToolsReason)
                // Only show tool-mode upgrade popup for actionable reasons (enrollment needed,
                // non-owner speaker). Do NOT nag when user explicitly set toolMode=off — that
                // is intentional and showing a popup every turn is disruptive.
                if !isToolFollowUp && hiddenToolsReason != "toolMode=off" {
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
                if currentSpeakerIsOwner {
                    ownerDetail = "ownerVerified=true"
                } else if currentSpeakerLabel == nil {
                    ownerDetail = "speakerUnknown"
                } else {
                    ownerDetail = "speaker=\(currentSpeakerLabel ?? "?")"
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
            let nativeTools = includeTools
                ? registry.nativeToolSpecs(for: toolMode)
                : nil

            let toolSchemas: String? = {
                guard includeTools else { return nil }
                if nativeTools != nil {
                    let compact = registry.compactToolSummary(for: toolMode)
                    return compact.isEmpty ? nil : compact
                }
                let full = registry.toolSchemas(for: toolMode)
                return full.isEmpty ? nil : full
            }()

            if let specs = nativeTools {
                debugLog(debugConsole, .pipeline, "Native tool specs: \(specs.count) tools")
            }

            if let schemas = toolSchemas {
                let lineCount = schemas.split(separator: "\n").count
                debugLog(debugConsole, .pipeline, "Tool prompt summary: lines=\(lineCount) chars=\(schemas.count)")
            }

            let soul = isRescueMode ? SoulManager.defaultSoul() : SoulManager.loadSoul()
            let nativeToolsAvailable = nativeTools != nil
            var systemPrompt = PersonalityManager.assemblePrompt(
                voiceOptimized: true,
                visionCapable: effectiveVisionEnabled(),
                userName: config.userName,
                speakerDisplayName: currentSpeakerDisplayName,
                speakerRole: currentSpeakerRole,
                soulContract: soul,
                directiveOverride: isRescueMode ? "" : nil,
                nativeToolsAvailable: nativeToolsAvailable,
                toolSchemas: toolSchemas,
                installedSkills: legacySkills,
                skillDescriptions: skillDescs
            )
            // Inject activated skill instructions into context.
            if let activatedCtx = await skillManager?.activatedContext() {
                systemPrompt += "\n\n" + activatedCtx
            }
            if let context = memoryContext {
                systemPrompt += "\n\n" + context
            }
            // First-owner enrollment: one-shot context prime — cleared after first use.
            if let enrollCtx = firstOwnerEnrollmentContext {
                systemPrompt += "\n\n" + enrollCtx
                firstOwnerEnrollmentContext = nil
            }
            generationContext = GenerationContext(
                systemPrompt: systemPrompt,
                nativeTools: nativeTools
            )
            currentTurnGenerationContext = generationContext
        } else if let providedGenerationContext {
            generationContext = providedGenerationContext
        } else if let currentTurnGenerationContext {
            generationContext = currentTurnGenerationContext
        } else {
            return
        }

        let systemPrompt = generationContext.systemPrompt
        let dynamicReservedTokens = max(
            1024,
            Self.estimateTokenCount(for: systemPrompt) + config.llm.maxTokens
        )
        await conversationState.setReservedTokens(dynamicReservedTokens)
        let history = await conversationState.history

        let suppressThinking = forceSuppressThinking || !(thinkingEnabledLive ?? config.llm.thinkingEnabled)

        let options = GenerationOptions(
            temperature: config.llm.temperature,
            topP: config.llm.topP,
            maxTokens: config.llm.maxTokens,
            repetitionPenalty: config.llm.repeatPenalty,
            suppressThinking: suppressThinking,
            tools: generationContext.nativeTools
        )

        // Stream tokens.
        thinkTagStripper = TextProcessing.ThinkTagStripper()
        voiceTagStripper = VoiceTagStripper()
        let roleplayActive = await RoleplaySessionStore.shared.isActive
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
        let suppressProvisionalSpeechForLikelyToolTurn = !isToolFollowUp && Self.isToolBackedLookupRequest(userText)
        let llmStartedAt = Date()
        var llmTokenCount = 0
        var firstTokenAt: Date?
        var spokenTextThisTurn = ""
        // Stability-first speech mode: keep live text streaming, but defer TTS
        // until the turn completes so Qwen3-TTS sees larger coherent text spans.
        // This avoids audible interleaving/hallucinated fragments from tiny chunks.
        let preferFinalOnlySpeech = true
        var deferredStreamingSpeech = ""

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

        // Streaming chunk smoothing: prioritize sentence-sized chunks, and only use
        // clause fallback when enough text has accumulated and cadence allows it.
        let minSentenceChunkChars = 28
        let minSentenceFlushIntervalSec: TimeInterval = 0.24
        let minClauseChunkChars = 55
        let minClauseFlushIntervalSec: TimeInterval = 0.55
        let maxCharsBeforeClauseFlush = 280
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
                eventBus.send(.assistantText(text: cleaned, isFinal: false))
                return
            }
            // Suppress UI self-narration at any position (model describing its own interface).
            if TextProcessing.isUISelfNarration(cleaned) {
                debugLog(debugConsole, .pipeline, "[suppressed UI self-narration] \(String(cleaned.prefix(80)))")
                eventBus.send(.assistantText(text: cleaned, isFinal: false))
                return
            }

            // Tool-backed lookup turns often emit provisional wording before tool calls.
            // Keep UI text live, but avoid speaking provisional chunks to prevent
            // rambling/contradictory audio while tools are still pending.
            if suppressProvisionalSpeechForLikelyToolTurn {
                eventBus.send(.assistantText(text: cleaned, isFinal: false))
                return
            }

            // Conservative mode: keep text streaming to UI, but defer audio until
            // turn completion so TTS receives larger coherent text context.
            if preferFinalOnlySpeech {
                eventBus.send(.assistantText(text: cleaned, isFinal: false))
                if deferredStreamingSpeech.isEmpty {
                    deferredStreamingSpeech = cleaned
                } else {
                    deferredStreamingSpeech += " " + cleaned
                }
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
            recordSpokenText(cleaned)
            eventBus.send(.assistantText(text: cleaned, isFinal: false))
            enqueueTTS(cleaned, isFinal: false)
        }

        let systemPromptTokens = Self.estimateTokenCount(for: systemPrompt)
        if forceSuppressThinking {
            debugLog(debugConsole, .pipeline, "Retrying turn with thinking suppression forced")
        }
        debugLog(debugConsole, .pipeline, "LLM generating (maxTokens=\(options.maxTokens), history=\(history.count) msgs, turn=\(turnCount), sysPrompt≈\(systemPromptTokens) tok, ctx=\(config.llm.contextSizeTokens), suppressThinking=\(options.suppressThinking))")
        if options.maxTokens < 1024 {
            debugLog(debugConsole, .pipeline, "⚠️ maxTokens=\(options.maxTokens) is very low — tool call JSON needs ~200-500 tokens")
        }

        let tokenStream = await llmEngine.generate(
            messages: history,
            systemPrompt: systemPrompt,
            options: options
        )

        var staleGenerationDetected = false

        do {
            for try await token in tokenStream {
                if activeGenerationID != generationID {
                    staleGenerationDetected = true
                    debugLog(debugConsole, .pipeline, "Drop stale token stream id=\(generationID.uuidString.prefix(8))")
                    break
                }

                llmTokenCount += 1
                if firstTokenAt == nil {
                    firstTokenAt = Date()
                }
                guard !interrupted else {
                    NSLog("PipelineCoordinator: generation interrupted")
                    break
                }

                let visible = thinkTagStripper.process(token)
                // For Qwen3.5-35B-A3B: <think> is literal text, so ThinkTagStripper
                // consumes it natively. When it exits the think block, signal thinkEndSeen
                // so the pipeline doesn't wait for </think> in thinkAccum (which never arrives
                // because ThinkTagStripper already consumed it).
                if thinkTagStripper.hasExitedThinkBlock && !thinkEndSeen {
                    thinkEndSeen = true
                    eventBus.send(.thinkingText(text: "", isActive: false))
                }
                guard !visible.isEmpty else { continue }

                fullResponse += visible

                // Once we detect a tool call, stop streaming to TTS.
                if !detectedToolCall && fullResponse.contains("<tool_call>") {
                    detectedToolCall = true
                    // Flush text before the tool call tag to TTS.
                    if let tagRange = sentenceBuffer.range(of: "<tool_call>") {
                        let beforeTag = String(sentenceBuffer[..<tagRange.lowerBound])
                        let cleaned = TextProcessing.stripNonSpeechChars(beforeTag)
                        emitStreamingChunk(cleaned)
                    }
                    if preferFinalOnlySpeech {
                        // Drop any deferred provisional speech once a tool call appears.
                        deferredStreamingSpeech = ""
                    }
                    sentenceBuffer = ""
                    continue
                }

                if detectedToolCall {
                    // Accumulate tool call content without speaking.
                    continue
                }

                // Think block suppression: Qwen3's <think> is a special token decoded to ""
                // so ThinkTagStripper never sees it. </think> IS emitted as literal text.
                // Buffer everything until </think>, then discard the think block.
                if !thinkEndSeen {
                    debugLog(debugConsole, .llmThink, visible)
                    thinkAccum += visible
                    // Stream thinking text to the thought bubble UI.
                    eventBus.send(.thinkingText(text: visible, isActive: true))
                    if let endRange = thinkAccum.range(of: "</think>") {
                        let afterThink = String(thinkAccum[endRange.upperBound...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        thinkAccum = ""
                        thinkEndSeen = true
                        // Signal thinking complete — bubble will fade out.
                        eventBus.send(.thinkingText(text: "", isActive: false))
                        // Seed sentenceBuffer with any content following </think>.
                        if !afterThink.isEmpty && !roleplayActive {
                            sentenceBuffer = afterThink
                        }
                        continue
                    }
                    // Safety timeout: if the think block is very long and </think> never
                    // arrives, the model likely went off-rails — flush and start speaking.
                    if thinkAccum.count > 80_000 {
                        thinkAccum = ""
                        thinkEndSeen = true
                        eventBus.send(.thinkingText(text: "", isActive: false))
                        // Fall through to normal routing.
                    } else {
                        continue
                    }
                }
                debugLog(debugConsole, .llmToken, visible)

                // Roleplay mode: route through voice tag parser for per-character TTS.
                if roleplayActive {
                    let segments = voiceTagStripper.process(visible)
                    for segment in segments {
                        let voice: String?
                        if let character = segment.character {
                            // Check session first, then fall back to global character voice library.
                            var matched = await RoleplaySessionStore.shared.voiceForCharacter(character)
                            if matched == nil {
                                let globalEntry = await CharacterVoiceLibrary.shared.find(name: character)
                                matched = globalEntry?.voiceInstruct
                            }
                            if matched == nil {
                                NSLog("PipelineCoordinator: unassigned character '%@' — using narrator voice", character)
                            }
                            voice = matched
                        } else {
                            voice = nil
                        }
                        let cleaned = TextProcessing.stripNonSpeechChars(segment.text)
                        if !cleaned.isEmpty {
                            recordSpokenText(cleaned)
                            eventBus.send(.assistantText(text: cleaned, isFinal: false))
                            enqueueTTS(cleaned, isFinal: false, voiceInstruct: voice)
                        }
                    }
                } else {
                    // Standard sentence-boundary streaming flow.
                    sentenceBuffer += visible

                    if let boundary = TextProcessing.findSentenceBoundary(in: sentenceBuffer) {
                        let sentence = String(sentenceBuffer[..<boundary])
                        let cleaned = TextProcessing.stripNonSpeechChars(sentence)
                        // Safety filter: if this is the very first TTS sentence and it looks
                        // like the model is narrating/describing what the user said (leaked
                        // reasoning), discard it and log to debug console instead.
                        let isMetaCommentary = !firstTtsSent && TextProcessing.isMetaCommentary(cleaned)
                        if !cleaned.isEmpty && !isMetaCommentary {
                            let now = Date()
                            let interval = lastStreamingFlushAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
                            let shouldHoldForCoalesce = cleaned.count < minSentenceChunkChars
                                && (interval < minSentenceFlushIntervalSec || !firstTtsSent)

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
                    } else if sentenceBuffer.count >= maxCharsBeforeClauseFlush {
                        if let clause = TextProcessing.findClauseBoundary(in: sentenceBuffer) {
                            let text = String(sentenceBuffer[..<clause])
                            let cleaned = TextProcessing.stripNonSpeechChars(text)
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
        } catch {
            NSLog("PipelineCoordinator: LLM error: %@", error.localizedDescription)
            debugLog(debugConsole, .pipeline, "⚠️ LLM error: \(error.localizedDescription)")
        }

        if staleGenerationDetected {
            return
        }

        let llmEndedAt = Date()
        let llmElapsed = llmEndedAt.timeIntervalSince(llmStartedAt)
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
                } else if llmTokenCount >= 128 && decodeTps < 2.0 {
                    debugLog(debugConsole, .pipeline, "⚠️ Low decode throughput (\(String(format: "%.1f", decodeTps)) t/s) during long generation")
                } else if llmTokenCount < 128 && firstTokenLatency > 8.0 {
                    debugLog(debugConsole, .pipeline, "ℹ️ Turn was prefill-heavy (long first-token latency) — decode speed itself was normal")
                }
            } else {
                debugLog(debugConsole, .pipeline, "LLM done: \(llmTokenCount) tokens in \(String(format: "%.1f", llmElapsed))s (\(String(format: "%.1f", throughput)) t/s)")
                if llmTokenCount == 0 {
                    debugLog(debugConsole, .pipeline, "⚠️ 0 tokens generated — possible model stall or context overflow")
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

        // Parse tool calls from the full response.
        let toolCalls = Self.parseToolCalls(from: fullResponse)
        if !toolCalls.isEmpty {
            debugLog(debugConsole, .pipeline, "Found \(toolCalls.count) tool call(s): \(toolCalls.map(\.name).joined(separator: ", "))")
        } else if fullResponse.contains("<tool_call>") {
            debugLog(debugConsole, .qa, "⚠️ Model emitted tool_call markup but no valid calls parsed")
        }

        if toolCalls.isEmpty {
            // No tool calls — flush remaining speech and finish.
            if roleplayActive {
                // Flush voice tag stripper with remaining think-tag text.
                let voiceRemaining = voiceTagStripper.process(remaining) + voiceTagStripper.flush()
                var spokeSomething = false
                for segment in voiceRemaining {
                    let voice: String?
                    if let character = segment.character {
                        var matched = await RoleplaySessionStore.shared.voiceForCharacter(character)
                        if matched == nil {
                            let globalEntry = await CharacterVoiceLibrary.shared.find(name: character)
                            matched = globalEntry?.voiceInstruct
                        }
                        if matched == nil {
                            NSLog("PipelineCoordinator: unassigned character '%@' — using narrator voice", character)
                        }
                        voice = matched
                    } else {
                        voice = nil
                    }
                    let cleaned = TextProcessing.stripNonSpeechChars(segment.text)
                    if !cleaned.isEmpty {
                        recordSpokenText(cleaned)
                        eventBus.send(.assistantText(text: cleaned, isFinal: true))
                        enqueueTTS(cleaned, isFinal: true, voiceInstruct: voice)
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
                let finalText = TextProcessing.stripNonSpeechChars(sentenceBuffer)
                let spokenTextCandidate: String = {
                    if deferredStreamingSpeech.isEmpty { return finalText }
                    if finalText.isEmpty { return deferredStreamingSpeech }
                    return deferredStreamingSpeech + " " + finalText
                }()
                let shouldSpeak = !spokenTextCandidate.isEmpty && !TextProcessing.looksLikeNonProse(spokenTextCandidate)
                if !finalText.isEmpty {
                    eventBus.send(.assistantText(text: finalText, isFinal: true))
                }
                if shouldSpeak {
                    NSLog("PipelineCoordinator: TTS final → \"%@\"", String(spokenTextCandidate.prefix(120)))
                    recordSpokenText(spokenTextCandidate)
                    enqueueTTS(spokenTextCandidate, isFinal: true)
                }
                // Wait for all TTS (streaming + final) to complete.
                await awaitPendingTTS()
                if !shouldSpeak && assistantSpeaking {
                    // No TTS was enqueued for the final chunk (empty or non-prose).
                    // Mark playback end first, then force-clear only if speaking remains stuck.
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
            let visibleResponse = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            if spokenText.isEmpty && visibleResponse.isEmpty && !options.suppressThinking && !forceSuppressThinking {
                debugLog(debugConsole, .pipeline, "No visible response after thinking block — retrying with thinking disabled")
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

                    let repairResult = await executeTool(repairCall, proactiveContext: proactiveContext)

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
               Self.isToolBackedLookupRequest(userText)
            {
                let ownerProfileExists = await speakerProfileStore?.hasOwnerProfile() ?? false
                let ownerEnrollmentRequired = config.speaker.requireOwnerForTools
                    && !ownerProfileExists

                let fallback: String
                let reasonCode: String
                if effectiveToolMode() == "off" {
                    reasonCode = "toolMode=off"
                    fallback = "I can’t check that right now because tools are off. If you enable tools, I can fetch the real result."
                } else if ownerEnrollmentRequired {
                    reasonCode = "owner_enrollment_required"
                    fallback = "I need to enroll your primary voice before I can run tools for that. Please complete voice enrollment, then ask me again."
                } else {
                    reasonCode = "tool_not_called"
                    fallback = "I need to check that with a tool before I answer, and I couldn’t run one this turn. Please ask me to try again."
                }

                debugLog(debugConsole, .qa, "Tool-backed lookup fallback reason=\(reasonCode)")
                // Show tool-mode upgrade popup (approval overlay, not canvas).
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .faeToolModeUpgradeRequested,
                        object: nil,
                        userInfo: ["reason": reasonCode]
                    )
                }

                eventBus.send(.assistantText(text: fallback, isFinal: true))
                enqueueTTS(fallback, isFinal: true)
                await awaitPendingTTS()
                assistantGenerating = false
                eventBus.send(.assistantGenerating(false))
                engagedUntil = Date().addingTimeInterval(
                    Double(config.conversation.directAddressFollowupS)
                )
                activeCapabilityTicket = nil
                debugLog(debugConsole, .qa, "=== TURN END fallback reason=\(reasonCode) ===")
                return
            }

            if !spokenText.isEmpty {
                await conversationState.addAssistantMessage(spokenText, tag: proactiveContext?.conversationTag)

                // Memory capture.
                let turnId = newMemoryId(prefix: "turn")
                _ = await memoryOrchestrator?.capture(
                    turnId: turnId,
                    userText: userText,
                    assistantText: spokenText,
                    speakerId: currentSpeakerLabel,
                    utteranceTimestamp: currentUtteranceTimestamp
                )

                // Sentiment → orb feeling.
                if let feeling = SentimentClassifier.classify(spokenText) {
                    eventBus.send(.orbStateChanged(mode: "idle", feeling: feeling.rawValue, palette: nil))
                }
            } else if !visibleResponse.isEmpty {
                debugLog(debugConsole, .llmThink, "[suppressed non-spoken output] \(String(fullResponse.prefix(160)))")
            }

            maybeShowCapabilitiesCanvas(triggerText: userText, modelResponse: fullResponse)

            assistantGenerating = false
            eventBus.send(.assistantGenerating(false))

            // Refresh follow-up window.
            engagedUntil = Date().addingTimeInterval(
                Double(config.conversation.directAddressFollowupS)
            )
            activeCapabilityTicket = nil
            debugLog(debugConsole, .qa, "=== TURN END spoken_chars=\(spokenText.count) tool_calls=0 ===")
            return
        }

        // Tool calls found — execute them.
        if turnCount == 0,
           !isToolFollowUp,
           proactiveContext == nil,
           Self.canRunDeferredToolCalls(toolCalls, registry: registry)
        {
            let assistantToolMessage = Self.stripThinkContent(fullResponse)

            let ack = "I’ll check that in the background and report back as soon as it’s ready."
            eventBus.send(.assistantText(text: ack, isFinal: true))
            enqueueTTS(ack, isFinal: true)

            // Prevent audio stutter: do not launch background tool execution while
            // the acknowledgement is still being spoken.
            await awaitPendingTTS()
            await awaitSpeechDrain(timeoutMs: 8_000, reason: "before_deferred_tools")

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

            assistantGenerating = false
            eventBus.send(.assistantGenerating(false))
            engagedUntil = Date().addingTimeInterval(
                Double(config.conversation.directAddressFollowupS)
            )
            activeCapabilityTicket = nil
            debugLog(debugConsole, .qa, "=== TURN END deferred_tools count=\(toolCalls.count) ===")
            return
        }

        guard turnCount < maxToolTurns else {
            debugLog(debugConsole, .qa, "Exceeded max tool turns (\(maxToolTurns))")
            let msg = "I've used several tools but couldn't complete that. Could you try rephrasing?"
            eventBus.send(.assistantText(text: msg, isFinal: true))
            await speakText(msg, isFinal: true)
            assistantGenerating = false
            eventBus.send(.assistantGenerating(false))
            activeCapabilityTicket = nil
            return
        }

        // Fallback filler: if the model emitted a bare tool call with no natural
        // preamble, speak a short acknowledgement so users don't hear dead air
        // while tools execute.
        var didEnqueueToolFiller = false
        if turnCount == 0,
           !isToolFollowUp,
           spokenTextThisTurn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let filler = Self.toolCallAcknowledgement(for: toolCalls)
            if !filler.isEmpty {
                recordSpokenText(filler)
                eventBus.send(.assistantText(text: filler, isFinal: false))
                enqueueTTS(filler, isFinal: false)
                didEnqueueToolFiller = true
            }
        }

        // Add the assistant's tool-calling message to history (strip think content).
        await conversationState.addAssistantMessage(Self.stripThinkContent(fullResponse), tag: proactiveContext?.conversationTag)

        // Prevent synthesis/playback jitter: avoid starting tool execution while
        // filler/pre-tool speech is still active.
        if didEnqueueToolFiller || assistantSpeaking || pendingTTSTask != nil {
            debugLog(debugConsole, .pipeline, "Delaying tool execution until speech drains")
            await awaitPendingTTS()
            await awaitSpeechDrain(timeoutMs: 8_000, reason: "before_tool_execution")
        }

        var toolSuccessCount = 0
        var toolFailureCount = 0
        var firstToolError: String?

        for call in toolCalls.prefix(5) {
            let callId = UUID().uuidString
            let inputJSON = Self.serializeArguments(call.arguments)

            if assistantSpeaking {
                debugLog(debugConsole, .pipeline, "⚠️ Tool start while assistantSpeaking=true (\(call.name))")
            }
            eventBus.send(.toolCall(id: callId, name: call.name, inputJSON: inputJSON))
            NSLog("PipelineCoordinator: executing tool '%@'", call.name)
            let inputPreview = String(inputJSON.prefix(220))
            debugLog(debugConsole, .toolCall, "id=\(callId.prefix(8)) name=\(call.name) args=\(inputPreview)")

            var result = await executeTool(call, proactiveContext: proactiveContext)
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
                if FileManager.default.fileExists(atPath: audioPath) {
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

        if toolFailureCount > 0 && toolSuccessCount == 0 {
            let reason = firstToolError ?? "the tool call was denied or failed"
            let msg = "I couldn't complete that because the required tool didn't run: \(reason)"
            eventBus.send(.assistantText(text: msg, isFinal: true))
            await speakText(msg, isFinal: true)
            assistantGenerating = false
            eventBus.send(.assistantGenerating(false))
            activeCapabilityTicket = nil
            return
        }

        // Recurse: generate again with tool results in context.
        await generateWithTools(
            userText: userText,
            isToolFollowUp: true,
            turnCount: turnCount + 1,
            forceSuppressThinking: forceSuppressThinking,
            generationContext: generationContext,
            generationID: generationID,
            proactiveContext: proactiveContext
        )
    }

    /// Snapshot of the current foreground turn's prompt/tool context.
    private var currentTurnGenerationContext: GenerationContext?

    // MARK: - Speech State

    private func markAssistantSpeechStarted() {
        guard !assistantSpeaking else { return }
        assistantSpeaking = true
        lastAssistantStart = Date()
        echoSuppressor.onAssistantSpeechStart()
    }

    private func markAssistantSpeechEnded(reason: String, resetVAD: Bool = false) {
        if assistantSpeaking {
            let speechDuration = lastAssistantStart.map { Date().timeIntervalSince($0) } ?? 0
            debugLog(debugConsole, .pipeline, "Speech state → idle (\(reason), dur=\(String(format: "%.1f", speechDuration))s)")
            assistantSpeaking = false
            echoSuppressor.onAssistantSpeechEnd(speechDurationSecs: speechDuration)
        }
        if resetVAD {
            vad.reset()
        }
    }

    // MARK: - TTS

    /// Non-blocking TTS enqueue — chains onto `pendingTTSTask` so sentences synthesize
    /// in order without blocking the LLM token stream.
    ///
    /// Call this from inside the token generation loop. The LLM keeps producing tokens
    /// while TTS runs concurrently on the actor (re-entrant at `await` points).
    private func enqueueTTS(_ text: String, isFinal: Bool, voiceInstruct: String? = nil) {
        // Set speaking state immediately so echo suppressor and barge-in work correctly.
        markAssistantSpeechStarted()

        let previous = pendingTTSTask
        pendingTTSTask = Task {
            await previous?.value  // Ensure sentence ordering
            guard !interrupted else {
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
        }
    }

    /// Wait for all pending TTS work to complete. Call after the token loop ends.
    private func awaitPendingTTS() async {
        await pendingTTSTask?.value
        pendingTTSTask = nil
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
            debugLog(debugConsole, .pipeline, "⚠️ Speech drain timeout (\(reason)) after \(timeoutMs)ms")
        }
    }

    /// Blocking TTS — used by `speakDirect`, `speakWithVoice`, and other non-streaming paths
    /// where we want to wait for speech to finish before continuing.
    private func speakText(_ text: String, isFinal: Bool, voiceInstruct: String? = nil) async {
        markAssistantSpeechStarted()

        let cleaned = TextProcessing.stripNonSpeechChars(text)
        if !cleaned.isEmpty {
            eventBus.send(.assistantText(text: cleaned, isFinal: isFinal))
        }

        // Use cleaned text for TTS — stripping self-introductions, markup, etc.
        let ttsText = cleaned.isEmpty ? text : cleaned
        await synthesizeSentence(ttsText, isFinal: isFinal, voiceInstruct: voiceInstruct)
    }

    /// Maximum time a single TTS synthesis call can take before we force-cancel.
    /// Prevents `assistantSpeaking` from getting stuck if the TTS model hangs.
    /// This covers both the "stream never yields" and "stream yields slowly" cases
    /// because we wrap the entire stream consumption in a cancellable task group.
    private static let ttsSynthesisTimeoutSeconds: UInt64 = 30

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

        do {
            didProduceAudio = try await withThrowingTaskGroup(of: Bool.self) { group in
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
                    for try await buffer in audioStream {
                        try Task.checkCancellation()
                        if !firstChunkEmitted {
                            let latencyMs = Date().timeIntervalSince(ttsStartedAt) * 1000
                            firstChunkEmitted = true
                            NSLog("phase1.tts_first_chunk_latency_ms=%.2f", latencyMs)
                        }
                        produced = true
                        let samples = Self.extractSamples(from: buffer)
                        await playback.enqueue(
                            samples: samples,
                            sampleRate: Int(buffer.format.sampleRate),
                            isFinal: isFinal
                        )
                    }
                    return produced
                }

                // Child 2: timeout watchdog — cancels the group if TTS hangs.
                group.addTask {
                    try await Task.sleep(nanoseconds: Self.ttsSynthesisTimeoutSeconds * 1_000_000_000)
                    // If we reach here, the timeout expired before the stream finished.
                    return false
                }

                // Wait for whichever finishes first.
                if let produced = try await group.next() {
                    // Cancel the remaining child (either the timeout or the stalled stream).
                    group.cancelAll()
                    if !produced {
                        NSLog("PipelineCoordinator: TTS synthesis timeout or produced no audio")
                        debugLog(debugConsole, .pipeline, "⚠️ TTS timeout/no-audio — forcing completion")
                    }
                    return produced
                }
                return false
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

    // MARK: - Barge-In

    static func shouldTrackBargeIn(assistantSpeaking: Bool) -> Bool {
        assistantSpeaking
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
        var next = pending
        if speechStarted && !echoSuppression && !bargeInSuppressed && !inDenyCooldown {
            next = PendingBargeIn(capturedAt: Date(), lastRms: rms)
        } else if speechStarted && (echoSuppression || bargeInSuppressed || inDenyCooldown) {
            return nil
        }

        if isSpeech, next != nil {
            next?.speechSamples += chunkSamples.count
            next?.lastRms = rms
            let remainingCapacity = max(0, 16_000 - (next?.audioSamples.count ?? 0))
            if remainingCapacity > 0 {
                next?.audioSamples.append(contentsOf: chunkSamples.prefix(remainingCapacity))
            }
        }

        return next
    }

    static func shouldAllowBargeInInterrupt(assistantSpeaking: Bool, assistantGenerating: Bool) -> Bool {
        // Intentional: barge-in is an audible interruption affordance.
        // If the model is generating silently, we should not interrupt due to
        // ambient noise or speaker bleed while no speech is active.
        assistantSpeaking
    }

    static func shouldStartDeferredFollowUp(
        originTurnID: String?,
        currentTurnID: String?,
        assistantSpeaking: Bool,
        assistantGenerating: Bool
    ) -> Bool {
        guard !assistantSpeaking, !assistantGenerating else { return false }
        guard let originTurnID else { return true }
        return originTurnID == currentTurnID
    }

    /// Owner-verified barge-in: only the owner's voice can interrupt Fae mid-speech.
    /// Fail-closed after enrollment: if owner exists but verification fails, barge-in is DENIED.
    private func handleBargeInWithVerification(barge: PendingBargeIn) async {
        guard bargeInEnabledLive ?? config.bargeIn.enabled else { return }
        guard !bargeInSuppressed else { return }
        guard Self.shouldAllowBargeInInterrupt(
            assistantSpeaking: assistantSpeaking,
            assistantGenerating: assistantGenerating
        ) else { return }
        guard barge.lastRms >= config.bargeIn.minRms else { return }

        // Check holdoff — don't interrupt immediately after playback starts.
        if let start = lastAssistantStart {
            let elapsed = Date().timeIntervalSince(start) * 1000
            if elapsed < Double(config.bargeIn.assistantStartHoldoffMs) {
                return
            }
        }

        // Speaker verification (fail-closed when owner exists).
        let isOwner = await verifyBargeInSpeaker(audio: barge.audioSamples)
        guard isOwner else {
            debugLog(debugConsole, .command, "Barge-in blocked (not owner)")
            bargeInDenyCooldownUntil = Date().addingTimeInterval(Self.bargeInDenyCooldownSeconds)
            return
        }

        interrupted = true
        pendingTTSTask?.cancel()
        pendingTTSTask = nil
        Task { await playback.stop() }
        debugLog(debugConsole, .command, "Barge-in (owner verified) rms=\(String(format: "%.4f", barge.lastRms))")
        NSLog("PipelineCoordinator: barge-in triggered (owner verified, rms=%.4f)", barge.lastRms)
    }

    /// Verify the barge-in speaker is the owner. Fail-closed: if owner exists but
    /// verification is unavailable or errors, barge-in is DENIED. Fail-open ONLY
    /// during enrollment (no owner profile yet).
    private func verifyBargeInSpeaker(audio: [Float]) async -> Bool {
        // During enrollment (no owner yet) — allow all barge-in.
        guard let store = speakerProfileStore else { return firstOwnerEnrollmentActive }
        let hasOwner = await store.hasOwnerProfile()
        guard hasOwner else { return true }  // No owner enrolled yet — allow

        // Owner exists — fail closed if encoder unavailable.
        guard let encoder = speakerEncoder, await encoder.isLoaded else {
            return false  // Encoder unavailable but owner exists — DENY
        }

        // Need minimum audio for a meaningful embedding (~350ms at 16kHz = 5600 samples).
        guard audio.count >= 5600 else {
            return false  // Too little audio for reliable verification — DENY
        }

        do {
            let embedding = try await encoder.embed(
                audio: audio,
                sampleRate: AudioCaptureManager.targetSampleRate
            )
            // Relaxed threshold compensates for shorter/noisier barge-in audio.
            let relaxed = max(config.speaker.ownerThreshold - 0.10, 0.50)
            return await store.isOwner(embedding: embedding, threshold: relaxed)
        } catch {
            return false  // Embed failed but owner exists — DENY
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
               !ttfaEmittedForCurrentTurn,
               rms > 0.0005,
               let turnEndedAt = lastUserTurnEndedAt
            {
                let ttfaMs = Date().timeIntervalSince(turnEndedAt) * 1000
                ttfaEmittedForCurrentTurn = true
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

    struct ToolCall: @unchecked Sendable {
        let name: String
        let arguments: [String: Any]
    }

    /// Parse tool calls from response text.
    /// Supports two formats:
    /// - JSON (Qwen3): `<tool_call>{"name":"...","arguments":{...}}</tool_call>`
    /// - XML (Qwen3.5): `<tool_call><function=name><parameter=key>value</parameter></function></tool_call>`
    static func parseToolCalls(from text: String) -> [ToolCall] {
        var calls: [ToolCall] = []
        var searchRange = text.startIndex..<text.endIndex

        while let openRange = text.range(of: "<tool_call>", range: searchRange),
              let closeRange = text.range(of: "</tool_call>", range: openRange.upperBound..<text.endIndex)
        {
            let content = text[openRange.upperBound..<closeRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Try JSON format first (Qwen3): {"name":"...","arguments":{...}}
            if let call = parseJSONToolCall(content) {
                calls.append(call)
            }
            // Fall back to XML parameter format (Qwen3.5): <function=name><parameter=key>value</parameter></function>
            else if let call = parseXMLToolCall(content) {
                calls.append(call)
            }

            searchRange = closeRange.upperBound..<text.endIndex
        }

        return calls
    }

    private static func parseJSONToolCall(_ content: String) -> ToolCall? {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String
        else { return nil }
        let args = json["arguments"] as? [String: Any] ?? [:]
        return ToolCall(name: name, arguments: args)
    }

    /// Parse Qwen3.5 XML parameter format: `<function=name><parameter=key>value</parameter></function>`
    private static func parseXMLToolCall(_ content: String) -> ToolCall? {
        guard let funcMatch = content.range(of: "<function="),
              let funcEnd = content.range(of: ">", range: funcMatch.upperBound..<content.endIndex)
        else { return nil }
        let name = String(content[funcMatch.upperBound..<funcEnd.lowerBound])
        guard !name.isEmpty else { return nil }

        var args: [String: Any] = [:]
        var paramSearch = content.startIndex..<content.endIndex
        while let paramOpen = content.range(of: "<parameter=", range: paramSearch),
              let paramNameEnd = content.range(of: ">", range: paramOpen.upperBound..<content.endIndex),
              let paramClose = content.range(of: "</parameter>", range: paramNameEnd.upperBound..<content.endIndex)
        {
            let key = String(content[paramOpen.upperBound..<paramNameEnd.lowerBound])
            let value = String(content[paramNameEnd.upperBound..<paramClose.lowerBound])

            // Try to parse value as JSON for nested objects/arrays/numbers/booleans
            if let data = value.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data)
            {
                args[key] = parsed
            } else {
                args[key] = value
            }

            paramSearch = paramClose.upperBound..<content.endIndex
        }

        return ToolCall(name: name, arguments: args)
    }

    private static func toolCallAcknowledgement(for calls: [ToolCall]) -> String {
        guard let first = calls.first?.name.lowercased() else {
            return ""
        }
        switch first {
        case "web_search", "fetch_url":
            return "Let me check that quickly."
        case "calendar", "reminders":
            return "Checking that now."
        case "contacts", "mail", "notes":
            return "One moment, I’m pulling that up."
        case "read", "write", "edit", "bash":
            return "Got it, working on that now."
        default:
            return "Let me check that for you."
        }
    }

    /// Strip tool call markup from response text, leaving only human-readable content.
    private static func stripToolCallMarkup(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<tool_call>"),
              let close = result.range(of: "</tool_call>", range: open.upperBound..<result.endIndex)
        {
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip `<voice character="...">...</voice>` tags, keeping inner text.
    private static func stripVoiceTagMarkup(_ text: String) -> String {
        var result = text
        // Remove closing tags first (simpler).
        result = result.replacingOccurrences(of: "</voice>", with: "")
        // Remove opening tags: <voice character="..."> or <voice character='...'>
        if let regex = try? NSRegularExpression(pattern: #"<voice\s+[^>]*>"#) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip everything up to and including the first `</think>` tag.
    ///
    /// Prevents Qwen3 reasoning content from polluting conversation history and TTS.
    private static func stripThinkContent(_ text: String) -> String {
        guard let endRange = text.range(of: "</think>") else { return text }
        return String(text[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tool names eligible for non-blocking background execution.
    private static let deferredToolAllowlist: Set<String> = [
        "calendar", "reminders", "contacts", "mail", "notes",
        "web_search", "fetch_url", "read", "scheduler_list",
    ]

    /// Returns true when every tool call is read-only and safe to defer.
    private static func canRunDeferredToolCalls(
        _ calls: [ToolCall],
        registry: ToolRegistry
    ) -> Bool {
        guard !calls.isEmpty else { return false }

        for call in calls {
            guard deferredToolAllowlist.contains(call.name),
                  let tool = registry.tool(named: call.name),
                  !tool.requiresApproval,
                  tool.riskLevel != .high,
                  isReadOnlyDeferredAction(call)
            else {
                return false
            }
        }

        return true
    }

    /// Action-level guard for tools that can be both read and write.
    private static func isReadOnlyDeferredAction(_ call: ToolCall) -> Bool {
        switch call.name {
        case "calendar":
            let action = (call.arguments["action"] as? String) ?? ""
            return ["list_today", "list_week", "list_date", "search"].contains(action)

        case "reminders":
            let action = (call.arguments["action"] as? String) ?? ""
            return ["list_incomplete", "search"].contains(action)

        case "contacts":
            let action = (call.arguments["action"] as? String) ?? ""
            return ["search", "get_phone", "get_email"].contains(action)

        case "mail":
            let action = (call.arguments["action"] as? String) ?? ""
            return ["check_inbox", "read_recent"].contains(action)

        case "notes":
            let action = (call.arguments["action"] as? String) ?? ""
            return ["search", "list_recent"].contains(action)

        case "scheduler_list", "web_search", "fetch_url", "read":
            return true

        default:
            return false
        }
    }

    /// Heuristic: explicit visual requests where the assistant should run webcam capture.
    private static func isCameraIntentRequest(_ text: String) -> Bool {
        let lower = text.lowercased()
        let cameraPhrases = [
            "can you see me", "do you see me", "look at me", "see me",
            "take a photo", "take a picture", "use the camera", "open the camera",
            "what do you see", "can you see", "look through the camera",
        ]
        if cameraPhrases.contains(where: { lower.contains($0) }) {
            return true
        }

        return lower.contains("camera") && (
            lower.contains("see") || lower.contains("look") || lower.contains("photo") || lower.contains("picture")
        )
    }

    /// Heuristic: requests that should be grounded in live tool data (calendar/notes/mail/etc.)
    /// rather than answered from model prior.
    private static func isToolBackedLookupRequest(_ text: String) -> Bool {
        let lower = text.lowercased()
        let toolNouns = [
            "calendar", "diary", "schedule", "event", "events",
            "note", "notes", "reminder", "reminders",
            "mail", "email", "inbox", "contact", "contacts",
        ]
        let lookupVerbs = [
            "check", "show", "read", "find", "look up", "list", "what's", "what is",
        ]
        let hasNoun = toolNouns.contains { lower.contains($0) }
        let hasVerb = lookupVerbs.contains { lower.contains($0) }
        return hasNoun && hasVerb
    }

    private static func estimateTokenCount(for text: String) -> Int {
        Int(Double(text.count) / 3.5)
    }

    private static func serializeArguments(_ args: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: args),
           let str = String(data: data, encoding: .utf8)
        {
            return str
        }
        return "{}"
    }

    /// Extract an audio file path from skill output JSON (looks for "audio_file" key).
    private static func extractAudioFilePath(from output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["audio_file"] as? String,
              path.hasSuffix(".wav")
        else { return nil }
        return path
    }

    private static func inferUserPresentFromCameraOutput(_ output: String) -> Bool {
        let lower = output.lowercased()
        let absentSignals = [
            "no person", "no people", "nobody", "empty", "vacant", "no one",
            "no human", "no face", "unoccupied",
        ]
        if absentSignals.contains(where: { lower.contains($0) }) {
            return false
        }
        return true
    }

    private static func contentHash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
        var firstToolError: String?

        for call in job.toolCalls {
            guard !Task.isCancelled else { return }

            let callId = UUID().uuidString
            let inputJSON = Self.serializeArguments(call.arguments)
            let inputPreview = String(inputJSON.prefix(100))
            debugLog(debugConsole, .toolCall, "id=\(callId.prefix(8)) name=\(call.name) args=\(inputPreview) [deferred]")
            eventBus.send(.toolCall(id: callId, name: call.name, inputJSON: inputJSON))

            let result = await executeTool(
                call,
                capabilityTicketOverride: job.capabilityTicket,
                explicitUserAuthorizationOverride: job.explicitUserAuthorization
            )
            if result.isError {
                toolFailureCount += 1
                if firstToolError == nil {
                    firstToolError = result.output
                }
            } else {
                toolSuccessCount += 1
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
            let reason = firstToolError ?? "the tool call was denied or failed"
            let msg = "I couldn't complete that background check because the required tool didn't run: \(reason)"
            eventBus.send(.assistantText(text: msg, isFinal: true))
            await speakText(msg, isFinal: true)
            return
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
            return
        }

        explicitUserAuthorizationForTurn = job.explicitUserAuthorization
        assistantGenerating = true
        eventBus.send(.assistantGenerating(true))
        await playback.playThinkingTone()

        // Re-issue a capability ticket for the follow-up turn so the LLM
        // can make additional tool calls (e.g. a second web_search).
        activeCapabilityTicket = CapabilityTicketIssuer.issue(
            mode: effectiveToolMode(),
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

    private static let toolTimeoutSeconds: TimeInterval = 30

    private func executeTool(
        _ call: ToolCall,
        capabilityTicketOverride: CapabilityTicket? = nil,
        explicitUserAuthorizationOverride: Bool? = nil,
        proactiveContext: ProactiveRequestContext? = nil
    ) async -> ToolResult {
        // Tool mode enforcement — reject tools not allowed in current mode.
        let toolMode = effectiveToolMode()
        debugLog(debugConsole, .toolCall, "Execute request: \(call.name) mode=\(toolMode)")
        guard registry.isToolAllowed(call.name, mode: toolMode) else {
            debugLog(debugConsole, .toolResult, "Blocked by mode: \(call.name) mode=\(toolMode)")
            return .error("Tool '\(call.name)' is not available in current mode (\(toolMode))")
        }

        if let proactiveContext,
           !proactiveContext.allowedTools.contains(call.name)
        {
            debugLog(debugConsole, .toolResult, "Blocked by proactive allowlist: \(call.name) task=\(proactiveContext.taskId)")
            return .error("Tool '\(call.name)' is not allowed for proactive task '\(proactiveContext.taskId)'")
        }

        // Computer-use action step limiter (click/type_text/scroll).
        let actionTools: Set<String> = ["click", "type_text", "scroll"]
        if actionTools.contains(call.name) {
            computerUseStepCount += 1
            if computerUseStepCount > Self.maxComputerUseSteps {
                return .error("Computer use step limit reached (\(Self.maxComputerUseSteps) per turn). Ask the user before continuing.")
            }
        }

        // Auto-enable vision when a vision tool executes after passing the approval gate.
        // The user already gave explicit consent, so don't let a hidden config toggle block it.
        let visionTools: Set<String> = ["screenshot", "camera", "read_screen",
                                         "click", "type_text", "scroll", "find_element"]
        if visionTools.contains(call.name) && !effectiveVisionEnabled() {
            visionEnabledLive = true
            debugLog(debugConsole, .pipeline, "Vision auto-enabled: user approved a vision tool")
            Task { @MainActor in
                SelfConfigTool.configPatcher?("vision.enabled", true)
            }
        }

        // Build VLM provider closure for vision tools.
        // Capture an effective config with vision enabled so loadVLMIfNeeded succeeds.
        var vlmConfigMut = config
        vlmConfigMut.vision.enabled = effectiveVisionEnabled()
        let vlmConfig = vlmConfigMut
        let capturedMM = modelManager
        let vlmProvider: VLMProvider? = {
            guard let mm = capturedMM else { return nil }
            return try await mm.loadVLMIfNeeded(config: vlmConfig)
        }

        guard let tool = registry.tool(named: call.name, vlmProvider: vlmProvider) else {
            return .error("Unknown tool: \(call.name)")
        }

        let policyProfile = currentPolicyProfile()
        let selfConfigRead = Self.isSelfConfigReadAction(arguments: call.arguments)
        let effectiveRequiresApproval = Self.toolRequiresApproval(
            toolName: call.name,
            arguments: call.arguments,
            defaultRequiresApproval: tool.requiresApproval
        )
        let effectiveRiskLevel: ToolRiskLevel = (call.name == "self_config" && selfConfigRead) ? .low : tool.riskLevel

        // Rate limiting.
        if let limitError = await rateLimiter.checkLimit(
            tool: call.name,
            riskLevel: effectiveRiskLevel,
            profile: policyProfile
        ) {
            debugLog(debugConsole, .toolResult, "Rate limited: \(call.name) reason=\(limitError)")
            return .error(limitError)
        }

        let livenessScore: Float? = await speakerEncoder?.lastLivenessResult?.score
        let effectiveTicket = capabilityTicketOverride ?? activeCapabilityTicket
        let hasCapabilityTicket = effectiveTicket?.allows(toolName: call.name) ?? false
        let explicitAuthorization = explicitUserAuthorizationOverride ?? explicitUserAuthorizationForTurn
        let intent = ActionIntent(
            source: proactiveContext?.source ?? .voice,
            toolName: call.name,
            riskLevel: effectiveRiskLevel,
            requiresApproval: effectiveRequiresApproval,
            isOwner: currentSpeakerIsOwner,
            livenessScore: livenessScore,
            explicitUserAuthorization: explicitAuthorization,
            hasCapabilityTicket: hasCapabilityTicket,
            policyProfile: policyProfile,
            argumentSummary: Self.buildApprovalDescription(
                toolName: call.name,
                reason: "confirmation required",
                arguments: call.arguments
            ),
            schedulerTaskId: proactiveContext?.taskId,
            schedulerConsentGranted: proactiveContext?.consentGranted ?? false
        )

        let brokerDecisionStartedAt = Date()
        let brokerDecision: BrokerDecision
        if let outboundDecision = await outboundGuard.evaluate(
            toolName: call.name,
            arguments: call.arguments
        ) {
            switch outboundDecision {
            case .confirm(let message):
                brokerDecision = .confirm(
                    prompt: ConfirmationPrompt(message: message),
                    reason: DecisionReason(
                        code: .outboundRecipientNovelty,
                        message: message
                    )
                )
            case .deny(let message):
                brokerDecision = .deny(
                    reason: DecisionReason(
                        code: .outboundPayloadRisk,
                        message: message
                    )
                )
            }
        } else {
            brokerDecision = await actionBroker.evaluate(intent)
        }
        let brokerDecisionString: String
        let brokerReasonCode: String?
        switch brokerDecision {
        case .allow(let reason):
            brokerDecisionString = "allow"
            brokerReasonCode = reason.code.rawValue
        case .allowWithTransform(_, let reason):
            brokerDecisionString = "allow_with_transform"
            brokerReasonCode = reason.code.rawValue
        case .confirm(_, let reason):
            brokerDecisionString = "confirm"
            brokerReasonCode = reason.code.rawValue
        case .deny(let reason):
            brokerDecisionString = "deny"
            brokerReasonCode = reason.code.rawValue
        }

        debugLog(debugConsole, .approval, "Broker decision for \(call.name): \(brokerDecisionString) reason=\(brokerReasonCode ?? "none")")

        await securityLogger.log(
            event: "broker_decision",
            toolName: call.name,
            decision: brokerDecisionString,
            reasonCode: brokerReasonCode,
            arguments: call.arguments
        )

        var effectiveDecision = brokerDecision
        if UserDefaults.standard.bool(forKey: "fae.security.shadowMode") {
            switch brokerDecision {
            case .confirm(_, let reason), .deny(let reason):
                await securityLogger.log(
                    event: "shadow_decision",
                    toolName: call.name,
                    decision: brokerDecisionString,
                    reasonCode: reason.code.rawValue,
                    approved: nil,
                    success: true,
                    error: "Shadow mode bypassed enforcement",
                    arguments: call.arguments
                )
                effectiveDecision = .allow(reason: reason)
            default:
                break
            }
        }

        var approvedByUser = false
        switch effectiveDecision {
        case .allow:
            break

        case .allowWithTransform(let transform, _):
            if let transformError = await applySafetyTransform(
                transform,
                toolName: call.name,
                arguments: call.arguments
            ) {
                return .error(transformError)
            }

        case .confirm(let prompt, _):
            if let manager = approvalManager {
                debugLog(debugConsole, .approval, "Requesting approval for \(call.name): \(prompt.message)")
                awaitingApproval = true
                async let approvalDecision = manager.requestApproval(
                    toolName: call.name,
                    description: prompt.message
                )
                await speakDirect(prompt.message)
                let approved = await approvalDecision
                awaitingApproval = false
                approvedByUser = approved
                debugLog(debugConsole, .approval, "Approval result for \(call.name): \(approved)")
                if !approved {
                    if let analytics = toolAnalytics {
                        let latencyMs = Int(Date().timeIntervalSince(brokerDecisionStartedAt) * 1000)
                        await analytics.record(
                            toolName: call.name,
                            success: false,
                            latencyMs: latencyMs,
                            approved: false,
                            error: "Tool execution denied by user"
                        )
                    }
                    await securityLogger.log(
                        event: "tool_denied",
                        toolName: call.name,
                        decision: "confirm",
                        reasonCode: brokerReasonCode,
                        approved: false,
                        success: false,
                        error: "Tool execution denied by user",
                        arguments: call.arguments
                    )
                    return .error("Tool execution denied by user.")
                }
            } else {
                if let analytics = toolAnalytics {
                    let latencyMs = Int(Date().timeIntervalSince(brokerDecisionStartedAt) * 1000)
                    await analytics.record(
                        toolName: call.name,
                        success: false,
                        latencyMs: latencyMs,
                        approved: nil,
                        error: "Tool requires approval, but no approval manager is available"
                    )
                }
                await securityLogger.log(
                    event: "tool_denied",
                    toolName: call.name,
                    decision: "confirm",
                    reasonCode: brokerReasonCode,
                    approved: nil,
                    success: false,
                    error: "No approval manager available",
                    arguments: call.arguments
                )
                return .error("Tool requires approval, but no approval manager is available.")
            }

        case .deny(let reason):
            debugLog(debugConsole, .toolResult, "Denied by broker: \(call.name) reason=\(reason.code.rawValue)")
            if let analytics = toolAnalytics {
                let latencyMs = Int(Date().timeIntervalSince(brokerDecisionStartedAt) * 1000)
                await analytics.record(
                    toolName: call.name,
                    success: false,
                    latencyMs: latencyMs,
                    approved: nil,
                    error: "Denied by broker: \(reason.code.rawValue)"
                )
            }
            await securityLogger.log(
                event: "tool_denied",
                toolName: call.name,
                decision: "deny",
                reasonCode: reason.code.rawValue,
                approved: nil,
                success: false,
                error: reason.message,
                arguments: call.arguments
            )
            return .error(reason.message)
        }

        // Execute with timeout and analytics.
        var executionArguments = call.arguments
        if call.name == "run_skill", let ticketId = effectiveTicket?.id {
            executionArguments["capability_ticket"] = ticketId
        }
        if call.name == "voice_identity",
           let action = executionArguments["action"] as? String,
           action == "collect_sample"
        {
            executionArguments["enrollment_active"] = firstOwnerEnrollmentActive
        }

        let startTime = Date()
        let result: ToolResult
        do {
            result = try await withThrowingTaskGroup(of: ToolResult.self) { group in
                group.addTask {
                    try await tool.execute(input: executionArguments)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(Self.toolTimeoutSeconds * 1_000_000_000))
                    return .error("Tool timed out after \(Int(Self.toolTimeoutSeconds))s")
                }
                guard let r = try await group.next() else {
                    group.cancelAll()
                    return .error("Tool execution did not return a result")
                }
                group.cancelAll()
                return r
            }
        } catch {
            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
            debugLog(debugConsole, .toolResult, "Tool threw error: \(call.name) latency=\(latencyMs)ms error=\(error.localizedDescription)")
            if let analytics = toolAnalytics {
                await analytics.record(
                    toolName: call.name,
                    success: false,
                    latencyMs: latencyMs,
                    approved: approvedByUser ? true : nil,
                    error: error.localizedDescription
                )
            }
            await securityLogger.log(
                event: "tool_result",
                toolName: call.name,
                decision: brokerDecisionString,
                reasonCode: brokerReasonCode,
                approved: approvedByUser ? true : nil,
                success: false,
                error: error.localizedDescription,
                arguments: call.arguments
            )
            return .error("Tool error: \(error.localizedDescription)")
        }

        let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
        debugLog(debugConsole, .toolResult, "Tool finished: \(call.name) success=\(!result.isError) latency=\(latencyMs)ms")
        if let analytics = toolAnalytics {
            await analytics.record(
                toolName: call.name,
                success: !result.isError,
                latencyMs: latencyMs,
                approved: approvedByUser ? true : nil,
                error: result.isError ? result.output : nil
            )
        }

        await securityLogger.log(
            event: "tool_result",
            toolName: call.name,
            decision: brokerDecisionString,
            reasonCode: brokerReasonCode,
            approved: approvedByUser ? true : nil,
            success: !result.isError,
            error: result.isError ? result.output : nil,
            arguments: call.arguments
        )

        if !result.isError {
            await outboundGuard.recordSuccessfulSend(toolName: call.name, arguments: call.arguments)
        }

        return result
    }

    /// Map current tool mode to an autonomy policy profile.
    ///
    /// - off => cautious profile
    /// - read_only/read_write/full => balanced profile
    /// - full_no_approval => autonomous profile
    private func currentPolicyProfile() -> PolicyProfile {
        switch effectiveToolMode() {
        case "off":
            return .moreCautious
        case "full_no_approval":
            return .moreAutonomous
        case "read_only", "read_write", "full":
            return .balanced
        default:
            return .balanced
        }
    }

    /// Apply deterministic safety wrappers before executing a tool.
    private func applySafetyTransform(
        _ transform: SafetyTransform,
        toolName: String,
        arguments: [String: Any]
    ) async -> String? {
        switch transform {
        case .none:
            return nil

        case .checkpointBeforeMutation:
            if ["write", "edit"].contains(toolName) {
                guard let path = arguments["path"] as? String else {
                    return "Safety checkpoint failed: missing path argument"
                }

                switch PathPolicy.validateWritePath(path) {
                case .blocked(let reason):
                    return reason
                case .allowed(let canonical):
                    let checkpointId = ReversibilityEngine.createCheckpoint(
                        for: canonical,
                        reason: "\(toolName) transform"
                    )
                    if checkpointId == nil {
                        return "Safety checkpoint failed: could not create reversible snapshot"
                    }

                    await securityLogger.log(
                        event: "safety_transform",
                        toolName: toolName,
                        decision: "checkpointBeforeMutation",
                        reasonCode: nil,
                        approved: nil,
                        success: true,
                        error: nil,
                        arguments: ["path": canonical, "checkpoint_id": checkpointId ?? ""]
                    )
                    return nil
                }
            }

            if toolName == "manage_skill",
               let action = arguments["action"] as? String,
               action == "delete",
               let name = arguments["name"] as? String,
               Self.isSafeSkillName(name)
            {
                let path = SkillManager.skillsDirectory.appendingPathComponent(name).path
                let checkpointId = ReversibilityEngine.createCheckpoint(
                    for: path,
                    reason: "manage_skill delete transform"
                )
                if checkpointId == nil {
                    return "Safety checkpoint failed: could not snapshot skill before delete"
                }
                await securityLogger.log(
                    event: "safety_transform",
                    toolName: toolName,
                    decision: "checkpointBeforeMutation",
                    reasonCode: nil,
                    approved: nil,
                    success: true,
                    error: nil,
                    arguments: ["path": path, "checkpoint_id": checkpointId ?? ""]
                )
            }

            return nil
        }
    }

    /// Self-config actions that are read-only and should bypass approval prompts.
    private static let selfConfigReadActions: Set<String> = [
        "get_settings", "get_directive", "get_instructions",
    ]

    static func isSelfConfigReadAction(arguments: [String: Any]) -> Bool {
        guard let action = (arguments["action"] as? String)?.lowercased() else { return false }
        return selfConfigReadActions.contains(action)
    }

    static func toolRequiresApproval(
        toolName: String,
        arguments: [String: Any],
        defaultRequiresApproval: Bool
    ) -> Bool {
        if toolName == "self_config" {
            return !isSelfConfigReadAction(arguments: arguments)
        }
        return defaultRequiresApproval
    }

    private static func selfConfigApprovalSummary(arguments: [String: Any]) -> String {
        let action = (arguments["action"] as? String)?.lowercased() ?? ""
        if selfConfigReadActions.contains(action) {
            return "I can check your current settings."
        }

        if action == "adjust_setting" {
            let key = arguments["key"] as? String ?? "a setting"
            return "I can update \(key)."
        }

        if action.contains("directive") || action.contains("instructions") {
            switch action {
            case "set_directive", "set_instructions":
                return "I can replace your persistent directive."
            case "append_directive", "append_instructions":
                return "I can append to your persistent directive."
            case "clear_directive", "clear_instructions":
                return "I can clear your persistent directive."
            default:
                return "I can update your persistent directive."
            }
        }

        return "I can update your Fae settings."
    }

    /// Build a plain-language confirmation prompt with concrete action context.
    private static func buildApprovalDescription(
        toolName: String, reason: String, arguments: [String: Any]
    ) -> String {
        let summary: String
        switch toolName {
        case "bash":
            if let command = arguments["command"] as? String {
                let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = trimmed.count > 140 ? String(trimmed.prefix(140)) + "…" : trimmed
                summary = "I can run this command: \(preview)."
            } else {
                summary = "I can run a shell command for this step."
            }

        case "write":
            if let path = arguments["path"] as? String {
                summary = "I can write to \(path)."
            } else {
                summary = "I can write file content for this step."
            }

        case "edit":
            if let path = arguments["path"] as? String {
                summary = "I can edit \(path)."
            } else {
                summary = "I can edit a file for this step."
            }

        case "self_config":
            summary = selfConfigApprovalSummary(arguments: arguments)

        case "run_skill":
            let skillName = arguments["name"] as? String ?? "a skill"
            summary = "I can run \(skillName) now."

        case "manage_skill":
            let action = arguments["action"] as? String ?? "modify"
            summary = "I can \(action) a skill in your local skills library."

        case "scheduler_create":
            summary = "I can create a scheduled task that runs automatically later."

        case "scheduler_update":
            summary = "I can update a scheduled task."

        case "scheduler_delete":
            summary = "I can delete this scheduled task."

        default:
            summary = "I can use \(toolName) for this step."
        }

        return "\(summary) Say yes or no, or press the Yes/No button."
    }

    // MARK: - Helpers

    private static func isSafeSkillName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.contains("..") { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
        )
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frameCount = Int(buffer.frameLength)
        guard let channelData = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
    }
}
