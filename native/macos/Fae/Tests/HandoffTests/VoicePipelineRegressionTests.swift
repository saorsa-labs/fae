import XCTest
@testable import Fae

final class VoicePipelineRegressionTests: XCTestCase {

    func testVadApplyConfigurationRecalculatesDerivedThresholds() {
        var vad = VoiceActivityDetector(sampleRate: 16_000)
        var config = FaeConfig.VadConfig()
        config.minSilenceDurationMs = 640
        config.speechPadMs = 96
        config.minSpeechDurationMs = 320
        config.maxSpeechDurationMs = 2_400

        vad.applyConfiguration(config)
        let derived = vad.debugDerivedThresholds

        XCTAssertEqual(derived.preRollMax, 1_536)
        XCTAssertEqual(derived.silenceSamplesThreshold, 10_240)
        XCTAssertEqual(derived.minSpeechSamples, 5_120)
        XCTAssertEqual(derived.maxSpeechSamples, 38_400)
    }

    func testSileroEngineLoadsAndReturnsProbabilityForSingleFrame() throws {
        let engine = try SileroVADEngine()
        let silence = [Float](repeating: 0, count: SileroVADEngine.chunkSize)

        let probability = try XCTUnwrap(engine.process(samples: silence))

        XCTAssertGreaterThanOrEqual(probability, 0)
        XCTAssertLessThanOrEqual(probability, 1)
    }

    func testSegmentAnalysisRejectsSilence() {
        let silence = [Float](repeating: 0, count: 16_000 * 4)

        let quality = AudioCaptureManager.analyzeSegment(silence)

        XCTAssertFalse(quality.hasUsableSpeech)
        XCTAssertEqual(quality.voicedFrameRatio, 0, accuracy: 0.001)
        XCTAssertEqual(quality.voicedDurationSeconds, 0, accuracy: 0.001)
    }

    func testSegmentAnalysisAcceptsStrongSpeechLikeSignal() {
        // Generate 4s of speech-like signal (two harmonics with amplitude envelope)
        // preceded and followed by 0.5s silence. WeSpeaker needs ~3s+ of voiced
        // speech with voicedDurationSeconds >= 2.0.
        let sampleRate = 16_000
        let speechStart = sampleRate / 2        // 0.5s silence lead-in
        let speechEnd = speechStart + sampleRate * 4  // 4s of speech
        var samples = [Float](repeating: 0, count: speechEnd + sampleRate / 2)
        for index in speechStart..<speechEnd {
            let t = Float(index - speechStart) / Float(sampleRate)
            let phaseA = 2 * Float.pi * 180 * t
            let phaseB = 2 * Float.pi * 240 * t
            let envelope = 0.75 + 0.25 * sin(2 * Float.pi * 3 * t)
            samples[index] = (sin(phaseA) * 0.12 + sin(phaseB) * 0.08) * envelope
        }

        let quality = AudioCaptureManager.analyzeSegment(samples, sampleRate: sampleRate)

        XCTAssertTrue(quality.hasUsableSpeech)
        XCTAssertGreaterThan(quality.voicedFrameRatio, 0.18)
        XCTAssertGreaterThan(quality.voicedDurationSeconds, 2.0)
    }

    func testShouldSkipSTTAfterSpeakerVerificationForUnknownSpeakerWhenOwnerExists() {
        XCTAssertTrue(
            PipelineCoordinator.shouldSkipSTTAfterSpeakerVerification(
                ownerProfileExists: true,
                speakerVerificationCompleted: true,
                firstOwnerEnrollmentActive: false,
                speakerRole: nil
            )
        )
    }

    func testStreamingSpeakerSimilarityDecisionAllowsStrongMatch() {
        XCTAssertEqual(
            PipelineCoordinator.streamingSpeakerSimilarityDecision(
                bestHumanSimilarity: 0.78,
                acceptThreshold: 0.70,
                rejectThreshold: 0.50
            ),
            .allow
        )
    }

    func testStreamingSpeakerSimilarityDecisionRejectsLowSimilarity() {
        XCTAssertEqual(
            PipelineCoordinator.streamingSpeakerSimilarityDecision(
                bestHumanSimilarity: 0.42,
                acceptThreshold: 0.70,
                rejectThreshold: 0.50
            ),
            .reject
        )
    }

