import Foundation

/// Pure static helper functions for gate control, silence threshold calculation,
/// speaker verification decisions, voice attention gating, and semantic turn deferral.
///
/// Extracted from PipelineCoordinator to reduce its line count.
/// All functions are stateless.
enum GateHelpers {

    // MARK: - Idle / Silence

    static func idleRearmSeconds(
        requireDirectAddress: Bool,
        idleTimeoutS: Int,
        directAddressFollowupS: Int
    ) -> Int {
        if requireDirectAddress {
            return max(max(directAddressFollowupS, idleTimeoutS), 5)
        }
        return max(idleTimeoutS, 0)
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
        eouProbability: Float? = nil,
        conversationalSilenceFloorMs: Int = 1800
    ) -> Int {
        if assistantSpeaking {
            return bargeInSilenceMs
        }

        let conversationalTurnActive = gateState == .active && (inFollowup || hasPendingSemanticTurn)

        // Neural turn detector signal.
        let eouThreshold: Float = 0.0049
        if let eou = eouProbability, !assistantSpeaking {
            if eou < eouThreshold {
                return max(configMinSilenceMs, 2200)
            } else if eou > eouThreshold * 4 {
                if let ema = emaSuggestedMs {
                    return min(ema, configMinSilenceMs)
                }
                return configMinSilenceMs
            }
        }

        // Transcript-aware endpointing.
        if let transcript = lastPartialTranscript, !transcript.isEmpty {
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

            if TextProcessing.isLikelyContinuationCue(trimmed) {
                let continuationFloorMs = 3000
                return max(configMinSilenceMs, continuationFloorMs)
            }

            if TextProcessing.isLikelyIncompleteTurn(trimmed) {
                let incompleteFloorMs = 2200
                return max(configMinSilenceMs, incompleteFloorMs)
            }

            if let ema = emaSuggestedMs {
                return min(ema, configMinSilenceMs)
            }
            return configMinSilenceMs
        }

        if conversationalTurnActive {
            return max(configMinSilenceMs, conversationalSilenceFloorMs)
        }

        if let ema = emaSuggestedMs {
            return max(ema, configMinSilenceMs)
        }

        return configMinSilenceMs
    }

    // MARK: - Speaker Verification

    static func shouldSkipSTTAfterSpeakerVerification(
        ownerProfileExists: Bool,
        speakerVerificationCompleted: Bool,
        firstOwnerEnrollmentActive: Bool,
        speakerRole: SpeakerRole?
    ) -> Bool {
        guard ownerProfileExists, speakerVerificationCompleted else {
            return false
        }
        return !VoiceConversationPolicy.allowsConversation(
            ownerProfileExists: ownerProfileExists,
            firstOwnerEnrollmentActive: firstOwnerEnrollmentActive,
            speakerRole: speakerRole
        )
    }

    static func streamingSpeakerSimilarityDecision(
        bestHumanSimilarity: Float?,
        acceptThreshold: Float,
        rejectThreshold: Float
    ) -> StreamingSpeakerSimilarityDecision {
        guard let bestHumanSimilarity else {
            return .reject
        }
        if bestHumanSimilarity >= acceptThreshold {
            return .allow
        }
        if bestHumanSimilarity <= rejectThreshold {
            return .reject
        }
        return .undecided
    }

    // MARK: - Voice Attention

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
        if firstOwnerEnrollmentActive {
            if !speakerAllowsConversation {
                return .dropSpeaker
            }
            if !awaitingApproval,
               !addressedToFae,
               wordCount <= 2
            {
                return .dropShortIdle
            }
            if gateState != .active {
                return .wakeAndContinue
            }
        }

        if gateState != .active {
            if addressedToFae {
                return .wakeAndContinue
            }
            if explicitWakeRequired {
                return .ignoreWhileSleeping
            }
            if speakerAllowsConversation && wordCount >= 4 {
                return .wakeAndContinue
            }
            return .ignoreWhileSleeping
        }

        if requireDirectAddress,
           !addressedToFae,
           !inFollowup,
           !awaitingApproval,
           !firstOwnerEnrollmentActive
        {
            return .dropDirectAddress
        }

        if !awaitingApproval,
           !inFollowup,
           !addressedToFae,
           wordCount <= 2
        {
            return .dropShortIdle
        }

        if !speakerAllowsConversation {
            return .dropSpeaker
        }

        return .allow
    }

    // MARK: - Semantic Turn Deferral

    static func shouldDeferSemanticTurn(
        text: String,
        addressedToFae: Bool,
        inFollowup: Bool,
        awaitingApproval: Bool,
        hasPendingGovernanceAction: Bool,
        firstOwnerEnrollmentActive: Bool
    ) -> Bool {
        guard !awaitingApproval,
              !hasPendingGovernanceAction,
              !firstOwnerEnrollmentActive
        else {
            return false
        }

        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        if addressedToFae && wordCount <= 2 {
            return false
        }

        guard inFollowup || addressedToFae || wordCount >= 3 else {
            return false
        }

        return TextProcessing.isLikelyIncompleteTurn(text)
    }
}
