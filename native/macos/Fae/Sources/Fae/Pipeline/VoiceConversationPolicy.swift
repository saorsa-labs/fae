import Foundation

enum VoiceConversationWakeStrength: Equatable {
    case exact
    case fuzzy
}

enum VoiceConversationPolicy {
    static func allowsConversation(
        ownerProfileExists: Bool,
        firstOwnerEnrollmentActive: Bool,
        speakerRole: SpeakerRole?
    ) -> Bool {
        guard ownerProfileExists else { return true }
        if firstOwnerEnrollmentActive { return true }
        guard let speakerRole else { return false }

        switch speakerRole {
        case .owner, .trusted, .guest:
            return true
        case .faeSelf:
            return false
        }
    }

    /// Whether the speaker should have access to tools.
    ///
    /// Guests (voiceprinted but not promoted) can converse but cannot use tools.
    /// The owner can grant tool access by promoting a guest to `.trusted`.
    static func allowsToolUse(speakerRole: SpeakerRole?) -> Bool {
        guard let speakerRole else { return false }
        switch speakerRole {
        case .owner, .trusted:
            return true
        case .guest, .faeSelf:
            return false
        }
    }

    static func shouldHonorWakeMatch(
        ownerProfileExists: Bool,
        firstOwnerEnrollmentActive: Bool,
        speakerRole: SpeakerRole?,
        wakeStrength: VoiceConversationWakeStrength?
    ) -> Bool {
        guard wakeStrength != nil else { return false }
        return allowsConversation(
            ownerProfileExists: ownerProfileExists,
            firstOwnerEnrollmentActive: firstOwnerEnrollmentActive,
            speakerRole: speakerRole
        )
    }

    static func shouldOfferSleepHint(
        ownerProfileExists: Bool,
        firstOwnerEnrollmentActive: Bool,
        speakerRole: SpeakerRole?
    ) -> Bool {
        allowsConversation(
            ownerProfileExists: ownerProfileExists,
            firstOwnerEnrollmentActive: firstOwnerEnrollmentActive,
            speakerRole: speakerRole
        )
    }

    static func shouldPersistSpeechMemory(
        ownerProfileExists: Bool,
        firstOwnerEnrollmentActive: Bool,
        speakerRole: SpeakerRole?
    ) -> Bool {
        allowsConversation(
            ownerProfileExists: ownerProfileExists,
            firstOwnerEnrollmentActive: firstOwnerEnrollmentActive,
            speakerRole: speakerRole
        )
    }

    static func shouldCompleteOnboarding(hasOwnerProfile: Bool) -> Bool {
        hasOwnerProfile
    }
}
