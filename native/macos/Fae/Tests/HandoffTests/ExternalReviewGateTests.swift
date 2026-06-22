import XCTest
@testable import Fae

/// Tests for ExternalReviewGate — fallback chain, verdict parsing,
/// deferral counting, and internal self-review heuristics.
final class ExternalReviewGateTests: XCTestCase {

    // MARK: - Helpers

    private func makeGate() -> ExternalReviewGate {
        ExternalReviewGate()
    }

    private func makeEvalDelta(
        toolCalling: Double? = 2.0,
        faeCapability: Double? = 1.5,
        assistantFit: Double? = 3.0,
        serialization: Double? = 0.0,
        throughput: Double? = nil
    ) -> EvalDelta {
        EvalDelta(
            toolCallingDelta: toolCalling,
            faeCapabilityDelta: faeCapability,
            assistantFitDelta: assistantFit,
            serializationDelta: serialization,
            throughputDelta: throughput
        )
    }

    // MARK: - Internal Self-Review Heuristics

    func testInternalReviewPassesWhenAllMetricsImprove() async throws {
        let gate = makeGate()
        // No delegateAgentRunner → will fall through to internal review.
        let result = try await gate.review(
            evalDelta: makeEvalDelta(toolCalling: 2.0, faeCapability: 1.0, assistantFit: 3.0, serialization: 0.5),
            currentDeferralCount: 0
        )
        XCTAssertEqual(result.provider, .internalSelfReview)
        XCTAssertEqual(result.verdict, .pass)
    }

    func testInternalReviewBlocksWhenNeutralNoImprovement() async throws {
        // P9/C4 (W1): an all-flat (all-zero) measured result is indistinguishable
        // from a non-measurement and must NOT certify a deploy. Fail-closed.
        let gate = makeGate()
        let result = try await gate.review(
            evalDelta: makeEvalDelta(toolCalling: 0.0, faeCapability: 0.0, assistantFit: 0.0, serialization: 0.0),
            currentDeferralCount: 0
        )
        XCTAssertEqual(result.verdict, .fail, "Zero delta = no measured improvement = fail-closed")
    }

    func testInternalReviewConcernForMinorRegression() async throws {
        let gate = makeGate()
        let result = try await gate.review(
            evalDelta: makeEvalDelta(toolCalling: -2.0, faeCapability: 1.0, assistantFit: 1.0, serialization: 0.0),
            currentDeferralCount: 0
        )
        XCTAssertEqual(result.verdict, .concern, "Minor regression (-2%) should yield CONCERN")
    }

    func testInternalReviewFailsForSignificantRegression() async throws {
        let gate = makeGate()
        let result = try await gate.review(
            evalDelta: makeEvalDelta(toolCalling: -10.0, faeCapability: 1.0, assistantFit: 1.0, serialization: 0.0),
            currentDeferralCount: 0
        )
        XCTAssertEqual(result.verdict, .fail, "Regression > 5% should yield FAIL")
    }

    func testInternalReviewFailsWhenNoMetricsMeasured() async throws {
        // P9/C4 (W1): all-nil deltas mean nothing was measured. The previous
        // behaviour folded nils into zero and PASSED — the F1 crack. Fail-closed now.
        let gate = makeGate()
        let result = try await gate.review(
            evalDelta: makeEvalDelta(toolCalling: nil, faeCapability: nil, assistantFit: nil, serialization: nil),
            currentDeferralCount: 0
        )
        XCTAssertEqual(result.verdict, .fail, "Nil metrics → nothing measured → fail-closed")
    }

    // MARK: - Deferral Counting

    func testReviewBlocksWhenMaxDeferralsReached() async throws {
        let gate = makeGate()
        do {
            _ = try await gate.review(
                evalDelta: makeEvalDelta(),
                currentDeferralCount: ExternalReviewGate.maxDeferrals
            )
            XCTFail("Expected maxDeferralsReached error")
        } catch let error as ExternalReviewGateError {
            if case .maxDeferralsReached(let count) = error {
                XCTAssertEqual(count, ExternalReviewGate.maxDeferrals)
            } else {
                XCTFail("Expected .maxDeferralsReached, got \(error)")
            }
        }
    }

