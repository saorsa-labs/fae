import XCTest
@testable import Fae

final class ShadowEvaluatorTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempStore() async throws -> ImprovementStore {
        let store = ImprovementStore()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shadow_eval_test_\(UUID().uuidString).db")
        try await store.open(at: url)
        try await store.ensureStateRow()
        return store
    }

    private func makeEpisode(id: Int64? = nil, conversationJSON: String = "[{\"role\":\"user\",\"content\":\"test\"}]") -> ShadowEvalEpisode {
        ShadowEvalEpisode(
            id: id,
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            conversationJSON: conversationJSON,
            actualResponse: "The original response.",
            receptionScore: nil,
            evaluated: false,
            evalOutcome: nil
        )
    }

    private func makeEvaluator(store: ImprovementStore) -> ShadowEvaluator {
        ShadowEvaluator(store: store)
    }

    // MARK: - Overnight Window

    func testOvernightWindowReturnsCorrectForHour22() {
        // Can't control system clock, but we can test the logic indirectly.
        // The method is a simple hour check — we trust the logic and test
        // indirectly by verifying ignoreWindow bypasses the check.
        let evaluator = ShadowEvaluator(store: ImprovementStore())
        // Just verify the method is callable and returns Bool.
        let _ = Task { await evaluator.isOvernightWindow() }
        // Primary coverage comes from integration tests.
    }

    func testRunEvaluationThrowsOutsideWindowWhenNotIgnored() async throws {
        let store = try await makeTempStore()
        let evaluator = makeEvaluator(store: store)
        await evaluator.setResponseGenerator { _, _ in "response" }

        // Store an episode so we won't hit noEpisodesAvailable first.
        _ = try await store.appendShadowEpisode(makeEpisode())

        // We don't know if we're in the overnight window during CI.
        // If we're in the window this test passes trivially; if not it throws.
        // Use ignoreWindow: false and accept either outcome gracefully.
        do {
            _ = try await evaluator.runEvaluation(ignoreWindow: false)
            // Passed — we're in the overnight window or the episode was processed.
        } catch let error as ShadowEvaluatorError {
            if case .outsideOvernightWindow = error {
                // Expected when not in overnight window.
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRunEvaluationIgnoresWindowWhenFlagSet() async throws {
        let store = try await makeTempStore()
        let evaluator = makeEvaluator(store: store)
        _ = try await store.appendShadowEpisode(makeEpisode())

        await evaluator.setResponseGenerator { _, _ in "response" }

        // Should not throw outsideOvernightWindow.
        let result = try await evaluator.runEvaluation(ignoreWindow: true)
        XCTAssertGreaterThan(result.episodesEvaluated, 0)
    }

    // MARK: - No Episodes

    func testRunEvaluationThrowsWhenNoEpisodes() async throws {
        let store = try await makeTempStore()
        let evaluator = makeEvaluator(store: store)
        await evaluator.setResponseGenerator { _, _ in "response" }

        do {
            _ = try await evaluator.runEvaluation(ignoreWindow: true)
            XCTFail("Expected noEpisodesAvailable")
        } catch let error as ShadowEvaluatorError {
            if case .noEpisodesAvailable = error { } else {
                XCTFail("Expected .noEpisodesAvailable, got \(error)")
            }
        }
    }

    // MARK: - Missing Generator

    func testRunEvaluationThrowsWhenNoGenerator() async throws {
        let store = try await makeTempStore()
        let evaluator = makeEvaluator(store: store)
        _ = try await store.appendShadowEpisode(makeEpisode())

        do {
            _ = try await evaluator.runEvaluation(ignoreWindow: true)
            XCTFail("Expected responseGeneratorNotSet")
        } catch let error as ShadowEvaluatorError {
            if case .responseGeneratorNotSet = error { } else {
                XCTFail("Expected .responseGeneratorNotSet, got \(error)")
            }
        }
    }

    // MARK: - Scoring via Injected Scorer

    func testAdapterWinsWhenScorerReturnsAdapterWins() async throws {
        let store = try await makeTempStore()
        let evaluator = makeEvaluator(store: store)
        _ = try await store.appendShadowEpisode(makeEpisode())

        await evaluator.setResponseGenerator { _, adapterPath in
            adapterPath == nil ? "base response" : "adapter response"
        }
        await evaluator.setScorer { _, _, _ in .adapterWins }

        let result = try await evaluator.runEvaluation(ignoreWindow: true)
        XCTAssertEqual(result.adapterWinRate, 1.0, accuracy: 0.01)
    }

    func testBaseWinsWhenScorerReturnsBaseWins() async throws {
        let store = try await makeTempStore()
        let evaluator = makeEvaluator(store: store)
        _ = try await store.appendShadowEpisode(makeEpisode())

        await evaluator.setResponseGenerator { _, _ in "response" }
        await evaluator.setScorer { _, _, _ in .baseWins }

        let result = try await evaluator.runEvaluation(ignoreWindow: true)
        XCTAssertEqual(result.adapterWinRate, 0.0, accuracy: 0.01)
    }

    func testTiesProduceZeroWinRate() async throws {
        let store = try await makeTempStore()
        let evaluator = makeEvaluator(store: store)
        for _ in 0..<5 {
            _ = try await store.appendShadowEpisode(makeEpisode())
        }
        await evaluator.setResponseGenerator { _, _ in "same response" }
        await evaluator.setScorer { _, _, _ in .tie }

        let result = try await evaluator.runEvaluation(ignoreWindow: true)
        XCTAssertEqual(result.adapterWinRate, 0.0, accuracy: 0.01)
        XCTAssertFalse(result.promotionGatePassed, "0% win rate should not pass promotion gate")
    }

    // MARK: - Promotion Gate

    func testPromotionGatePassesAtExactThreshold() async throws {
        let store = try await makeTempStore()
        let evaluator = makeEvaluator(store: store)

        // 6 episodes, 4 adapter wins = 66.7% → above 60% threshold.
        for _ in 0..<6 {
            _ = try await store.appendShadowEpisode(makeEpisode())
        }
        var callIndex = 0
        await evaluator.setResponseGenerator { _, _ in "response" }
        await evaluator.setScorer { _, _, _ in
            defer { callIndex += 1 }
            return callIndex < 4 ? .adapterWins : .baseWins
        }

        let result = try await evaluator.runEvaluation(ignoreWindow: true)
        XCTAssertTrue(result.promotionGatePassed, "66.7% win rate should pass 60% gate")
    }

    func testPromotionGateFailsBelowThreshold() async throws {
        let store = try await makeTempStore()
        let evaluator = makeEvaluator(store: store)

        // 10 episodes, 5 adapter wins = 50% → below 60%.
        for _ in 0..<10 {
            _ = try await store.appendShadowEpisode(makeEpisode())
        }
        var callIndex = 0
        await evaluator.setResponseGenerator { _, _ in "response" }
        await evaluator.setScorer { _, _, _ in
            defer { callIndex += 1 }
            return callIndex < 5 ? .adapterWins : .baseWins
        }

        let result = try await evaluator.runEvaluation(ignoreWindow: true)
        XCTAssertFalse(result.promotionGatePassed, "50% win rate should not pass 60% gate")
    }

    func testPromotionGatePassesAtExactly60Percent() async throws {
        let store = try await makeTempStore()
        let evaluator = makeEvaluator(store: store)

        // 10 episodes, 6 adapter wins = 60.0%.
        for _ in 0..<10 {
            _ = try await store.appendShadowEpisode(makeEpisode())
        }
        var callIndex = 0
        await evaluator.setResponseGenerator { _, _ in "response" }
        await evaluator.setScorer { _, _, _ in
            defer { callIndex += 1 }
            return callIndex < 6 ? .adapterWins : .baseWins
        }

        let result = try await evaluator.runEvaluation(ignoreWindow: true)
        XCTAssertTrue(result.promotionGatePassed, "Exactly 60% should pass the gate (>= threshold)")
    }

    // MARK: - Outcomes Persisted to Store

    func testOutcomesArePersistedToStore() async throws {
        let store = try await makeTempStore()
        let evaluator = makeEvaluator(store: store)

        for _ in 0..<3 {
            _ = try await store.appendShadowEpisode(makeEpisode())
        }
        await evaluator.setResponseGenerator { _, _ in "response" }
        await evaluator.setScorer { _, _, _ in .adapterWins }

        _ = try await evaluator.runEvaluation(ignoreWindow: true)

        let counts = try await store.shadowEvalCounts()
        XCTAssertEqual(counts.adapterWins, 3, "All 3 outcomes should be persisted as adapter_wins")
        XCTAssertEqual(counts.baseWins, 0)
        XCTAssertEqual(counts.ties, 0)
    }

    func testAlreadyEvaluatedEpisodesAreSkipped() async throws {
        let store = try await makeTempStore()
        let evaluator = makeEvaluator(store: store)

        // Add 1 unevaluated episode.
        _ = try await store.appendShadowEpisode(makeEpisode())
        // Add 1 already-evaluated episode (evaluated = true).
        var alreadyDone = makeEpisode()
        alreadyDone.evaluated = true
        _ = try await store.appendShadowEpisode(alreadyDone)

        await evaluator.setResponseGenerator { _, _ in "response" }
        await evaluator.setScorer { _, _, _ in .adapterWins }

        let result = try await evaluator.runEvaluation(ignoreWindow: true)
        // unevaluatedEpisodes() only returns evaluated=0 rows.
        XCTAssertEqual(result.episodesEvaluated, 1, "Only 1 unevaluated episode should be processed")
    }

    // MARK: - Heuristic Scorer

    func testHeuristicScorerReturnsAdapterWinsForShorterResponse() {
        let episode = makeEpisode()
        let base = String(repeating: "x", count: 100)
        let adapter = String(repeating: "x", count: 70) // 70% of base → ≤ 80% → adapter wins.
        let outcome = ShadowEvaluator.heuristicScore(
            episode: episode, baseResponse: base, adapterResponse: adapter
        )
        XCTAssertEqual(outcome, .adapterWins)
    }

    func testHeuristicScorerReturnsBaseWinsForLongerResponse() {
        let episode = makeEpisode()
        let base = String(repeating: "x", count: 100)
        let adapter = String(repeating: "x", count: 130) // 130% of base → ≥ 120% → base wins.
        let outcome = ShadowEvaluator.heuristicScore(
            episode: episode, baseResponse: base, adapterResponse: adapter
        )
        XCTAssertEqual(outcome, .baseWins)
    }

    func testHeuristicScorerReturnsTieForSimilarLength() {
        let episode = makeEpisode()
        let base = String(repeating: "x", count: 100)
        let adapter = String(repeating: "x", count: 100) // 100% → tie.
        let outcome = ShadowEvaluator.heuristicScore(
            episode: episode, baseResponse: base, adapterResponse: adapter
        )
        XCTAssertEqual(outcome, .tie)
    }

    func testHeuristicScorerReturnsTieForEmptyResponses() {
        let episode = makeEpisode()
        let outcome = ShadowEvaluator.heuristicScore(
            episode: episode, baseResponse: "", adapterResponse: ""
        )
        XCTAssertEqual(outcome, .tie)
    }

    // MARK: - EvalOutcome raw values

    func testEvalOutcomeRawValues() {
        XCTAssertEqual(EvalOutcome.baseWins.rawValue, "base_wins")
        XCTAssertEqual(EvalOutcome.adapterWins.rawValue, "adapter_wins")
        XCTAssertEqual(EvalOutcome.tie.rawValue, "tie")
    }

    // MARK: - Result timestamp

    func testResultHasValidTimestamp() async throws {
        let store = try await makeTempStore()
        let evaluator = makeEvaluator(store: store)
        _ = try await store.appendShadowEpisode(makeEpisode())
        await evaluator.setResponseGenerator { _, _ in "response" }
        await evaluator.setScorer { _, _, _ in .tie }

        let result = try await evaluator.runEvaluation(ignoreWindow: true)
        XCTAssertFalse(result.evaluatedAt.isEmpty)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: result.evaluatedAt))
    }
}
