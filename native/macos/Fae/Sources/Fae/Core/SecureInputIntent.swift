import Foundation

/// A detected intent to store a secret (API key / password / token) under a
/// named Keychain slot.
struct SecretStoreIntent: Equatable, Sendable {
    /// The Keychain slot name the value should be stored under. Always a
    /// valid `InputRequestTool.isSafeKeychainKey` string.
    let storeKey: String
}

/// Deterministic, model-free detection of "store a secret" intent.
///
/// Gemma-4-E4B (the 4B local model) does NOT reliably call the `input_request`
/// tool when the owner asks Fae to save an API key / password / secret — it
/// treats the request as chat, asks the user to type the secret into the reply
/// (leaking it into plain context), and has been observed to HALLUCINATE
/// success ("I've securely saved that API key") without collecting or storing
/// anything. Per CLAUDE.md Rule 5 ("if code can answer, code answers — don't
/// use the model for deterministic routing"), routing to the secure input card
/// is done in Swift, not by strengthening the prompt.
///
/// The detector is intentionally CONSERVATIVE: a false positive (popping a
/// secure card the user did not want) is a worse UX than a miss, so it requires
/// BOTH a store-verb AND a secret-noun, rejects questions, and rejects messages
/// that already contain a secret-looking value (that is `SensitiveDataRedactor`
/// / the W2 withholding path's job — let it withhold).
enum SecureInputIntent {

    // MARK: - Store-intent detection

    /// Returns a `SecretStoreIntent` when `text` clearly means "store/save a
    /// secret", or nil otherwise.
    ///
    /// Fires only when ALL of the following hold:
    ///   1. a store-verb is present (save / store / keep / remember / set),
    ///   2. a secret-noun is present (api key / password / token / secret / …),
    ///   3. the message is not a question ("how do I store a password?"),
    ///   4. the message does not already contain a raw secret value.
    ///
    /// Trigger examples that DO fire:
    ///   - "save my openai api key"           → openai_api_key
    ///   - "store this password call it wifi" → wifi
    ///   - "keep my github token as gh"       → github_token (explicit "gh" is
    ///                                          too short for a Keychain key, so
    ///                                          it falls back to the provider key)
    ///
    /// Trigger examples that do NOT fire:
    ///   - "how do I store passwords safely?" (question)
    ///   - "I saved the file"                 (no secret-noun)
    ///   - "remember to buy milk"             (no secret-noun)
    ///   - "my key is sk-abc123…"             (already contains a secret value)
    static func secretStorageIntent(_ text: String) -> SecretStoreIntent? {
        let lower = text.lowercased()

        // 4. Reject when the message already carries a raw secret — the W2
        //    structural credential guard withholds those; opening a card would
        //    be redundant and the value must not be echoed into the card path.
        if SensitiveDataRedactor.looksLikeCredential(text) {
            return nil
        }

        // 3. Reject questions — "how do I store a password?" is guidance, not a
        //    request to store one.
        if looksLikeQuestion(lower) {
            return nil
        }

        // 1 + 2. Require BOTH a store-verb and a secret-noun.
        guard matches(storeVerbPattern, in: lower) else { return nil }
        guard let noun = firstSecretNoun(in: lower) else { return nil }

        return SecretStoreIntent(storeKey: deriveStoreKey(from: lower, noun: noun))
    }

    // MARK: - Anti-hallucination backstop

    /// Returns true when `reply` claims a credential was saved/stored/kept.
    ///
    /// Scoped TIGHTLY to credential nouns so it does not trip on legitimate
    /// "I saved that to your reminders" / "I stored the file" — only claims
    /// mentioning an api key / password / token / secret / credential count.
    /// A negation near the verb ("I have NOT saved your key") does not count.
    static func claimsCredentialSaved(_ reply: String) -> Bool {
        let lower = reply.lowercased()
        let ns = lower as NSString
        guard let verbRe = try? NSRegularExpression(pattern: #"\b(saved|stored|kept)\b"#) else {
            return false
        }
        let matches = verbRe.matches(in: lower, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            let verbStart = match.range.location
            // Window around the verb for the credential noun.
            let windowStart = max(0, verbStart - 60)
            let windowEnd = min(ns.length, match.range.location + match.range.length + 60)
            let window = ns.substring(with: NSRange(location: windowStart, length: windowEnd - windowStart))
            guard firstSecretNoun(in: window) != nil else { continue }
            // Negation guard: reject "have not saved", "haven't stored", etc.
            let negStart = max(0, verbStart - 24)
            let negWindow = ns.substring(with: NSRange(location: negStart, length: verbStart - negStart))
            if containsNegation(negWindow) { continue }
            return true
        }
        return false
    }