    func testStreamingSpeakerSimilarityDecisionStaysUndecidedInMiddleBand() {
        XCTAssertEqual(
            PipelineCoordinator.streamingSpeakerSimilarityDecision(
                bestHumanSimilarity: 0.61,
                acceptThreshold: 0.70,
                rejectThreshold: 0.50
            ),
            .undecided
        )
    }

    func testStreamingSpeakerSimilarityDecisionRejectsMissingProfiles() {
        XCTAssertEqual(
            PipelineCoordinator.streamingSpeakerSimilarityDecision(
                bestHumanSimilarity: nil,
                acceptThreshold: 0.70,
                rejectThreshold: 0.50
            ),
            .reject
        )
    }

    func testFusedVoiceAttentionWakesWhenAddressedFromIdle() {
        XCTAssertEqual(
            PipelineCoordinator.fusedVoiceAttentionDecision(
                gateState: .idle,
                explicitWakeRequired: false,
                requireDirectAddress: true,
                addressedToFae: true,
                inFollowup: false,
                awaitingApproval: false,
                firstOwnerEnrollmentActive: false,
                speakerAllowsConversation: true,
                wordCount: 4
            ),
            .wakeAndContinue
        )
    }

    func testFusedVoiceAttentionWakesSleepingOwnerSpeechWhenWakeWordDrops() {
        XCTAssertEqual(
            PipelineCoordinator.fusedVoiceAttentionDecision(
                gateState: .idle,
                explicitWakeRequired: false,
                requireDirectAddress: true,
                addressedToFae: false,
                inFollowup: false,
                awaitingApproval: false,
                firstOwnerEnrollmentActive: false,
                speakerAllowsConversation: true,
                wordCount: 6
            ),
            .wakeAndContinue
        )
    }

    func testFusedVoiceAttentionKeepsExplicitQuietModeAsleepUntilAddressed() {
        XCTAssertEqual(
            PipelineCoordinator.fusedVoiceAttentionDecision(
                gateState: .idle,
                explicitWakeRequired: true,
                requireDirectAddress: true,
                addressedToFae: false,
                inFollowup: false,
                awaitingApproval: false,
                firstOwnerEnrollmentActive: false,
                speakerAllowsConversation: true,
                wordCount: 7
            ),
            .ignoreWhileSleeping
        )
    }

    func testFusedVoiceAttentionStillWakesExplicitQuietModeWhenAddressed() {
        XCTAssertEqual(
            PipelineCoordinator.fusedVoiceAttentionDecision(
                gateState: .idle,
                explicitWakeRequired: true,
                requireDirectAddress: true,
                addressedToFae: true,
                inFollowup: false,
                awaitingApproval: false,
                firstOwnerEnrollmentActive: false,
                speakerAllowsConversation: true,
                wordCount: 3
            ),
            .wakeAndContinue
        )
    }

    func testFusedVoiceAttentionStillIgnoresShortSleepingBackgroundSpeech() {
        XCTAssertEqual(
            PipelineCoordinator.fusedVoiceAttentionDecision(
                gateState: .idle,
                explicitWakeRequired: false,
                requireDirectAddress: true,
                addressedToFae: false,
                inFollowup: false,
                awaitingApproval: false,
                firstOwnerEnrollmentActive: false,
                speakerAllowsConversation: true,
                wordCount: 2
            ),
            .ignoreWhileSleeping
        )
    }

    func testConversationStopTriggerAcceptsBareStopWhileAssistantIsActive() {
        XCTAssertTrue(
            PipelineCoordinator.isConversationStopTrigger(
                text: "stop",
                configuredPhrases: ["go to sleep"],
                assistantSpeaking: true,
                assistantGenerating: false,
                gateState: .active
            )
        )
        XCTAssertTrue(
            PipelineCoordinator.isConversationStopTrigger(
                text: "that's enough",
                configuredPhrases: ["go to sleep"],
                assistantSpeaking: false,
                assistantGenerating: true,
                gateState: .active
            )
        )
    }

    func testConversationStopTriggerRejectsBareStopWhileIdle() {
        XCTAssertFalse(
            PipelineCoordinator.isConversationStopTrigger(
                text: "stop",
                configuredPhrases: ["go to sleep"],
                assistantSpeaking: false,
                assistantGenerating: false,
                gateState: .idle
            )
        )
    }

