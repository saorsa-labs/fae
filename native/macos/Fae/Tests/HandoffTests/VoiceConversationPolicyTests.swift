import XCTest
@testable import Fae

final class VoiceConversationPolicyTests: XCTestCase {
    func testOwnerAndTrustedSpeakersCanConverseWhenOwnerExists() {
        XCTAssertTrue(
            VoiceConversationPolicy.allowsConversation(
                ownerProfileExists: true,
                firstOwnerEnrollmentActive: false,
                speakerRole: .owner
            )
        )
        XCTAssertTrue(
            VoiceConversationPolicy.allowsConversation(
                ownerProfileExists: true,
                firstOwnerEnrollmentActive: false,
                speakerRole: .trusted
            )
        )
    }

    func testUnknownSpeakersCannotConverseAfterOwnerEnrollment() {
        XCTAssertFalse(
            VoiceConversationPolicy.allowsConversation(
                ownerProfileExists: true,
                firstOwnerEnrollmentActive: false,
                speakerRole: nil
            )
        )
    }

    func testGuestSpeakersCanConverseButNotUseTools() {
        // Guests (voiceprinted) can converse...
        XCTAssertTrue(
            VoiceConversationPolicy.allowsConversation(
                ownerProfileExists: true,
                firstOwnerEnrollmentActive: false,
                speakerRole: .guest
            )
        )
        // ...but cannot use tools.
        XCTAssertFalse(VoiceConversationPolicy.allowsToolUse(speakerRole: .guest))
        XCTAssertTrue(VoiceConversationPolicy.allowsToolUse(speakerRole: .owner))
        XCTAssertTrue(VoiceConversationPolicy.allowsToolUse(speakerRole: .trusted))
        XCTAssertFalse(VoiceConversationPolicy.allowsToolUse(speakerRole: nil))
    }

    func testEnrollmentModeAllowsConversationBeforeOwnerExists() {
        XCTAssertTrue(
            VoiceConversationPolicy.allowsConversation(
                ownerProfileExists: false,
                firstOwnerEnrollmentActive: true,
                speakerRole: nil
            )
        )
    }

    func testUnknownWakeMatchIsIgnoredAfterOwnerEnrollment() {
        XCTAssertFalse(
            VoiceConversationPolicy.shouldHonorWakeMatch(
                ownerProfileExists: true,
                firstOwnerEnrollmentActive: false,
                speakerRole: nil,
                wakeStrength: .exact
            )
        )
    }

    func testGuestWakeMatchIsHonoredAfterOwnerEnrollment() {
        // Guests can converse, so their wake matches should be honored.
        XCTAssertTrue(
            VoiceConversationPolicy.shouldHonorWakeMatch(
                ownerProfileExists: true,
                firstOwnerEnrollmentActive: false,
                speakerRole: .guest,
                wakeStrength: .fuzzy
            )
        )
    }

    func testTrustedWakeMatchAndMemoryAreAllowed() {
        XCTAssertTrue(
            VoiceConversationPolicy.shouldHonorWakeMatch(
                ownerProfileExists: true,
                firstOwnerEnrollmentActive: false,
                speakerRole: .trusted,
                wakeStrength: .fuzzy
            )
        )
        XCTAssertTrue(
            VoiceConversationPolicy.shouldPersistSpeechMemory(
                ownerProfileExists: true,
                firstOwnerEnrollmentActive: false,
                speakerRole: .trusted
            )
        )
    }

    func testSleepHintAndOnboardingCompletionFollowOwnerTruth() {
        XCTAssertFalse(
            VoiceConversationPolicy.shouldOfferSleepHint(
                ownerProfileExists: true,
                firstOwnerEnrollmentActive: false,
                speakerRole: nil
            )
        )
        XCTAssertFalse(VoiceConversationPolicy.shouldCompleteOnboarding(hasOwnerProfile: false))
        XCTAssertTrue(VoiceConversationPolicy.shouldCompleteOnboarding(hasOwnerProfile: true))
    }
}
