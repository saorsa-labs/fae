import XCTest
@testable import Fae

/// Coverage for `SecureInputIntent` — the deterministic secure-input detector
/// that routes "store my API key/password" requests to the secure Keychain card
/// instead of trusting the 4B model to call `input_request`. Pure logic.
///
/// The WHY these tests encode (Rule 9): the detector must be CONSERVATIVE. A
/// false positive (an unwanted secure card) is a worse UX than a miss, so the
/// negative cases (questions, "I saved the file", messages already carrying a
/// secret) must stay non-firing even as the positive grammar is extended.
final class SecureInputIntentTests: XCTestCase {

    // MARK: - Positives (must fire)

    func testFiresOnSaveOpenAIKey() {
        let intent = SecureInputIntent.secretStorageIntent("save my openai api key")
        XCTAssertEqual(intent?.storeKey, "openai_api_key")
    }

    func testFiresWithExplicitCallItName() {
        let intent = SecureInputIntent.secretStorageIntent("store this password call it wifi")
        XCTAssertEqual(intent?.storeKey, "wifi")
    }

    func testFiresOnKeepGithubTokenAsGh() {
        // "gh" is too short for a Keychain key (min 3 chars), so the derived key
        // falls back to the provider slot — but the intent must still fire.
        let intent = SecureInputIntent.secretStorageIntent("keep my github token as gh")
        XCTAssertNotNil(intent)
        XCTAssertEqual(intent?.storeKey, "github_token")
    }

    func testFiresOnOpenRouterKeyWithProviderSlot() {
        let intent = SecureInputIntent.secretStorageIntent("remember my openrouter api key")
        XCTAssertEqual(intent?.storeKey, "openrouter.apiKey")
    }

    func testFiresOnBarePasswordUsesNounDerivedKey() {
        let intent = SecureInputIntent.secretStorageIntent("save my password")
        XCTAssertEqual(intent?.storeKey, "password")
    }

    func testDerivedStoreKeysAreAlwaysSafeKeychainKeys() {
        for phrase in [
            "save my openai api key",
            "store this password call it wifi",
            "keep my github token as gh",
            "remember my openrouter api key",
            "set my anthropic api key",
        ] {
            let key = SecureInputIntent.secretStorageIntent(phrase)?.storeKey
            XCTAssertNotNil(key, "expected \(phrase) to fire")
            if let key {
                XCTAssertTrue(
                    InputRequestTool.isSafeKeychainKey(key),
                    "derived key \(key) for \(phrase) must be a safe Keychain key"
                )
            }
        }
    }

    // MARK: - Negatives (must NOT fire)

    func testDoesNotFireOnQuestion() {
        XCTAssertNil(SecureInputIntent.secretStorageIntent("how do I store passwords safely?"))
    }

    func testDoesNotFireOnSavedTheFile() {
        // "file" is not a secret-noun (and past-tense "saved" is not a store-verb).
        XCTAssertNil(SecureInputIntent.secretStorageIntent("I saved the file"))
    }

    func testDoesNotFireOnRememberToBuyMilk() {
        // "remember" is a store-verb but there is no secret-noun.
        XCTAssertNil(SecureInputIntent.secretStorageIntent("remember to buy milk"))
    }

    func testDoesNotFireWhenMessageContainsRawSecret() {
        // The message already carries a raw token — the W2 withholding path owns
        // this; the detector must not open a (redundant) card.
        XCTAssertNil(
            SecureInputIntent.secretStorageIntent("save my api key sk-abcdefghijklmnopqrstuvwx")
        )
    }

    func testDoesNotFireOnWhereQuestion() {
        XCTAssertNil(SecureInputIntent.secretStorageIntent("where do I keep my api key?"))
    }

    // MARK: - Anti-hallucination backstop

    func testClaimsCredentialSavedDetectsFalseClaim() {
        XCTAssertTrue(SecureInputIntent.claimsCredentialSaved("I've securely saved that API key."))
        XCTAssertTrue(SecureInputIntent.claimsCredentialSaved("Done — your password is stored now."))
    }

    func testClaimsCredentialSavedIgnoresNonCredentialSaves() {
        XCTAssertFalse(SecureInputIntent.claimsCredentialSaved("I saved that to your reminders."))
        XCTAssertFalse(SecureInputIntent.claimsCredentialSaved("I stored the file in Documents."))
    }

    func testClaimsCredentialSavedRespectsNegation() {
        XCTAssertFalse(SecureInputIntent.claimsCredentialSaved("I haven't saved your api key yet."))
        XCTAssertFalse(SecureInputIntent.claimsCredentialSaved("Your api key was not stored."))
    }
}
