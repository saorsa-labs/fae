import XCTest
@testable import Fae

// MARK: - SensitiveDataRedactor.looksLikeCredential Tests

final class CredentialDetectorTests: XCTestCase {

    // MARK: - Known-prefix positives

    func testDetectsOpenAIKey() {
        XCTAssertTrue(
            SensitiveDataRedactor.looksLikeCredential("sk-" + "proj-abc123defghi456jklmno789"),
            "OpenAI sk- key must be detected"
        )
    }

    func testDetectsGitHubToken() {
        XCTAssertTrue(
            SensitiveDataRedactor.looksLikeCredential("ghp" + "_ABCDEFGHIJKLMNOPQRSTUVWXYZabcd"),
            "GitHub ghp_ token must be detected"
        )
    }

    func testDetectsSlackBotToken() {
        XCTAssertTrue(
            SensitiveDataRedactor.looksLikeCredential("xoxb" + "-123456789012-ABCDEFGHIJKLMNO"),
            "Slack xoxb- token must be detected"
        )
    }

    func testDetectsGoogleAPIKey() {
        XCTAssertTrue(
            SensitiveDataRedactor.looksLikeCredential("AIza" + "SyDummyKeyFor0Testing1234567"),
            "Google AIza key must be detected"
        )
    }

    // MARK: - High-entropy heuristic positive

    func testDetectsHighEntropyFortyCharToken() {
        // 40 pure-alphanumeric chars with no spaces — classic opaque bearer token shape.
        let token = "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0"
        XCTAssertTrue(
            SensitiveDataRedactor.looksLikeCredential(token),
            "40-char no-space alphanumeric token must be detected by entropy heuristic"
        )
    }

    func testDetectsExactly20CharToken() {
        // Boundary: exactly 20 compact-alphanumeric chars.
        let token = "Abcdef1234Ghijkl5678"
        XCTAssertTrue(
            SensitiveDataRedactor.looksLikeCredential(token),
            "20-char compact token should be detected"
        )
    }

    // MARK: - Hint-context positive

    func testDetectsShortValueWhenHintContainsKey() {
        // Even a short value (≥8 chars, no spaces) triggers when the hint says "API key".
        XCTAssertTrue(
            SensitiveDataRedactor.looksLikeCredential("abc12345", hint: "Enter your API key"),
            "Short no-space value with 'key' in hint must be detected"
        )
    }

    func testDetectsShortValueWhenHintContainsToken() {
        XCTAssertTrue(
            SensitiveDataRedactor.looksLikeCredential("tok12345", hint: "Paste your access token"),
            "Short no-space value with 'token' in hint must be detected"
        )
    }

    func testDetectsShortValueWhenHintContainsSecret() {
        XCTAssertTrue(
            SensitiveDataRedactor.looksLikeCredential("hunter42", hint: "Webhook secret"),
            "Short no-space value with 'secret' in hint must be detected"
        )
    }

    // MARK: - Negatives (legitimate inputs)

    func testDoesNotFlagNormalSentence() {
        XCTAssertFalse(
            SensitiveDataRedactor.looksLikeCredential("The quick brown fox jumped over the lazy dog"),
            "Ordinary sentence must not be flagged"
        )
    }

    func testDoesNotFlagShortWord() {
        XCTAssertFalse(
            SensitiveDataRedactor.looksLikeCredential("hello"),
            "Short common word must not be flagged"
        )
    }

    func testDoesNotFlagEmptyString() {
        XCTAssertFalse(
            SensitiveDataRedactor.looksLikeCredential(""),
            "Empty string must not be flagged"
        )
    }

    func testDoesNotFlagNameWithHintForURL() {
        // A person's name asked for via a URL-type prompt — hint has no credential word.
        XCTAssertFalse(
            SensitiveDataRedactor.looksLikeCredential("John Smith", hint: "What is your name?"),
            "Full name (contains space) must not be flagged even with neutral hint"
        )
    }

    func testDoesNotFlagShortValueWithNoCredentialHint() {
        // 8 chars, no spaces — but no hint keyword, so context-path doesn't fire.
        XCTAssertFalse(
            SensitiveDataRedactor.looksLikeCredential("abc12345"),
            "Short value with no hint should not be flagged without credential keyword context"
        )
    }
}

// MARK: - InputRequestTool credential withholding contract

/// Tests the static path: withhold produces the instructive error message and
/// the raw value is absent. These verify the detector integration rather than
/// the async Bridge (which requires a live UI), so they call looksLikeCredential
/// directly to mirror the logic in execute().
final class InputRequestWithholdPathTests: XCTestCase {