    func testFusedVoiceAttentionWakesForEnrollmentWithoutDirectAddress() {
        XCTAssertEqual(
            PipelineCoordinator.fusedVoiceAttentionDecision(
                gateState: .idle,
                explicitWakeRequired: false,
                requireDirectAddress: true,
                addressedToFae: false,
                inFollowup: false,
                awaitingApproval: false,
                firstOwnerEnrollmentActive: true,
                speakerAllowsConversation: true,
                wordCount: 4
            ),
            .wakeAndContinue
        )
    }

    func testFusedVoiceAttentionStillDropsTinyEnrollmentFragments() {
        XCTAssertEqual(
            PipelineCoordinator.fusedVoiceAttentionDecision(
                gateState: .idle,
                explicitWakeRequired: false,
                requireDirectAddress: true,
                addressedToFae: false,
                inFollowup: false,
                awaitingApproval: false,
                firstOwnerEnrollmentActive: true,
                speakerAllowsConversation: true,
                wordCount: 2
            ),
            .dropShortIdle
        )
    }

    func testLlmFailureFallbackUsesOnboardingSpecificCopy() {
        XCTAssertEqual(
            PipelineCoordinator.llmFailureFallbackMessage(
                firstOwnerEnrollmentActive: true,
                proactiveContextPresent: false
            ),
            "I can hear you. Use Let me get to know you to record your voice, and then I'll recognize you properly."
        )
    }

    func testLlmFailureFallbackSkipsProactiveTurns() {
        XCTAssertNil(
            PipelineCoordinator.llmFailureFallbackMessage(
                firstOwnerEnrollmentActive: false,
                proactiveContextPresent: true
            )
        )
    }

    func testFusedVoiceAttentionAllowsFollowupWithoutAddress() {
        XCTAssertEqual(
            PipelineCoordinator.fusedVoiceAttentionDecision(
                gateState: .active,
                explicitWakeRequired: false,
                requireDirectAddress: true,
                addressedToFae: false,
                inFollowup: true,
                awaitingApproval: false,
                firstOwnerEnrollmentActive: false,
                speakerAllowsConversation: true,
                wordCount: 5
            ),
            .allow
        )
    }

    func testFusedVoiceAttentionDropsWhenDirectAddressRequired() {
        XCTAssertEqual(
            PipelineCoordinator.fusedVoiceAttentionDecision(
                gateState: .active,
                explicitWakeRequired: false,
                requireDirectAddress: true,
                addressedToFae: false,
                inFollowup: false,
                awaitingApproval: false,
                firstOwnerEnrollmentActive: false,
                speakerAllowsConversation: true,
                wordCount: 5
            ),
            .dropDirectAddress
        )
    }

    func testFusedVoiceAttentionDropsShortIdleFragments() {
        XCTAssertEqual(
            PipelineCoordinator.fusedVoiceAttentionDecision(
                gateState: .active,
                explicitWakeRequired: false,
                requireDirectAddress: false,
                addressedToFae: false,
                inFollowup: false,
                awaitingApproval: false,
                firstOwnerEnrollmentActive: false,
                speakerAllowsConversation: true,
                wordCount: 2
            ),
            .dropShortIdle
        )
    }

    func testFusedVoiceAttentionDropsDisallowedSpeaker() {
        XCTAssertEqual(
            PipelineCoordinator.fusedVoiceAttentionDecision(
                gateState: .active,
                explicitWakeRequired: false,
                requireDirectAddress: false,
                addressedToFae: true,
                inFollowup: false,
                awaitingApproval: false,
                firstOwnerEnrollmentActive: false,
                speakerAllowsConversation: false,
                wordCount: 4
            ),
            .dropSpeaker
        )
    }

    func testSemanticTurnDefersClearlyIncompletePhrase() {
        XCTAssertTrue(
            PipelineCoordinator.shouldDeferSemanticTurn(
                text: "set a timer for",
                addressedToFae: false,
                inFollowup: true,
                awaitingApproval: false,
                hasPendingGovernanceAction: false,
                firstOwnerEnrollmentActive: false
            )
        )
    }

    func testSemanticTurnDoesNotDeferBareWakePhrase() {
        XCTAssertFalse(
            PipelineCoordinator.shouldDeferSemanticTurn(
                text: "hey fae",
                addressedToFae: true,
                inFollowup: false,
                awaitingApproval: false,
                hasPendingGovernanceAction: false,
                firstOwnerEnrollmentActive: false
            )
        )
    }

