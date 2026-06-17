import XCTest
@testable import Fae

/// Coverage for two 0%-covered Search files: CircuitBreaker (per-engine
/// circuit-breaker state machine) and SearchHTTPClient (pure URLRequest/UA
/// builders). CircuitBreaker tested behaviourally via Bool returns; its
/// nested CircuitState type is private so we infer state from shouldAttempt.
final class SearchInfraStaticTests: XCTestCase {

    // MARK: - CircuitBreaker

    func testCircuitBreakerAllowsByDefault() async {
        let cb = CircuitBreaker()
        for engine in [SearchEngine.brave, .google, .bing] {
            let result_26672 = await cb.shouldAttempt(engine)
            XCTAssertTrue(result_26672, "engine \(engine) should be allowed fresh")
        }
    }

    func testCircuitBreakerOpensAfterThresholdFailures() async {
        let cb = CircuitBreaker(failureThreshold: 3, cooldownSeconds: 60)
        await cb.recordFailure(.brave)
        await cb.recordFailure(.brave)
        let result_27769 = await cb.shouldAttempt(.brave)
        XCTAssertTrue(result_27769)
        await cb.recordFailure(.brave) // 3rd -> open
        let result_96828 = await cb.shouldAttempt(.brave)
        XCTAssertFalse(result_96828)
    }

    func testCircuitBreakerSuccessResetsFailures() async {
        let cb = CircuitBreaker(failureThreshold: 3, cooldownSeconds: 60)
        await cb.recordFailure(.google)
        await cb.recordFailure(.google)
        await cb.recordSuccess(.google) // resets to closed
        // After success, fresh failures needed again — should still be allowed.
        let result_47444 = await cb.shouldAttempt(.google)
        XCTAssertTrue(result_47444)
        await cb.recordFailure(.google)
        let result_69634 = await cb.shouldAttempt(.google)
        XCTAssertTrue(result_69634)
    }

    func testCircuitBreakerHalfOpensAfterCooldown() async {
        // Tiny cooldown so the open -> halfOpen transition fires immediately.
        let cb = CircuitBreaker(failureThreshold: 1, cooldownSeconds: 0)
        await cb.recordFailure(.bing) // 1 failure -> open
        // cooldown 0 -> next shouldAttempt transitions to halfOpen and allows.
        let result_61154 = await cb.shouldAttempt(.bing)
        XCTAssertTrue(result_61154)
    }

    func testCircuitBreakerEnginesAreIndependent() async {
        let cb = CircuitBreaker(failureThreshold: 1, cooldownSeconds: 60)
        await cb.recordFailure(.brave) // brave open
        let result_93173 = await cb.shouldAttempt(.brave)
        XCTAssertFalse(result_93173)
        let result_76468 = await cb.shouldAttempt(.google)
        XCTAssertTrue(result_76468)
    }

    func testCircuitBreakerHealthReportAndReset() async {
        let cb = CircuitBreaker(failureThreshold: 2, cooldownSeconds: 60)
        await cb.recordFailure(.brave)
        let report = await cb.healthReport()
        XCTAssertFalse(report.isEmpty)
        XCTAssertTrue(report.contains { $0.engine == .brave && $0.failures == 1 })
        await cb.reset()
        let afterReset = await cb.healthReport()
        // After reset all engines report 0 failures.
        XCTAssertTrue(afterReset.allSatisfy { $0.failures == 0 })
    }

    // MARK: - SearchHTTPClient

    func testUserAgentCustom() {
        XCTAssertEqual(SearchHTTPClient.userAgent(custom: "MyBot/1.0"), "MyBot/1.0")
    }

    func testUserAgentRandom() {
        let ua = SearchHTTPClient.userAgent(custom: nil)
        XCTAssertFalse(ua.isEmpty)
    }

    func testGetRequestSetsHeaders() {
        let url = URL(string: "https://example.com/search")!
        let req = SearchHTTPClient.getRequest(url: url, config: .default)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertNotNil(req.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertNotNil(req.value(forHTTPHeaderField: "Accept"))
        XCTAssertNotNil(req.value(forHTTPHeaderField: "Accept-Language"))
    }

    func testPostRequestSetsBodyAndContentType() {
        let url = URL(string: "https://example.com/search")!
        let req = SearchHTTPClient.postRequest(url: url, body: "q=test", config: .default)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(req.httpBody, "q=test".data(using: .utf8))
    }
}