    func testWithholdPathReturnsInstructiveError() {
        // Simulate what execute() does: if looksLikeCredential fires, the
        // return value is the instructive error, not the raw credential.
        let fakeCredential = "sk-" + "proj-realtoken1234567890abcdef"
        let hint = "Enter your OpenAI API key"

        if SensitiveDataRedactor.looksLikeCredential(fakeCredential, hint: hint) {
            let result = "[input looked like a credential and was withheld; re-ask with secure:true and store_key:<name> to store it safely]"
            XCTAssertTrue(result.contains("withheld"), "Withhold message must say 'withheld'")
            XCTAssertTrue(result.contains("secure:true"), "Withhold message must mention secure:true")
            XCTAssertTrue(result.contains("store_key"), "Withhold message must mention store_key")
            XCTAssertFalse(result.contains(fakeCredential), "Raw credential must not appear in result")
        } else {
            XCTFail("Credential detector must fire for a sk- token with API key hint")
        }
    }

    func testWithholdFiresEvenWhenSecureIsTrue() {
        // secure:true without store_key still triggers the withhold path,
        // because secure+returnToModel=true would otherwise leak raw credential.
        let fakeCredential = "ghp" + "_ABCDEFGHIJKLMNOPQRSTUVWXYZabcd"
        XCTAssertTrue(
            SensitiveDataRedactor.looksLikeCredential(fakeCredential, hint: "GitHub token"),
            "Detector must fire for ghp_ token — withhold applies even when caller sets secure:true"
        )
    }

    func testEmailAddressIsNotWithheld() {
        // Fae legitimately asks for emails (mail/channel setup). An email must
        // never be withheld — even when the prompt mentions "auth".
        XCTAssertFalse(
            SensitiveDataRedactor.looksLikeCredential(
                "david.irvine@maidsafe.net",
                hint: "What email should I use for authentication?"
            ),
            "Email-shaped values are exempt from entropy/hint heuristics"
        )
    }

    func testPlainUrlIsNotWithheld() {
        // "Paste the link" is a legitimate clear-text request.
        XCTAssertFalse(
            SensitiveDataRedactor.looksLikeCredential(
                "https://api.example.com/v1/resources/some-long-path",
                hint: "Paste the API docs link"
            ),
            "URL-shaped values are exempt from entropy/hint heuristics"
        )
    }

    func testUrlEmbeddingProviderTokenIsStillWithheld() {
        // A credential embedded in a URL must still be caught by the explicit
        // provider-prefix patterns — the URL exemption only skips heuristics.
        XCTAssertTrue(
            SensitiveDataRedactor.looksLikeCredential(
                "https://example.com/callback?key=" + "sk-" + "ABCDEFGHIJKL1234",
                hint: ""
            ),
            "Provider-token patterns run before the URL exemption"
        )
    }

    // MARK: - A-2: whitespace-bearing secrets withheld via SensitiveContentPolicy

    /// Mirrors the tool gate `looksLikeCredential(value, hint) ||
    /// SensitiveContentPolicy.scan(value).containsSensitiveContent`.
    private func inputWouldBeWithheld(_ value: String, hint: String = "") -> Bool {
        SensitiveDataRedactor.looksLikeCredential(value, hint: hint)
            || SensitiveContentPolicy.scan(value).containsSensitiveContent
    }

    func testMultilinePEMBlockIsWithheld() {
        // A pasted private-key block has whitespace/newlines, so the token-shaped
        // looksLikeCredential heuristic misses it — SensitiveContentPolicy must
        // close the gap so the raw key is never returned to the model. The 64-char
        // base64 body lines of a real PEM trip the long-opaque-token rule.
        let body = "MIIEowIBAAKCAQEAabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKL"
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n"
            + body + "\n"
            + body + "\n"
            + "-----END OPENSSH PRIVATE KEY-----"

        XCTAssertFalse(
            SensitiveDataRedactor.looksLikeCredential(pem),
            "Baseline: the whitespace-free heuristic alone misses a multi-line PEM block"
        )
        XCTAssertTrue(
            inputWouldBeWithheld(pem),
            "Combined gate must withhold a multi-line PEM private-key block"
        )
    }

    func testSeedPhrasePhraseIsWithheld() {
        // "seed phrase" / "recovery phrase" wording is highlySensitive by policy
        // even though it contains spaces (so looksLikeCredential does not fire).
        let value = "my recovery phrase is table chair window ocean forest planet"
        XCTAssertFalse(
            SensitiveDataRedactor.looksLikeCredential(value),
            "Baseline: spaced seed-phrase text is missed by the token heuristic"
        )
        XCTAssertTrue(
            inputWouldBeWithheld(value),
            "Combined gate must withhold a spoken seed/recovery phrase"
        )
    }

