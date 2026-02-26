import AVFoundation
import Foundation

/// Central voice pipeline: AudioCapture → VAD → STT → LLM → TTS → Playback.
///
/// Wires all pipeline stages together with echo suppression, barge-in,
/// gate/sleep system, intent-based routing, and text injection.
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

    // MARK: - Pipeline State

    private var mode: PipelineMode = .conversation
    private var degradedMode: PipelineDegradedMode?
    private var gateState: GateState = .active
    private var vad = VoiceActivityDetector()
    private var echoSuppressor = EchoSuppressor()
    private var thinkTagStripper = TextProcessing.ThinkTagStripper()

    // MARK: - Atomic-like Flags

    private var assistantSpeaking: Bool = false
    private var assistantGenerating: Bool = false
    private var interrupted: Bool = false
    private var awaitingApproval: Bool = false

    // MARK: - Timing

    private var lastAssistantStart: Date?
    private var engagedUntil: Date?

    // MARK: - Barge-In

    private var pendingBargeIn: PendingBargeIn?

    // MARK: - Phase 1 Observability

    private var pipelineStartedAt: Date?
    private var firstAudioLatencyEmitted: Bool = false

    struct PendingBargeIn {
        var capturedAt: Date
        var speechSamples: Int = 0
        var lastRms: Float = 0
    }

    // MARK: - Pipeline Tasks

    private var pipelineTask: Task<Void, Never>?
    private var captureStream: AsyncStream<AudioChunk>?

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
        approvalManager: ApprovalManager? = nil
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

        // Set up playback event handler.
        try await playback.setup()
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

    // MARK: - Text Injection

    /// Inject text directly into the LLM (bypasses STT).
    func injectText(_ text: String) async {
        // If assistant is active, trigger barge-in.
        if assistantSpeaking || assistantGenerating {
            interrupted = true
            await playback.stop()
        }

        await processTranscription(text: text, rms: nil, durationSecs: nil)
    }

    /// Speak text directly via TTS without going through the LLM.
    ///
    /// Used for system messages like the first-launch greeting.
    func speakDirect(_ text: String) async {
        await speakText(text, isFinal: true)
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

            // Track barge-in.
            if vadOutput.speechStarted {
                pendingBargeIn = PendingBargeIn(capturedAt: Date(), lastRms: vadOutput.rms)
            }
            if vadOutput.isSpeech, pendingBargeIn != nil {
                pendingBargeIn?.speechSamples += chunk.samples.count
                pendingBargeIn?.lastRms = vadOutput.rms

                // Check barge-in confirmation.
                let confirmSamples = (config.bargeIn.confirmMs * config.audio.inputSampleRate) / 1000
                if let barge = pendingBargeIn,
                   barge.speechSamples >= confirmSamples,
                   config.bargeIn.enabled
                {
                    handleBargeIn(rms: barge.lastRms)
                    pendingBargeIn = nil
                }
            }

            // Adjust VAD silence threshold based on assistant state.
            if assistantSpeaking {
                vad.setSilenceThresholdMs(config.bargeIn.bargeInSilenceMs)
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
            return
        }

        // LLM quality gate — drop ambient noise.
        if rms < 0.008 && durationSecs > 3.0 {
            NSLog("PipelineCoordinator: dropping ambient segment (rms=%.4f, dur=%.1fs)", rms, durationSecs)
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

            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            NSLog("PipelineCoordinator: STT → \"%@\"", text)
            eventBus.send(.transcription(text: text, isFinal: true))

            // Gate check.
            guard gateState == .active else { return }

            // Check for sleep phrases.
            let lower = text.lowercased()
            if config.conversation.sleepPhrases.contains(where: { lower.contains($0) }) {
                sleep()
                return
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
            await playback.stop()
        }

        // Intent classification.
        let lastAssistant = await conversationState.lastAssistantText
        let intent = IntentClassifier.classify(queryText, lastAssistantText: lastAssistant)

        if intent.needsTools {
            // Speak canned acknowledgment, then dispatch to background agent.
            let ack = PersonalityManager.nextToolAcknowledgment()
            await speakText(ack, isFinal: true)
            await conversationState.addUserMessage(queryText)
            await conversationState.addAssistantMessage(ack)

            // Spawn background agent with filtered tool registry.
            NSLog("PipelineCoordinator: tool intent detected, tools: %@", intent.toolAllowlist.joined(separator: ", "))
            await spawnBackgroundAgent(userText: queryText, toolAllowlist: intent.toolAllowlist)
            return
        }

        if intent.needsThinking {
            let ack = PersonalityManager.nextThinkingAcknowledgment()
            await speakText(ack, isFinal: false)
        }

        // Generate LLM response.
        await generateAndSpeak(userText: queryText)
    }

    /// Run LLM generation and stream output to TTS.
    private func generateAndSpeak(userText: String) async {
        await refreshDegradedModeIfNeeded(context: "before_generation")

        guard await llmEngine.isLoaded else {
            NSLog("PipelineCoordinator: LLM not loaded")
            return
        }

        interrupted = false
        assistantGenerating = true
        eventBus.send(.assistantGenerating(true))

        // Play thinking tone.
        await playback.playThinkingTone()

        // Add user message to history.
        await conversationState.addUserMessage(userText)
        let history = await conversationState.history

        // Memory recall — inject context before generation.
        let memoryContext = await memoryOrchestrator?.recall(query: userText)

        // Build system prompt.
        var systemPrompt = PersonalityManager.assemblePrompt(
            voiceOptimized: true,
            userName: config.userName
        )
        if let context = memoryContext {
            systemPrompt += "\n\n" + context
        }

        let options = GenerationOptions(
            temperature: config.llm.temperature,
            topP: config.llm.topP,
            maxTokens: config.llm.maxTokens,
            repetitionPenalty: config.llm.repeatPenalty
        )

        // Stream tokens.
        thinkTagStripper = TextProcessing.ThinkTagStripper()
        var fullResponse = ""
        var sentenceBuffer = ""
        let llmStartedAt = Date()
        var llmTokenCount = 0

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
                guard !visible.isEmpty else { continue }

                fullResponse += visible
                sentenceBuffer += visible

                // Check for sentence boundary — send to TTS.
                if let boundary = TextProcessing.findSentenceBoundary(in: sentenceBuffer) {
                    let sentence = String(sentenceBuffer[..<boundary])
                    let cleaned = TextProcessing.stripNonSpeechChars(sentence)
                    if !cleaned.isEmpty {
                        eventBus.send(.assistantText(text: cleaned, isFinal: false))
                        await speakText(cleaned, isFinal: false)
                    }
                    sentenceBuffer = String(sentenceBuffer[boundary...])
                } else if sentenceBuffer.count > 200 {
                    // Force-flush long buffer at clause boundary.
                    if let clause = TextProcessing.findClauseBoundary(in: sentenceBuffer) {
                        let text = String(sentenceBuffer[..<clause])
                        let cleaned = TextProcessing.stripNonSpeechChars(text)
                        if !cleaned.isEmpty {
                            eventBus.send(.assistantText(text: cleaned, isFinal: false))
                            await speakText(cleaned, isFinal: false)
                        }
                        sentenceBuffer = String(sentenceBuffer[clause...])
                    }
                }
            }
        } catch {
            NSLog("PipelineCoordinator: LLM error: %@", error.localizedDescription)
        }

        let llmElapsed = Date().timeIntervalSince(llmStartedAt)
        if llmElapsed > 0 {
            let throughput = Double(llmTokenCount) / llmElapsed
            NSLog("phase1.llm_token_throughput_tps=%.2f", throughput)
        }

        // Flush remaining text.
        let remaining = thinkTagStripper.flush()
        sentenceBuffer += remaining
        let finalText = TextProcessing.stripNonSpeechChars(sentenceBuffer)
        if !finalText.isEmpty {
            eventBus.send(.assistantText(text: finalText, isFinal: true))
            await speakText(finalText, isFinal: true)
        }

        fullResponse += remaining
        if !fullResponse.isEmpty {
            await conversationState.addAssistantMessage(fullResponse)

            // Memory capture — persist durable memories from this turn.
            let turnId = newMemoryId(prefix: "turn")
            _ = await memoryOrchestrator?.capture(
                turnId: turnId,
                userText: userText,
                assistantText: fullResponse
            )

            // Sentiment → orb feeling: classify the response and update the orb.
            if let feeling = SentimentClassifier.classify(fullResponse) {
                eventBus.send(.orbStateChanged(mode: "idle", feeling: feeling.rawValue, palette: nil))
            }
        }

        assistantGenerating = false
        eventBus.send(.assistantGenerating(false))

        // Refresh follow-up window after assistant responds.
        engagedUntil = Date().addingTimeInterval(
            Double(config.conversation.directAddressFollowupS)
        )
    }

    // MARK: - TTS

    private func speakText(_ text: String, isFinal: Bool) async {
        guard await ttsEngine.isLoaded else {
            NSLog("PipelineCoordinator: TTS not loaded, skipping speech")
            return
        }

        assistantSpeaking = true
        echoSuppressor.onAssistantSpeechStart()

        do {
            let ttsStartedAt = Date()
            var ttsFirstChunkEmitted = false
            let audioStream = await ttsEngine.synthesize(text: text)
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
        }
    }

    // MARK: - Barge-In

    private func handleBargeIn(rms: Float) {
        guard config.bargeIn.enabled else { return }
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

    // MARK: - Background Agent Dispatch

    /// Spawn a background agent with a filtered tool registry to handle tool-needing queries.
    private func spawnBackgroundAgent(userText: String, toolAllowlist: [String]) async {
        guard await llmEngine.isLoaded else {
            NSLog("PipelineCoordinator: LLM not loaded, cannot spawn agent")
            return
        }

        // Speak a context-specific progress cue.
        if let cue = Self.toolProgressPhrase(toolAllowlist) {
            await speakText(cue, isFinal: false)
        }

        // Emit tool executing event for UI feedback.
        let primaryTool = toolAllowlist.first ?? "tool"
        eventBus.send(.toolExecuting(name: primaryTool))

        // Build filtered registry.
        let registry = ToolRegistry.buildFiltered(allowlist: toolAllowlist)

        // Build agent.
        let agent = AgentLoop(
            llmEngine: llmEngine,
            registry: registry,
            approvalManager: approvalManager,
            config: config,
            eventBus: eventBus
        )

        // Build system prompt with permission context.
        let permissionContext = PermissionStatusProvider.promptFragment()
        let systemPrompt = PersonalityManager.backgroundAgentPrompt
            + "\n\n" + permissionContext
            + "\n\nAvailable tools:\n" + registry.toolSchemas

        let history = await conversationState.history

        // Run the agent loop.
        let result = await agent.run(
            userText: userText,
            systemPrompt: systemPrompt,
            history: history
        )

        // Emit tool result event.
        eventBus.send(.toolResult(id: UUID().uuidString, name: primaryTool, success: true, output: result))

        // Add result to conversation history and speak it.
        let cleanResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanResult.isEmpty {
            await conversationState.addAssistantMessage(cleanResult)
            eventBus.send(.assistantText(text: cleanResult, isFinal: true))
            await speakText(cleanResult, isFinal: true)

            // Memory capture.
            let turnId = newMemoryId(prefix: "agent")
            _ = await memoryOrchestrator?.capture(
                turnId: turnId,
                userText: userText,
                assistantText: cleanResult
            )

            // Sentiment → orb feeling.
            if let feeling = SentimentClassifier.classify(cleanResult) {
                eventBus.send(.orbStateChanged(mode: "idle", feeling: feeling.rawValue, palette: nil))
            }
        }

        // Refresh follow-up engagement window.
        engagedUntil = Date().addingTimeInterval(
            Double(config.conversation.directAddressFollowupS)
        )
    }

    /// Context-specific progress phrase based on tool allowlist.
    private static func toolProgressPhrase(_ allowlist: [String]) -> String? {
        if allowlist.contains("calendar") { return "Checking your calendar." }
        if allowlist.contains("reminders") { return "Looking at your reminders." }
        if allowlist.contains("contacts") { return "Searching your contacts." }
        if allowlist.contains("mail") { return "Checking your mail." }
        if allowlist.contains("notes") { return "Looking through your notes." }
        if allowlist.contains("bash") { return "Running that command." }
        if allowlist.contains("web_search") || allowlist.contains("fetch_url") { return "Searching the web." }
        if allowlist.contains("scheduler_list") || allowlist.contains("scheduler_create") { return "Checking your scheduled tasks." }
        return nil
    }

    // MARK: - Helpers

    private static func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frameCount = Int(buffer.frameLength)
        guard let channelData = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
    }
}