    func testSemanticTurnDoesNotDeferCompleteSentence() {
        XCTAssertFalse(
            PipelineCoordinator.shouldDeferSemanticTurn(
                text: "set a timer for ten minutes.",
                addressedToFae: false,
                inFollowup: true,
                awaitingApproval: false,
                hasPendingGovernanceAction: false,
                firstOwnerEnrollmentActive: false
            )
        )
    }

    func testIncompleteTurnDetectorHandlesHesitationFragments() {
        XCTAssertTrue(TextProcessing.isLikelyIncompleteTurn("hold on"))
        XCTAssertTrue(TextProcessing.isLikelyIncompleteTurn("let me check"))
        XCTAssertTrue(TextProcessing.isLikelyIncompleteTurn("can you set a timer for the"))
        XCTAssertFalse(TextProcessing.isLikelyIncompleteTurn("set a timer for ten minutes"))
        XCTAssertTrue(TextProcessing.isLikelyContinuationCue("no wait"))
        XCTAssertFalse(TextProcessing.isLikelyContinuationCue("what time is it"))
    }

    func testShortCompleteQuestionsAreNotDeferred() {
        // Regression: short valid questions without "?" must NOT be deferred.
        // ASR (Qwen3-ASR) frequently drops trailing "?" from transcripts.
        // These are complete utterances that should be processed immediately.
        XCTAssertFalse(TextProcessing.isLikelyIncompleteTurn("what time is it"))
        XCTAssertFalse(TextProcessing.isLikelyIncompleteTurn("who are you"))
        XCTAssertFalse(TextProcessing.isLikelyIncompleteTurn("where am i"))
        XCTAssertFalse(TextProcessing.isLikelyIncompleteTurn("is it raining"))
        XCTAssertFalse(TextProcessing.isLikelyIncompleteTurn("can you hear me"))
        XCTAssertFalse(TextProcessing.isLikelyIncompleteTurn("how are you"))
        // NOTE: "do you know" intentionally omitted — matches trailing bigram
        // "you know" (continuation cue).  The heuristic errs on patience there.
        XCTAssertFalse(TextProcessing.isLikelyIncompleteTurn("whats the weather"))

        // But partials that end with function words/determiners ARE still caught:
        XCTAssertTrue(TextProcessing.isLikelyIncompleteTurn("what's the"))  // "the" is a determiner
        XCTAssertTrue(TextProcessing.isLikelyIncompleteTurn("I want to"))   // "to" is a function word
        XCTAssertTrue(TextProcessing.isLikelyIncompleteTurn("can you set a timer for the"))  // "the"
    }

    func testIncompleteTurnUnclosedSubordinateClause() {
        // Leading clause opener without a main clause.
        XCTAssertTrue(TextProcessing.isLikelyIncompleteTurn("if it rains"))
        XCTAssertTrue(TextProcessing.isLikelyIncompleteTurn("because the server"))
        XCTAssertTrue(TextProcessing.isLikelyIncompleteTurn("unless you want"))
        XCTAssertTrue(TextProcessing.isLikelyIncompleteTurn("although i agree"))

        // Subordinator NOT in leading position — should not fire.
        // "since" was removed from clause openers to avoid temporal false positives.
        XCTAssertFalse(TextProcessing.isLikelyIncompleteTurn("since yesterday morning"))

        // Short phrases (< 3 tokens) — clause opener heuristic doesn't fire,
        // but "so" is in trailingFunctionWords so "if so" is still caught.
        XCTAssertTrue(TextProcessing.isLikelyIncompleteTurn("if so"))  // "so" in trailing function words
    }

    func testSemanticTurnDoesNotDeferDuringOnboarding() {
        XCTAssertFalse(
            PipelineCoordinator.shouldDeferSemanticTurn(
                text: "my name is david and",
                addressedToFae: false,
                inFollowup: true,
                awaitingApproval: false,
                hasPendingGovernanceAction: false,
                firstOwnerEnrollmentActive: true
            )
        )
    }

    func testShouldNotSkipSTTWhenVerificationUnavailable() {
        XCTAssertFalse(
            PipelineCoordinator.shouldSkipSTTAfterSpeakerVerification(
                ownerProfileExists: true,
                speakerVerificationCompleted: false,
                firstOwnerEnrollmentActive: false,
                speakerRole: nil
            )
        )
    }

