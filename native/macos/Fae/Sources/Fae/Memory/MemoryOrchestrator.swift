import Foundation

/// Orchestrates memory recall and capture for the voice pipeline.
///
/// Before each LLM generation: `recall(query:)` retrieves relevant context.
/// After each completed turn: `capture(turnId:userText:assistantText:)` extracts
/// and persists durable memories (profile, facts) plus episode records.
///
/// Replaces: `src/memory/jsonl.rs` (MemoryOrchestrator)
actor MemoryOrchestrator {
    private struct ProactiveMemorySpec: Sendable {
        let kind: MemoryKind
        let source: String
        let tags: [String]
        let importanceScore: Float
        let staleAfterSecs: UInt64?
        let lookbackHours: Double
        let recallSources: Set<String>
    }

    private static let arithmeticNumberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty",
        "sixty", "seventy", "eighty", "ninety", "hundred",
    ]

    private let store: SQLiteMemoryStore
    private var config: FaeConfig.MemoryConfig
    private let embeddingEngine: NeuralEmbeddingEngine?
    private let vectorStore: VectorStore?
    private let entityLinker: EntityLinker?
    private let entityStore: EntityStore?

    init(
        store: SQLiteMemoryStore,
        config: FaeConfig.MemoryConfig,
        entityLinker: EntityLinker? = nil,
        entityStore: EntityStore? = nil,
        vectorStore: VectorStore? = nil,
        embeddingEngine: NeuralEmbeddingEngine? = nil
    ) {
        self.store = store
        self.config = config
        self.vectorStore = vectorStore
        self.embeddingEngine = embeddingEngine
        self.entityLinker = entityLinker
        self.entityStore = entityStore
    }

    func setConfig(_ config: FaeConfig.MemoryConfig) {
        self.config = config
    }

    // MARK: - Recall

    /// Build a memory context string for injection into the LLM system prompt.
    func recall(query: String, proactiveTaskId: String? = nil) async -> String? {
        guard config.enabled else { return nil }

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerQuery = normalizedQuery.lowercased()
        let groundingInstructions = groundingInstructions(for: lowerQuery)
        let wantsRecentSummary = isRecentMemorySummaryQuery(lowerQuery)
        let wantsPersonalRecall = isPersonalMemoryQuery(lowerQuery)

        do {
            // Entity-enriched recall: detect person-centric queries first.
            let entityContext = await buildEntityContext(for: normalizedQuery)
            let proactiveContext = try await buildProactiveContext(
                taskId: proactiveTaskId,
                query: normalizedQuery
            )

            let limit = max(config.maxRecallResults, 1)
            let hits = try await store.search(query: normalizedQuery, limit: limit)
            let rerankedHits = await rerankHitsIfPossible(query: normalizedQuery, hits: hits)
            let recallHits = try await supplementedRecallHits(
                query: normalizedQuery,
                lowerQuery: lowerQuery,
                baseHits: rerankedHits
            )

            if recallHits.isEmpty {
                var fallbackParts = groundingInstructions
                if let entityContext {
                    fallbackParts.append(entityContext)
                }
                if let proactiveContext {
                    fallbackParts.append(proactiveContext)
                }
                if let noMatchContext = noMatchMemoryContext(for: lowerQuery) {
                    fallbackParts.append(noMatchContext)
                }
                guard !fallbackParts.isEmpty else { return nil }
                return "<memory_context>\n" + fallbackParts.joined(separator: "\n") + "\n</memory_context>"
            }

            let minConfidence: Float = 0.5
            let now = UInt64(Date().timeIntervalSince1970)

            // Filter out stale records (past their staleAfterSecs expiry).
            let freshHits = recallHits.filter { hit in
                guard let staleSecs = hit.record.staleAfterSecs,
                      hit.record.createdAt > 0
                else { return true }
                return (hit.record.createdAt + staleSecs) > now
            }

            // Split digest, durable, and episode hits.
            let digestHits = wantsRecentSummary ? freshHits.filter {
                $0.record.kind == .digest && $0.record.confidence >= minConfidence
            } : []
            let durableHits = freshHits.filter {
                $0.record.kind != .episode
                    && $0.record.kind != .digest
                    && $0.record.confidence >= minConfidence
            }
            let episodeHits: [MemorySearchHit] = if wantsPersonalRecall || wantsRecentSummary {
                []
            } else {
                freshHits.filter {
                    $0.record.kind == .episode
                        && $0.score >= MemoryConstants.episodeThresholdLexical
                }
            }

            guard !digestHits.isEmpty || !durableHits.isEmpty || !episodeHits.isEmpty
                || entityContext != nil || proactiveContext != nil
            else {
                return nil
            }

            var insightLines: [String] = []
            var supportingLines: [String] = []
            let maxChars = 2000

            for hit in digestHits.prefix(2) {
                guard let line = await formattedRecallLine(for: hit) else { continue }
                let projected = insightLines.joined(separator: "\n").count + line.count
                if projected > maxChars { break }
                insightLines.append(line)
            }

            for hit in durableHits {
                guard let line = await formattedRecallLine(for: hit) else { continue }
                let projected = supportingLines.joined(separator: "\n").count
                    + insightLines.joined(separator: "\n").count
                    + line.count
                if projected > maxChars { break }
                supportingLines.append(line)
            }

            for hit in episodeHits.prefix(3) {
                let line = "- [episode \(String(format: "%.2f", hit.record.confidence))] \(compactMemoryText(hit.record.text, maxLength: 220))"
                let projected = supportingLines.joined(separator: "\n").count
                    + insightLines.joined(separator: "\n").count
                    + line.count
                if projected > maxChars { break }
                supportingLines.append(line)
            }

            var contextParts = groundingInstructions
            if let entitySection = entityContext {
                contextParts.append(entitySection)
            }
            if let proactiveContext {
                contextParts.append(proactiveContext)
            }
            if !insightLines.isEmpty {
                contextParts.append("Memory insights:\n" + insightLines.joined(separator: "\n"))
            }
            if !supportingLines.isEmpty {
                contextParts.append("Supporting memories:\n" + supportingLines.joined(separator: "\n"))
            }
            return "<memory_context>\n" + contextParts.joined(separator: "\n") + "\n</memory_context>"
        } catch {
            NSLog("MemoryOrchestrator: recall error: %@", error.localizedDescription)
            return nil
        }
    }

    func handleForgetCommandIfNeeded(userText: String) async -> String? {
        let normalizedUserText = Self.stripWakePrefix(userText)
        guard let query = Self.extractForgetQuery(from: normalizedUserText) else { return nil }

        do {
            let forgotCount = try await forgetMatching(query: query)
            if forgotCount > 0 {
                return "Okay — I'll forget that and stop relying on it."
            }
            return "I don't have a stored memory for that right now, so I won't rely on it."
        } catch {
            NSLog("MemoryOrchestrator: deterministic forget failed: %@", error.localizedDescription)
            return "I hit a problem forgetting that, so I haven't changed memory yet."
        }
    }

    func handleDirectPersonalRecallIfNeeded(userText: String) async -> String? {
        let normalizedUserText = Self.stripWakePrefix(userText)
        let lowerQuery = normalizedUserText.lowercased()

        do {
            if isNameRecallQuery(lowerQuery) {
                if let name = try await primaryStoredUserName() {
                    return "Your name is \(name)."
                }
                return "I don't have your name stored yet."
            }

            if isFavoriteColorQuery(lowerQuery) {
                if let color = try await storedFavoriteColor() {
                    return "Your favorite color is \(color)."
                }
                return "I don't have your favorite color stored right now."
            }

            if isRecentMemorySummaryQuery(lowerQuery) {
                return try await recentLearningReply()
            }

            return nil
        } catch {
            NSLog("MemoryOrchestrator: deterministic personal recall failed: %@", error.localizedDescription)
            return nil
        }
    }

    func rememberedUserName() async -> String? {
        do {
            return try await primaryStoredUserName()
        } catch {
            NSLog("MemoryOrchestrator: rememberedUserName lookup failed: %@", error.localizedDescription)
            return nil
        }
    }

    private func groundingInstructions(for lowerQuery: String) -> [String] {
        var instructions = [
            "Grounding: Use only the memory records below. Do not invent details that are not present here.",
        ]
        if isPersonalMemoryQuery(lowerQuery) {
            instructions.append(
                "For direct personal-memory questions, prefer durable profile, fact, person, or commitment records over prior question-and-answer episodes."
            )
        }
        if isNameRecallQuery(lowerQuery) {
            instructions.append("For name questions, answer with the stored name directly if it is present.")
        }
        if isRecentMemorySummaryQuery(lowerQuery) {
            instructions.append(
                "For recent-learning questions, summarize Memory insights first and mention imported source labels when helpful."
            )
            instructions.append(
                "Keep the answer focused on imported or proactively gathered material. Do not switch to unrelated preferences, relationships, or commitments."
            )
        }
        return instructions
    }

    private func supplementedRecallHits(
        query: String,
        lowerQuery: String,
        baseHits: [MemorySearchHit]
    ) async throws -> [MemorySearchHit] {
        let wantsRecentSummary = isRecentMemorySummaryQuery(lowerQuery)
        var merged: [MemorySearchHit] = []
        var seenIDs = Set<String>()

        func append(_ hit: MemorySearchHit) {
            guard seenIDs.insert(hit.record.id).inserted else { return }
            merged.append(hit)
        }

        if wantsRecentSummary {
            let recentDigests = try await store.findActiveByKind(.digest, limit: 3)
            for digest in recentDigests {
                append(MemorySearchHit(record: digest, score: max(digest.confidence, 0.95)))
            }
        }

        if isNameRecallQuery(lowerQuery) {
            let nameProfiles = try await store.findActiveByTag("name")
            for profile in nameProfiles {
                append(MemorySearchHit(record: profile, score: max(profile.confidence, 0.99)))
            }
        }

        if isFavoriteColorQuery(lowerQuery) {
            let colorHits = try await store.search(query: "favorite color", limit: max(config.maxRecallResults, 4))
            for hit in colorHits where hit.record.kind != .episode && hit.record.status == .active {
                append(MemorySearchHit(record: hit.record, score: max(hit.score, max(hit.record.confidence, 0.92))))
            }
        }

        for hit in baseHits {
            if wantsRecentSummary,
               hit.record.kind != .digest,
               !isRecentMemorySummarySupportCandidate(hit.record)
            {
                continue
            }
            append(hit)
        }

        if wantsRecentSummary {
            let recentRecords = try await store.recentRecords(limit: max(config.maxRecallResults * 3, 12))
            for record in recentRecords where isRecentMemorySummarySupportCandidate(record) {
                append(MemorySearchHit(record: record, score: max(record.confidence, 0.75)))
            }
        }

        return merged
    }

    private func noMatchMemoryContext(for lowerQuery: String) -> String? {
        guard isPersonalMemoryQuery(lowerQuery) else { return nil }
        return "No matching stored memory found for this personal question. Do not guess or restate forgotten details; answer that you do not know from memory yet."
    }

    private static func extractForgetQuery(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if lower.hasPrefix("forget ") {
            return normalizeForgetQuery(String(trimmed.dropFirst(7)))
        }
        if lower.hasPrefix("please forget ") {
            return normalizeForgetQuery(String(trimmed.dropFirst(14)))
        }
        if let range = lower.range(of: "don't want you to remember ") {
            let query = substring(in: trimmed, matchingLowerRange: range.upperBound..<lower.endIndex)
            return normalizeForgetQuery(query)
        }
        if let range = lower.range(of: "do not want you to remember ") {
            let query = substring(in: trimmed, matchingLowerRange: range.upperBound..<lower.endIndex)
            return normalizeForgetQuery(query)
        }
        if let range = lower.range(of: "want you to forget ") {
            let query = substring(in: trimmed, matchingLowerRange: range.upperBound..<lower.endIndex)
            return normalizeForgetQuery(query)
        }

        return nil
    }

    private static func extractRememberFact(from text: String) -> String? {
        let trimmed = stripWakePrefix(text)
        let lower = trimmed.lowercased()

        if lower.hasPrefix("remember ") {
            return normalizeRememberFact(String(trimmed.dropFirst(9)))
        }
        if lower.hasPrefix("please remember ") {
            return normalizeRememberFact(String(trimmed.dropFirst(16)))
        }
        if let range = lower.range(of: "want you to remember ") {
            let fact = substring(in: trimmed, matchingLowerRange: range.upperBound..<lower.endIndex)
            return normalizeRememberFact(fact)
        }

        return nil
    }

    private static func substring(
        in original: String,
        matchingLowerRange range: Range<String.Index>
    ) -> String {
        let lowerPrefixCount = original.lowercased().distance(from: original.lowercased().startIndex, to: range.lowerBound)
        let lowerUpperCount = original.lowercased().distance(from: original.lowercased().startIndex, to: range.upperBound)
        let start = original.index(original.startIndex, offsetBy: lowerPrefixCount)
        let end = original.index(original.startIndex, offsetBy: lowerUpperCount)
        return String(original[start..<end])
    }

    private static func normalizeForgetQuery(_ text: String) -> String? {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))

        if normalized.lowercased().hasPrefix("what ") {
            normalized = String(normalized.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if normalized.lowercased().hasPrefix("that ") {
            normalized = String(normalized.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if normalized.lowercased().hasSuffix(" anymore") {
            normalized = String(normalized.dropLast(8)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if normalized.lowercased().hasSuffix(" is") {
            normalized = String(normalized.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizeRememberFact(_ text: String) -> String? {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
        if normalized.lowercased().hasPrefix("that ") {
            normalized = String(normalized.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized.isEmpty ? nil : normalized
    }

    private static func stripWakePrefix(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for prefix in ["fae, ", "fae "] where lower.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func isPersonalMemoryQuery(_ lowerQuery: String) -> Bool {
        let directPhrases = [
            "what's my ",
            "what is my ",
            "do you know my ",
            "do you remember my ",
            "what do you call me",
            "do you know who i am",
            "what color do i like",
            "what do i like",
            "who am i",
            "what have you learned about me",
            "tell me about me",
        ]
        if directPhrases.contains(where: { lowerQuery.contains($0) }) {
            return true
        }

        let hasPersonalMarker = lowerQuery.contains(" my ") || lowerQuery.hasPrefix("my ")
        let hasMemoryIntent = ["remember", "know", "favorite", "name", "birthday", "like"]
            .contains { lowerQuery.contains($0) }
        return hasPersonalMarker && hasMemoryIntent
    }

    private func isNameRecallQuery(_ lowerQuery: String) -> Bool {
        let phrases = [
            "what's my name",
            "what is my name",
            "what do you call me",
            "do you know who i am",
            "who am i",
        ]
        return phrases.contains { lowerQuery.contains($0) }
    }

    private func isFavoriteColorQuery(_ lowerQuery: String) -> Bool {
        let phrases = [
            "what's my favorite color",
            "what is my favorite color",
            "do you remember my favorite color",
            "do you know my favorite color",
            "what color do i like",
        ]
        return phrases.contains { lowerQuery.contains($0) }
    }

    private func isRecentMemorySummaryQuery(_ lowerQuery: String) -> Bool {
        let explicitPhrases = [
            "what have you learned recently",
            "what have you learned lately",
            "learned recently",
            "memory lately",
            "stands out from memory",
            "imported notes",
            "recent digest",
            "recently from my imported notes",
        ]
        if explicitPhrases.contains(where: { lowerQuery.contains($0) }) {
            return true
        }

        let mentionsLearning = lowerQuery.contains("learned") || lowerQuery.contains("learning")
        let mentionsRecency = lowerQuery.contains("recent") || lowerQuery.contains("lately")
        let mentionsMemory = lowerQuery.contains("memory") || lowerQuery.contains("import")
        return mentionsLearning && (mentionsRecency || mentionsMemory)
    }

    private func isRecentMemorySummarySupportCandidate(_ record: MemoryRecord) -> Bool {
        if record.kind == .digest {
            return false
        }
        if record.tags.contains("imported") || record.tags.contains("proactive") {
            return true
        }
        if metadataValue(for: record, key: "source_type") != nil {
            return true
        }
        if metadataValue(for: record, key: "artifact_id") != nil {
            return true
        }
        if let source = metadataValue(for: record, key: "source"), !source.isEmpty {
            return source != "conversation"
        }
        return false
    }

    private func primaryStoredUserName() async throws -> String? {
        let profiles = try await store.findActiveByTag("name")
        for profile in profiles {
            if let name = Self.extractStoredName(from: profile.text) {
                return name
            }
        }
        return nil
    }

    private static func extractStoredName(from text: String) -> String? {
        let prefix = "Primary user name is "
        guard text.hasPrefix(prefix) else { return nil }
        let remainder = text.dropFirst(prefix.count)
        return remainder
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func storedFavoriteColor() async throws -> String? {
        let hits = try await store.search(query: "favorite color", limit: 8)
        for hit in hits where hit.record.status == .active && hit.record.kind != .episode {
            if let color = Self.extractFavoriteColor(from: hit.record.text) {
                return color
            }
        }
        return nil
    }

    private static func extractFavoriteColor(from text: String) -> String? {
        let lower = text.lowercased()
        guard let range = lower.range(of: "favorite color is ") else { return nil }
        let original = text[range.upperBound...]
        let candidate = original
            .prefix(while: { $0.isLetter || $0 == " " || $0 == "-" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return candidate.isEmpty ? nil : candidate
    }

    private func recentLearningReply() async throws -> String {
        let recentRecords = try await store.recentRecords(limit: max(config.maxRecallResults * 4, 16))
        let relevant = recentRecords.filter { isRecentMemorySummarySupportCandidate($0) }
        let importedRecords = relevant.filter { $0.tags.contains("imported") || metadataValue(for: $0, key: "source_type") != nil }

        if !importedRecords.isEmpty {
            let snippets = importedRecords.prefix(2).map { compactMemoryText($0.text, maxLength: 180) }
            return "From your imported notes: " + snippets.joined(separator: " ")
        }

        let digests = try await store.findActiveByKind(.digest, limit: 1)
        if let digest = digests.first {
            return "Recently in memory: " + compactMemoryText(digest.text, maxLength: 220)
        }

        return "I don't have recent imported learning stored right now."
    }

    // MARK: - Capture

    /// Extract and persist memories from a completed conversation turn.
    func capture(
        turnId: String,
        userText: String,
        assistantText: String,
        speakerId: String? = nil,
        utteranceTimestamp: Date? = nil
    ) async -> MemoryCaptureReport {
        guard config.enabled else { return MemoryCaptureReport() }

        // Encode utterance timestamp into metadata JSON for all records in this turn.
        let timestampMetadata: String?
        if let ts = utteranceTimestamp {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let json = "{\"utterance_at\":\"\(iso.string(from: ts))\"}"
            timestampMetadata = json
        } else {
            timestampMetadata = nil
        }

        var report = MemoryCaptureReport()
        let userSensitivity = SensitiveContentPolicy.scan(userText)
        let assistantSensitivity = SensitiveContentPolicy.scan(assistantText)
        let sanitizedUserText = SensitiveContentPolicy.redactForStorage(userText)
        let sanitizedAssistantText = SensitiveContentPolicy.redactForStorage(assistantText)

        do {
            // 1. Always insert episode record.
            if !Self.shouldSkipEpisodeCapture(userText: sanitizedUserText) {
                let episodeText: String
                if sanitizedAssistantText.isEmpty {
                    episodeText = "User: \(sanitizedUserText)"
                } else {
                    episodeText = "User: \(sanitizedUserText)\nAssistant: \(sanitizedAssistantText)"
                }
                let episode = try await store.insertRecord(
                    kind: .episode,
                    text: episodeText,
                    confidence: MemoryConstants.episodeConfidence,
                    sourceTurnId: turnId,
                    tags: ["turn"],
                    importanceScore: 0.30,
                    staleAfterSecs: 7_776_000,  // 90 days
                    speakerId: speakerId,
                    metadata: timestampMetadata
                )
                report.episodeId = episode.id

                // Embed the new record non-blocking.
                if let engine = embeddingEngine, let vs = vectorStore {
                    let recordId = episode.id
                    let textToEmbed = episodeText
                    Task {
                        if let embedding = try? await engine.embed(text: textToEmbed) {
                            try? await vs.upsertRecordEmbedding(recordId: recordId, embedding: embedding)
                        }
                    }
                }
            } else {
                NSLog("MemoryOrchestrator: skipping episode capture for ephemeral arithmetic turn")
            }

            let lower = sanitizedUserText.lowercased()
            let shouldSuppressStructuredExtraction = userSensitivity.shouldSuppressStructuredExtraction
                || assistantSensitivity.shouldSuppressStructuredExtraction
            if shouldSuppressStructuredExtraction {
                NSLog("MemoryOrchestrator: suppressing structured extraction for sensitive turn")
            }

            // 2. Parse forget commands.
            if !shouldSuppressStructuredExtraction,
               let query = Self.extractForgetQuery(from: sanitizedUserText)
            {
                let forgotCount = try await forgetMatching(query: query)
                report.forgottenCount += forgotCount
            }

            // 3. Parse "remember ..." commands.
            if !shouldSuppressStructuredExtraction,
               let fact = Self.extractRememberFact(from: sanitizedUserText)
            {
                _ = try await store.insertRecord(
                    kind: .fact,
                    text: fact,
                    confidence: MemoryConstants.factRememberConfidence,
                    sourceTurnId: turnId,
                    tags: ["remembered"],
                    importanceScore: 0.80,
                    speakerId: speakerId,
                    metadata: timestampMetadata
                )
                report.extractedCount += 1
            }

            // 4. Parse name statements.
            if !shouldSuppressStructuredExtraction,
               let name = extractName(from: lower, fullText: sanitizedUserText)
            {
                try await upsertProfile(
                    tag: "name",
                    text: "Primary user name is \(name).",
                    confidence: MemoryConstants.profileNameConfidence,
                    sourceTurnId: turnId,
                    allTags: ["name", "identity"],
                    report: &report,
                    speakerId: speakerId,
                    metadata: timestampMetadata
                )
            }

            // 5. Parse preference statements.
            if !shouldSuppressStructuredExtraction,
               let pref = extractPreference(from: lower, fullText: sanitizedUserText)
            {
                // Check for contradiction with existing preferences.
                try await supersedeContradiction(
                    tag: "preference",
                    newText: pref,
                    sourceTurnId: turnId,
                    speakerId: speakerId,
                    metadata: timestampMetadata
                )
                _ = try await store.insertRecord(
                    kind: .profile,
                    text: pref,
                    confidence: MemoryConstants.profilePreferenceConfidence,
                    sourceTurnId: turnId,
                    tags: ["preference"],
                    importanceScore: 0.85,
                    speakerId: speakerId,
                    metadata: timestampMetadata
                )
                report.extractedCount += 1
            }

            // 6. Parse interest statements.
            if !shouldSuppressStructuredExtraction,
               let interest = extractInterest(from: lower, fullText: sanitizedUserText)
            {
                _ = try await store.insertRecord(
                    kind: .interest,
                    text: interest,
                    confidence: MemoryConstants.profilePreferenceConfidence,
                    sourceTurnId: turnId,
                    tags: ["interest"],
                    importanceScore: 0.70,
                    speakerId: speakerId,
                    metadata: timestampMetadata
                )
                report.extractedCount += 1
            }

            // 7. Parse commitment statements (deadlines, promises).
            if !shouldSuppressStructuredExtraction,
               let commitment = extractCommitment(from: lower, fullText: sanitizedUserText)
            {
                _ = try await store.insertRecord(
                    kind: .commitment,
                    text: commitment,
                    confidence: MemoryConstants.factConversationalConfidence,
                    sourceTurnId: turnId,
                    tags: ["commitment"],
                    importanceScore: 0.90,
                    staleAfterSecs: 2_592_000,  // 30 days
                    speakerId: speakerId,
                    metadata: timestampMetadata
                )
                report.extractedCount += 1
            }

            // 8. Parse event mentions (birthdays, anniversaries, dates).
            if !shouldSuppressStructuredExtraction,
               let event = extractEvent(from: lower, fullText: sanitizedUserText)
            {
                _ = try await store.insertRecord(
                    kind: .event,
                    text: event,
                    confidence: MemoryConstants.factConversationalConfidence,
                    sourceTurnId: turnId,
                    tags: ["event"],
                    importanceScore: 0.85,
                    staleAfterSecs: 604_800,  // 7 days
                    speakerId: speakerId,
                    metadata: timestampMetadata
                )
                report.extractedCount += 1
            }

            // 9. Parse person mentions (relationships, people).
            if !shouldSuppressStructuredExtraction,
               let person = extractPerson(from: lower, fullText: sanitizedUserText)
            {
                let personRecord = try await store.insertRecord(
                    kind: .person,
                    text: person,
                    confidence: MemoryConstants.factConversationalConfidence,
                    sourceTurnId: turnId,
                    tags: ["person"],
                    importanceScore: 0.75,
                    speakerId: speakerId,
                    metadata: timestampMetadata
                )
                report.extractedCount += 1

                // Fire async entity linking (non-blocking).
                if let linker = entityLinker {
                    let recordId = personRecord.id
                    Task {
                        await linker.linkPersonRecord(
                            text: person,
                            recordId: recordId,
                            turnId: turnId
                        )
                    }
                }
            }

        } catch {
            NSLog("MemoryOrchestrator: capture error: %@", error.localizedDescription)
        }

        return report
    }

    private static func shouldSkipEpisodeCapture(userText: String) -> Bool {
        let lower = " " + userText.lowercased() + " "
        let operatorHints = [
            " plus ", " minus ", " times ", " multiplied by ", " divided by ",
            " over ", " x ", " * ", " / ", " + ", " - ",
        ]
        guard operatorHints.contains(where: { lower.contains($0) }) else { return false }

        let digitCount = userText
            .replacingOccurrences(of: #"[^0-9]+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .count
        let wordCount = lower
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { arithmeticNumberWords.contains($0) }
            .count

        return digitCount + wordCount >= 2
    }

    /// Persist a structured proactive observation so silent scheduler turns remain queryable.
    func captureProactiveRecord(
        turnId: String,
        taskId: String,
        prompt: String,
        responseText: String,
        speakerId: String? = nil,
        capturedAt: Date = Date()
    ) async -> MemoryCaptureReport {
        guard config.enabled else { return MemoryCaptureReport() }

        let scan = SensitiveContentPolicy.scan(responseText)
        let trimmed = SensitiveContentPolicy.redactForStorage(responseText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !scan.shouldSuppressStructuredExtraction,
              SensitiveContentPolicy.shouldPersistProactiveObservation(taskId: taskId, text: responseText),
              let spec = proactiveMemorySpec(for: taskId)
        else {
            return MemoryCaptureReport()
        }

        do {
            let record = try await store.insertRecord(
                kind: spec.kind,
                text: trimmed,
                confidence: MemoryConstants.factConversationalConfidence,
                sourceTurnId: turnId,
                tags: spec.tags,
                importanceScore: spec.importanceScore,
                staleAfterSecs: spec.staleAfterSecs,
                speakerId: speakerId,
                metadata: proactiveMetadataJSON(
                    taskId: taskId,
                    source: spec.source,
                    prompt: prompt,
                    capturedAt: capturedAt
                )
            )

            if let engine = embeddingEngine, let vs = vectorStore {
                let recordId = record.id
                Task {
                    if let embedding = try? await engine.embed(text: trimmed) {
                        try? await vs.upsertRecordEmbedding(recordId: recordId, embedding: embedding)
                    }
                }
            }

            return MemoryCaptureReport(episodeId: record.id, extractedCount: 1)
        } catch {
            NSLog("MemoryOrchestrator: proactive capture error: %@", error.localizedDescription)
            return MemoryCaptureReport()
        }
    }

    // MARK: - Garbage Collection

    /// Apply retention policy to episode records.
    func garbageCollect(retentionDays: UInt64 = 90) async -> Int {
        do {
            return try await store.applyRetentionPolicy(retentionDays: retentionDays)
        } catch {
            NSLog("MemoryOrchestrator: gc error: %@", error.localizedDescription)
            return 0
        }
    }

    // MARK: - Private Helpers

    /// Hybrid ANN + FTS5 reranking (0.60 ANN + 0.40 lexical).
    /// Falls back to lexical ordering when vectorStore or embeddingEngine not ready.
    private func rerankHitsIfPossible(query: String, hits: [MemorySearchHit]) async -> [MemorySearchHit] {
        guard !hits.isEmpty else { return [] }

        // ANN hybrid path — preferred when vectorStore + loaded engine available.
        if let vs = vectorStore, let engine = embeddingEngine, await engine.isLoaded {
            do {
                let queryEmbedding = try await engine.embedQuery(query)
                let annResults = try await vs.searchRecords(
                    queryEmbedding: queryEmbedding,
                    limit: hits.count * 3
                )

                // Build ANN score lookup: recordId → similarity in [0, 1].
                // sqlite-vec returns cosine distance in [0, 2]; convert to similarity.
                var annScores: [String: Float] = [:]
                for (id, distance) in annResults {
                    annScores[id] = max(0, 1.0 - (distance / 2.0))
                }

                var reranked: [MemorySearchHit] = []
                reranked.reserveCapacity(hits.count)
                for hit in hits {
                    let ann = annScores[hit.record.id] ?? 0.0
                    let blended = 0.60 * ann + 0.40 * hit.score
                    reranked.append(MemorySearchHit(record: hit.record, score: blended))
                }
                reranked.sort { $0.score > $1.score }
                return reranked
            } catch {
                NSLog("MemoryOrchestrator: ANN rerank error (falling back): %@",
                      error.localizedDescription)
            }
        }

        return hits
    }

    private func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        let length = min(lhs.count, rhs.count)
        guard length > 0 else { return 0 }

        var dot: Float = 0
        var lhsSq: Float = 0
        var rhsSq: Float = 0

        for i in 0 ..< length {
            let a = lhs[i]
            let b = rhs[i]
            dot += a * b
            lhsSq += a * a
            rhsSq += b * b
        }

        let denom = sqrt(lhsSq) * sqrt(rhsSq)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    private func buildProactiveContext(taskId: String?, query: String) async throws -> String? {
        guard let taskId,
              let spec = proactiveMemorySpec(for: taskId)
        else {
            return nil
        }

        let cutoff = Date().addingTimeInterval(-(spec.lookbackHours * 3600))
        let queryTokens = Set(tokenizeForSearch(query))
        let records = try await store.recentRecords(limit: 160)
            .filter { $0.status == .active }
            .filter { record in
                recordDate(record) >= cutoff
                    && spec.recallSources.contains(metadataValue(for: record, key: "source") ?? "")
            }

        guard !records.isEmpty else { return nil }

        let lines = records
            .sorted { lhs, rhs in
                let lhsScore = proactiveRecallScore(record: lhs, queryTokens: queryTokens)
                let rhsScore = proactiveRecallScore(record: rhs, queryTokens: queryTokens)
                if lhsScore == rhsScore {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhsScore > rhsScore
            }
            .prefix(5)
            .map { record in
                let source = metadataValue(for: record, key: "source") ?? spec.source
                let timestamp = Self.proactiveTimestampFormatter.string(from: recordDate(record))
                let sourceLabel = source.replacingOccurrences(of: "_", with: " ")
                return "- [\(sourceLabel) \(timestamp)] \(record.text)"
            }

        guard !lines.isEmpty else { return nil }
        return "<proactive_memory_context task=\"\(taskId)\">\n"
            + lines.joined(separator: "\n")
            + "\n</proactive_memory_context>"
    }

    private func formattedRecallLine(for hit: MemorySearchHit) async -> String? {
        let snippet = compactMemoryText(
            hit.record.text,
            maxLength: hit.record.kind == .digest ? 260 : 180
        )
        let provenance = await provenanceSummary(for: hit.record)
        if let provenance, !provenance.isEmpty {
            return "- [\(hit.record.kind.rawValue) \(String(format: "%.2f", hit.record.confidence))] \(snippet) (sources: \(provenance))"
        }
        return "- [\(hit.record.kind.rawValue) \(String(format: "%.2f", hit.record.confidence))] \(snippet)"
    }

    private func provenanceSummary(for record: MemoryRecord) async -> String? {
        do {
            let links = try await store.sourceLinks(recordID: record.id)
            guard !links.isEmpty else {
                if let source = metadataValue(for: record, key: "source"), !source.isEmpty {
                    return source.replacingOccurrences(of: "_", with: " ")
                }
                return metadataProvenanceLabel(for: record)
            }

            var labels: [String] = []
            for link in links {
                if let artifactId = link.artifactId,
                   let artifact = try await store.fetchArtifact(id: artifactId)
                {
                    labels.append(Self.artifactLabel(for: artifact))
                } else if let sourceRecordId = link.sourceRecordId,
                          let sourceRecord = try await store.fetchRecord(id: sourceRecordId)
                {
                    if let label = try await provenanceLabel(forSourceRecord: sourceRecord) {
                        labels.append(label)
                    }
                }
                if labels.count >= 3 { break }
            }

            let uniqueLabels = Array(NSOrderedSet(array: labels)) as? [String] ?? labels
            guard !uniqueLabels.isEmpty else { return nil }
            return uniqueLabels.prefix(3).joined(separator: ", ")
        } catch {
            NSLog("MemoryOrchestrator: provenance lookup failed: %@", error.localizedDescription)
            return nil
        }
    }

    private func provenanceLabel(forSourceRecord record: MemoryRecord) async throws -> String? {
        if let direct = metadataProvenanceLabel(for: record) {
            return direct
        }
        let links = try await store.sourceLinks(recordID: record.id)
        for link in links {
            if let artifactId = link.artifactId,
               let artifact = try await store.fetchArtifact(id: artifactId)
            {
                return Self.artifactLabel(for: artifact)
            }
        }
        if let source = metadataValue(for: record, key: "source"), !source.isEmpty {
            return source.replacingOccurrences(of: "_", with: " ")
        }
        return record.kind.rawValue
    }

    private func metadataProvenanceLabel(for record: MemoryRecord) -> String? {
        guard let sourceTypeRaw = metadataValue(for: record, key: "source_type"),
              let sourceType = MemoryArtifactSourceType(rawValue: sourceTypeRaw)
        else {
            return nil
        }
        let title = metadataValue(for: record, key: "title")
        let origin = metadataValue(for: record, key: "origin")
        return Self.sourceLabel(sourceType: sourceType, title: title, origin: origin)
    }

    private static func artifactLabel(for artifact: MemoryArtifact) -> String {
        sourceLabel(sourceType: artifact.sourceType, title: artifact.title, origin: artifact.origin)
    }

    private static func sourceLabel(
        sourceType: MemoryArtifactSourceType,
        title: String?,
        origin: String?
    ) -> String {
        switch sourceType {
        case .url:
            if let origin,
               let host = URL(string: origin)?.host,
               !host.isEmpty
            {
                return "url \(host)"
            }
            return "url"
        case .pdf:
            if let title, !title.isEmpty {
                return "pdf \(title)"
            }
            if let origin {
                return "pdf \((origin as NSString).lastPathComponent)"
            }
            return "pdf"
        case .file, .coworkAttachment:
            if let title, !title.isEmpty {
                return "\(sourceType == .coworkAttachment ? "cowork attachment" : "file") \(title)"
            }
            if let origin {
                return "\(sourceType == .coworkAttachment ? "cowork attachment" : "file") \((origin as NSString).lastPathComponent)"
            }
            return sourceType == .coworkAttachment ? "cowork attachment" : "file"
        case .pastedText:
            return "pasted text"
        case .proactive:
            return "proactive"
        }
    }

    private func compactMemoryText(_ text: String, maxLength: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength - 4)).trimmingCharacters(in: .whitespaces) + " ..."
    }

    private func proactiveRecallScore(record: MemoryRecord, queryTokens: Set<String>) -> Int {
        guard !queryTokens.isEmpty else { return 0 }
        let recordTokens = Set(tokenizeForSearch(record.text))
        return queryTokens.intersection(recordTokens).count
    }

    private func proactiveMemorySpec(for taskId: String) -> ProactiveMemorySpec? {
        switch taskId {
        case "camera_presence_check":
            return ProactiveMemorySpec(
                kind: .event,
                source: "presence_observation",
                tags: ["proactive", "presence", "camera"],
                importanceScore: 0.55,
                staleAfterSecs: 86_400,
                lookbackHours: 24,
                recallSources: ["presence_observation"]
            )
        case "screen_activity_check":
            return ProactiveMemorySpec(
                kind: .episode,
                source: "screen_context",
                tags: ["proactive", "screen_context"],
                importanceScore: 0.50,
                staleAfterSecs: 43_200,
                lookbackHours: 12,
                recallSources: ["screen_context"]
            )
        case "overnight_work":
            return ProactiveMemorySpec(
                kind: .fact,
                source: "overnight_research",
                tags: ["proactive", "overnight_research", "research"],
                importanceScore: 0.78,
                staleAfterSecs: 604_800,
                lookbackHours: 72,
                recallSources: ["overnight_research"]
            )
        case "enhanced_morning_briefing":
            return ProactiveMemorySpec(
                kind: .episode,
                source: "morning_briefing",
                tags: ["proactive", "morning_briefing"],
                importanceScore: 0.45,
                staleAfterSecs: 86_400,
                lookbackHours: 24,
                recallSources: ["overnight_research", "screen_context", "presence_observation", "morning_briefing"]
            )
        default:
            return nil
        }
    }

    private func proactiveMetadataJSON(
        taskId: String,
        source: String,
        prompt: String,
        capturedAt: Date
    ) -> String? {
        let payload: [String: Any] = [
            "task_id": taskId,
            "source": source,
            "captured_at": Self.isoFormatter.string(from: capturedAt),
            "prompt": String(prompt.prefix(240)),
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
    }

    private func metadataValue(for record: MemoryRecord, key: String) -> String? {
        guard let json = record.metadata,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return dict[key] as? String
    }

    private func recordDate(_ record: MemoryRecord) -> Date {
        if let capturedAt = metadataValue(for: record, key: "captured_at"),
           let date = Self.isoFormatter.date(from: capturedAt)
        {
            return date
        }
        return Date(timeIntervalSince1970: TimeInterval(record.createdAt))
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let proactiveTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()

    /// Supersede contradicting records for a given tag when new text diverges semantically.
    private func supersedeContradiction(
        tag: String,
        newText: String,
        sourceTurnId: String,
        speakerId: String? = nil,
        metadata: String? = nil
    ) async throws {
        let existing = try await store.findActiveByTag(tag, speakerId: speakerId)
        guard !existing.isEmpty else { return }

        guard let engine = embeddingEngine, await engine.isLoaded else {
            // No semantic engine — skip contradiction detection.
            return
        }

        do {
            let newEmbedding = try await engine.embed(text: newText)

            for old in existing {
                let oldEmbedding: [Float]
                if let cached = old.cachedEmbedding, !cached.isEmpty {
                    oldEmbedding = cached
                } else {
                    oldEmbedding = try await engine.embed(text: old.text)
                }
                let similarity = cosineSimilarity(newEmbedding, oldEmbedding)
                if similarity < 0.5 {
                    // Low similarity with same tag = contradiction → supersede.
                    _ = try await store.supersedeRecord(
                        oldId: old.id,
                        newText: newText,
                        confidence: old.confidence,
                        sourceTurnId: sourceTurnId,
                        tags: old.tags,
                        note: "contradiction detected (cosine=\(String(format: "%.2f", similarity)))",
                        importanceScore: old.importanceScore,
                        staleAfterSecs: old.staleAfterSecs,
                        speakerId: speakerId ?? old.speakerId,
                        metadata: metadata ?? old.metadata
                    )
                    NSLog("MemoryOrchestrator: superseded contradicting record %@ (tag=%@, cos=%.2f)",
                          old.id, tag, similarity)
                }
            }
        } catch {
            NSLog("MemoryOrchestrator: contradiction check error: %@", error.localizedDescription)
        }
    }

    /// Forget records matching a query.
    private func forgetMatching(query: String) async throws -> Int {
        let hits = try await store.search(query: query, limit: 5)
        var count = 0
        for hit in hits where hit.score > 0.5 {
            try await store.forgetSoftRecord(id: hit.record.id, note: "user requested forget")
            count += 1
        }
        return count
    }

    /// Upsert a profile record by tag — supersede existing if found.
    private func upsertProfile(
        tag: String,
        text: String,
        confidence: Float,
        sourceTurnId: String,
        allTags: [String],
        report: inout MemoryCaptureReport,
        importanceScore: Float = 1.0,
        speakerId: String? = nil,
        metadata: String? = nil
    ) async throws {
        let existing = try await store.findActiveByTag(tag, speakerId: speakerId)

        if let old = existing.first {
            _ = try await store.supersedeRecord(
                oldId: old.id,
                newText: text,
                confidence: confidence,
                sourceTurnId: sourceTurnId,
                tags: allTags,
                note: "updated \(tag)",
                importanceScore: importanceScore,
                speakerId: speakerId,
                metadata: metadata
            )
            report.supersededCount += 1
        } else {
            _ = try await store.insertRecord(
                kind: .profile,
                text: text,
                confidence: confidence,
                sourceTurnId: sourceTurnId,
                tags: allTags,
                importanceScore: importanceScore,
                speakerId: speakerId,
                metadata: metadata
            )
            report.extractedCount += 1
        }
    }

    /// Extract a name from explicit self-identification statements.
    private func extractName(from lower: String, fullText: String) -> String? {
        let patterns = [
            "my name is ", "my name's ", "call me ",
            "you can call me ", "people call me ",
            "i'm called ", "i am called ",
            "i'm named ", "i am named ",
        ]
        for pattern in patterns {
            if let range = lower.range(of: pattern) {
                let after = fullText[range.upperBound...]
                let candidate = after.prefix(while: { $0.isLetter || $0 == " " || $0 == "-" || $0 == "'" })
                    .trimmingCharacters(in: .whitespaces)
                if isLikelyHumanName(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    private func isLikelyHumanName(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 50 else { return false }

        let words = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty, words.count <= 4 else { return false }

        let blockedTokens: Set<String> = [
            "in", "my", "own", "kitchen", "here", "there", "home",
            "doing", "good", "fine", "okay", "ok", "the", "a", "an",
        ]

        for word in words {
            let lowered = word.lowercased()
            if blockedTokens.contains(lowered) { return false }
            if word.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil { return false }
            if word.count < 2 { return false }
        }

        return true
    }

    /// Extract preference statements like "I prefer X", "I like X".
    private func extractPreference(from lower: String, fullText: String) -> String? {
        extractFirstMatch(
            from: lower, fullText: fullText,
            patterns: ["i prefer ", "i like ", "i love ", "i enjoy ",
                       "i hate ", "i dislike ", "i don't like "],
            anchorAtUpperBound: false,
            resultPrefix: "User says: "
        )
    }

    /// Extract interest statements like "I'm interested in X", "I'm passionate about X".
    private func extractInterest(from lower: String, fullText: String) -> String? {
        extractFirstMatch(
            from: lower, fullText: fullText,
            patterns: ["i'm interested in ", "i am interested in ",
                       "i'm passionate about ", "i am passionate about ",
                       "i'm into ", "i am into ",
                       "i'm fascinated by ", "i am fascinated by ",
                       "i'm curious about ", "i am curious about ",
                       "my hobby is ", "my hobbies are "],
            anchorAtUpperBound: true,
            minLength: 3,
            resultPrefix: "User is interested in: "
        )
    }

    /// Extract commitment statements like "I need to X by Y", "deadline is".
    private func extractCommitment(from lower: String, fullText: String) -> String? {
        extractFirstMatch(
            from: lower, fullText: fullText,
            patterns: ["i need to ", "i have to ", "i must ",
                       "i should ", "i promised to ",
                       "deadline is ", "the deadline is ",
                       "due by ", "due on ", "due date is ",
                       "i committed to ", "i agreed to "],
            anchorAtUpperBound: false,
            maxLength: 300,
            resultPrefix: "User commitment: "
        )
    }

    /// Extract event mentions like "my birthday is", "anniversary on".
    private func extractEvent(from lower: String, fullText: String) -> String? {
        extractFirstMatch(
            from: lower, fullText: fullText,
            patterns: ["my birthday is ", "birthday is on ",
                       "anniversary is ", "anniversary on ",
                       "wedding is ", "wedding on ",
                       "graduation is ", "graduation on ",
                       "appointment on ", "appointment is ",
                       "meeting on ", "event on ",
                       "party on ", "dinner on ",
                       "trip on ", "flight on ", "vacation on "],
            anchorAtUpperBound: false,
            resultPrefix: "User event: "
        )
    }

    /// Extract person mentions like "my sister X", "my friend X works at".
    private func extractPerson(from lower: String, fullText: String) -> String? {
        extractFirstMatch(
            from: lower, fullText: fullText,
            patterns: ["my wife ", "my husband ", "my partner ",
                       "my sister ", "my brother ", "my mom ", "my mum ", "my dad ",
                       "my daughter ", "my son ", "my child ",
                       "my friend ", "my colleague ", "my coworker ", "my co-worker ",
                       "my boss ", "my manager ", "my teacher ",
                       "my girlfriend ", "my boyfriend ",
                       "my uncle ", "my aunt ", "my cousin ",
                       "my grandmother ", "my grandfather ", "my grandma ", "my grandpa "],
            anchorAtUpperBound: false,
            resultPrefix: "User knows: "
        )
    }

    /// Shared pattern-match extractor for memory capture functions.
    ///
    /// Searches `lower` for the first matching trigger phrase, then captures text from
    /// `fullText` starting at the pattern boundary.
    ///
    /// - Parameters:
    ///   - lower: Lowercased user text used for case-insensitive pattern matching.
    ///   - fullText: Original text used for the captured content (preserves original casing).
    ///   - patterns: Trigger phrases to match.
    ///   - anchorAtUpperBound: `true` to capture text *after* the pattern; `false` to include it.
    ///   - maxLength: Maximum character length for the captured result.
    ///   - minLength: Minimum character length required for a valid match (default 1).
    ///   - resultPrefix: Prepended to the captured text in the returned string.
    private func extractFirstMatch(
        from lower: String,
        fullText: String,
        patterns: [String],
        anchorAtUpperBound: Bool,
        maxLength: Int = 200,
        minLength: Int = 1,
        resultPrefix: String
    ) -> String? {
        for pattern in patterns {
            if lower.contains(pattern),
               let range = lower.range(of: pattern)
            {
                let start = anchorAtUpperBound ? range.upperBound : range.lowerBound
                let result = String(fullText[start...].prefix(maxLength))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !result.isEmpty, result.count >= minLength {
                    return "\(resultPrefix)\(result)"
                }
            }
        }
        return nil
    }

    // MARK: - Entity Context

    /// Build entity-enriched context section for person-centric queries.
    private func buildEntityContext(for query: String) async -> String? {
        guard let entityStore else { return nil }
        guard let match = PersonQueryDetector.detectPersonQuery(in: query) else { return nil }

        do {
            var profiles: [EntityProfile] = []

            if let org = match.targetOrganisation {
                // "Who works at X?" — find people connected via works_at edge.
                let people = try await entityStore.findEntities(
                    connectedTo: org, via: "works_at"
                )
                for person in people.prefix(5) {
                    if let profile = try await entityStore.entityProfile(id: person.id) {
                        profiles.append(profile)
                    }
                }
            } else if let loc = match.targetLocation {
                // "Who lives in X?" — find people connected via lives_in edge.
                let people = try await entityStore.findEntities(
                    connectedTo: loc, via: "lives_in"
                )
                for person in people.prefix(5) {
                    if let profile = try await entityStore.entityProfile(id: person.id) {
                        profiles.append(profile)
                    }
                }
            } else if let name = match.targetName,
                      let entity = try await entityStore.findEntity(byName: name),
                      let profile = try await entityStore.entityProfile(id: entity.id)
            {
                profiles.append(profile)
            } else if let label = match.targetRelationLabel {
                // No name — find by relation label (first strong match).
                let candidates = try await entityStore.staleEntities(
                    olderThanDays: 0,
                    priorityOrder: RelationType.allCases
                )
                for candidate in candidates where candidate.relationLabel == label {
                    if let profile = try await entityStore.entityProfile(id: candidate.id) {
                        profiles.append(profile)
                        break
                    }
                }
            }

            guard !profiles.isEmpty else { return nil }

            // Format profiles with resolved relationship edges.
            var sections: [String] = []
            var totalChars = 0
            for profile in profiles {
                let edges = try await resolvedEdges(for: profile.entity.id, entityStore: entityStore)
                let section = EntityContextFormatter.format(
                    profile: profile,
                    linkedRecords: [],
                    edges: edges
                )
                if totalChars + section.count > MemoryConstants.entityMaxContextChars,
                   !sections.isEmpty { break }
                sections.append(section)
                totalChars += section.count
            }
            let formatted = sections.joined(separator: "\n")
            return formatted.isEmpty ? nil : formatted
        } catch {
            NSLog("MemoryOrchestrator: buildEntityContext error: %@", error.localizedDescription)
            return nil
        }
    }

    /// Resolve relationship edges for an entity into formatted edges (with target canonical names).
    private func resolvedEdges(
        for entityId: String,
        entityStore: EntityStore
    ) async throws -> [EntityContextFormatter.FormattedEdge] {
        let rels = try await entityStore.relationships(forEntityId: entityId)
        var result: [EntityContextFormatter.FormattedEdge] = []
        for rel in rels.prefix(6) {
            if let target = try? await entityStore.findEntity(byId: rel.targetId) {
                result.append(EntityContextFormatter.FormattedEdge(
                    relationType: rel.relationType,
                    targetName: target.canonicalName,
                    startedAt: rel.startedAt,
                    endedAt: rel.endedAt
                ))
            }
        }
        return result
    }
}