    func testReviewAllowedWhenBelowMaxDeferrals() async throws {
        let gate = makeGate()
        // Deferral count = 2 (below max of 3) — should not throw.
        let result = try await gate.review(
            evalDelta: makeEvalDelta(),
            currentDeferralCount: ExternalReviewGate.maxDeferrals - 1
        )
        XCTAssertNotNil(result)
    }

    // MARK: - Delegate Agent Runner (Codex/Claude Code path)

    func testDelegateAgentRunnerPassVerdictParsed() async throws {
        let gate = makeGate()
        await gate.setDelegateAgentRunner { _ in
            "PASS: All metrics improved, no regressions detected."
        }
        let result = try await gate.review(
            evalDelta: makeEvalDelta(),
            currentDeferralCount: 0
        )
        XCTAssertEqual(result.provider, .codex, "First provider in chain is codex")
        XCTAssertEqual(result.verdict, .pass)
    }

    func testDelegateAgentRunnerFailVerdictParsed() async throws {
        let gate = makeGate()
        await gate.setDelegateAgentRunner { _ in
            "FAIL: Significant regression in tool calling (-15%)."
        }
        let result = try await gate.review(
            evalDelta: makeEvalDelta(),
            currentDeferralCount: 0
        )
        XCTAssertEqual(result.verdict, .fail)
    }

    func testDelegateAgentRunnerConcernVerdictParsed() async throws {
        let gate = makeGate()
        await gate.setDelegateAgentRunner { _ in
            "CONCERN: Minor regression in assistant fit. Recommend human review."
        }
        let result = try await gate.review(
            evalDelta: makeEvalDelta(),
            currentDeferralCount: 0
        )
        XCTAssertEqual(result.verdict, .concern)
    }

    func testDelegateAgentRunnerFallsBackToInternalOnInvalidResponse() async throws {
        let gate = makeGate()
        await gate.setDelegateAgentRunner { _ in
            // Response that cannot be parsed as a verdict.
            "I'm not sure what to say about this adapter."
        }
        // Should fall through Codex → Claude Code (same runner) → internal self-review.
        let result = try await gate.review(
            evalDelta: makeEvalDelta(toolCalling: 5.0, faeCapability: 3.0, assistantFit: 2.0, serialization: 1.0),
            currentDeferralCount: 0
        )
        XCTAssertEqual(result.provider, .internalSelfReview, "Should fall back to internal review when delegate fails")
    }

    func testDelegateAgentRunnerThrowsFallsBackToInternal() async throws {
        let gate = makeGate()
        await gate.setDelegateAgentRunner { _ in
            struct NetworkError: Error {}
            throw NetworkError()
        }
        let result = try await gate.review(
            evalDelta: makeEvalDelta(),
            currentDeferralCount: 0
        )
        XCTAssertEqual(result.provider, .internalSelfReview)
    }

    // MARK: - ReviewVerdict enum

    func testAllVerdictsHaveRawValues() {
        XCTAssertEqual(ReviewVerdict.pass.rawValue, "pass")
        XCTAssertEqual(ReviewVerdict.fail.rawValue, "fail")
        XCTAssertEqual(ReviewVerdict.concern.rawValue, "concern")
    }

    func testAllProvidersHaveRawValues() {
        XCTAssertEqual(ReviewProvider.codex.rawValue, "codex")
        XCTAssertEqual(ReviewProvider.claudeCode.rawValue, "claudeCode")
        XCTAssertEqual(ReviewProvider.internalSelfReview.rawValue, "internalSelfReview")
    }

    // MARK: - SecurityEventLogger Integration