    func testShouldNotSkipSTTDuringFirstOwnerEnrollment() {
        XCTAssertFalse(
            PipelineCoordinator.shouldSkipSTTAfterSpeakerVerification(
                ownerProfileExists: true,
                speakerVerificationCompleted: true,
                firstOwnerEnrollmentActive: true,
                speakerRole: nil
            )
        )
    }

    func testShouldNotSkipSTTForTrustedSpeaker() {
        XCTAssertFalse(
            PipelineCoordinator.shouldSkipSTTAfterSpeakerVerification(
                ownerProfileExists: true,
                speakerVerificationCompleted: true,
                firstOwnerEnrollmentActive: false,
                speakerRole: .trusted
            )
        )
    }

    func testBargeInCandidateAccumulatesAcrossSpeechChunks() {
        let chunk = [Float](repeating: 0.12, count: 512)

        var pending = PipelineCoordinator.advancePendingBargeIn(
            pending: nil,
            speechStarted: true,
            isSpeech: true,
            chunkSamples: chunk,
            rms: 0.12,
            echoSuppression: false,
            bargeInSuppressed: false,
            inDenyCooldown: false
        )
        XCTAssertEqual(pending?.speechSamples, 512)
        XCTAssertEqual(pending?.audioSamples.count, 512)

        pending = PipelineCoordinator.advancePendingBargeIn(
            pending: pending,
            speechStarted: false,
            isSpeech: true,
            chunkSamples: chunk,
            rms: 0.11,
            echoSuppression: false,
            bargeInSuppressed: false,
            inDenyCooldown: false
        )
        XCTAssertEqual(pending?.speechSamples, 1_024)
        XCTAssertEqual(pending?.audioSamples.count, 1_024)
        XCTAssertEqual(Double(pending?.lastRms ?? 0), 0.11, accuracy: 0.0001)
    }

    func testDeferredFollowUpStartsOnlyForSameTurnWhenIdle() {
        XCTAssertTrue(
            PipelineCoordinator.shouldStartDeferredFollowUp(
                originTurnID: "turn-a",
                currentTurnID: "turn-a",
                assistantSpeaking: false,
                assistantGenerating: false
            )
        )
        XCTAssertFalse(
            PipelineCoordinator.shouldStartDeferredFollowUp(
                originTurnID: "turn-a",
                currentTurnID: "turn-b",
                assistantSpeaking: false,
                assistantGenerating: false
            )
        )
        XCTAssertFalse(
            PipelineCoordinator.shouldStartDeferredFollowUp(
                originTurnID: "turn-a",
                currentTurnID: "turn-a",
                assistantSpeaking: false,
                assistantGenerating: true
            )
        )
    }

    func testDeferredProactiveQueueCoalescesDuplicateTasks() {
        let next = PipelineCoordinator.coalescedDeferredProactiveTaskIDs(
            existing: ["camera_presence_check", "screen_activity_check"],
            incomingTaskID: "camera_presence_check"
        )

        XCTAssertEqual(
            next,
            ["screen_activity_check", "camera_presence_check"]
        )
    }

    func testDirectAddressLingerUsesLongestConversationWindow() {
        XCTAssertEqual(
            PipelineCoordinator.idleRearmSeconds(
                requireDirectAddress: true,
                idleTimeoutS: 45,
                directAddressFollowupS: 12
            ),
            45
        )
        XCTAssertEqual(
            PipelineCoordinator.idleRearmSeconds(
                requireDirectAddress: false,
                idleTimeoutS: 45,
                directAddressFollowupS: 12
            ),
            45
        )
    }

    func testConversationalSilenceThresholdStaysPatientDuringFollowup() {
        XCTAssertEqual(
            PipelineCoordinator.silenceThresholdMs(
                assistantSpeaking: false,
                gateState: .active,
                inFollowup: true,
                hasPendingSemanticTurn: false,
                configMinSilenceMs: 1000,
                bargeInSilenceMs: 600
            ),
            1800
        )
        XCTAssertEqual(
            PipelineCoordinator.silenceThresholdMs(
                assistantSpeaking: true,
                gateState: .active,
                inFollowup: true,
                hasPendingSemanticTurn: true,
                configMinSilenceMs: 1000,
                bargeInSilenceMs: 600
            ),
            600
        )
    }

