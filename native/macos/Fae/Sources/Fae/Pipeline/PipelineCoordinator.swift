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
    private let llmEngine: any LLMEngine
    private let ttsEngine: any TTSEngine
    private var config: FaeConfig
    private let conversationState: ConversationStateTracker
    private let memoryOrchestrator: MemoryOrchestrator?
    private let sessionStore: SessionStore?
    private let workflowTraceStore: WorkflowTraceStore?
    private let registry: ToolRegistry
    private let damageControlPolicy = DamageControlPolicy()
    private var modelLocality: ModelLocality = .local
    private let securityLogger = SecurityEventLogger.shared
    private let speakerEncoder: CoreMLSpeakerEncoder?
    private let speakerProfileStore: SpeakerProfileStore?
    private let wakeWordProfileStore: WakeWordProfileStore?
    private let skillManager: SkillManager?
    private let toolAnalytics: ToolAnalytics?
    private let modelManager: ModelManager?
    private let isRescueMode: Bool
    private let toolExecutor: ToolExecutor

    // MARK: - Voice spine V3b (FAE_DAEMON_PLAYBACK)

    /// When true, assistant TTS plays in the daemon (`tts.speak`) and the level
    /// envelope + playback-end arrive as server-push events (see
    /// `DaemonEventSubscriber`), NOT via local `AudioPlaybackManager`.
    ///
    /// DEFAULT ON (V3b cutover, 2026-06-17). This is the path that emits daemon
    /// `audio.level`, which the orb host now rides to derive Speaking
    /// (orb-host-owns-state, commit 908485a3). Set `FAE_DAEMON_PLAYBACK=0` to
    /// opt OUT — it is a loud kill switch so an audio regression is one env
    /// var away from the old local-playback behavior. Computed (not a stored
    /// init) so it reads the env lazily without a `Self`-reference in a
    /// stored-property initializer.
    private var useDaemonPlayback: Bool { Self.readDaemonPlaybackFlag() }

    /// Live daemon playback id for the current assistant utterance (flag-ON).
    /// Nil when nothing is playing through the daemon.
    private var currentDaemonPlaybackID: String?

    /// Dedicated event-subscribe connection (default-ON only). Nil until the
    /// daemon TTS engine provides its endpoints and the subscriber is started.
    private var eventSubscriber: DaemonEventSubscriber?

    /// Tracks which daemon-playback fallback reasons have already been loudly
    /// logged this run, so we log each distinct reason ONCE (not per turn).
    /// Cleared never — a fallback reason is a runtime condition, not a
    /// turn-local one.
    private var daemonPlaybackFallbackReasonsLogged: Set<String> = []

    /// Phase G2: true while an after-turn conversation compaction is in flight, so
    /// overlapping turns do not double-fold the same evicted backlog.
    private var compactionInFlight = false

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

    /// Wire plugin hook runner into the tool executor for PreToolUse/PostToolUse hooks.
    func setPluginHookRunner(_ runner: PluginHookRunner?) async {
        await toolExecutor.setPluginHookRunner(runner)
    }

    /// Wire the action receipt store into the tool executor.
    ///
    /// Also retains a reference in the coordinator so that barge-in handlers
    /// can undo the last narrated action when the user interrupts narration.
    func setReceiptStore(_ store: ReceiptStore) async {
        narrationReceiptStore = store
        await toolExecutor.setReceiptStore(store)
    }

    /// Receipt store retained for narration-time undo.
    /// Populated by `setReceiptStore(_:)` alongside the tool executor wire.
    private var narrationReceiptStore: ReceiptStore?

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

    /// Query the current mic mute state from the audio capture manager.
    func isMicMuted() async -> Bool {
        await capture.isMuted
    }

    // MARK: - Push-to-Talk (S18)

    // Deliberate capture: click the orb (talk toggle) or hold the configured
    // hotkey. While capturing, mic chunks accumulate into a buffer and VAD
    // runs only as a plain endpointer. This is THE capture model (S18 3/3) —
    // there is no always-on listening lane; capture is a deliberate physical
    // act by the person at the machine, so the turn runs as the owner. The
    // buffer is WAV-encoded and rides the daemon request directly to Gemma:
    // ASR + reasoning + tool calling in one request, with the `[heard]:`
    // first-line contract preserving the transcript for memory capture
    // (see docs/spikes/S18-pure-gemma-asr-ptt.md).

    private var pttCapturing = false
    private var pttBuffer: [Float] = []
    private var pttSpeechSeen = false
    private var pttSilenceSamples = 0
    private var pttMicWasMuted = false
    /// Hold gestures (Right ⌥ / orb long-press) end on RELEASE, never on the
    /// silence endpointer — a mid-sentence pause must not send the turn early
    /// (toggle captures — panel mic, "Talk to Fae" menu — keep the endpointer).
    private var pttHoldMode = false
    /// Base64 WAV consumed by the next user-turn generation (S18 audio turn).
    private var pendingPTTAudioBase64: String?
    /// The `[heard]:` transcription extracted from the model's first reply of
    /// an audio turn. Spans tool follow-up recursion so end-of-turn memory
    /// capture records what the user actually said, not the placeholder.
    private var pttHeardTranscriptForTurn: String?

    /// System-prompt block for audio turns — proven against Gemma 4 E4B (the
    /// daemon strips nothing; Swift strips the [heard] line + tool residue).
    private static let pttHeardInstruction = """
    The user's message arrives as audio. Begin EVERY reply with one line of \
    the form `[heard]: <verbatim transcription of the user's speech>` and \
    then answer (or call a tool) based on what you heard.
    """

    /// Trailing silence (after speech) that ends a capture: 1.2 s @ 16 kHz.
    private static let pttEndpointSilenceSamples = 19_200
    /// Minimum capture worth sending: 0.5 s @ 16 kHz.
    private static let pttMinimumSamples = 8_000
    /// Hard cap on one capture: 30 s @ 16 kHz (~1.3 MB as base64 WAV).
    private static let pttMaximumSamples = 480_000

    /// Orb click: start capture, or end-and-send when already capturing.
    func pttToggle() async {
        if pttCapturing {
            await pttStop()
        } else {
            await pttStart()
        }
    }

    /// Begin a deliberate capture (orb click / hotkey press).
    ///
    /// `holdMode: true` (hotkey hold / orb long-press) disables the silence
    /// endpointer — only the release (or the 30 s cap) ends the capture.
    func pttStart(holdMode: Bool = false) async {
        guard !pttCapturing else { return }
        // A deliberate capture interrupts whatever Fae is saying.
        if assistantSpeaking {
            markGenerationInterrupted()
            ttsState.cancelPending()
            await stopAssistantPlaybackForInterrupt()
        }
        pttCapturing = true
        pttHoldMode = holdMode
        pttBuffer = []
        pttBuffer.reserveCapacity(Self.pttMaximumSamples)
        pttSpeechSeen = false
        pttSilenceSamples = 0
        vad.reset()
        pttMicWasMuted = await capture.isMuted
        if pttMicWasMuted {
            await capture.setMuted(false)
        }
        eventBus.send(.orbStateChanged(mode: "listening", feeling: OrbFeeling.curiosity.rawValue, palette: nil))
        NSLog("PipelineCoordinator: PTT capture started (holdMode=%d)", holdMode ? 1 : 0)
        debugLog(debugConsole, .pipeline, "PTT capture started")
    }

    /// End a deliberate capture (orb click again / hotkey release) and send.
    func pttStop() async {
        guard pttCapturing else { return }
        await finishPTTCapture(reason: "stop")
    }

    /// Accumulate one mic chunk while capturing. VAD acts as a plain
    /// endpointer only: 1.2 s of trailing silence after speech ends the
    /// capture, as does the 30 s hard cap.
    private func handlePTTChunk(_ chunk: AudioChunk) async {
        let vadOutput = vad.processChunk(chunk)
        eventBus.send(.audioLevel(vadOutput.rms))
        pttBuffer.append(contentsOf: chunk.samples)

        if vadOutput.isSpeech {
            pttSpeechSeen = true
            pttSilenceSamples = 0
        } else if pttSpeechSeen {
            pttSilenceSamples += chunk.samples.count
        }

        if !pttHoldMode, pttSpeechSeen, pttSilenceSamples >= Self.pttEndpointSilenceSamples {
            await finishPTTCapture(reason: "silence_endpoint")
        } else if pttBuffer.count >= Self.pttMaximumSamples {
            await finishPTTCapture(reason: "max_duration")
        }
    }

    /// Close the capture, restore mic state, and run the audio turn through
    /// the daemon. Captures with no speech (or too short) are discarded.
    private func finishPTTCapture(reason: String) async {
        guard pttCapturing else { return }
        pttCapturing = false
        let samples = pttBuffer
        pttBuffer = []
        await capture.setMuted(pttMicWasMuted)
        vad.reset()
        eventBus.send(.orbStateChanged(mode: "idle", feeling: OrbFeeling.neutral.rawValue, palette: nil))
        NSLog(
            "PipelineCoordinator: PTT capture finished (%@): %d samples, speech=%d",
            reason, samples.count, pttSpeechSeen ? 1 : 0)
        debugLog(
            debugConsole, .pipeline,
            "PTT capture finished (\(reason)): \(samples.count) samples, speech=\(pttSpeechSeen)")

        guard pttSpeechSeen, samples.count >= Self.pttMinimumSamples else {
            NSLog("PipelineCoordinator: PTT capture discarded (no usable speech)")
            debugLog(debugConsole, .pipeline, "PTT capture discarded (no usable speech)")
            return
        }

        let wav = WAVEncoder.encode(samples: samples, sampleRate: 16_000)
        pendingPTTAudioBase64 = wav.base64EncodedString()

        // Deliberate physical act at the machine = the owner is speaking.
        speakerGate.currentSpeakerLabel = "owner"
        speakerGate.currentSpeakerDisplayName = await speakerProfileStore?.ownerDisplayName() ?? "Owner"
        speakerGate.currentSpeakerRole = .owner
        speakerGate.currentSpeakerIsOwner = true
        speakerGate.currentSpeakerIsKnownNonOwner = false
        speakerGate.currentUtteranceTimestamp = Date()
        if gateState == .idle {
            wake()
        }

        // The placeholder is never sent to the model (the audio message ships
        // with empty content); the `[heard]:` transcription replaces it in
        // history, transcript and memory once the model answers.
        await processTranscription(
            text: Self.pttPlaceholderUserText,
            wakeMatch: nil,
            rms: nil,
            durationSecs: Float(samples.count) / 16_000.0,
            turnSource: .voice
        )
    }

    /// User-turn placeholder while the `[heard]:` transcription is pending.
    static let pttPlaceholderUserText = "(voice message)"

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

    /// Switch the TTS voice live without restarting.
    func setTTSVoice(_ voice: String) async {
        if let adapter = ttsEngine as? FaeTTSAdapter {
            await adapter.switchVoice(to: voice)
        } else if let daemon = ttsEngine as? DaemonTTSEngine {
            await daemon.switchVoice(to: voice)
        }
    }

    /// Preview a named voice by synthesizing a short phrase and playing it once.
    func previewTTSVoice(_ voice: String) async {
        let phrase = "Hiya, I'm Fae. I've just fed the wee birdies, and I'm feeling quietly cheeky today."
        do {
            let stream = await ttsEngine.synthesize(text: phrase, voiceInstruct: voice)
            markAssistantSpeechStarted()
            for try await buffer in stream {
                guard let channelData = buffer.floatChannelData?[0] else { continue }
                let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
                await playback.enqueue(
                    samples: samples,
                    sampleRate: Int(buffer.format.sampleRate),
                    isFinal: false
                )
            }
            await playback.markEnd()
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
    private let personalLexicon: PersonalLexicon
    private var thinkTagStripper = TextProcessing.ThinkTagStripper()
    private var voiceTagStripper = VoiceTagStripper()
    private let keywordSpotter: KeywordSpotter

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
    private var assistantGenerationTracker = AssistantGenerationTracker()
    private var activeGenerationID: UUID? { assistantGenerationTracker.activeGenerationID }
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
    private let instrumentation = PipelineInstrumentation()

    // Generation takeover candidate (Path C) moved to bargeInState.
    // GenerationTakeoverCandidate type in BargeInTypes.swift.

    // MARK: - Pipeline Tasks

    private var pipelineTask: Task<Void, Never>?
    private var captureStream: AsyncStream<AudioChunk>?


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

    private static let conversationalSilenceFloorMs: Int = 1800



    // MARK: - Deferred Tool Jobs

    private struct DeferredToolJob: Sendable {
        let id: UUID
        let userText: String
        let toolCalls: [ToolCall]
        let assistantToolMessage: String
        let forceSuppressThinking: Bool
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

    private var sessionDeclaredUserName: String?

    /// Tracks tool call signatures (name + args) already executed this user turn.
    /// Prevents the LLM looping on identical web_search / calendar calls.
    /// Reset at the start of each new user turn (turnCount == 0, isToolFollowUp == false).
    private var seenToolCallSignatures: Set<String> = []
    /// Cached results for duplicate tool calls — returns real data instead of hallucination-causing notices.
    private var seenToolCallResults: [String: ToolResult] = [:]

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

    /// Called after proactive camera observations when the owner is detected,
    /// providing the VLM's description text for progressive visual identity updates.
    private var proactiveVisualUpdateHandler: (@Sendable (String) async -> Void)?

    /// Called after proactive screen observations to decide whether to persist context.
    private var proactiveScreenContextHandler: (@Sendable (String) async -> Bool)?

    // MARK: - Init

    init(
        eventBus: FaeEventBus,
        capture: AudioCaptureManager,
        playback: AudioPlaybackManager,
        llmEngine: any LLMEngine,
        ttsEngine: any TTSEngine,
        config: FaeConfig,
        conversationState: ConversationStateTracker,
        memoryOrchestrator: MemoryOrchestrator? = nil,
        sessionStore: SessionStore? = nil,
        workflowTraceStore: WorkflowTraceStore? = nil,
        registry: ToolRegistry,
        speakerEncoder: CoreMLSpeakerEncoder? = nil,
        speakerProfileStore: SpeakerProfileStore? = nil,
        wakeWordProfileStore: WakeWordProfileStore? = nil,
        skillManager: SkillManager? = nil,
        toolAnalytics: ToolAnalytics? = nil,
        modelManager: ModelManager? = nil,
        personalLexicon: PersonalLexicon? = nil,
        rescueMode: Bool = false
    ) {
        self.eventBus = eventBus
        self.capture = capture
        self.playback = playback
        self.llmEngine = llmEngine
        self.ttsEngine = ttsEngine
        self.config = config
        self.conversationState = conversationState
        self.memoryOrchestrator = memoryOrchestrator
        self.sessionStore = sessionStore
        self.workflowTraceStore = workflowTraceStore
        self.registry = registry
        self.speakerEncoder = speakerEncoder
        self.speakerProfileStore = speakerProfileStore
        self.wakeWordProfileStore = wakeWordProfileStore
        self.skillManager = skillManager
        self.toolAnalytics = toolAnalytics
        self.modelManager = modelManager
        self.personalLexicon = personalLexicon ?? PersonalLexicon()
        self.isRescueMode = rescueMode
        self.toolExecutor = ToolExecutor(
            registry: registry,
            damageControlPolicy: damageControlPolicy,
            securityLogger: securityLogger,
            workflowTraceStore: workflowTraceStore,
            toolAnalytics: toolAnalytics,
            daemonIntendedForToolhostRouting: config.llm.useDaemonEngine
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

            // Clear any stale pipeline state from before the restart.
            // The enrollment's speakDirect("Thanks, David") may have set
            // assistantSpeaking without a matching clear (playback completed
            // during the old pipeline loop which is now dead).
            assistantSpeaking = false
            endAssistantGeneration(scheduleDeferredDrain: false)
            interrupted = false
            interruptedGenerationID = nil
            ttsState.cancelPending()
            ttsState.resetForNewTurn()

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

        // Voice spine V3b: daemon-owned playback is now the default, so open
        // the daemon event stream so `audio.level` / `audio.playback_ended`
        // drive the orb + pipeline state. With the kill switch
        // (`FAE_DAEMON_PLAYBACK=0`) we never start it (byte-identical legacy
        // local-playback path).
        if useDaemonPlayback {
            await startDaemonEventSubscriberIfNeeded()
        }

        if let wakeStore = wakeWordProfileStore {
            wakeAliases = await wakeStore.allAliases()
            debugLog(debugConsole, .command, "Wake aliases loaded: \(wakeAliases.joined(separator: ", "))")
        }

        // Load personal vocabulary and build dynamic corrections from known names.
        await personalLexicon.load()
        await rebuildVocabularyCorrections()

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
        markGenerationInterrupted()
        pendingGovernanceAction = nil
        setApprovalState(awaiting: false, manualOnly: false)
        computerUseStepCount = 0
        bargeInState.generationTakeoverCandidate = nil
        endAssistantGeneration(scheduleDeferredDrain: false)

        // Ensure any in-flight TTS synthesis task fully exits before teardown.
        let activeTTSTask = ttsState.pendingTask
        ttsState.pendingTask = nil
        activeTTSTask?.cancel()
        await activeTTSTask?.value

        pipelineTask?.cancel()
        pipelineTask = nil
        cancelDeferredToolJobs()
        await closeConversationSessionIfNeeded(reason: "pipeline_stop")
        await abandonAllWorkflowTraces(reason: "Pipeline stopped before workflow completion.")
        await capture.stopCapture()
        await stopAssistantPlaybackForInterrupt()
        // Voice spine V3b: close the daemon event stream on teardown (flag-ON).
        eventSubscriber?.stop()
        eventSubscriber = nil
        // The subscriber is gone, so no `audio.playback_ended` can arrive to
        // clear a live playback id — clear it here so a future turn isn't
        // stranded waiting the full drain timeout.
        currentDaemonPlaybackID = nil
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
        bargeInState.generationTakeoverCandidate = nil

        let activeTTSTask = ttsState.pendingTask
        ttsState.pendingTask = nil
        activeTTSTask?.cancel()
        if let activeTTSTask {
            Task { await activeTTSTask.value }
        }

        Task { [weak self] in
            await self?.stopAssistantPlaybackForInterrupt()
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
        setApprovalState(awaiting: false, manualOnly: false)
        computerUseStepCount = 0
        bargeInState.generationTakeoverCandidate = nil

        // Cancel and drain the entire TTS task chain. This prevents stale
        // isFinal chunks from prior generations interfering with new turns.
        ttsState.cancelPending()
        let activeTTSTask = ttsState.pendingTask
        ttsState.pendingTask = nil
        activeTTSTask?.cancel()
        await activeTTSTask?.value
        ttsState.resetForNewTurn()

        cancelDeferredToolJobs()
        await stopAssistantPlaybackForInterrupt()
        assistantSpeaking = false
        lastAssistantStart = nil
        echoSuppressor.reset()
        // Ensure generation state is cleared so the pipeline accepts new injections after reset.
        setApprovalState(awaiting: false, manualOnly: false)
        endAssistantGeneration(scheduleDeferredDrain: false)
        await abandonAllWorkflowTraces(reason: "Generation cancelled before workflow completion.")
        NSLog("PipelineCoordinator: cancelAndWait complete")
    }

    /// Hot-swap the personal LoRA adapter overlay on the running LLM engine.
    ///
    /// Called by `FaeCore.patchConfig` when `training.personal_adapter_path`
    /// changes, and by the improvement cycle's adapter-deploy/rollback callback
    /// (P3/C3, wired in `FaeScheduler`).
    ///
    /// Routing is polymorphic via `LLMEngine.swapAdapter`:
    /// - **Daemon lane** (`DaemonLLMEngine`): `path` is a GGUF — the engine
    ///   `engine.reload`s the llama.cpp sidecar and sets scale 1.0; `nil` flips
    ///   scale to 0.0 (instant rollback) then reloads base.
    /// - **MLX lane**: hot-swaps the adapter directory (resets the KV cache after
    ///   the swap, no effect on the current turn — applies from the next turn).
    ///
    /// Safe during idle; if generation is in progress the swap runs immediately.
    ///
    /// - Parameter path: Daemon GGUF / MLX adapter directory, or `nil` to unload.
    func applyAdapterChange(path: String?) async {
        let url = path.map { URL(fileURLWithPath: $0) }
        do {
            try await llmEngine.swapAdapter(to: url)
            if let path {
                NSLog("PipelineCoordinator: personal adapter loaded from '%@'", path)
            } else {
                NSLog("PipelineCoordinator: personal adapter unloaded — base model active")
            }
            eventBus.send(.runtimeProgress(stage: "adapter_changed", progress: 1.0))
        } catch {
            NSLog("PipelineCoordinator: adapter swap failed — %@", error.localizedDescription)
            eventBus.send(.runtimeProgress(stage: "adapter_change_failed", progress: 0.0))
        }
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
            // Text injection is always a deliberate user action — always wake.
            // Direct-address gating only applies to VOICE input (ambient conversation
            // filtering). Typed/injected text should never be silently dropped.
            wake()
        }

        // If assistant is active, trigger barge-in. Silent background generations
        // do not light the orb, but typed user input still supersedes them.
        if assistantSpeaking || assistantGenerating || assistantGenerationTracker.hasActiveGeneration {
            markGenerationInterrupted()
            await stopAssistantPlaybackForInterrupt()
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

    /// Inject text from a desktop text surface (input bar, local runtime server).
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

    /// Speak text via TTS while keeping barge-in active.
    ///
    /// Unlike `speakDirect`, barge-in is NOT suppressed so the user can interrupt
    /// mid-narration. Used for post-action narration where interrupting triggers undo.
    func speakInterruptible(_ text: String) async {
        await speakText(text, isFinal: true)
    }

    /// Set/clear the first-owner enrollment active flag.
    func setFirstOwnerEnrollmentActive(_ active: Bool) {
        speakerGate.firstOwnerEnrollmentActive = active
        // Clear any deny cooldown from pre-enrollment barge-in attempts.
        bargeInState.denyCooldownUntil = nil
        vad.reset()
    }

    /// Register a callback fired on each user-initiated turn.
    func setUserInteractionHandler(_ handler: @escaping @Sendable () async -> Void) {
        userInteractionHandler = handler
    }

    /// Register a callback fired after proactive camera observations.
    func setProactivePresenceHandler(_ handler: @escaping @Sendable (Bool) async -> Void) {
        proactivePresenceHandler = handler
    }

    /// Register a callback for progressive visual identity updates.
    ///
    /// Called when the camera detects the owner during a presence check,
    /// providing the VLM's description of what it sees for progressive
    /// photo and description updates.
    func setProactiveVisualUpdateHandler(_ handler: @escaping @Sendable (String) async -> Void) {
        proactiveVisualUpdateHandler = handler
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

        // Defer proactive tasks when:
        // 1. Assistant is generating or speaking
        // 2. User is in an active conversation (spoke recently)
        // This preserves GPU for responsive voice interaction.
        let recentConversation = await conversationState.lastAssistantMessageAt
            .map { Date().timeIntervalSince($0) < 30 } ?? false
        guard !assistantGenerationTracker.hasActiveGeneration, !assistantSpeaking else {
            enqueueDeferredProactiveRequest(request)
            NSLog("PipelineCoordinator: proactive query deferred — assistant busy")
            return
        }
        if recentConversation, request.silent {
            // Silent proactive tasks can wait — don't steal GPU during conversation
            enqueueDeferredProactiveRequest(request)
            NSLog("PipelineCoordinator: silent proactive query deferred — active conversation")
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
            proactiveContext: proactiveContext,
            playsThinkingTone: !request.silent,
            allowsAudibleOutput: !request.silent
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
        guard !assistantGenerationTracker.hasActiveGeneration,
              !assistantSpeaking,
              !deferredProactiveRequests.isEmpty
        else { return }
        Task { await drainDeferredProactiveIfIdle() }
    }

    private func drainDeferredProactiveIfIdle() async {
        guard !assistantGenerationTracker.hasActiveGeneration,
              !assistantSpeaking,
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
    /// S18: rides the daemon audio lane — the clip is WAV-encoded and attached
    /// to the next turn exactly like a push-to-talk capture.
    func injectAudio(samples: [Float], sampleRate: Int = 16_000) async {
        guard !samples.isEmpty else { return }
        let sr = max(sampleRate, 1)
        let wav = WAVEncoder.encode(samples: samples, sampleRate: sr)
        pendingPTTAudioBase64 = wav.base64EncodedString()
        speakerGate.currentSpeakerLabel = "owner"
        speakerGate.currentSpeakerDisplayName = await speakerProfileStore?.ownerDisplayName() ?? "Owner"
        speakerGate.currentSpeakerRole = .owner
        speakerGate.currentSpeakerIsOwner = true
        speakerGate.currentSpeakerIsKnownNonOwner = false
        speakerGate.currentUtteranceTimestamp = Date()
        if gateState == .idle {
            wake()
        }
        await processTranscription(
            text: Self.pttPlaceholderUserText,
            wakeMatch: nil,
            rms: nil,
            durationSecs: Float(samples.count) / Float(sr),
            turnSource: .voice
        )
    }

    /// Reset conversation history (for test harness use).
    func resetConversation() async {
        sleep()
        currentTurnGenerationContext = nil
        engagedUntil = nil
        lastAssistantResponseText = ""

        setApprovalState(awaiting: false, manualOnly: false)
        endAssistantGeneration(scheduleDeferredDrain: false)
        pendingGovernanceAction = nil
        computerUseStepCount = 0
        ttsState.cancelPending()
        cancelDeferredToolJobs()
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
        vad.reset()
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
        if assistantSpeaking || assistantGenerating || assistantGenerationTracker.hasActiveGeneration {
            markGenerationInterrupted()
            Task { await stopAssistantPlaybackForInterrupt() }
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

        // Reset accumulated adaptive state to prevent the pipeline from going
        // "deaf" after long sessions — VAD silence EMA, noise floor, echo
        // suppressor baseline, and wake detector all accumulate over hours.
        vad.resetAdaptiveState()
        vad.reset()
        echoSuppressor.reset()
        echoSuppressor.resetPlaybackBaseline()

        NSLog("PipelineCoordinator: gate → idle (idle timeout %ds, adaptive state reset)", seconds)
        await closeConversationSessionIfNeeded(reason: "idle_timeout")
    }

    private func effectiveVisionEnabled() -> Bool {
        visionEnabledLive ?? config.vision.enabled
    }

    private func effectiveVoiceIdentityLock() -> Bool {
        voiceIdentityLockLive ?? config.tts.voiceIdentityLock
    }

    static func normalizeForPhraseMatch(_ text: String) -> String {
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

        // Ingest PersonalLexicon entries on top of the standard vocabulary sources.
        let lexiconSnapshot = await personalLexicon.snapshot()
        await vocabularyCorrector.ingestLexicon(lexiconSnapshot)
    }

    private func resetConversationSession(trigger: String, source: String) async {
        // Stop any active speech/generation immediately.
        if assistantSpeaking || assistantGenerating || assistantGenerationTracker.hasActiveGeneration {
            markGenerationInterrupted()
            await stopAssistantPlaybackForInterrupt()
        }
        sleep(requireExplicitWake: true)
        currentTurnGenerationContext = nil
        engagedUntil = nil
        lastAssistantResponseText = ""
        bargeInState.generationTakeoverCandidate = nil
        bargeInState.falseInterruptionRecovery.cancel()

        setApprovalState(awaiting: false, manualOnly: false)
        endAssistantGeneration(scheduleDeferredDrain: false)
        pendingGovernanceAction = nil
        computerUseStepCount = 0
        ttsState.cancelPending()
        cancelDeferredToolJobs()
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

    static func workflowTraceSignature(for toolSequence: [String]) -> String? {
        let normalized = toolSequence
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return nil }
        return normalized.joined(separator: " -> ")
    }

    // MARK: - Main Pipeline Loop

    private func runPipelineLoop(stream: AsyncStream<AudioChunk>) async {
        NSLog("PipelineCoordinator: pipeline loop STARTED")
        for await chunk in stream {
            guard !Task.isCancelled else {
                NSLog("PipelineCoordinator: pipeline loop EXITING (task cancelled)")
                break
            }

            // S18 push-to-talk: deliberate capture (orb click / hotkey) is the
            // ONLY audio entry. While capturing, chunks feed the PTT buffer and
            // VAD acts as a plain endpointer. Outside a capture, mic chunks are
            // dropped — there is no always-on listening lane.
            if pttCapturing {
                await handlePTTChunk(chunk)
            }
        }
        NSLog("PipelineCoordinator: pipeline loop EXITED (stream ended)")
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
        if assistantSpeaking {
            markGenerationInterrupted()
            ttsState.cancelPending()
            await stopAssistantPlaybackForInterrupt()
        } else if assistantGenerating {
            // Silent generation in progress. Post-S18 every turn reaching here
            // is a DELIBERATE act (PTT capture or typed text) — dropping it
            // made "press, speak, release → nothing" the single most confusing
            // failure in owner testing. The user's new input wins: interrupt
            // the stale turn and proceed. (Proactive queries never preempt —
            // they queue via the deferred-proactive path.)
            guard proactiveContext == nil else { return }
            debugLog(debugConsole, .pipeline, "User turn takeover — interrupting in-flight generation")
            markGenerationInterrupted()
            endAssistantGeneration()
        } else if assistantGenerationTracker.hasActiveGeneration {
            // Silent/background generation in progress. It intentionally does
            // not drive assistantGenerating, but deliberate user input still
            // supersedes it and becomes the active token stream owner.
            guard proactiveContext == nil else { return }
            debugLog(debugConsole, .pipeline, "User turn takeover — interrupting silent background generation")
            markGenerationInterrupted()
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

        let generationID = beginAssistantGeneration(visibility: .visible)
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
            let captureReport = await memoryOrchestrator?.capture(
                turnId: turnId,
                userText: originalUserText,
                assistantText: responseText,
                speakerId: speakerGate.currentSpeakerLabel,
                utteranceTimestamp: speakerGate.currentUtteranceTimestamp
            )
            if captureReport?.failedExplicitCommand == true {
                debugLog(
                    debugConsole,
                    .memory,
                    "WARNING: explicit remember/forget command failed to persist for turn \(turnId) — the user was told it was remembered but it was not"
                )
            }
            await capturePendingCorrection()
        }

        endAssistantGeneration(for: generationID)
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

    static func detectExplicitUserAuthorization(in text: String) -> Bool {
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

        // Feed name corrections into DynamicVocabularyCorrector and PersonalLexicon.
        if record.correction.kind == .nameError,
           let correct = record.correction.correctedValue
        {
            let wrong = record.correction.originalValue
            await vocabularyCorrector.addCorrectionPair(
                wrong: wrong,
                correct: correct
            )
            let variants = wrong.map { [$0] } ?? []
            await personalLexicon.upsert(canonical: correct, variants: variants, source: "correction")
            await personalLexicon.save()
            debugLog(debugConsole, .pipeline, "Fed name correction to vocabulary corrector + lexicon: \(correct)")
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
        // Allow enough tool turns for thorough multi-step queries.
        // A web search chain alone can use 4-5 turns (search → fetch → fetch → search → summarize).
        // Previously capped at 5, which killed multi-tool chains.
        let maxToolTurns = tillDoneListActive ? 25 : 10

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
            generationID = beginAssistantGeneration(
                visibility: generationVisibility(
                    proactiveContext: proactiveContext,
                    playsThinkingTone: playsThinkingTone,
                    allowsAudibleOutput: allowsAudibleOutput
                )
            )
            debugLog(debugConsole, .pipeline, "Generation started id=\(generationID.uuidString.prefix(8))")
        }

        // Reset computer-use step counter and duplicate-tool guard at the start of each user turn.
        if !isToolFollowUp {
            computerUseStepCount = 0
            seenToolCallSignatures = []
            seenToolCallResults = [:]
            pruneUnusedWorkflowTraceContexts(keeping: currentTurnID)
            prepareWorkflowTraceContextIfNeeded(
                turnID: currentTurnID,
                userGoal: userText,
                proactiveContext: proactiveContext,
                turnSource: turnSource
            )
        }

        await refreshDegradedModeIfNeeded(context: "before_generation")

        // Previous turn's final reply — stashed before this turn clears
        // lastAssistantResponseText, so CorrectionDetector has the right
        // context when the [heard] transcript arrives mid-generation.
        let previousAssistantTextForCorrection = lastAssistantResponseText

        // S18 audio turn: the pending PTT clip is consumed by this turn's
        // FIRST request only — tool follow-ups resend history as plain text.
        // The [heard] transcript captured during streaming replaces the
        // placeholder user text in history, transcript and memory capture.
        let pttAudioForTurn: String?
        if !isToolFollowUp, let pending = pendingPTTAudioBase64 {
            pttAudioForTurn = pending
            pendingPTTAudioBase64 = nil
            pttHeardTranscriptForTurn = nil
        } else {
            pttAudioForTurn = nil
            // Clear any stale [heard] transcript from a PRIOR turn at the start
            // of a fresh non-tool-follow-up turn that carries no PTT audio (e.g.
            // a typed turn). Otherwise turn-final paths that skip the capture
            // block (LLM-failure fallback, tool-repair early returns, non-
            // conversational skip, suppressed output) leave it set, and this
            // typed turn's memory capture would store the previous turn's
            // spoken transcript as this turn's user text. Tool follow-ups MUST
            // preserve it — the [heard] must survive the tool round-trip within
            // the same turn — so only clear when !isToolFollowUp.
            if !isToolFollowUp {
                pttHeardTranscriptForTurn = nil
            }
        }

        let generationContext: GenerationContext
        if !isToolFollowUp {
            debugLog(debugConsole, .qa, "=== TURN START user=\(userText.prefix(160)) ===")
            interrupted = false
            interruptedGenerationID = nil
            // Ensure no stale TTS tasks from a previous turn can block this one.
            ttsState.cancelPending()
            lastAssistantResponseText = ""

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
            if proactiveContext == nil, pttAudioForTurn == nil {
                // Audio turns persist once the [heard] transcription arrives —
                // the placeholder never reaches the session store.
                await persistAcceptedUserTurnIfNeeded(userText)
            }

            if proactiveContext == nil,
               let forgetReply = await memoryOrchestrator?.handleForgetCommandIfNeeded(userText: userText)
            {
                sendAssistantText(forgetReply, isFinal: true)
                if allowsAudibleOutput {
                    await speakText(forgetReply, isFinal: true, emitAssistantText: false)
                }
                await conversationState.addAssistantMessage(
                    forgetReply,
                    tag: proactiveContext?.conversationTag
                )
                await persistFinalAssistantTurnIfNeeded(forgetReply)
                endAssistantGeneration(for: generationID)
                engage()
        
                debugLog(debugConsole, .qa, "=== TURN END deterministic_forget ===")
                return
            }

            if proactiveContext == nil,
               let directRecallReply = await memoryOrchestrator?.handleDirectPersonalRecallIfNeeded(userText: userText)
            {
                sendAssistantText(directRecallReply, isFinal: true)
                if allowsAudibleOutput {
                    // emitAssistantText: false — sendAssistantText already fired above.
                    // Without this, the UI receives two isFinal events → duplicate message.
                    await speakText(directRecallReply, isFinal: true, emitAssistantText: false)
                }
                await conversationState.addAssistantMessage(
                    directRecallReply,
                    tag: proactiveContext?.conversationTag
                )
                await persistFinalAssistantTurnIfNeeded(directRecallReply)
                endAssistantGeneration(for: generationID)
                engage()
        
                debugLog(debugConsole, .qa, "=== TURN END deterministic_personal_recall ===")
                return
            }

            let toolMode = effectiveToolMode()
            let privacyMode = effectivePrivacyMode()

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

            // Build system prompt with tool schemas. A deliberate physical act
            // at the machine (push-to-talk click, typed text) marks the turn's
            // speaker as the owner — that satisfies the owner requirement
            // without a voiceprint (S18: enrollment is no longer the gate).
            let ownerProfileExists = await speakerProfileStore?.hasOwnerProfile() ?? false
            let ownerEnrollmentRequired = config.speaker.requireOwnerForTools
                && !ownerProfileExists
                && !speakerGate.currentSpeakerIsOwner
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
            let indexedToolNames: Set<String>? = speakerGate.firstOwnerEnrollmentActive
                ? []
                : proactiveContext?.allowedTools
            let recentlyUsedTools = isRecentContinuation
                ? await conversationState.recentToolNames(within: continuationWindowSeconds)
                : []
            let fullSchemaToolNames = TurnHelpers.fullSchemaToolNamesForTurn(
                firstOwnerEnrollmentActive: speakerGate.firstOwnerEnrollmentActive,
                userText: userText,
                availableToolNames: registry.toolNames,
                proactiveAllowedTools: proactiveContext?.allowedTools,
                isConversationContinuation: isRecentContinuation,
                recentlyUsedTools: recentlyUsedTools
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
            // Build native tool specs for MLX/daemon tool calling. The prompt
            // still carries a compact index of the allowed tool surface, but
            // full JSON schemas are limited to the conservative working set for
            // this turn to reduce prefill and avoid known bad prompt windows.
            let useNativeToolCalling = includeTools && !preferLegacyInlineToolPrompt
            let nativeTools = useNativeToolCalling
                ? registry.nativeToolSpecs(
                    for: toolMode,
                    privacyMode: privacyMode,
                    limitedTo: fullSchemaToolNames
                )
                : nil

            let toolSchemas: String? = {
                guard includeTools else { return nil }
                if useNativeToolCalling {
                    let compact = registry.compactToolSummary(
                        for: toolMode,
                        privacyMode: privacyMode,
                        limitedTo: indexedToolNames
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
                let indexedCount = registry.allowedToolNames(
                    for: toolMode,
                    privacyMode: privacyMode,
                    limitedTo: indexedToolNames
                ).count
                debugLog(
                    debugConsole,
                    .pipeline,
                    "Tool disclosure: index=\(indexedCount) full_schemas=\(specs.count)"
                )
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

            // Prefix KV-cache is off by default (FAE_PREFIX_CACHE_N), so re-prefilling
            // the full SOUL/HEARTBEAT on every continuation buys nothing — the original
            // "full contract on later turns, KV cache makes it near-instant" assumption
            // no longer holds. Use the condensed character + proactive contracts on every
            // turn: they preserve the load-bearing personality and rules at ~350 / ~120
            // tokens vs ~2,200 / ~570 for the full files. Rescue mode keeps full defaults.
            let soul = isRescueMode
                ? SoulManager.defaultSoul()
                : SoulManager.loadCondensedSoul()
            let heartbeat = isRescueMode
                ? HeartbeatManager.defaultHeartbeat()
                : HeartbeatManager.condensedHeartbeat()
            // Situational sub-prompts are injected only when this turn's working set
            // actually involves them — vision/computer-use guidance when a vision or
            // automation tool is in play, proactive guidance on proactive turns —
            // rather than on every tool-enabled turn.
            let visionRelevant = fullSchemaToolNames.contains("screenshot")
                || fullSchemaToolNames.contains("camera")
                || fullSchemaToolNames.contains("read_screen")
            let computerUseRelevant = fullSchemaToolNames.contains("click")
                || fullSchemaToolNames.contains("type_text")
                || fullSchemaToolNames.contains("scroll")
                || fullSchemaToolNames.contains("find_element")
            let proactiveRelevant = proactiveContext != nil
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
                lightweight: config.isLightweightContext,
                includeVisionGuidance: visionRelevant,
                includeComputerUseGuidance: computerUseRelevant,
                includeProactiveGuidance: proactiveRelevant
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
        } else if let providedGenerationContext {
            generationContext = providedGenerationContext
        } else if let currentTurnGenerationContext {
            generationContext = currentTurnGenerationContext
        } else {
            // No generation context available (should not happen on a tool
            // follow-up). End the generation so it does not leak in
            // AssistantGenerationTracker and the orb can leave Thinking.
            NSLog("PipelineCoordinator: no generation context — ending generation id=%@", generationID.uuidString)
            endAssistantGeneration(for: generationID)
            engage()
            return
        }

        var systemPrompt = generationContext.systemPrompt
        if pttAudioForTurn != nil {
            // S18 audio turn: the [heard] contract lives in the system prompt
            // ONLY — any text on the audio user message out-competes the audio.
            systemPrompt += "\n\n" + Self.pttHeardInstruction
        }
        let baseTurnContextPrefix = generationContext.turnContextPrefix ?? ""
        let history = await conversationState.history
        // Phase G2: the pinned summary of turns already evicted from `history`.
        // Sent alongside the kept window so the model keeps long-horizon context;
        // the covered turns are already excluded (they were trimmed). `nil` until
        // the first compaction, and only the daemon lane honours it.
        let pinnedSummary = await conversationState.pinnedSummary

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
            prefillStepSize: prefillStep,
            audioWAVBase64: pttAudioForTurn,
            pinnedSummary: pinnedSummary
        )

        // Cache options for speculative prefill on next turn. The audio clip
        // is strictly this turn's payload — never cached or replayed.
        // Stream tokens.
        thinkTagStripper = TextProcessing.ThinkTagStripper()
        voiceTagStripper = VoiceTagStripper()
        let roleplayActive = await RoleplaySessionStore.shared.isActive
        var roleplayChunker = RoleplaySpeechChunker()
        var fullResponse = ""
        var sentenceBuffer = ""
        var detectedToolCall = false
        // S18 audio turn: the first text of the reply carries the `[heard]:`
        // transcription line (the daemon delivers the whole turn in one text
        // event). It becomes the user transcript and is never spoken.
        var pttAwaitingHeard = pttAudioForTurn != nil
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
            // Emit the deterministic LLM-failure fallback so the user hears a
            // response instead of silence, and end the generation so it does
            // not leak in AssistantGenerationTracker (orb stuck Thinking).
            if let fallback = Self.llmFailureFallbackMessage(
                firstOwnerEnrollmentActive: speakerGate.firstOwnerEnrollmentActive,
                proactiveContextPresent: proactiveContext != nil
            ) {
                sendAssistantText(fallback, isFinal: true)
                if generationContext.allowsAudibleOutput {
                    recordSpokenText(fallback)
                    enqueueTTS(fallback, isFinal: true, generationID: generationID)
                }
                await awaitPendingTTS()
                await conversationState.addAssistantMessage(fallback, tag: proactiveContext?.conversationTag)
                await persistFinalAssistantTurnIfNeeded(fallback)
            }
            endAssistantGeneration(for: generationID)
            engage()
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
                    // Normalize tool name: smaller models sometimes emit
                    // "reminders=create" instead of "reminders" with action
                    // as a separate parameter. Strip the =action suffix.
                    var toolName = nativeCall.function.name
                    if let eqRange = toolName.range(of: "=") {
                        toolName = String(toolName[..<eqRange.lowerBound])
                    }
                    streamedToolCalls.append(
                        ToolCall(
                            name: toolName,
                            arguments: nativeCall.function.arguments.mapValues { $0.anyValue }
                        )
                    )
                    deferredSentenceQueue = []
                    sentenceBuffer = ""
                    continue

                case .text(let rawToken):
                    var token = rawToken
                    llmTokenCount += 1
                    if firstTokenAt == nil {
                        firstTokenAt = Date()
                        await instrumentation.markLLMFirstToken(
                            latencyMs: Date().timeIntervalSince(llmStartedAt) * 1000
                        )
                    }

                    if pttAwaitingHeard {
                        // The daemon lane is non-streaming: this event holds the
                        // complete reply, so the [heard] line is fully present.
                        pttAwaitingHeard = false
                        let split = HeardLineParser.split(token)
                        if let rawTranscript = split.heard {
                            // Post-ASR vocabulary correction (S18): static "Fae"
                            // garble fixes first, then dynamic corrections from
                            // the user's known vocabulary (names, entities).
                            var transcript = TextProcessing.correctNameRecognition(rawTranscript)
                            transcript = await vocabularyCorrector.correct(transcript)
                            pttHeardTranscriptForTurn = transcript
                            await conversationState.updateLastUserMessage(
                                transcript,
                                speakerDisplayName: speakerGate.currentSpeakerDisplayName,
                                speakerId: speakerGate.currentSpeakerLabel
                            )
                            eventBus.send(.transcription(text: transcript, isFinal: true))
                            if proactiveContext == nil {
                                await persistAcceptedUserTurnIfNeeded(transcript)
                                // "My name is X not Y" corrections — feed memory
                                // + the vocabulary corrector at end of turn.
                                if let correction = CorrectionDetector.detect(
                                    in: transcript,
                                    lastAssistantText: previousAssistantTextForCorrection
                                ) {
                                    pendingCorrection = CorrectionRecord(
                                        correction: correction,
                                        lastAssistantText: previousAssistantTextForCorrection.isEmpty
                                            ? nil : previousAssistantTextForCorrection,
                                        speakerLabel: speakerGate.currentSpeakerLabel,
                                        timestamp: Date()
                                    )
                                    debugLog(debugConsole, .pipeline, "Correction detected in [heard]: \(correction.kind.rawValue)")
                                }
                            }
                            debugLog(debugConsole, .pipeline, "PTT [heard]: \(transcript)")
                        } else {
                            pttHeardTranscriptForTurn = Self.pttPlaceholderUserText
                            debugLog(debugConsole, .pipeline, "⚠️ PTT reply missing [heard] line")
                        }
                        // Tool-call markup leaked into the text channel is
                        // never speakable; the structured calls drive tools.
                        token = HeardLineParser.stripToolCallResidue(split.remainder)
                        if token.isEmpty { continue }
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

        // Phase G2: the turn's generation is done (past ttfa) — fold any turns
        // evicted from the kept window into the pinned summary off the hot path.
        // Fire-and-forget: never blocks this turn or the next; a failure is logged
        // loudly and retried, never dropped silently.
        scheduleConversationCompaction()

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
                    explicitUserAuthorization: explicitUserAuthorizationForTurn,
                    generationContext: generationContext,
                    originTurnID: currentTurnID
                )

                endAssistantGeneration(for: generationID)
                engage()
        
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
                    && !speakerGate.currentSpeakerIsOwner

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
                    // S18 audio turns: memory records what the user actually
                    // said (the [heard] transcription), not the placeholder.
                    let captureReport = await memoryOrchestrator?.capture(
                        turnId: turnId,
                        userText: pttHeardTranscriptForTurn ?? userText,
                        assistantText: assistantTextForStorage,
                        speakerId: speakerGate.currentSpeakerLabel,
                        utteranceTimestamp: speakerGate.currentUtteranceTimestamp
                    )
                    // Degraded signal: an explicit "remember"/"forget" command
                    // failed to persist even though Fae may have confirmed it.
                    // Surface it loudly rather than swallowing the failure.
                    if captureReport?.failedExplicitCommand == true {
                        debugLog(
                            debugConsole,
                            .memory,
                            "WARNING: explicit remember/forget command failed to persist for turn \(turnId) — the user was told it was remembered but it was not"
                        )
                    }
                    pttHeardTranscriptForTurn = nil
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
                explicitUserAuthorization: explicitUserAuthorizationForTurn,
                generationContext: generationContext,
                originTurnID: currentTurnID
            )

            endAssistantGeneration(for: generationID)
            engage()

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
        var duplicateErrorCount = 0
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
            var isDuplicateError = false
            if seenToolCallSignatures.contains(callSignature),
               let cached = seenToolCallResults[callSignature] {
                // Return the ACTUAL cached result so the LLM has real data.
                // Previously returned a "you already retrieved" notice which
                // forced the model to hallucinate content.
                debugLog(debugConsole, .toolCall, "⚠️ Duplicate tool call: \(call.name) — returning cached result")
                isDuplicateError = cached.isError
                if isDuplicateError {
                    // Append guidance so the LLM tries a different approach instead
                    // of looping on the exact same failing call.
                    result = .error(
                        cached.output
                        + "\n\n[This exact command already failed. Do NOT repeat it."
                        + " Try a completely different approach, different arguments,"
                        + " or tell the user what went wrong.]"
                    )
                } else {
                    result = cached
                }
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
                    explicitUserAuthorizationOverride: explicitAuthorizationForToolTurn,
                    proactiveContext: proactiveContext,
                    generationContextOverride: generationContext,
                    traceTurnID: currentTurnID,
                    traceToolCallID: callId
                )
                seenToolCallResults[callSignature] = result
            }
            if call.name == "camera", proactiveContext?.taskId == "camera_presence_check", !result.isError {
                let userPresent = Self.inferUserPresentFromCameraOutput(result.output)
                await proactivePresenceHandler?(userPresent)
                // Progressive visual identity: when user is present, provide the
                // camera description for potential reference photo refresh.
                if userPresent {
                    await proactiveVisualUpdateHandler?(result.output)
                }
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
                if isDuplicateError { duplicateErrorCount += 1 }
                if firstToolError == nil {
                    firstToolError = result.output
                }
            } else {
                toolSuccessCount += 1
                if let reply = Self.directToolReplyText(for: call, result: result) {
                    if directToolReply == nil {
                        directToolReply = reply
                    } else {
                        directToolReply = directToolReply! + "\n" + reply
                    }
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

        // TillDone: clean up nudge history when the workflow ends.
        let tillDoneListStillActive = await TillDoneManager.shared.isListActive
        if tillDoneListStillActive, await TillDoneManager.shared.allDone {
            await conversationState.removeMessages(taggedWith: "tilldone_nudge")
        } else if !tillDoneListStillActive {
            // List was cleared mid-conversation — remove any leftover nudge messages.
            await conversationState.removeMessages(taggedWith: "tilldone_nudge")
        }

        if toolFailureCount > 0 && toolSuccessCount == 0 {
            // Distinguish unrecoverable denials from recoverable tool errors.
            // Preflight denials (tool blocked by mode/policy) can't be retried.
            // Duplicate errors get guidance injected ("try a different approach")
            // so the LLM can be creative, but we still bail after a few turns.
            // Tool execution errors (wrong params, validation) should be fed back
            // to the LLM so it can self-correct with the right arguments.
            let allFailuresAreDenials = preflightDenialCount == toolFailureCount
            let duplicateLoopExhausted = duplicateErrorCount > 0 && turnCount >= 3
            if allFailuresAreDenials || duplicateLoopExhausted || turnCount >= 8 {
                await conversationState.removeMessages(taggedWith: "tilldone_nudge")
                let reason = firstToolError ?? "the tool call was denied or failed"
                let msg = "I couldn't complete that because the required tool didn't run: \(reason)"
                sendAssistantText(msg, isFinal: true)
                if generationContext.allowsAudibleOutput {
                    await speakText(msg, isFinal: true)
                }
                endAssistantGeneration(for: generationID)
                await finalizeWorkflowTraceIfNeeded(turnID: currentTurnID, assistantOutcome: msg, success: false)
        
                return
            }
            // Recoverable tool error — let LLM see the error and retry.
            debugLog(debugConsole, .qa, "Tool error is recoverable (turn \(turnCount)) — feeding back to LLM for self-correction")
        }

        // Use direct reply for single or multi-tool calls when ALL tools
        // produced direct replies. This prevents hallucination on multi-tool
        // chains (calendar + mail + reminders) where the LLM ignores real data.
        if turnCount == 0,
           toolFailureCount == 0,
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

    /// Start tracking an assistant generation.
    ///
    /// The latest generation ID remains the token-stream authority, but only
    /// visible generations drive the orb's Thinking state. Silent background
    /// chores stay tracked so a newer turn can stale them out without lighting
    /// the UI.
    @discardableResult
    private func beginAssistantGeneration(
        id generationID: UUID = UUID(),
        visibility: AssistantGenerationTracker.Visibility
    ) -> UUID {
        assistantGenerationTracker.begin(generationID, visibility: visibility)
        reconcileAssistantGenerating()
        return generationID
    }

    /// Clear a generation-in-progress record.
    ///
    /// When called with a stale `generationID`, only that generation is removed;
    /// a newer visible generation continues to own the Thinking indicator. If no
    /// visible generation remains and no approval is pending, the indicator is
    /// forced back to idle.
    private func endAssistantGeneration(
        for generationID: UUID? = nil,
        scheduleDeferredDrain: Bool = true
    ) {
        assistantGenerationTracker.end(generationID)
        if !assistantGenerationTracker.hasVisibleGeneration {
            bargeInState.generationTakeoverCandidate = nil
        }
        reconcileAssistantGenerating()
        if scheduleDeferredDrain {
            scheduleDeferredProactiveDrain()
        }
    }

    private func generationVisibility(
        proactiveContext: ProactiveRequestContext?,
        playsThinkingTone: Bool,
        allowsAudibleOutput: Bool
    ) -> AssistantGenerationTracker.Visibility {
        if proactiveContext != nil, !playsThinkingTone, !allowsAudibleOutput {
            return .silentBackground
        }
        return .visible
    }

    private func reconcileAssistantGenerating() {
        let shouldShow = assistantGenerationTracker.shouldShowAssistantGenerating(
            awaitingApproval: awaitingApproval
        )
        guard assistantGenerating != shouldShow else { return }
        assistantGenerating = shouldShow
        eventBus.send(.assistantGenerating(shouldShow))
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
                // Silently drop TTS chunks from interrupted (prior) generations.
                // Do NOT clear speaking state — a new generation may already be
                // running and the stale isFinal chunk from the old generation was
                // causing the new generation's follow-up to be flagged as 0-token
                // (because markAssistantSpeechEnded triggered the failure path).
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
            // Do NOT interrupt the current generation — the speech drain is about
            // playback cleanup, not about the LLM. Tool follow-up generations were
            // being killed here because assistantSpeaking was still true from the
            // first turn's "Let me check that for you" TTS.
            await stopAssistantPlaybackForInterrupt()
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

        // Voice spine V3b (FAE_DAEMON_PLAYBACK, default-on since 2026-06-17):
        // synthesize + play in the daemon. Returns immediately with a playback
        // id; the level envelope + playback-end arrive as server-push events
        // (`handleDaemonPlaybackEvent`). No local enqueue/markEnd — the daemon
        // owns playback, so there is no dual audio stream. When the daemon path
        // is requested but unavailable (e.g. the MLX in-process TTS lane is
        // selected, or the event subscriber failed to start) we fall through to
        // the local Swift path below AND log loudly (once) that the orb will
        // not show Speaking on that fallback.
        if daemonPlaybackActive, let daemon = ttsEngine as? DaemonTTSEngine {
            // Serialize segments: wait for any in-flight daemon playback to end
            // before starting the next (otherwise clips overlap — the daemon's
            // play_start is non-blocking). Bounded; a missing end-event falls
            // through to the speech-drain watchdog.
            await awaitDaemonPlaybackDrained(timeoutMs: 30_000)
            do {
                let playbackID = try await daemon.speak(
                    text: text, voiceInstruct: effectiveVoiceInstruct, speed: config.tts.speed)
                if let playbackID {
                    currentDaemonPlaybackID = playbackID
                    didProduceAudio = true
                }
                // `audio.playback_ended` resolves speech-end for the final
                // chunk; for a non-final sentence there is no markEnd analogue
                // (the daemon plays it through). If synthesis produced nothing,
                // fall through to the no-audio handling below.
                if isFinal && !didProduceAudio && assistantSpeaking {
                    markAssistantSpeechEnded(reason: "tts_final_no_audio")
                }
            } catch {
                NSLog("PipelineCoordinator: daemon tts.speak failed: %@", error.localizedDescription)
                markAssistantSpeechEnded(reason: "tts_error")
            }
            return
        }

        // We wanted daemon-owned playback (default-on) but it is not active at
        // runtime — loudly note the fallback so the no-Speaking orb is
        // diagnosable, then continue on the local Swift playback path.
        logDaemonPlaybackFallbackIfNeeded()

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
            await stopAssistantPlaybackForInterrupt()
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

    private func markGenerationInterrupted(file: String = #file, line: Int = #line) {
        interrupted = true
        interruptedGenerationID = activeGenerationID
        let caller = URL(fileURLWithPath: file).lastPathComponent
        NSLog("PipelineCoordinator: markGenerationInterrupted() called from %@:%d", caller, line)
    }

    private func isGenerationInterrupted(_ generationID: UUID?) -> Bool {
        guard interrupted else { return false }
        guard let generationID else { return true }
        if let interruptedGenerationID {
            return interruptedGenerationID == generationID
        }
        return true
    }

    // MARK: - Playback Events

    // MARK: - Voice spine V3b (FAE_DAEMON_PLAYBACK) helpers

    /// `FAE_DAEMON_PLAYBACK` is **DEFAULT ON** (V3b cutover, 2026-06-17). It is
    /// an opt-OUT kill switch: set it to `0/false/off/no` (case-insensitive) to
    /// restore the legacy local Swift playback path (`tts.synthesize` +
    /// `AudioPlaybackManager`). Any other value (including UNSET) → ON.
    ///
    /// Why default-on: the orb host now derives Speaking from daemon
    /// `audio.level` events (orb-host-owns-state, commit 908485a3), which are
    /// emitted ONLY by daemon-owned playback (`tts.speak`). On the old default
    /// lane the daemon emits no levels, so the orb shows no Speaking. Keeping
    /// this default-on is the gate that makes orb-speaking work for
    /// default-config users.
    private static func readDaemonPlaybackFlag() -> Bool {
        let value = ProcessInfo.processInfo.environment["FAE_DAEMON_PLAYBACK"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return !["0", "false", "off", "no"].contains(value)
    }

    // MARK: - Phase G2 conversation compaction

    /// Fire-and-forget trigger for the after-turn pinned-summary fold. Detached so
    /// it never blocks the turn that scheduled it or the next one.
    private func scheduleConversationCompaction() {
        Task { [weak self] in
            await self?.runConversationCompaction()
        }
    }

    /// Fold the previous turn's evicted messages into the pinned summary via the
    /// daemon, off the hot path. Contract: the turn already proceeded on the
    /// hard-truncated window, so this NEVER blocks and NEVER drops context
    /// silently — an unavailable summarizer or a compact failure is logged loudly
    /// and the evicted backlog is retained for a later attempt. Reentrancy-guarded
    /// so overlapping turns cannot double-fold the same backlog.
    private func runConversationCompaction() async {
        guard !compactionInFlight else { return }
        compactionInFlight = true
        defer { compactionInFlight = false }

        guard let work = await conversationState.pendingCompaction() else { return }
        let covered = work.evicted.count
        do {
            guard let summary = try await llmEngine.compactConversation(
                evicted: work.evicted, priorSummary: work.priorSummary)
            else {
                NSLog(
                    "PipelineCoordinator: conversation compaction unavailable — %d evicted turns kept hard-truncated (no daemon summarizer)",
                    covered)
                return
            }
            await conversationState.applyCompactionResult(summary: summary, covered: covered)
            NSLog(
                "PipelineCoordinator: conversation compaction folded %d evicted turns into pinned summary",
                covered)
        } catch {
            NSLog(
                "PipelineCoordinator: conversation compaction failed (%@) — %d evicted turns kept hard-truncated, will retry",
                error.localizedDescription, covered)
        }
    }

    /// Whether the daemon-owned playback path is active RIGHT NOW: the flag is
    /// ON (now the default), the configured TTS engine is the daemon engine
    /// (the in-process MLX lane has no `tts.speak`), AND the event stream is
    /// subscribed (without it, `audio.playback_ended` would never arrive and
    /// strand the speaking state — so we fall back to the local path rather
    /// than risk a hang). When this is false but `useDaemonPlayback` is true,
    /// the orb will NOT show Speaking on the local fallback (the Swift
    /// orb-drive was retired by orb-host-owns-state) — see
    /// `logDaemonPlaybackFallbackIfNeeded()`.
    private var daemonPlaybackActive: Bool {
        useDaemonPlayback && (ttsEngine is DaemonTTSEngine) && eventSubscriber != nil
    }

    /// Loudly log ONCE per distinct reason when daemon-owned playback is
    /// requested (default-on) but can't run, so the local Swift fallback is
    /// taken. On that fallback the daemon emits no `audio.level`, so the orb
    /// shows no Speaking even though she still talks — this log makes that
    /// diagnosable instead of silently looking broken. Called from the TTS
    /// speak site before falling through to the local path.
    private func logDaemonPlaybackFallbackIfNeeded() {
        guard useDaemonPlayback, !daemonPlaybackActive else { return }
        let reason: String
        if !(ttsEngine is DaemonTTSEngine) {
            reason = "tts_engine_not_daemon"
        } else if eventSubscriber == nil {
            reason = "event_subscriber_not_started"
        } else {
            reason = "unknown"
        }
        guard daemonPlaybackFallbackReasonsLogged.insert(reason).inserted else { return }
        NSLog(
            "PipelineCoordinator: daemon-owned playback requested but UNAVAILABLE (reason=%@) — " +
                "falling back to local Swift AudioPlaybackManager. NOTE: the daemon emits no " +
                "audio.level on this path, so the orb will NOT show Speaking even though TTS " +
                "plays. To restore the daemon-owned path check the daemon TTS engine and event " +
                "subscriber. Set FAE_DAEMON_PLAYBACK=0 to silence this if the local path is intended.",
            reason)
    }

    /// Tear down the current daemon event subscriber (its read loop is bound to
    /// the dead daemon's socket) and reopen it against the revived daemon's new
    /// endpoints. Called by `FaeCore` after a supervised daemon restart —
    /// `startDaemonEventSubscriberIfNeeded` alone would no-op because
    /// `eventSubscriber` is still non-nil. Reads the ttsEngine's (just-updated)
    /// endpoints, so the reconnected engine must be retargeted first.
    func restartDaemonEventSubscriber() async {
        eventSubscriber?.stop()
        eventSubscriber = nil
        // No `audio.playback_ended` can arrive across the reconnect gap; clear
        // any live id so the next segment doesn't eat the full drain timeout.
        currentDaemonPlaybackID = nil
        await startDaemonEventSubscriberIfNeeded()
    }

    /// Open the daemon event-subscribe connection (once) and route
    /// `audio.level` / `audio.playback_ended` into the existing playback-event
    /// path. No-op if already started or if the daemon endpoints are missing.
    private func startDaemonEventSubscriberIfNeeded() async {
        guard eventSubscriber == nil,
              let daemon = ttsEngine as? DaemonTTSEngine
        else { return }
        // DEV/TEST HOOK (not shipped behavior): force the daemon-owned playback
        // FALLBACK so the local Swift path + its loud log can be exercised
        // deterministically without racing startup. Leaves useDaemonPlayback
        // true and ttsEngine a DaemonTTSEngine, but keeps eventSubscriber nil →
        // daemonPlaybackActive is false → local playback + the
        // `event_subscriber_not_started` fallback log. Only active under
        // FAE_DEV=1 + FAE_DEV_SKIP_DAEMON_EVENT_SUBSCRIBER=1.
        let env = ProcessInfo.processInfo.environment
        if env["FAE_DEV"] == "1",
           env["FAE_DEV_SKIP_DAEMON_EVENT_SUBSCRIBER"] == "1" {
            NSLog(
                "PipelineCoordinator: DEV_TEST skipping daemon event subscriber " +
                    "(FAE_DEV_SKIP_DAEMON_EVENT_SUBSCRIBER=1); daemon playback fallback " +
                    "will use local Swift AudioPlaybackManager")
            return
        }
        let endpoints = await daemon.endpoints
        let deliveryQueue = DispatchQueue(label: "fae.daemon-events.delivery")
        let subscriber = DaemonEventSubscriber(
            socketPath: endpoints.socketPath,
            tokenPath: endpoints.tokenPath,
            deliveryQueue: deliveryQueue
        ) { [weak self] event in
            Task { await self?.handleDaemonPlaybackEvent(event) }
        }
        do {
            try await subscriber.start()
            eventSubscriber = subscriber
            NSLog("PipelineCoordinator: daemon event stream subscribed (V3b)")
        } catch {
            NSLog(
                "PipelineCoordinator: daemon event subscribe failed (%@) — flag-ON without levels",
                error.localizedDescription)
        }
    }

    /// Route a daemon server-push event into the pipeline. `audio.level` reuses
    /// the local playback-level path (orb motion + TTFA); `audio.playback_ended`
    /// ends assistant speech exactly like a local `.finished`/`.stopped`.
    private func handleDaemonPlaybackEvent(_ event: DaemonPlaybackEvent) {
        switch event {
        case .level(let rms, let playbackID):
            // Only ride the level for the playback we started — a stale event
            // from a previous (already-stopped) clip must not move the orb.
            guard playbackID == currentDaemonPlaybackID else { return }
            handlePlaybackEvent(.level(rms: rms))
            // Voice spine V4: notify daemon-specific consumers (the Rust orb
            // shell's real-audio ride) with a name DISTINCT from `.faeAudioLevel`
            // (which also carries local AudioPlaybackManager levels). V4 rides
            // ONLY the daemon's voice.
            NotificationCenter.default.post(
                name: .faeDaemonAudioLevel, object: nil,
                userInfo: ["rms": Double(rms), "playback_id": playbackID])
        case .ended(let playbackID, let reason):
            guard playbackID == currentDaemonPlaybackID else { return }
            NSLog(
                "PipelineCoordinator: daemon audio.playback_ended playback_id=%@ reason=%@",
                playbackID, reason)
            currentDaemonPlaybackID = nil
            handlePlaybackEvent(reason == "interrupted" ? .stopped : .finished)
            // Voice spine V4: tell the real-audio orb to stop riding (return to
            // its synthetic breath).
            NotificationCenter.default.post(
                name: .faeDaemonAudioEnded, object: nil,
                userInfo: ["playback_id": playbackID, "reason": reason])
        }
    }

    /// Central assistant-speech interrupt (barge-in / teardown). Flag-ON stops
    /// the daemon playback; flag-OFF stops local playback. Tones/beeps are NOT
    /// routed through here — they keep using `playback.stop()`/tone helpers
    /// directly.
    /// Wait for the current daemon playback to end (driven by the
    /// `audio.playback_ended` event), so multi-segment turns play sequentially
    /// with NO overlap (the local path achieves this by queueing in
    /// AudioPlaybackManager; the daemon path must serialize explicitly). Bounded
    /// by `timeoutMs` so a missing end-event can't hang a turn.
    private func awaitDaemonPlaybackDrained(timeoutMs: Int) async {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)
        while currentDaemonPlaybackID != nil, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)  // 20 ms poll
        }
        // If the loop exited on the deadline with the id still set, the
        // `audio.playback_ended` event was lost (subscriber read-loop death,
        // dropped event, or a missing ended-event after a barge-in audio.stop).
        // Clear the stranded id so the NEXT segment isn't forced to eat the full
        // drain timeout before it can speak.
        if let stranded = currentDaemonPlaybackID {
            NSLog(
                "PipelineCoordinator: daemon playback drain timed out (playback_id=%@) — " +
                    "clearing stranded id so subsequent segments recover",
                stranded)
            currentDaemonPlaybackID = nil
        }
    }

    private func stopAssistantPlaybackForInterrupt() async {
        if daemonPlaybackActive, let id = currentDaemonPlaybackID {
            // Ask the daemon to stop; do NOT clear currentDaemonPlaybackID here —
            // the daemon's `audio.playback_ended{interrupted}` event clears it
            // (and resolves pipeline state via handleDaemonPlaybackEvent). If we
            // nilled it now, that end-event would be ignored as a stale id.
            await (ttsEngine as? DaemonTTSEngine)?.stopPlayback(playbackID: id)
        } else {
            await playback.stop()
        }
    }

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
        let llmLoaded = await llmEngine.isLoaded
        let ttsLoaded = await ttsEngine.isLoaded

        if llmLoaded && ttsLoaded {
            return .full
        }
        if !llmLoaded && !ttsLoaded {
            return .unavailable
        }
        if !llmLoaded {
            return .noLLM
        }
        return .noTTS
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

    static func stripVoiceTagMarkup(_ text: String) -> String {
        ToolRoutingHelpers.stripVoiceTagMarkup(text)
    }

    static func stripThinkContent(_ text: String) -> String {
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

    static func isCameraIntentRequest(_ text: String) -> Bool {
        ToolRoutingHelpers.isCameraIntentRequest(text)
    }

    static func isScreenIntentRequest(_ text: String) -> Bool {
        ToolRoutingHelpers.isScreenIntentRequest(text)
    }

    private static func screenRepairToolCall(for text: String) -> ToolCall {
        ToolRoutingHelpers.screenRepairToolCall(for: text)
    }

    static func extractReferencedAppName(from text: String) -> String? {
        ToolRoutingHelpers.extractReferencedAppName(from: text)
    }

    static func isToolBackedLookupRequest(_ text: String) -> Bool {
        ToolRoutingHelpers.isToolBackedLookupRequest(text)
    }

    static func repairedToolCallForSkippedTurn(_ text: String) -> ToolCall? {
        ToolRoutingHelpers.repairedToolCallForSkippedTurn(text)
    }

    static func extractSessionSearchQuery(from text: String) -> String? {
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

    static func serializeArguments(_ args: [String: Any]) -> String {
        ToolRoutingHelpers.serializeArguments(args)
    }

    static func estimateTokenCount(for text: String) -> Int {
        ToolRoutingHelpers.estimateTokenCount(for: text)
    }

    static func inferUserPresentFromCameraOutput(_ output: String) -> Bool {
        ToolRoutingHelpers.inferUserPresentFromCameraOutput(output)
    }

    static func extractAudioFilePath(from output: String) -> String? {
        ToolRoutingHelpers.extractAudioFilePath(from: output)
    }

    static func contentHash(_ text: String) -> String {
        ToolRoutingHelpers.contentHash(text)
    }

    // MARK: - Tool Execution

    private func startDeferredToolJob(
        userText: String,
        toolCalls: [ToolCall],
        assistantToolMessage: String,
        forceSuppressThinking: Bool,
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
        let generationID = beginAssistantGeneration(
            visibility: job.generationContext.playsThinkingTone || job.generationContext.allowsAudibleOutput
                ? .visible
                : .silentBackground
        )
        if job.generationContext.playsThinkingTone {
            await playback.playThinkingTone()
        }

        await generateWithTools(
            userText: job.userText,
            isToolFollowUp: true,
            turnCount: 1,
            forceSuppressThinking: job.forceSuppressThinking,
            generationContext: job.generationContext,
            generationID: generationID
        )
    }

    static func toolTimeoutSeconds(for toolName: String) -> TimeInterval {
        ToolExecutor.toolTimeoutSeconds(for: toolName)
    }

    private func executeTool(
        _ call: ToolCall,
        explicitUserAuthorizationOverride: Bool? = nil,
        proactiveContext: ProactiveRequestContext? = nil,
        generationContextOverride: GenerationContext? = nil,
        traceTurnID: String? = nil,
        traceToolCallID: String? = nil
    ) async -> ToolResult {
        let workflowTurnID = traceTurnID ?? currentTurnID

        // Build per-call context from coordinator state.
        let livenessScore: Float? = await speakerEncoder?.lastLivenessResult?.score
        let currentToolMode = effectiveToolMode()
        let explicitAuthorization = explicitUserAuthorizationOverride ?? explicitUserAuthorizationForTurn
        let effectiveGenerationContext = generationContextOverride ?? currentTurnGenerationContext

        let context = ToolExecutorContext(
            toolMode: currentToolMode,
            privacyMode: effectivePrivacyMode(),
            modelLocality: modelLocality,
            explicitUserAuthorization: explicitAuthorization,
            isOwner: speakerGate.currentSpeakerIsOwner,
            livenessScore: livenessScore,
            speakerId: speakerGate.currentSpeakerLabel,
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
        reconcileAssistantGenerating()
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
            }
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

        debugLog(debugConsole, .toolCall, "Script execution started (budget: \(budget.maxToolCalls) calls, \(Int(budget.maxWallClockSeconds))s)")
        eventBus.send(.toolCall(
            id: "script-\(UUID().uuidString.prefix(8))",
            name: "tool_program",
            inputJSON: "{\"source_length\":\(block.source.count)}"
        ))

        // Build real per-turn context from coordinator state.
        let livenessScore: Float? = await speakerEncoder?.lastLivenessResult?.score
        let currentToolMode = effectiveToolMode()
        let effectiveGenerationContext = currentTurnGenerationContext

        let scriptContext = ToolExecutorContext(
            toolMode: currentToolMode,
            privacyMode: effectivePrivacyMode(),
            modelLocality: modelLocality,
            explicitUserAuthorization: explicitUserAuthorizationForTurn,
            isOwner: speakerGate.currentSpeakerIsOwner,
            livenessScore: livenessScore,
            speakerId: speakerGate.currentSpeakerLabel,
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
    static func isSafeSkillName(_ name: String) -> Bool {
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
    ///
    /// Two-tier SmolVLM2 architecture:
    /// - Fast path (256M, <1GB): always loaded at startup for proactive awareness.
    ///   Used for camera presence, screen triage, app identification.
    /// - Deep path (500M, 1.8GB): loaded on-demand for detailed screenshot/camera analysis.
    ///   Used when user explicitly asks vision questions via tools.
    ///
    /// The provider returns the fast VLM for proactive tasks (which set
    /// `allowedTools` to just ["camera"] or ["screenshot"]). For user-triggered
    /// tool calls, it loads the deep VLM for higher accuracy.
    func toolExecutorVLMProvider() async -> VLMProvider? {
        guard let mm = modelManager else { return nil }

        // If fast VLM is loaded, return it for proactive use.
        // For user-triggered vision tools, the deep VLM loads on-demand.
        let hasFastVLM = await mm.fastVLMEngine != nil
        var vlmConfigMut = config
        vlmConfigMut.vision.enabled = effectiveVisionEnabled()
        let vlmConfig = vlmConfigMut

        return {
            // Prefer fast VLM (always-on, <1s latency) for quick triage.
            // Falls through to deep VLM if fast VLM isn't loaded.
            if hasFastVLM, let fast = await mm.fastVLMEngine, await fast.isLoaded {
                return fast
            }
            // Deep VLM — loaded on-demand for detailed analysis (1.8GB).
            return try await mm.loadVLMIfNeeded(config: vlmConfig)
        }
    }

    /// Speak text directly through the playback pipeline (used for non-manual approval prompts).
    func toolExecutorSpeakDirect(_ text: String) async {
        await speakDirect(text)
    }

    /// Narrate a completed action to the user with barge-in enabled for undo.
    ///
    /// Tags `bargeInState.pendingNarrationReceiptId` so that if the user
    /// interrupts mid-narration, the barge-in handler can undo the action.
    /// Only called for write-class tools (reversibility != `.notApplicable`).
    func toolExecutorNarrateAction(_ text: String, receiptId: String?) async {
        bargeInState.pendingNarrationReceiptId = receiptId
        defer { bargeInState.pendingNarrationReceiptId = nil }
        await speakInterruptible(text)
    }

    /// Present a narrated countdown before executing an irreversible action.
    ///
    /// Speaks the announcement then polls for barge-in once per second for 5 seconds.
    /// Returns `true` if the countdown completes without interruption (proceed),
    /// or `false` if the user barged in (cancel the action).
    func toolExecutorCountdownBeforeIrreversible(_ text: String) async -> Bool {
        // Announce the countdown — non-suppressible so user hears it clearly.
        await speakDirect(text)

        // Poll for barge-in once per second for 5 seconds.
        for _ in 0..<5 {
            // Check whether a barge-in is pending (user is speaking).
            // Do NOT speak "Cancelled." here — the barge-in pipeline is already
            // processing the user's audio. Speaking simultaneously would interleave
            // with or override the barge-in handling. Let the barge-in be the
            // natural cancellation signal; Fae will respond to whatever the user said.
            if bargeInState.pendingBargeIn != nil {
                NSLog("PipelineCoordinator: irreversible countdown cancelled by barge-in")
                return false
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return false }
        }
        return true
    }
}
