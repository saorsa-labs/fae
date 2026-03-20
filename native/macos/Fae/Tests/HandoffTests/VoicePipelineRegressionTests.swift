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
        let sampleRate = 16_000
        var samples = [Float](repeating: 0, count: sampleRate * 4)
        for index in sampleRate..<(sampleRate * 3) {
            let t = Float(index - sampleRate) / Float(sampleRate)
            let phaseA = 2 * Float.pi * 180 * t
            let phaseB = 2 * Float.pi * 240 * t
            let envelope = 0.65 + 0.35 * sin(2 * Float.pi * 3 * t)
            samples[index] = (sin(phaseA) * 0.07 + sin(phaseB) * 0.05) * envelope
        }

        let quality = AudioCaptureManager.analyzeSegment(samples, sampleRate: sampleRate)

        XCTAssertTrue(quality.hasUsableSpeech)
        XCTAssertGreaterThan(quality.voicedFrameRatio, 0.18)
        XCTAssertGreaterThan(quality.voicedDurationSeconds, 0.6)
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
        let suppressUntil = Date(timeIntervalSinceReferenceDate: 102)
        let onset = Date(timeIntervalSinceReferenceDate: 100.4)

        XCTAssertTrue(
            EchoSuppressor.shouldRejectForEchoTail(
                segmentOnset: onset,
                durationSecs: 1.0,
                suppressUntil: suppressUntil
            )
        )
    }

    func testEchoTailAcceptsPromptUserUtteranceThatContinuesPastTail() {
        let suppressUntil = Date(timeIntervalSinceReferenceDate: 102)
        let onset = Date(timeIntervalSinceReferenceDate: 100.4)

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

    func testOnboardingTurnsLimitVisibleToolsToVoiceIdentity() {
        XCTAssertEqual(
            PipelineCoordinator.visibleToolNamesForTurn(
                firstOwnerEnrollmentActive: true,
                userText: "",
                availableToolNames: ["read", "bash", "voice_identity"],
                proactiveAllowedTools: ["read", "bash"]
            ),
            ["voice_identity"]
        )
        XCTAssertEqual(
            PipelineCoordinator.visibleToolNamesForTurn(
                firstOwnerEnrollmentActive: false,
                userText: "",
                availableToolNames: ["read", "bash", "voice_identity"],
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
        // 32K context with 4096 maxTokens:
        // available = 32768 - 18000 - 4096 = 10672 tokens → 26 messages
        let maxHistory = FaeConfig.recommendedMaxHistory(contextSize: 32_768, maxTokens: 4_096)
        XCTAssertLessThanOrEqual(maxHistory, 30, "maxHistory should be conservative on 32K context")
        XCTAssertGreaterThanOrEqual(maxHistory, 6, "maxHistory should be at least 6")
    }

    func testRecommendedMaxHistoryHandlesSmallContext() {
        // 8K context: available = 8192 - 18000 - 2048 = negative → 6 (minimum)
        let maxHistory = FaeConfig.recommendedMaxHistory(contextSize: 8_192, maxTokens: 2_048)
        XCTAssertEqual(maxHistory, 6, "Small context should clamp to minimum 6")
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