    func testPasswordAssignmentPhraseIsWithheld() {
        let value = "the password is hunter2please"
        XCTAssertTrue(
            inputWouldBeWithheld(value),
            "Combined gate must withhold a 'password is …' assignment"
        )
    }

    // MARK: - A-3: URL exemption must not leak embedded credentials

    func testBasicAuthCredentialInURLIsWithheld() {
        // https://user:pass@host embeds a basic-auth secret — must NOT be exempted.
        XCTAssertTrue(
            SensitiveDataRedactor.looksLikeCredential("https://admin:s3cr3tPass@internal.example.com/api"),
            "basic-auth userinfo in a URL must be treated as a credential"
        )
    }

    func testAccessTokenQueryParamInURLIsWithheld() {
        XCTAssertTrue(
            SensitiveDataRedactor.looksLikeCredential("https://example.com/callback?access_token=Zx19abcd"),
            "?access_token= in a URL must be treated as a credential"
        )
    }

    func testCleanHttpsURLIsStillExempted() {
        XCTAssertFalse(
            SensitiveDataRedactor.looksLikeCredential("https://example.com/docs/getting-started"),
            "A clean https URL with no embedded secret must remain exempt"
        )
    }

    func testStoreKeyPathNotAffected() {
        // When store_key is set, execute() returns early before reaching the
        // credential guard. Verify the detector would fire for such a value so
        // it's clear the early-exit is intentional (the value is already stored).
        let fakeCredential = "sk-realtoken1234567890"
        // looksLikeCredential would return true for this value, confirming the
        // guard fires for the same class of input — but execute() exits earlier
        // via CredentialManager.store(), so the withhold path is never reached.
        XCTAssertTrue(
            SensitiveDataRedactor.looksLikeCredential(fakeCredential),
            "Detector confirms the value class — store_key path bypasses withhold correctly"
        )
    }
}

// MARK: - Memory capture redaction tests

final class MemoryCaptureRedactionTests: XCTestCase {

    func testSkTokenRedactedFromEpisodeText() {
        let fakeKey = "sk-" + "proj-ABCDEFGHIJKLMNOPQRSTUVWXYZ12345"
        let textWithKey = "My OpenAI key is \(fakeKey) and I just set it up"
        let redacted = SensitiveDataRedactor.redact(textWithKey)

        XCTAssertNotNil(redacted)
        XCTAssertFalse(
            redacted!.contains(fakeKey),
            "sk- token must be absent after redaction"
        )
        XCTAssertTrue(
            redacted!.contains("REDACTED"),
            "Redacted placeholder must appear in output"
        )
    }

    func testGhpTokenRedactedFromEpisodeText() {
        let fakeToken = "ghp" + "_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123"
        let textWithToken = "Here is my GitHub token: \(fakeToken) please store it"
        let redacted = SensitiveDataRedactor.redact(textWithToken)

        XCTAssertNotNil(redacted)
        XCTAssertFalse(
            redacted!.contains(fakeToken),
            "ghp_ token must be absent after redaction"
        )
    }

    func testHighEntropyTokenRedactedFromEpisodeText() {
        // A 40-char pure-alphanumeric bearer token embedded in conversation text.
        let bearer = "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0"
        let text = "Use this token \(bearer) to authenticate"
        let redacted = SensitiveDataRedactor.redact(text)

        XCTAssertNotNil(redacted)
        XCTAssertFalse(
            redacted!.contains(bearer),
            "High-entropy token must be absent after redaction"
        )
    }

    func testNormalConversationUnchanged() {
        let normal = "Remind me to call Alice tomorrow at 3pm about the project."
        let redacted = SensitiveDataRedactor.redact(normal)

        XCTAssertEqual(redacted, normal, "Normal conversation text must pass through unmodified")
    }

    func testSensitiveContentPolicyAndRedactorComposed() {
        // Verify that chaining SensitiveContentPolicy.redactForStorage then
        // SensitiveDataRedactor.redact (the exact order used at the capture boundary)
        // redacts an sk- key that arrives in conversation text.
        let fakeComposed = "sk-" + "proj-Test1234567890abcdefghijklmno"
        let text = "My API key is \(fakeComposed)"
        let afterPolicy = SensitiveContentPolicy.redactForStorage(text)
        let afterBoth = SensitiveDataRedactor.redact(afterPolicy)

        XCTAssertNotNil(afterBoth)
        XCTAssertFalse(
            afterBoth!.contains(fakeComposed),
            "sk- key must be absent after the composed redaction chain used in capture()"
        )
    }
}
