import Foundation

// MARK: - DetectedSignal

/// A feedback signal detected from conversation analysis.
struct DetectedSignal: Sendable {
    /// The type of implicit feedback signal.
    let signalType: String
    /// Confidence score from 0.0 (uncertain) to 1.0 (definite).
    let confidence: Double
    /// Brief description of why this signal was detected.
    let evidence: String
}

// MARK: - FeedbackAnalysisTurn

/// A simplified conversation turn for feedback analysis.
///
/// Contains just enough information for signal detection without
/// requiring the full LLMMessage type.
struct FeedbackAnalysisTurn: Sendable {
    /// Role: "user" or "assistant".
    let role: String
    /// The text content of the turn.
    let content: String
    /// Whether the user interrupted (barged-in) during this turn.
    let wasInterrupted: Bool
}

// MARK: - ImplicitFeedbackDetector

/// Detects implicit user feedback signals from conversation patterns.
///
/// Analyzes pairs of turns (user query → assistant response → user follow-up)
/// to identify satisfaction/dissatisfaction signals without requiring explicit
/// feedback from the user.
///
/// ## Signal Types
/// | Signal | Valence | Description |
/// |--------|---------|-------------|
/// | re_ask | Negative | User rephrases the same question |
/// | abandonment | Negative | User drops topic without resolution |
/// | follow_through | Positive | User acts on suggestion |
/// | interruption | Negative | User barged-in during response |
/// | praise | Positive | User expresses gratitude |
/// | topic_change | Mildly negative | User changes topic after response |
/// | silence_acceptance | Mildly positive | User accepts without comment |
enum ImplicitFeedbackDetector {

    // MARK: - Main Detection

    /// Analyze a conversation window and return all detected signals.
    ///
    /// - Parameters:
    ///   - currentTurn: The most recent user message.
    ///   - previousTurns: Recent conversation history (most recent first).
    ///   - wasInterrupted: Whether the user interrupted the last assistant response.
    /// - Returns: Array of detected signals (may be empty or contain multiple).
    static func detect(
        currentTurn: FeedbackAnalysisTurn,
        previousTurns: [FeedbackAnalysisTurn],
        wasInterrupted: Bool
    ) -> [DetectedSignal] {
        var signals: [DetectedSignal] = []

        // Find the last assistant response and the previous user query.
        let lastAssistantResponse = previousTurns.first { $0.role == "assistant" }
        let previousUserQueries = previousTurns.filter { $0.role == "user" }

        // 1. Interruption — direct from flag.
        if wasInterrupted {
            signals.append(DetectedSignal(
                signalType: "interruption",
                confidence: 0.95,
                evidence: "User barged-in during assistant response"
            ))
        }

        // 2. Praise — gratitude keywords.
        if let praiseSignal = detectPraise(in: currentTurn.content) {
            signals.append(praiseSignal)
        }

        // 3. Follow-through — user acts on suggestion.
        if let followSignal = detectFollowThrough(
            userMessage: currentTurn.content,
            assistantResponse: lastAssistantResponse?.content
        ) {
            signals.append(followSignal)
        }

        // 4. Re-ask — user rephrases a previous question.
        if let reaskSignal = detectReAsk(
            currentQuery: currentTurn.content,
            previousQueries: previousUserQueries.map(\.content)
        ) {
            signals.append(reaskSignal)
        }

        // 5. Topic change / abandonment.
        if let lastAssistant = lastAssistantResponse,
           !previousUserQueries.isEmpty
        {
            let previousQuery = previousUserQueries.first?.content ?? ""
            let similarity = textSimilarity(currentTurn.content, previousQuery)

            if similarity < 0.15 {
                // Very different topic — could be abandonment or topic change.
                if let abandonSignal = detectAbandonment(
                    currentMessage: currentTurn.content,
                    previousQuery: previousQuery,
                    assistantResponse: lastAssistant.content
                ) {
                    signals.append(abandonSignal)
                } else {
                    signals.append(DetectedSignal(
                        signalType: "topic_change",
                        confidence: 0.6,
                        evidence: "User changed topic (similarity: \(String(format: "%.2f", similarity)))"
                    ))
                }
            }
        }

        return signals
    }

    /// Detect silence acceptance by analyzing the conversation flow.
    ///
    /// Called separately because it requires knowing that no follow-up was received
    /// within a timeout window.
    ///
    /// - Parameters:
    ///   - lastAssistantResponse: The assistant's last response text.
    ///   - secondsSinceResponse: Time elapsed since the response was delivered.
    ///   - minSilenceSeconds: Minimum silence to count as acceptance (default: 30).
    /// - Returns: A silence_acceptance signal if the criteria are met, nil otherwise.
    static func detectSilenceAcceptance(
        lastAssistantResponse: String,
        secondsSinceResponse: TimeInterval,
        minSilenceSeconds: TimeInterval = 30
    ) -> DetectedSignal? {
        guard secondsSinceResponse >= minSilenceSeconds else { return nil }
        guard !lastAssistantResponse.isEmpty else { return nil }
        return DetectedSignal(
            signalType: "silence_acceptance",
            confidence: 0.5,
            evidence: "No follow-up for \(Int(secondsSinceResponse))s after response"
        )
    }

