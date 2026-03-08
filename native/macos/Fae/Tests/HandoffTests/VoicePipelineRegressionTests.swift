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

    func testFusedVoiceAttentionIgnoresSleepingBackgroundSpeech() {
        XCTAssertEqual(
            PipelineCoordinator.fusedVoiceAttentionDecision(
                gateState: .idle,
                requireDirectAddress: true,
                addressedToFae: false,
                inFollowup: false,
                awaitingApproval: false,
                firstOwnerEnrollmentActive: false,
                speakerAllowsConversation: true,
                wordCount: 6
            ),
            .ignoreWhileSleeping
        )
    }

    func testFusedVoiceAttentionWakesForEnrollmentWithoutDirectAddress() {
        XCTAssertEqual(
            PipelineCoordinator.fusedVoiceAttentionDecision(
                gateState: .idle,
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

    func testDirectAddressUsesFollowupWindowInsteadOfIdleTimeout() {
        XCTAssertEqual(
            PipelineCoordinator.idleRearmSeconds(
                requireDirectAddress: true,
                idleTimeoutS: 45,
                directAddressFollowupS: 12
            ),
            12
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

    func testOnboardingTurnsSkipMemoryRecall() {
        XCTAssertFalse(PipelineCoordinator.shouldRecallMemoryForTurn(firstOwnerEnrollmentActive: true))
        XCTAssertTrue(PipelineCoordinator.shouldRecallMemoryForTurn(firstOwnerEnrollmentActive: false))
    }

    func testOnboardingTurnsLimitVisibleToolsToVoiceIdentity() {
        XCTAssertEqual(
            PipelineCoordinator.visibleToolNamesForTurn(
                firstOwnerEnrollmentActive: true,
                proactiveAllowedTools: ["read", "bash"]
            ),
            ["voice_identity"]
        )
        XCTAssertEqual(
            PipelineCoordinator.visibleToolNamesForTurn(
                firstOwnerEnrollmentActive: false,
                proactiveAllowedTools: ["read", "bash"]
            ),
            ["read", "bash"]
        )
    }
}
