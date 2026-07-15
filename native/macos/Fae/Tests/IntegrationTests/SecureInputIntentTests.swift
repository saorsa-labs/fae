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

    // Live incident 2026-07-15: both replies Fae actually produced after the
    // owner's HF key went uncaptured. The first was caught by the original
    // verb set; the second ("secured") slipped through — both must now trip
    // the backstop so a false "it's saved" claim never stands.
    func testClaimsCredentialSavedCatchesLiveIncidentPhrases() {
        XCTAssertTrue(SecureInputIntent.claimsCredentialSaved(
            "Got it, the Hugging Face API key is securely stored."))
        XCTAssertTrue(SecureInputIntent.claimsCredentialSaved(
            "I've got your Hugging Face API key secured."))
    }

    func testClaimsCredentialSavedCatchesWidenedVerbs() {
        XCTAssertTrue(SecureInputIntent.claimsCredentialSaved(
            "Your API key is safe with me."))
        XCTAssertTrue(SecureInputIntent.claimsCredentialSaved(
            "I'm keeping your token protected."))
        XCTAssertTrue(SecureInputIntent.claimsCredentialSaved(
            "I've remembered your password."))
        // "keychain" is itself credential context — no separate noun needed.
        XCTAssertTrue(SecureInputIntent.claimsCredentialSaved(
            "It's in your keychain now."))
        XCTAssertTrue(SecureInputIntent.claimsCredentialSaved(
            "I put that in the keychain for you."))
    }

    func testClaimsCredentialSavedWidenedVerbsKeepPrecision() {
        // Widened verbs still require a secret noun (or "keychain") nearby.
        XCTAssertFalse(SecureInputIntent.claimsCredentialSaved(
            "Your files are safe and stored in Documents."))
        XCTAssertFalse(SecureInputIntent.claimsCredentialSaved(
            "I've remembered your birthday."))
        // Negation guard applies to the widened verbs too.
        XCTAssertFalse(SecureInputIntent.claimsCredentialSaved(
            "I haven't secured your api key yet."))
    }

    // MARK: - Credential-shaped input_request detection (auto-secure)

    func testCredentialRequestStoreKeyDetectsHuggingFacePrompt() {
        // The live incident's request shape: prompt names the provider + noun.
        XCTAssertEqual(
            SecureInputIntent.credentialRequestStoreKey(
                prompt: "Enter your Hugging Face API key to continue"),
            "huggingface_token")
    }

    func testCredentialRequestStoreKeyUsesProviderSlot() {
        XCTAssertEqual(
            SecureInputIntent.credentialRequestStoreKey(
                prompt: "Paste the OpenRouter API key", title: "API Key Required"),
            "openrouter.apiKey")
    }

    func testCredentialRequestStoreKeyFallsBackToNounSlot() {
        XCTAssertEqual(
            SecureInputIntent.credentialRequestStoreKey(prompt: "Please enter the password"),
            "password")
    }

    func testCredentialRequestStoreKeyNilForOrdinaryInput() {
        XCTAssertNil(SecureInputIntent.credentialRequestStoreKey(prompt: "What's your name?"))
        XCTAssertNil(SecureInputIntent.credentialRequestStoreKey(prompt: "Paste the article URL"))
    }

    // MARK: - Intercepted-token slot inference (composer paste path)

    func testInterceptedTokenSlotFromPrefix() {
        XCTAssertEqual(
            SecureInputIntent.storeKey(forInterceptedToken: "hf_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456"),
            "huggingface_token")
        XCTAssertEqual(
            SecureInputIntent.storeKey(forInterceptedToken: "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcd"),
            "github_token")
        XCTAssertEqual(
            SecureInputIntent.storeKey(forInterceptedToken: "sk-ant-abc123def456ghi789"),
            "anthropic_api_key")
        XCTAssertEqual(
            SecureInputIntent.storeKey(forInterceptedToken: "sk-proj-abc123def456ghi789"),
            "openai_api_key")
    }

    func testInterceptedTokenSlotFromContextHintThenGeneric() {
        XCTAssertEqual(
            SecureInputIntent.storeKey(
                forInterceptedToken: "ZZZZ1234YYYY5678XXXX",
                contextHint: "I'm ready for your Hugging Face API key"),
            "huggingface_token")
        XCTAssertEqual(
            SecureInputIntent.storeKey(forInterceptedToken: "ZZZZ1234YYYY5678XXXX"),
            "captured_credential")
    }

    func testInterceptedTokenSlotsAreSafeKeychainKeys() {
        for token in ["hf_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456", "ghp_ABCDEFGHIJKLMNOP",
                      "sk-abc", "xoxb-1234", "AKIA1234", "ZZZZ1234"] {
            XCTAssertTrue(
                InputRequestTool.isSafeKeychainKey(
                    SecureInputIntent.storeKey(forInterceptedToken: token)),
                "slot for \(token) must be a safe Keychain key")
        }
    }
}
