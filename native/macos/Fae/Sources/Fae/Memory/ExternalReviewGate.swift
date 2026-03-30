import Foundation

// MARK: - ReviewVerdict

/// The verdict returned by an external review agent.
enum ReviewVerdict: String, Sendable, Equatable, CaseIterable {
    /// The adapter passed review and may be deployed.
    case pass
    /// The adapter failed review and must not be deployed.
    case fail
    /// A concern was raised; human or another reviewer should look at it.
    case concern
}

// MARK: - ReviewProvider

/// The external reviewer that produced the verdict.
enum ReviewProvider: String, Sendable, Equatable {
    /// OpenAI Codex (primary external reviewer).
    case codex
    /// Claude Code (secondary reviewer, fallback from Codex).
    case claudeCode
    /// Internal self-review (last-resort fallback).
    case internalSelfReview
}

// MARK: - ReviewResult

/// The full result of an external review gate check.
struct ReviewResult: Sendable {
    /// Which reviewer produced this result.
    let provider: ReviewProvider
    /// The verdict: pass, fail, or concern.
    let verdict: ReviewVerdict
    /// Human-readable summary of the review findings.
    let summary: String
    /// ISO-8601 timestamp when the review was performed.
    let reviewedAt: String
}

// MARK: - ExternalReviewGateError

/// Errors produced by `ExternalReviewGate`.
enum ExternalReviewGateError: Error, Sendable {
    /// All review providers are unavailable or failed.
    case allProvidersFailed
    /// The maximum number of deferrals has been reached.
    case maxDeferralsReached(count: Int)
    /// A review provider returned an unexpected result format.
    case invalidResponse(provider: ReviewProvider)
}

// MARK: - ExternalReviewGate