    // MARK: - Individual Detectors

    /// Detect praise/gratitude in user message.
    static func detectPraise(in message: String) -> DetectedSignal? {
        let lowered = message.lowercased()
        let praisePatterns = [
            "thank", "thanks", "great", "perfect", "awesome",
            "excellent", "that's helpful", "that helps", "love it",
            "well done", "nice", "good job", "appreciate",
            "exactly what i needed", "that's exactly",
        ]
        for pattern in praisePatterns {
            if lowered.contains(pattern) {
                return DetectedSignal(
                    signalType: "praise",
                    confidence: 0.85,
                    evidence: "Detected gratitude keyword: \"\(pattern)\""
                )
            }
        }
        return nil
    }

    /// Detect follow-through — user confirms acting on a suggestion.
    static func detectFollowThrough(
        userMessage: String,
        assistantResponse: String?
    ) -> DetectedSignal? {
        guard assistantResponse != nil else { return nil }
        let lowered = userMessage.lowercased()
        let followPatterns = [
            "i did", "done", "okay i'll", "ok i'll", "i'll do that",
            "i tried", "i followed", "it worked", "that fixed it",
            "i installed", "i updated", "i changed", "i set",
        ]
        for pattern in followPatterns {
            if lowered.contains(pattern) {
                return DetectedSignal(
                    signalType: "follow_through",
                    confidence: 0.75,
                    evidence: "User confirmed action: \"\(pattern)\""
                )
            }
        }
        return nil
    }

    /// Detect re-ask — user rephrases a previous question.
    static func detectReAsk(
        currentQuery: String,
        previousQueries: [String]
    ) -> DetectedSignal? {
        for prev in previousQueries.prefix(3) {
            let similarity = textSimilarity(currentQuery, prev)
            if similarity > 0.6 && similarity < 0.95 {
                // High similarity but not identical — likely a rephrase.
                return DetectedSignal(
                    signalType: "re_ask",
                    confidence: min(similarity, 0.9),
                    evidence: "Query similar to previous (similarity: \(String(format: "%.2f", similarity)))"
                )
            }
        }
        return nil
    }

    /// Detect abandonment — user drops a topic without resolution.
    static func detectAbandonment(
        currentMessage: String,
        previousQuery: String,
        assistantResponse: String
    ) -> DetectedSignal? {
        // Abandonment: previous query was a question, assistant gave a response,
        // user moves on to something completely different without acknowledgment.
        let previousWasQuestion = previousQuery.contains("?") ||
            previousQuery.lowercased().hasPrefix("how") ||
            previousQuery.lowercased().hasPrefix("what") ||
            previousQuery.lowercased().hasPrefix("why") ||
            previousQuery.lowercased().hasPrefix("can you") ||
            previousQuery.lowercased().hasPrefix("could you")

        guard previousWasQuestion else { return nil }

        let responseSimilarity = textSimilarity(currentMessage, assistantResponse)
        let querySimilarity = textSimilarity(currentMessage, previousQuery)

        if responseSimilarity < 0.1 && querySimilarity < 0.15 {
            return DetectedSignal(
                signalType: "abandonment",
                confidence: 0.65,
                evidence: "User dropped question without acknowledgment"
            )
        }
        return nil
    }

    // MARK: - Text Similarity (Jaccard on word bigrams)

    /// Compute text similarity using Jaccard coefficient on word bigrams.
    ///
    /// Returns a value from 0.0 (completely different) to 1.0 (identical).
    /// This is a lightweight approximation — no ML model needed.
    static func textSimilarity(_ text1: String, _ text2: String) -> Double {
        let bigrams1 = wordBigrams(text1)
        let bigrams2 = wordBigrams(text2)
        guard !bigrams1.isEmpty || !bigrams2.isEmpty else { return 0.0 }
        let intersection = bigrams1.intersection(bigrams2).count
        let union = bigrams1.union(bigrams2).count
        guard union > 0 else { return 0.0 }
        return Double(intersection) / Double(union)
    }

    /// Extract word bigrams from text.
    private static func wordBigrams(_ text: String) -> Set<String> {
        let words = text.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard words.count >= 2 else {
            return Set(words)
        }
        var bigrams = Set<String>()
        for i in 0..<(words.count - 1) {
            bigrams.insert("\(words[i]) \(words[i + 1])")
        }
        return bigrams
    }
}