    func testEchoTailRejectsSegmentContainedInsideSuppressionWindow() {
        let suppressUntil: TimeInterval = 102
        let onset: TimeInterval = 100.4

        XCTAssertTrue(
            EchoSuppressor.shouldRejectForEchoTail(
                segmentOnset: onset,
                durationSecs: 1.0,
                suppressUntil: suppressUntil
            )
        )
    }

    func testEchoTailAcceptsPromptUserUtteranceThatContinuesPastTail() {
        let suppressUntil: TimeInterval = 102
        let onset: TimeInterval = 100.4

        XCTAssertFalse(
            EchoSuppressor.shouldRejectForEchoTail(
                segmentOnset: onset,
                durationSecs: 3.1,
                suppressUntil: suppressUntil
            )
        )
    }

    func testOnboardingTurnsSkipMemoryRecall() {
        XCTAssertFalse(
            PipelineCoordinator.shouldRecallMemoryForTurn(
                firstOwnerEnrollmentActive: true,
                userText: "hello",
                availableToolNames: ["read"]
            )
        )
        XCTAssertTrue(
            PipelineCoordinator.shouldRecallMemoryForTurn(
                firstOwnerEnrollmentActive: false,
                userText: "tell me a joke",
                availableToolNames: ["read"]
            )
        )
    }

    func testOnboardingTurnsExposeNoTools() {
        // Voice-identity teardown: enrollment turns expose no tools at all.
        XCTAssertEqual(
            PipelineCoordinator.visibleToolNamesForTurn(
                firstOwnerEnrollmentActive: true,
                userText: "",
                availableToolNames: ["read", "bash"],
                proactiveAllowedTools: ["read", "bash"]
            ),
            []
        )
        XCTAssertEqual(
            PipelineCoordinator.visibleToolNamesForTurn(
                firstOwnerEnrollmentActive: false,
                userText: "",
                availableToolNames: ["read", "bash"],
                proactiveAllowedTools: ["read", "bash"]
            ),
            ["read", "bash"]
        )
    }

    // MARK: - ASR Command Corrections

    func testCommandCorrectionFixesClearAllGarble() {
        let corrected = TextProcessing.correctNameRecognition("The law reminds us.")
        XCTAssertEqual(corrected, "clear all reminders.")
    }

    func testCommandCorrectionFixesMarkAllGarble() {
        let corrected = TextProcessing.correctNameRecognition("Marco, my reminder is done.")
        XCTAssertTrue(corrected.lowercased().contains("mark all my reminder"))
    }

    func testCommandCorrectionDoesNotAlterNormalSpeech() {
        let normal = "Tell me what the reminders are."
        XCTAssertEqual(TextProcessing.correctNameRecognition(normal), normal)
    }

    // MARK: - Context Budget

    func testRecommendedMaxHistoryAccountsForLargeSystemPrompt() {
        // 32K context with 4096 maxTokens, P-H2 8K system budget:
        // available = 32768 - 8000 - 4096 = 20672 tokens → 51 messages.
        let maxHistory = FaeConfig.recommendedMaxHistory(contextSize: 32_768, maxTokens: 4_096)
        XCTAssertEqual(maxHistory, 51, "32K context should yield 51 history messages")
    }

    func testRecommendedMaxHistoryHandlesSmallContext() {
        // 8K context: available = 8192 - 8000 - 2048 = negative → 6 (minimum)
        let maxHistory = FaeConfig.recommendedMaxHistory(contextSize: 8_192, maxTokens: 2_048)
        XCTAssertEqual(maxHistory, 6, "Small context should clamp to minimum 6")
    }

    // MARK: - Streaming TTS: batchedTTSSegments (Phase 1.3)

    func testBatchedTTSSegmentsEmptyStringReturnsEmpty() {
        let segments = PipelineCoordinator.batchedTTSSegments(from: "")
        XCTAssertTrue(segments.isEmpty, "Empty input must produce no segments")
    }