    // MARK: - Internals

    /// Store verbs (with common inflections). Word-bounded so "keeper" ≠ "keep".
    private static let storeVerbPattern =
        #"\b(save|saves|saving|store|stores|storing|keep|keeping|remember|remembering|set|setting)\b"#

    /// Secret nouns, longest-first so "api key" wins over a bare "key" and
    /// multi-word forms match before single-word ones.
    private static let secretNouns: [String] = [
        "openai api key", "openrouter api key", "anthropic api key",
        "access key", "private key", "secret key", "api key", "apikey",
        "api-key", "passphrase", "password", "credentials", "credential",
        "token", "secret",
    ]

    private static func firstSecretNoun(in lower: String) -> String? {
        for noun in secretNouns where lower.contains(noun) {
            return noun
        }
        return nil
    }

    private static func looksLikeQuestion(_ lower: String) -> Bool {
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let questionStarts = ["how ", "what ", "whats ", "what's ", "why ", "where ",
                              "when ", "which ", "who ", "should i "]
        if questionStarts.contains(where: { trimmed.hasPrefix($0) }) {
            return true
        }
        let questionPhrases = ["how do i", "how can i", "how should i", "how to ",
                               "is it safe", "what's the best", "whats the best",
                               "best way to", "what is the best"]
        return questionPhrases.contains(where: { lower.contains($0) })
    }

    private static func containsNegation(_ window: String) -> Bool {
        let negations = ["not", "n't", "never", "unable", "cannot", "can't",
                         "won't", "couldn't", "didn't", "haven't", "without", "wasn't"]
        return negations.contains(where: { window.contains($0) })
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// Known providers → their conventional Keychain slot names.
    private static let providerKeys: [(needle: String, key: String)] = [
        ("openrouter", "openrouter.apiKey"),
        ("openai", "openai_api_key"),
        ("anthropic", "anthropic_api_key"),
        ("github", "github_token"),
        ("gitlab", "gitlab_token"),
        ("discord", "discord_bot_token"),
        ("gemini", "gemini_api_key"),
        ("google", "google_api_key"),
        ("huggingface", "huggingface_token"),
        ("hugging face", "huggingface_token"),
    ]

    /// Derive a safe Keychain slot name.
    ///
    /// Priority: an explicit user name ("call it X" / "name it X" / "as X") when
    /// it yields a valid key; else a known provider slot; else a noun-derived
    /// default; else "secret". Every returned key passes
    /// `InputRequestTool.isSafeKeychainKey`.
    private static func deriveStoreKey(from lower: String, noun: String) -> String {
        if let named = explicitName(in: lower), InputRequestTool.isSafeKeychainKey(named) {
            return named
        }
        for provider in providerKeys where lower.contains(provider.needle) {
            return provider.key
        }
        let nounKey = slugify(noun)
        if InputRequestTool.isSafeKeychainKey(nounKey) {
            return nounKey
        }
        return "secret"
    }

    /// Extract a single-token name from "call it X" / "name it X" / "as X".
    private static func explicitName(in lower: String) -> String? {
        let patterns = [
            #"call it ([a-z0-9._-]+)"#,
            #"name it ([a-z0-9._-]+)"#,
            #"named ([a-z0-9._-]+)"#,
            #" as ([a-z0-9._-]+)"#,
        ]
        let ns = lower as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            guard let match = regex.firstMatch(
                in: lower, range: NSRange(location: 0, length: ns.length)
            ), match.numberOfRanges > 1 else { continue }
            return slugify(ns.substring(with: match.range(at: 1)))
        }
        return nil
    }

    private static func slugify(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let replaced = lowered.replacingOccurrences(
            of: #"[^a-z0-9._-]+"#, with: "_", options: .regularExpression
        )
        return replaced.trimmingCharacters(in: CharacterSet(charactersIn: "_-."))
    }
}