    func testSecurityLogClosureCalledOnReview() async throws {
        let gate = makeGate()
        var loggedEvent: String?
        var loggedTool: String?
        var loggedDecision: String?
        var loggedApproved: Bool?
        var loggedSummary: String?

        await gate.setSecurityLogClosure { event, toolName, decision, _, approved, summary in
            loggedEvent = event
            loggedTool = toolName
            loggedDecision = decision
            loggedApproved = approved
            loggedSummary = summary
        }

        // No delegate runner → falls through to internal review.
        let result = try await gate.review(
            evalDelta: makeEvalDelta(toolCalling: 2.0, faeCapability: 1.0, assistantFit: 3.0, serialization: 0.5),
            currentDeferralCount: 0
        )
        XCTAssertEqual(result.verdict, .pass)
        XCTAssertEqual(loggedEvent, "external_review_gate")
        XCTAssertEqual(loggedTool, "internalSelfReview")
        XCTAssertEqual(loggedDecision, "pass")
        XCTAssertEqual(loggedApproved, true)
        XCTAssertNotNil(loggedSummary)
    }

    func testSecurityLogClosureRecordsFailVerdict() async throws {
        let gate = makeGate()
        var loggedDecision: String?
        var loggedApproved: Bool?

        await gate.setSecurityLogClosure { _, _, decision, _, approved, _ in
            loggedDecision = decision
            loggedApproved = approved
        }

        let result = try await gate.review(
            evalDelta: makeEvalDelta(toolCalling: -10.0),
            currentDeferralCount: 0
        )
        XCTAssertEqual(result.verdict, .fail)
        XCTAssertEqual(loggedDecision, "fail")
        XCTAssertEqual(loggedApproved, false)
    }

    func testSecurityLogClosureRecordsConcernVerdict() async throws {
        let gate = makeGate()
        var loggedDecision: String?
        var loggedApproved: Bool?

        await gate.setSecurityLogClosure { _, _, decision, _, approved, _ in
            loggedDecision = decision
            loggedApproved = approved
        }

        let result = try await gate.review(
            evalDelta: makeEvalDelta(toolCalling: -2.0),
            currentDeferralCount: 0
        )
        XCTAssertEqual(result.verdict, .concern)
        XCTAssertEqual(loggedDecision, "concern")
        XCTAssertEqual(loggedApproved, false)
    }

    func testSecurityLogClosureCalledForDelegateProvider() async throws {
        let gate = makeGate()
        var loggedTool: String?

        await gate.setDelegateAgentRunner { _ in
            "PASS: All good"
        }
        await gate.setSecurityLogClosure { _, toolName, _, _, _, _ in
            loggedTool = toolName
        }

        let result = try await gate.review(
            evalDelta: makeEvalDelta(),
            currentDeferralCount: 0
        )
        XCTAssertEqual(result.provider, .codex)
        XCTAssertEqual(loggedTool, "codex")
    }

    // MARK: - EvalDelta

    func testEvalDeltaAllNilFailsClosed() async throws {
        // P9/C4 (W1): all-nil = nothing measured ⇒ fail-closed (was the F1 crack).
        let gate = makeGate()
        let delta = EvalDelta(
            toolCallingDelta: nil, faeCapabilityDelta: nil,
            assistantFitDelta: nil, serializationDelta: nil,
            throughputDelta: nil
        )
        let result = try await gate.review(evalDelta: delta, currentDeferralCount: 0)
        XCTAssertEqual(result.verdict, .fail)
    }

    func testEvalDeltaExactly5PercentRegressionIsConcernNotFail() async throws {
        let gate = makeGate()
        // -5% is still > -5.0 (not strictly less than -5.0)
        let delta = EvalDelta(
            toolCallingDelta: -5.0, faeCapabilityDelta: 0.0,
            assistantFitDelta: 0.0, serializationDelta: 0.0,
            throughputDelta: nil
        )
        let result = try await gate.review(evalDelta: delta, currentDeferralCount: 0)
        XCTAssertEqual(result.verdict, .concern, "-5.0 is concern, not fail (fail requires < -5.0)")
    }
}