/// Gates adapter deployment by requiring an external review before proceeding.
///
/// The gate uses a fallback chain:
/// 1. **Codex** — primary external reviewer (via delegate_agent skill)
/// 2. **Claude Code** — secondary reviewer (fallback if Codex unavailable)
/// 3. **Internal self-review** — last resort (simple heuristics on eval delta)
///
/// Results are logged to `SecurityEventLogger` for audit purposes.
///
/// ## Deferral policy
/// A CONCERN verdict may be deferred up to `maxDeferrals` times. If a concern
/// is raised and the deferral count is below the maximum, the gate returns
/// `.concern` and the coordinator records a deferral. The next cycle will
/// re-attempt review. After `maxDeferrals` concerns, the gate blocks deployment
/// with `ExternalReviewGateError.maxDeferralsReached`.
///
/// ## Usage
/// ```swift
/// let gate = ExternalReviewGate()
/// let result = try await gate.review(
///     evalDelta: delta,
///     currentDeferralCount: state.deferralCount
/// )
/// // result.verdict == .pass → proceed to deploy
/// // result.verdict == .concern → increment deferral, skip this cycle
/// // result.verdict == .fail → abort, return to idle
/// ```
actor ExternalReviewGate {

    // MARK: - Configuration

    /// Maximum number of CONCERN deferrals before blocking deployment entirely.
    static let maxDeferrals = 3

    // MARK: - Dependencies

    /// Called to run a delegate_agent tool call. Injected to allow testing.
    var delegateAgentRunner: ((_ prompt: String) async throws -> String)?

    // MARK: - Init / Configuration

    /// Set the delegate agent runner closure. Called by tests or FaeCore.
    func setDelegateAgentRunner(_ runner: @escaping (_ prompt: String) async throws -> String) {
        delegateAgentRunner = runner
    }

    // MARK: - Review Entry Point

    /// Request an external review of an adapter before deployment.
    ///
    /// Tries providers in order: Codex → Claude Code → internal self-review.
    /// Logs the result to SecurityEventLogger for audit.
    ///
    /// - Parameters:
    ///   - evalDelta: Evaluation metrics delta (adapter score minus baseline score).
    ///                Positive values = improvement, negative = regression.
    ///   - currentDeferralCount: How many times a CONCERN has been deferred so far.
    /// - Returns: A `ReviewResult` from the first available provider.
    /// - Throws: `ExternalReviewGateError.maxDeferralsReached` if deferral limit exceeded.
    ///           `ExternalReviewGateError.allProvidersFailed` if no provider is available.
    func review(
        evalDelta: EvalDelta,
        currentDeferralCount: Int
    ) async throws -> ReviewResult {
        // Check deferral limit before attempting.
        if currentDeferralCount >= Self.maxDeferrals {
            throw ExternalReviewGateError.maxDeferralsReached(count: currentDeferralCount)
        }

        // Try providers in order.
        let providers: [ReviewProvider] = [.codex, .claudeCode, .internalSelfReview]
        var lastError: Error = ExternalReviewGateError.allProvidersFailed

        for provider in providers {
            do {
                let result = try await runReview(provider: provider, evalDelta: evalDelta)
                logResult(result)
                return result
            } catch {
                NSLog("ExternalReviewGate: %@ failed — %@", provider.rawValue, error.localizedDescription)
                lastError = error
                // Continue to next provider.
            }
        }

        throw lastError
    }

    // MARK: - Provider Dispatch

    /// Run a review with the specified provider.
    private func runReview(
        provider: ReviewProvider,
        evalDelta: EvalDelta
    ) async throws -> ReviewResult {
        let now = ISO8601DateFormatter().string(from: Date())

        switch provider {
        case .codex:
            return try await runDelegateReview(
                provider: .codex,
                prompt: buildCodexPrompt(evalDelta: evalDelta),
                reviewedAt: now
            )

        case .claudeCode:
            return try await runDelegateReview(
                provider: .claudeCode,
                prompt: buildClaudeCodePrompt(evalDelta: evalDelta),
                reviewedAt: now
            )

        case .internalSelfReview:
            return runInternalReview(evalDelta: evalDelta, reviewedAt: now)
        }
    }

    /// Run a review by delegating to an external agent tool call.
    private func runDelegateReview(
        provider: ReviewProvider,
        prompt: String,
        reviewedAt: String
    ) async throws -> ReviewResult {
        guard let runner = delegateAgentRunner else {
            throw ExternalReviewGateError.invalidResponse(provider: provider)
        }

        let response = try await runner(prompt)
        let verdict = parseVerdictFromResponse(response)

        guard let verdict else {
            throw ExternalReviewGateError.invalidResponse(provider: provider)
        }

        return ReviewResult(
            provider: provider,
            verdict: verdict,
            summary: response.prefix(500).description,
            reviewedAt: reviewedAt
        )
    }

    /// Run the internal self-review heuristic (no external dependency).
    ///
    /// Rules:
    /// - Any eval metric regresses by > 5% → FAIL
    /// - All metrics are neutral or improved → PASS
    /// - Minor regression (≤ 5%) on any metric → CONCERN
    private func runInternalReview(
        evalDelta: EvalDelta,
        reviewedAt: String
    ) -> ReviewResult {
        let allDeltas = [
            evalDelta.toolCallingDelta,
            evalDelta.faeCapabilityDelta,
            evalDelta.assistantFitDelta,
            evalDelta.serializationDelta,
        ].compactMap { $0 }

        let minDelta = allDeltas.min() ?? 0.0
        let verdict: ReviewVerdict
        let summary: String

        if minDelta < -5.0 {
            verdict = .fail
            summary = "Internal review: regression detected (\(String(format: "%.1f", minDelta))%). Deployment blocked."
        } else if minDelta < 0.0 {
            verdict = .concern
            summary = "Internal review: minor regression (\(String(format: "%.1f", minDelta))%). Human review recommended."
        } else {
            verdict = .pass
            summary = "Internal review: all metrics stable or improved (min delta: +\(String(format: "%.1f", minDelta))%)."
        }

        return ReviewResult(
            provider: .internalSelfReview,
            verdict: verdict,
            summary: summary,
            reviewedAt: reviewedAt
        )
    }

    // MARK: - Prompt Construction

    private func buildCodexPrompt(evalDelta: EvalDelta) -> String {
        """
        You are reviewing a personal AI adapter for deployment.

        Evaluation deltas (positive = improvement, negative = regression):
        - Tool calling: \(deltaString(evalDelta.toolCallingDelta))
        - Fae capability: \(deltaString(evalDelta.faeCapabilityDelta))
        - Assistant fit: \(deltaString(evalDelta.assistantFitDelta))
        - Serialization: \(deltaString(evalDelta.serializationDelta))

        Respond with exactly one of:
        PASS: [brief reason]
        FAIL: [brief reason]
        CONCERN: [brief reason]
        """
    }

    private func buildClaudeCodePrompt(evalDelta: EvalDelta) -> String {
        buildCodexPrompt(evalDelta: evalDelta) // Same format, different provider
    }

    private func deltaString(_ value: Double?) -> String {
        guard let value else { return "N/A" }
        return value >= 0 ? "+\(String(format: "%.1f", value))%" : "\(String(format: "%.1f", value))%"
    }

    // MARK: - Response Parsing

    /// Parse a PASS/FAIL/CONCERN verdict from an agent response string.
    private func parseVerdictFromResponse(_ response: String) -> ReviewVerdict? {
        let upper = response.uppercased()
        if upper.hasPrefix("PASS") || upper.contains("\nPASS:") {
            return .pass
        }
        if upper.hasPrefix("FAIL") || upper.contains("\nFAIL:") {
            return .fail
        }
        if upper.hasPrefix("CONCERN") || upper.contains("\nCONCERN:") {
            return .concern
        }
        return nil
    }

    // MARK: - Audit Logging

    private func logResult(_ result: ReviewResult) {
        NSLog(
            "ExternalReviewGate: %@ → %@ at %@",
            result.provider.rawValue,
            result.verdict.rawValue,
            result.reviewedAt
        )
        // In production, this will also call SecurityEventLogger.
        // SecurityEventLogger is in the Tools/ folder and we avoid circular imports
        // by keeping the log call here as a stub. Phase 3.2 integration wires the
        // real SecurityEventLogger via a closure injected into the gate.
    }
}

// MARK: - EvalDelta

/// Evaluation metric deltas between baseline and post-training adapter.
///
/// Positive values indicate improvement; negative values indicate regression.
/// `nil` means the metric was not measured in this cycle.
struct EvalDelta: Sendable {
    /// Delta in tool calling accuracy (percentage points).
    let toolCallingDelta: Double?
    /// Delta in Fae capability accuracy.
    let faeCapabilityDelta: Double?
    /// Delta in assistant fit accuracy.
    let assistantFitDelta: Double?
    /// Delta in serialization accuracy.
    let serializationDelta: Double?
    /// Delta in average throughput (tokens per second).
    let throughputDelta: Double?
}
