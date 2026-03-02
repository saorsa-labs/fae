import AVFoundation
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
    private let skillManager: SkillManager?
    private let toolAnalytics: ToolAnalytics?
    private let isRescueMode: Bool

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

    private var assistantSpeaking: Bool = false
    private var assistantGenerating: Bool = false
    private var interrupted: Bool = false
    private var awaitingApproval: Bool = false

    // MARK: - Speaker Identity State

    private var currentSpeakerLabel: String?
    private var currentSpeakerDisplayName: String?
    private var currentSpeakerRole: SpeakerRole?
    private var currentSpeakerIsOwner: Bool = false
    /// True when speaker verification ran and matched a non-owner profile.
    /// Distinguished from "not matched at all" (unknown/degraded) — only this
    /// flag should hard-block tools when `requireOwnerForTools` is enabled.
    private var currentSpeakerIsKnownNonOwner: Bool = false
    private var previousSpeakerLabel: String?
    private var utterancesSinceOwnerVerified: Int = 0

    // MARK: - Enrollment State

    /// One-shot system prompt addition for the LLM's first response after owner enrollment.
    /// Set by FaeCore during the voice enrollment flow; cleared after first use.
    private var firstOwnerEnrollmentContext: String?

    // MARK: - Timing & Echo Detection

    private var lastAssistantStart: Date?
    private var engagedUntil: Date?
    /// Last assistant response text — used to detect echo (mic picking up speaker output).
    private var lastAssistantResponseText: String = ""

    // MARK: - Barge-In

    private var pendingBargeIn: PendingBargeIn?

    // MARK: - Phase 1 Observability

    private var pipelineStartedAt: Date?
    private var firstAudioLatencyEmitted: Bool = false
    private let instrumentation = PipelineInstrumentation()

    struct PendingBargeIn {
        var capturedAt: Date
        var speechSamples: Int = 0
        var lastRms: Float = 0
    }

    // MARK: - Pipeline Tasks

    private var pipelineTask: Task<Void, Never>?
    private var captureStream: AsyncStream<AudioChunk>?

    /// Chained TTS task — each sentence enqueues onto this so TTS runs in order
    /// without blocking the LLM token stream.
    private var pendingTTSTask: Task<Void, Never>?

    // MARK: - Capability Tickets

    /// Task-scoped capability grant consumed by the broker.
    private var activeCapabilityTicket: CapabilityTicket?

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
        skillManager: SkillManager? = nil,
        toolAnalytics: ToolAnalytics? = nil,
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
        self.skillManager = skillManager
        self.toolAnalytics = toolAnalytics
        self.isRescueMode = rescueMode

        // Configure VAD from config.
        vad.threshold = config.vad.threshold
        vad.hysteresisRatio = config.vad.hysteresisRatio
        vad.minSilenceDurationMs = config.vad.minSilenceDurationMs
        vad.speechPadMs = config.vad.speechPadMs
        vad.minSpeechDurationMs = config.vad.minSpeechDurationMs
        vad.maxSpeechDurationMs = config.vad.maxSpeechDurationMs
    }

    // MARK: - Lifecycle

    /// Start the voice pipeline.
    func start() async throws {
        guard pipelineTask == nil else { return }

        eventBus.send(.pipelineStateChanged(.starting))

        // Set up playback event handler and voice speed.
        try await playback.setup()
        await playback.setSpeed(config.tts.speed)
        await setPlaybackEventHandler()

        // Start audio capture.
        let stream = try await capture.startCapture()
        captureStream = stream

        eventBus.send(.pipelineStateChanged(.running))
        pipelineStartedAt = Date()
        await refreshDegradedModeIfNeeded(context: "startup")
        NSLog("PipelineCoordinator: pipeline started in %@ mode", mode.rawValue)

        // Main pipeline loop.
        pipelineTask = Task { [weak self] in
            guard let self else { return }
            await self.runPipelineLoop(stream: stream)
        }
    }

    /// Stop the pipeline.
    func stop() async {
        pipelineTask?.cancel()
        pipelineTask = nil
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
        pendingTTSTask?.cancel()
        pendingTTSTask = nil
        Task { await playback.stop() }
        NSLog("PipelineCoordinator: cancelled by user")
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
        }

        // If assistant is active, trigger barge-in.
        if assistantSpeaking || assistantGenerating {
            interrupted = true
            await playback.stop()
        }

        await processTranscription(text: trimmed, rms: nil, durationSecs: nil)
    }

    /// Speak text directly via TTS without going through the LLM.
    ///
    /// Used for system messages like the first-launch greeting.
    func speakDirect(_ text: String) async {
        await speakText(text, isFinal: true)
    }

    /// Speak text with a specific voice description, bypassing the LLM.
    ///
    /// Used for voice preview in roleplay and settings.
    func speakWithVoice(_ text: String, voiceInstruct: String) async {
        await speakText(text, isFinal: true, voiceInstruct: voiceInstruct)
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
            durationSeconds: Double(samples.count) / Double(sr)
        )
        await handleSpeechSegment(segment)
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

    private func isAddressedToFae(_ text: String) -> Bool {
        if TextProcessing.findNameMention(in: text) != nil {
            return true
        }
        let normalizedText = Self.normalizeForPhraseMatch(text)
        let wakeWord = Self.normalizeForPhraseMatch(config.conversation.wakeWord)
        return !wakeWord.isEmpty && normalizedText.contains(wakeWord)
    }

    private func resetConversationSession(trigger: String, source: String) async {
        sleep()
        currentSystemPrompt = nil
        engagedUntil = nil
        lastAssistantResponseText = ""
        activeCapabilityTicket = nil
        pendingTTSTask?.cancel()
        pendingTTSTask = nil
        await conversationState.clear()
        NSLog("PipelineCoordinator: conversation reset via %@ trigger: %@", source, trigger)
        debugLog(debugConsole, .pipeline, "Conversation reset (\(source)): \(trigger)")
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

            // Track barge-in — skip when echo suppressor is active to prevent
            // Fae's own voice from triggering barge-in.
            if vadOutput.speechStarted && !echoSuppressor.isInSuppression {
                pendingBargeIn = PendingBargeIn(capturedAt: Date(), lastRms: vadOutput.rms)
            } else if vadOutput.speechStarted && echoSuppressor.isInSuppression {
                // Don't create barge-in candidate during echo suppression.
                pendingBargeIn = nil
            }
            if vadOutput.isSpeech, pendingBargeIn != nil {
                pendingBargeIn?.speechSamples += chunk.samples.count
                pendingBargeIn?.lastRms = vadOutput.rms

                // Check barge-in confirmation.
                let bargeInEnabled = bargeInEnabledLive ?? config.bargeIn.enabled
                let confirmSamples = (config.bargeIn.confirmMs * config.audio.inputSampleRate) / 1000
                if let barge = pendingBargeIn,
                   barge.speechSamples >= confirmSamples,
                   bargeInEnabled
                {
                    handleBargeIn(rms: barge.lastRms)
                    pendingBargeIn = nil
                }
            }

            // Adjust VAD silence threshold based on assistant state.
            if assistantSpeaking {
                vad.setSilenceThresholdMs(config.bargeIn.bargeInSilenceMs)
                pendingBargeIn = nil  // Clear any pending barge-in during active speech
            } else {
                vad.setSilenceThresholdMs(config.vad.minSilenceDurationMs)
            }

            // Process completed speech segment.
            if let segment = vadOutput.segment {
                await handleSpeechSegment(segment)
            }
        }
    }

    // MARK: - Speech Segment Processing

    private func handleSpeechSegment(_ segment: SpeechSegment) async {
        let rms = VoiceActivityDetector.computeRMS(segment.samples)
        let durationSecs = Float(segment.samples.count) / Float(segment.sampleRate)

        // Echo suppression check.
        guard echoSuppressor.shouldAccept(
            durationSecs: durationSecs,
            rms: rms,
            awaitingApproval: awaitingApproval
        ) else {
            NSLog("PipelineCoordinator: dropping %.1fs speech segment (echo suppression)", durationSecs)
            debugLog(debugConsole, .pipeline, "Echo suppressed: \(String(format: "%.1f", durationSecs))s segment (rms=\(String(format: "%.3f", rms)))")
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
        if config.speaker.enabled,
           let encoder = speakerEncoder, await encoder.isLoaded,
           let store = speakerProfileStore
        {
            do {
                let embedding = try await encoder.embed(
                    audio: segment.samples,
                    sampleRate: segment.sampleRate
                )

                // First-launch enrollment: first voice becomes the owner.
                // Fires whenever there is no owner profile — regardless of onboarded flag.
                let hasOwner = await store.hasOwnerProfile()
                if !hasOwner {
                    let ownerName = config.userName ?? "Owner"
                    await store.enroll(
                        label: "owner", embedding: embedding,
                        role: .owner, displayName: ownerName
                    )
                    currentSpeakerLabel = "owner"
                    currentSpeakerDisplayName = ownerName
                    currentSpeakerRole = .owner
                    currentSpeakerIsOwner = true
                    NSLog("PipelineCoordinator: owner voice enrolled from first speech")
                    NotificationCenter.default.post(
                        name: .faePipelineState,
                        object: nil,
                        userInfo: [
                            "event": "pipeline.enrollment_complete",
                            "payload": [:] as [String: Any],
                        ]
                    )
                } else if let match = await store.match(
                    embedding: embedding,
                    threshold: config.speaker.threshold
                ) {
                    currentSpeakerLabel = match.label
                    currentSpeakerDisplayName = match.displayName
                    currentSpeakerRole = match.role
                    currentSpeakerIsOwner = match.role == .owner
                    currentSpeakerIsKnownNonOwner = match.role != .owner

                    // Progressive enrollment: strengthen known profiles (skip fae_self).
                    if config.speaker.progressiveEnrollment, match.role != .faeSelf {
                        await store.enrollIfBelowMax(
                            label: match.label,
                            embedding: embedding,
                            max: config.speaker.maxEnrollments
                        )
                    }

                    NSLog("PipelineCoordinator: speaker matched: %@ (%@), similarity: %.3f",
                          match.displayName, match.label, match.similarity)
                    debugLog(debugConsole, .speaker, "Matched: \(match.displayName) (\(match.label)) sim=\(String(format: "%.3f", match.similarity)) owner=\(currentSpeakerIsOwner)")
                } else {
                    NSLog("PipelineCoordinator: speaker not recognized")
                    debugLog(debugConsole, .speaker, "Not recognized (no match above threshold \(String(format: "%.2f", config.speaker.threshold)))")
                }
            } catch {
                NSLog("PipelineCoordinator: speaker embed failed: %@", error.localizedDescription)
                debugLog(debugConsole, .speaker, "Embed failed: \(error.localizedDescription)")
            }
        } else {
            // Speaker verification not available — log why.
            if !config.speaker.enabled {
                debugLog(debugConsole, .speaker, "Speaker ID disabled in config")
            } else {
                debugLog(debugConsole, .speaker, "Speaker encoder not loaded — owner verification skipped")
            }
        }

        // Self-echo rejection: if the segment matches Fae's own voice, drop it.
        // This catches echo that slips through the time-based echo suppressor
        // (e.g. when the echo tail expires but Fae's voice is still in the room).
        if currentSpeakerLabel == "fae_self" {
            NSLog("PipelineCoordinator: dropping %.1fs segment (matched Fae's own voice)", durationSecs)
            return
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

            eventBus.send(.transcription(text: text, isFinal: true))

            if isConversationStopTrigger(text) {
                await resetConversationSession(trigger: text, source: "voice")
                return
            }

            if gateState != .active {
                guard isAddressedToFae(text) else { return }
                wake()
            }

            // Conversation gate — direct address check.
            if config.conversation.requireDirectAddress {
                let nameFound = TextProcessing.findNameMention(in: text) != nil
                let inFollowup = engagedUntil.map { Date() < $0 } ?? false
                if !nameFound && !inFollowup && !awaitingApproval {
                    return // Drop — not addressed to Fae.
                }
            }

            // Process through LLM.
            await processTranscription(text: text, rms: rms, durationSecs: durationSecs)

        } catch {
            NSLog("PipelineCoordinator: STT error: %@", error.localizedDescription)
        }
    }

    // MARK: - LLM Processing

    private func processTranscription(text: String, rms: Float?, durationSecs: Float?) async {
        // Extract query if name-addressed.
        var queryText = text
        if let (nameRange, _) = TextProcessing.findNameMention(in: text) {
            queryText = TextProcessing.extractQueryAroundName(in: text, nameRange: nameRange)
            // Refresh follow-up window.
            engagedUntil = Date().addingTimeInterval(
                Double(config.conversation.directAddressFollowupS)
            )
        }

        // If assistant is still active, interrupt.
        if assistantSpeaking || assistantGenerating {
            interrupted = true
            pendingTTSTask?.cancel()
            pendingTTSTask = nil
            await playback.stop()
        }

        // Unified pipeline: LLM decides when to use tools via <tool_call> markup.
        await generateWithTools(userText: queryText, isToolFollowUp: false, turnCount: 0)
    }

    /// Unified LLM generation with inline tool execution.
    ///
    /// Streams tokens to TTS. If the model outputs `<tool_call>` markup, executes the
    /// tools and re-generates with the results. Recurses up to `maxToolTurns` times.
    private func generateWithTools(
        userText: String,
        isToolFollowUp: Bool,
        turnCount: Int
    ) async {
        let maxToolTurns = 5

        await refreshDegradedModeIfNeeded(context: "before_generation")

        guard await llmEngine.isLoaded else {
            NSLog("PipelineCoordinator: LLM not loaded")
            debugLog(debugConsole, .pipeline, "⚠️ LLM not loaded — cannot generate")
            return
        }

        if !isToolFollowUp {
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
            await conversationState.addUserMessage(userText, speakerDisplayName: currentSpeakerDisplayName)

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
            // Owner gating: only *known* non-owner voices are blocked from tools.
            // Unknown speakers (encoder not loaded, no match) still get tools — this is
            // a single-user device where physical access implies trust. Only positively
            // matched non-owner profiles are gated.
            let includeTools = toolMode != "off"
                && !(config.speaker.requireOwnerForTools && currentSpeakerIsKnownNonOwner)

            // Diagnostic logging — critical for debugging tool use failures.
            if !includeTools {
                let reason: String
                if toolMode == "off" {
                    reason = "toolMode=off"
                } else if config.speaker.requireOwnerForTools && currentSpeakerIsKnownNonOwner {
                    reason = "requireOwnerForTools=true and speaker matched as non-owner (\(currentSpeakerLabel ?? "unknown"))"
                } else {
                    reason = "unknown"
                }
                debugLog(debugConsole, .pipeline, "⚠️ Tools HIDDEN from LLM: \(reason)")
                NSLog("PipelineCoordinator: tools hidden — %@", reason)
            } else {
                let ownerDetail: String
                if currentSpeakerIsOwner {
                    ownerDetail = "ownerVerified=true"
                } else if currentSpeakerLabel == nil {
                    ownerDetail = "speakerUnknown (tools allowed — physical access trusted)"
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
            let toolSchemas: String? = {
                guard includeTools else { return nil }
                let schemas = registry.toolSchemas(for: toolMode)
                return schemas.isEmpty ? nil : schemas
            }()

            if let schemas = toolSchemas {
                let schemaCount = schemas.components(separatedBy: "\"name\":").count - 1
                debugLog(debugConsole, .pipeline, "Tool schemas: ~\(schemaCount) tools, \(schemas.count) chars")
            }

            let soul = isRescueMode ? SoulManager.defaultSoul() : SoulManager.loadSoul()
            var systemPrompt = PersonalityManager.assemblePrompt(
                voiceOptimized: true,
                userName: config.userName,
                speakerDisplayName: currentSpeakerDisplayName,
                speakerRole: currentSpeakerRole,
                soulContract: soul,
                directiveOverride: isRescueMode ? "" : nil,
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
            self.currentSystemPrompt = systemPrompt
        }

        guard let systemPrompt = self.currentSystemPrompt else { return }
        let dynamicReservedTokens = max(
            1024,
            Self.estimateTokenCount(for: systemPrompt) + config.llm.maxTokens
        )
        await conversationState.setReservedTokens(dynamicReservedTokens)
        let history = await conversationState.history

        let options = GenerationOptions(
            temperature: config.llm.temperature,
            topP: config.llm.topP,
            maxTokens: config.llm.maxTokens,
            repetitionPenalty: config.llm.repeatPenalty,
            suppressThinking: !(thinkingEnabledLive ?? config.llm.thinkingEnabled)
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
        // When thinking is disabled OR this is a tool follow-up (no think block expected),
        // mark think as already seen so tokens route directly to TTS.
        let suppressThink = !(thinkingEnabledLive ?? config.llm.thinkingEnabled)
        var thinkEndSeen = suppressThink || isToolFollowUp
        var thinkAccum = ""
        var firstTtsSent = false
        let llmStartedAt = Date()
        var llmTokenCount = 0

        let systemPromptTokens = Self.estimateTokenCount(for: systemPrompt)
        debugLog(debugConsole, .pipeline, "LLM generating (maxTokens=\(options.maxTokens), history=\(history.count) msgs, turn=\(turnCount), sysPrompt≈\(systemPromptTokens) tok, ctx=\(config.llm.contextSizeTokens))")
        if options.maxTokens < 1024 {
            debugLog(debugConsole, .pipeline, "⚠️ maxTokens=\(options.maxTokens) is very low — tool call JSON needs ~200-500 tokens")
        }

        let tokenStream = await llmEngine.generate(
            messages: history,
            systemPrompt: systemPrompt,
            options: options
        )

        do {
            for try await token in tokenStream {
                llmTokenCount += 1
                guard !interrupted else {
                    NSLog("PipelineCoordinator: generation interrupted")
                    break
                }

                let visible = thinkTagStripper.process(token)
                // For Qwen3.5-35B-A3B: <think> is literal text, so ThinkTagStripper
                // consumes it natively. When it exits the think block, signal thinkEndSeen
                // so the pipeline doesn't wait for </think> in thinkAccum (which never arrives
                // because ThinkTagStripper already consumed it).
                if thinkTagStripper.hasExitedThinkBlock {
                    thinkEndSeen = true
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
                        if !cleaned.isEmpty {
                            eventBus.send(.assistantText(text: cleaned, isFinal: false))
                            enqueueTTS(cleaned, isFinal: false)
                        }
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
                    if let endRange = thinkAccum.range(of: "</think>") {
                        let afterThink = String(thinkAccum[endRange.upperBound...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        thinkAccum = ""
                        thinkEndSeen = true
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
                            firstTtsSent = true
                            lastAssistantResponseText += " " + cleaned
                            eventBus.send(.assistantText(text: cleaned, isFinal: false))
                            enqueueTTS(cleaned, isFinal: false)
                        } else if isMetaCommentary {
                            debugLog(debugConsole, .llmThink, "[suppressed meta-commentary] \(cleaned)")
                        }
                        sentenceBuffer = String(sentenceBuffer[boundary...])
                    } else if sentenceBuffer.count > 200 {
                        if let clause = TextProcessing.findClauseBoundary(in: sentenceBuffer) {
                            let text = String(sentenceBuffer[..<clause])
                            let cleaned = TextProcessing.stripNonSpeechChars(text)
                            if !cleaned.isEmpty {
                                firstTtsSent = true
                                lastAssistantResponseText += " " + cleaned
                                eventBus.send(.assistantText(text: cleaned, isFinal: false))
                                enqueueTTS(cleaned, isFinal: false)
                            }
                            sentenceBuffer = String(sentenceBuffer[clause...])
                        }
                    }
                }
            }
        } catch {
            NSLog("PipelineCoordinator: LLM error: %@", error.localizedDescription)
            debugLog(debugConsole, .pipeline, "⚠️ LLM error: \(error.localizedDescription)")
        }

        let llmElapsed = Date().timeIntervalSince(llmStartedAt)
        if llmElapsed > 0 {
            let throughput = Double(llmTokenCount) / llmElapsed
            NSLog("phase1.llm_token_throughput_tps=%.2f", throughput)
            debugLog(debugConsole, .pipeline, "LLM done: \(llmTokenCount) tokens in \(String(format: "%.1f", llmElapsed))s (\(String(format: "%.1f", throughput)) t/s)")
            if llmTokenCount == 0 {
                debugLog(debugConsole, .pipeline, "⚠️ 0 tokens generated — possible memory pressure, model not loaded, or context overflow")
            } else if throughput < 2.0 {
                debugLog(debugConsole, .pipeline, "⚠️ Very low throughput (\(String(format: "%.1f", throughput)) t/s) — system under memory pressure?")
            }
        }

        // Flush remaining text.
        let remaining = thinkTagStripper.flush()
        fullResponse += remaining

        // Parse tool calls from the full response.
        let toolCalls = Self.parseToolCalls(from: fullResponse)
        if !toolCalls.isEmpty {
            debugLog(debugConsole, .pipeline, "Found \(toolCalls.count) tool call(s): \(toolCalls.map(\.name).joined(separator: ", "))")
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
                        eventBus.send(.assistantText(text: cleaned, isFinal: true))
                        enqueueTTS(cleaned, isFinal: true, voiceInstruct: voice)
                        spokeSomething = true
                    }
                }
                // Wait for all TTS (streaming + final) to complete.
                await awaitPendingTTS()
                if !spokeSomething && assistantSpeaking {
                    await playback.markEnd()
                }
            } else {
                sentenceBuffer += remaining
                let finalText = TextProcessing.stripNonSpeechChars(sentenceBuffer)
                if !finalText.isEmpty {
                    eventBus.send(.assistantText(text: finalText, isFinal: true))
                    enqueueTTS(finalText, isFinal: true)
                }
                // Wait for all TTS (streaming + final) to complete.
                await awaitPendingTTS()
                if finalText.isEmpty && assistantSpeaking {
                    await playback.markEnd()
                }
            }

            let spokenText = Self.stripThinkContent(Self.stripVoiceTagMarkup(Self.stripToolCallMarkup(fullResponse)))
            if !spokenText.isEmpty {
                lastAssistantResponseText = spokenText
                await conversationState.addAssistantMessage(spokenText)

                // Memory capture.
                let turnId = newMemoryId(prefix: "turn")
                _ = await memoryOrchestrator?.capture(
                    turnId: turnId,
                    userText: userText,
                    assistantText: spokenText,
                    speakerId: currentSpeakerLabel
                )

                // Sentiment → orb feeling.
                if let feeling = SentimentClassifier.classify(spokenText) {
                    eventBus.send(.orbStateChanged(mode: "idle", feeling: feeling.rawValue, palette: nil))
                }
            }

            assistantGenerating = false
            eventBus.send(.assistantGenerating(false))

            // Refresh follow-up window.
            engagedUntil = Date().addingTimeInterval(
                Double(config.conversation.directAddressFollowupS)
            )
            activeCapabilityTicket = nil
            return
        }

        // Tool calls found — execute them.
        guard turnCount < maxToolTurns else {
            let msg = "I've used several tools but couldn't complete that. Could you try rephrasing?"
            eventBus.send(.assistantText(text: msg, isFinal: true))
            await speakText(msg, isFinal: true)
            assistantGenerating = false
            eventBus.send(.assistantGenerating(false))
            activeCapabilityTicket = nil
            return
        }

        // Add the assistant's tool-calling message to history (strip think content).
        await conversationState.addAssistantMessage(Self.stripThinkContent(fullResponse))

        for call in toolCalls.prefix(5) {
            let callId = UUID().uuidString
            let inputJSON = Self.serializeArguments(call.arguments)

            eventBus.send(.toolCall(id: callId, name: call.name, inputJSON: inputJSON))
            NSLog("PipelineCoordinator: executing tool '%@'", call.name)
            debugLog(debugConsole, .toolCall, "\(call.name)(\(inputJSON.prefix(80)))")

            let result = await executeTool(call)
            debugLog(debugConsole, .toolResult, "\(call.name) → \(result.isError ? "error" : "ok") \(String(result.output.prefix(100)))")

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
                content: result.output
            )
        }

        // Recurse: generate again with tool results in context.
        await generateWithTools(
            userText: userText,
            isToolFollowUp: true,
            turnCount: turnCount + 1
        )
    }

    /// Cached system prompt for tool follow-up turns (avoids rebuilding each recursion).
    private var currentSystemPrompt: String?

    // MARK: - TTS

    /// Non-blocking TTS enqueue — chains onto `pendingTTSTask` so sentences synthesize
    /// in order without blocking the LLM token stream.
    ///
    /// Call this from inside the token generation loop. The LLM keeps producing tokens
    /// while TTS runs concurrently on the actor (re-entrant at `await` points).
    private func enqueueTTS(_ text: String, isFinal: Bool, voiceInstruct: String? = nil) {
        // Set speaking state immediately so echo suppressor and barge-in work correctly.
        if !assistantSpeaking {
            assistantSpeaking = true
            lastAssistantStart = Date()
            echoSuppressor.onAssistantSpeechStart()
        }

        let previous = pendingTTSTask
        pendingTTSTask = Task {
            await previous?.value  // Ensure sentence ordering
            guard !interrupted else { return }
            await synthesizeSentence(text, isFinal: isFinal, voiceInstruct: voiceInstruct)
        }
    }

    /// Wait for all pending TTS work to complete. Call after the token loop ends.
    private func awaitPendingTTS() async {
        await pendingTTSTask?.value
        pendingTTSTask = nil
    }

    /// Blocking TTS — used by `speakDirect`, `speakWithVoice`, and other non-streaming paths
    /// where we want to wait for speech to finish before continuing.
    private func speakText(_ text: String, isFinal: Bool, voiceInstruct: String? = nil) async {
        if !assistantSpeaking {
            assistantSpeaking = true
            lastAssistantStart = Date()
            echoSuppressor.onAssistantSpeechStart()
        }
        await synthesizeSentence(text, isFinal: isFinal, voiceInstruct: voiceInstruct)
    }

    /// Core TTS synthesis — shared by both `enqueueTTS` and `speakText`.
    private func synthesizeSentence(_ text: String, isFinal: Bool, voiceInstruct: String? = nil) async {
        guard await ttsEngine.isLoaded else {
            NSLog("PipelineCoordinator: TTS not loaded, skipping speech")
            debugLog(debugConsole, .pipeline, "⚠️ TTS not loaded — skipping speech")
            return
        }
        debugLog(debugConsole, .pipeline, "TTS: \"\(String(text.prefix(80)))\"\(text.count > 80 ? "…" : "") (final=\(isFinal))")

        // Emotional prosody: when enabled and no explicit voiceInstruct (i.e. not roleplay),
        // classify sentiment and use instruct mode with emotion description.
        let effectiveVoiceInstruct: String?
        if voiceInstruct != nil {
            effectiveVoiceInstruct = voiceInstruct
        } else if config.tts.emotionalProsody {
            let feeling = SentimentClassifier.classify(text) ?? .neutral
            effectiveVoiceInstruct = SentimentClassifier.ttsInstruct(
                for: feeling, warmth: config.tts.warmth
            )
        } else {
            effectiveVoiceInstruct = nil
        }

        do {
            let ttsStartedAt = Date()
            var ttsFirstChunkEmitted = false
            let audioStream = await ttsEngine.synthesize(text: text, voiceInstruct: effectiveVoiceInstruct)
            for try await buffer in audioStream {
                if !ttsFirstChunkEmitted {
                    let latencyMs = Date().timeIntervalSince(ttsStartedAt) * 1000
                    ttsFirstChunkEmitted = true
                    NSLog("phase1.tts_first_chunk_latency_ms=%.2f", latencyMs)
                }
                guard !interrupted else { break }
                // Convert AVAudioPCMBuffer to Float array and enqueue.
                let samples = Self.extractSamples(from: buffer)
                await playback.enqueue(
                    samples: samples,
                    sampleRate: Int(buffer.format.sampleRate),
                    isFinal: isFinal
                )
            }
            if isFinal {
                await playback.markEnd()
            }
        } catch {
            NSLog("PipelineCoordinator: TTS error: %@", error.localizedDescription)
            // Ensure assistantSpeaking is cleared on TTS failure.
            assistantSpeaking = false
            echoSuppressor.onAssistantSpeechEnd()
        }
    }

    // MARK: - Barge-In

    private func handleBargeIn(rms: Float) {
        guard bargeInEnabledLive ?? config.bargeIn.enabled else { return }
        guard assistantSpeaking || assistantGenerating else { return }
        guard rms >= config.bargeIn.minRms else { return }

        // Check holdoff — don't interrupt immediately after playback starts.
        if let start = lastAssistantStart {
            let elapsed = Date().timeIntervalSince(start) * 1000
            if elapsed < Double(config.bargeIn.assistantStartHoldoffMs) {
                return
            }
        }

        interrupted = true
        Task { await playback.stop() }
        NSLog("PipelineCoordinator: barge-in triggered (rms=%.4f)", rms)
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
            assistantSpeaking = false
            echoSuppressor.onAssistantSpeechEnd()
            vad.reset()
            NSLog("PipelineCoordinator: playback finished")

        case .stopped:
            assistantSpeaking = false
            echoSuppressor.onAssistantSpeechEnd()
            vad.reset()

        case .level(let rms):
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

    // MARK: - Tool Execution

    private static let toolTimeoutSeconds: TimeInterval = 30

    private func executeTool(_ call: ToolCall) async -> ToolResult {
        // Tool mode enforcement — reject tools not allowed in current mode.
        let toolMode = effectiveToolMode()
        guard registry.isToolAllowed(call.name, mode: toolMode) else {
            return .error("Tool '\(call.name)' is not available in current mode (\(toolMode))")
        }

        guard let tool = registry.tool(named: call.name) else {
            return .error("Unknown tool: \(call.name)")
        }

        let policyProfile = currentPolicyProfile()

        // Rate limiting.
        if let limitError = await rateLimiter.checkLimit(
            tool: call.name,
            riskLevel: tool.riskLevel,
            profile: policyProfile
        ) {
            return .error(limitError)
        }

        let livenessScore: Float? = await speakerEncoder?.lastLivenessResult?.score
        let hasCapabilityTicket = activeCapabilityTicket?.allows(toolName: call.name) ?? false
        let intent = ActionIntent(
            source: .voice,
            toolName: call.name,
            riskLevel: tool.riskLevel,
            requiresApproval: tool.requiresApproval,
            isOwner: currentSpeakerIsOwner,
            livenessScore: livenessScore,
            explicitUserAuthorization: false,
            hasCapabilityTicket: hasCapabilityTicket,
            policyProfile: policyProfile,
            argumentSummary: Self.buildApprovalDescription(
                toolName: call.name,
                reason: "confirmation required",
                arguments: call.arguments
            )
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
                let approved = await manager.requestApproval(
                    toolName: call.name,
                    description: prompt.message
                )
                approvedByUser = approved
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
        if call.name == "run_skill", let ticketId = activeCapabilityTicket?.id {
            executionArguments["capability_ticket"] = ticketId
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
    /// - off/read_only => cautious profile
    /// - read_write/full => balanced profile
    /// - full_no_approval => autonomous profile
    private func currentPolicyProfile() -> PolicyProfile {
        switch effectiveToolMode() {
        case "off", "read_only":
            return .moreCautious
        case "full_no_approval":
            return .moreAutonomous
        case "read_write", "full":
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

    /// Build a plain-language confirmation prompt with concrete action context.
    private static func buildApprovalDescription(
        toolName: String, reason: String, arguments: [String: Any]
    ) -> String {
        switch toolName {
        case "bash":
            if let command = arguments["command"] as? String {
                let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = trimmed.count > 140 ? String(trimmed.prefix(140)) + "…" : trimmed
                return "I can run this command: \(preview). Run it now?"
            }
            return "I can run a shell command for this step. Run it now?"

        case "write":
            if let path = arguments["path"] as? String {
                return "I can write to \(path). Proceed?"
            }
            return "I can write file content for this step. Proceed?"

        case "edit":
            if let path = arguments["path"] as? String {
                return "I can edit \(path). Proceed?"
            }
            return "I can edit a file for this step. Proceed?"

        case "self_config":
            return "I can update your persistent Fae directive. Apply this change?"

        case "run_skill":
            let skillName = arguments["name"] as? String ?? "a skill"
            return "I can run \(skillName) now. Continue?"

        case "manage_skill":
            let action = arguments["action"] as? String ?? "modify"
            return "I can \(action) a skill in your local skills library. Continue?"

        case "scheduler_create":
            return "I can create a scheduled task that runs automatically later. Create it?"

        case "scheduler_update":
            return "I can update a scheduled task. Apply the change?"

        case "scheduler_delete":
            return "I can delete this scheduled task. Delete it now?"

        default:
            return "I can use \(toolName) for this step. Continue?"
        }
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
