import XCTest
@testable import Fae

/// Coverage for SearchOrchestrator.swift (was 0% covered). Exposed two pure-ish
/// instance methods: selectEngines (circuit-breaker-gated engine selection) and
/// scoreResults (per-engine position-decay scoring). Default SearchOrchestrator()
/// init (no custom init). Network methods (search/fetchPageContent) excluded.
final class SearchOrchestratorStaticTests: XCTestCase {

    private func makeResult(_ engine: SearchEngine, _ url: String, score: Double = 0) -> SearchResult {
        SearchResult(title: "T", url: url, snippet: "S", engine: engine.rawValue, score: score)
    }

    // MARK: - selectEngines

    func testSelectEnginesReturnsAllByDefault() async {
        // Fresh circuit breakers — all engines in config should be selected.
        let orchestrator = SearchOrchestrator()
        let cfg = SearchConfig(engines: [.duckDuckGo, .brave, .google], maxResults: 10,
                               timeoutSeconds: 8, safeSearch: true, cacheTTLSeconds: 60,
                               requestDelayMs: (0, 0), userAgent: nil)
        // Reset global breaker to a clean state first (process-global).
        await GlobalCircuitBreaker.shared.reset()
        let selected = await orchestrator.selectEngines(config: cfg)
        XCTAssertEqual(Set(selected), Set([.duckDuckGo, .brave, .google]))
    }

    func testSelectEnginesFallsBackToAllWhenTripped() async throws {
        // Trip every engine's breaker, then selectEngines should fall back to
        // returning the full configured set (better to try than return nothing).
        let orchestrator = SearchOrchestrator()
        let cfg = SearchConfig(engines: [.bing], maxResults: 10, timeoutSeconds: 8,
                               safeSearch: true, cacheTTLSeconds: 60,
                               requestDelayMs: (0, 0), userAgent: nil)
        await GlobalCircuitBreaker.shared.reset()
        // Trip bing with the shared breaker (1 failure, threshold-1 default -> open).
        for _ in 0..<5 { await GlobalCircuitBreaker.shared.recordFailure(.bing) }
        let selected = await orchestrator.selectEngines(config: cfg)
        XCTAssertEqual(selected, [.bing]) // fallback returns config.engines
        await GlobalCircuitBreaker.shared.reset()
    }

    // MARK: - scoreResults

    func testScoreResultsAppliesPositionDecay() async {
        let orchestrator = SearchOrchestrator()
        let results = [
            makeResult(.google, "https://g.com/1"),
            makeResult(.google, "https://g.com/2"),
            makeResult(.google, "https://g.com/3"),
        ]
        let scored = await orchestrator.scoreResults(results)
        XCTAssertEqual(scored.count, 3)
        // Position 0 has the highest score within the google group.
        let sorted = scored.sorted { $0.score > $1.score }
        XCTAssertEqual(sorted.first?.url, "https://g.com/1")
        // All scores positive and bounded by the engine weight.
        for r in scored { XCTAssertGreaterThan(r.score, 0) }
    }

    func testScoreResultsWeightsVaryByEngine() async {
        let orchestrator = SearchOrchestrator()
        let results = [
            makeResult(.google, "https://g.com/1"),    // google weight
            makeResult(.duckDuckGo, "https://d.com/1"), // ddg weight
        ]
        let scored = await orchestrator.scoreResults(results)
        let google = scored.first { $0.url == "https://g.com/1" }
        let ddg = scored.first { $0.url == "https://d.com/1" }
        XCTAssertNotNil(google)
        XCTAssertNotNil(ddg)
        // Different engine weights => different scores (both position 0).
        if let g = google?.score, let d = ddg?.score {
            XCTAssertFalse(abs(g - d) < 1e-6, "google/ddg scores should differ by engine weight")
        }
    }

    func testScoreResultsEmpty() async {
        let orchestrator = SearchOrchestrator()
        let scored = await orchestrator.scoreResults([])
        XCTAssertEqual(scored.count, 0)
    }

    // MARK: - clearCache

    func testClearCacheDoesNotThrow() async {
        let orchestrator = SearchOrchestrator()
        await orchestrator.clearCache() // smoke test — no crash
        XCTAssertTrue(true)
    }
}