    func testBatchedTTSSegmentsShortTextReturnsSingleSegment() {
        let text = "Hello, how are you?"
        let segments = PipelineCoordinator.batchedTTSSegments(from: text)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first, text)
    }

    func testBatchedTTSSegmentsLongMultiSentenceSplitsCorrectly() {
        // Build a string that exceeds 420 chars and has a clear sentence boundary.
        // Each repetition is ~60 chars; 8 repetitions = ~480 chars total before sentence2.
        let sentence1 = String(repeating: "This is the first sentence with enough words to fill space. ", count: 8)
        let sentence2 = "This is the second sentence."
        let text = sentence1 + sentence2
        XCTAssertGreaterThan(text.count, 420, "Test string must exceed maxCharacters threshold")

        let segments = PipelineCoordinator.batchedTTSSegments(from: text)
        XCTAssertGreaterThan(segments.count, 1, "Long multi-sentence text must be split")
        // Each segment must be non-empty.
        for segment in segments {
            XCTAssertFalse(segment.isEmpty, "No segment should be empty")
        }
        // Rejoining segments should approximate the original text.
        let rejoined = segments.joined(separator: " ")
        XCTAssertFalse(rejoined.isEmpty)
    }

    func testBatchedTTSSegmentsPreservesSegmentOrder() {
        // Ensure segments appear in the same order as the original text.
        // "Alpha sentence comes first." is ~28 chars. Need total >420.
        let first = "Alpha sentence comes first. "
        // Each filler repetition is ~72 chars; 6 repetitions = ~432 chars.
        let filler = String(repeating: "Filler content that takes up space without any punctuation here so it goes on ", count: 6)
        let last = "Beta sentence comes last."
        let text = first + filler + last
        XCTAssertGreaterThan(text.count, 420, "Test string must exceed maxCharacters threshold")

        let segments = PipelineCoordinator.batchedTTSSegments(from: text)
        guard let firstSeg = segments.first else {
            XCTFail("Expected at least one segment")
            return
        }
        XCTAssertTrue(firstSeg.lowercased().contains("alpha"),
                      "First segment should contain 'alpha' — got: \(firstSeg)")
    }

    func testBatchedTTSSegmentsHandlesWhitespaceOnlyInput() {
        let segments = PipelineCoordinator.batchedTTSSegments(from: "   \n\t  ")
        XCTAssertTrue(segments.isEmpty, "Whitespace-only input must produce no segments")
    }

    func testBatchedTTSSegmentsHandlesEmojiAndUnicode() {
        // Emoji must not cause a crash or produce garbled segments.
        let text = "Great news! 🎉 This is the second sentence with emoji. 🚀 And a third one here."
        let segments = PipelineCoordinator.batchedTTSSegments(from: text)
        XCTAssertFalse(segments.isEmpty)
        for segment in segments {
            XCTAssertFalse(segment.isEmpty)
        }
    }

    func testBatchedTTSSegmentsVeryLongSingleSentenceStaysIntact() {
        // A single sentence >420 chars without any internal boundary gets returned as-is.
        // (No boundary found → split at maxCharacters index → remainder loop handles rest)
        let longWord = String(repeating: "verylongword ", count: 40) // ~560 chars
        let segments = PipelineCoordinator.batchedTTSSegments(from: longWord)
        XCTAssertFalse(segments.isEmpty, "Should produce at least one segment")
        // Verify no segment is empty.
        for segment in segments {
            XCTAssertFalse(segment.isEmpty)
        }
    }

    func testBatchedTTSSegmentsCustomMaxCharacters() {
        let text = "First sentence here. Second sentence here. Third sentence here."
        // With a tiny max, each sentence should become its own segment.
        let segments = PipelineCoordinator.batchedTTSSegments(from: text, maxCharacters: 25)
        XCTAssertGreaterThan(segments.count, 1, "Should split into multiple segments at low maxCharacters")
    }

    func testConversationStateTrimHistoryRespectsReservedTokens() async {
        let state = ConversationStateTracker()
        await state.setContextBudget(contextSize: 32_768, reservedTokens: 28_000)

        // Add many messages — should be trimmed aggressively.
        for i in 0..<20 {
            await state.addUserMessage("Message \(i) with some reasonable length content here.")
            await state.addAssistantMessage("Response \(i) with some reasonable length content too.")
        }

        let history = await state.history
        // With 28K reserved out of 32K, only ~4768 tokens for history.
        // Each message ≈ 20 tokens. Should be heavily trimmed.
        XCTAssertLessThan(history.count, 20, "History should be trimmed when reserved tokens are large")
    }
}
