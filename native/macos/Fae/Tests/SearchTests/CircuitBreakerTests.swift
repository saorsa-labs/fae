import XCTest
@testable import Fae

final class CircuitBreakerTests: XCTestCase {

    // MARK: - Initial state

    func testInitialStateAllowsAttempts() async {
        let cb = CircuitBreaker()
        let allowed = await cb.shouldAttempt(.duckDuckGo)
        XCTAssertTrue(allowed, "New circuit breaker should allow attempts")
    }

    // MARK: - Failure tracking

    func testSingleFailureStillAllows() async {
        let cb = CircuitBreaker()
        await cb.recordFailure(.duckDuckGo)
        let allowed = await cb.shouldAttempt(.duckDuckGo)
        XCTAssertTrue(allowed, "One failure should not trip the breaker")
    }

    func testThreeFailuresTripsBreaker() async {
        let cb = CircuitBreaker()
        await cb.recordFailure(.duckDuckGo)
        await cb.recordFailure(.duckDuckGo)
        await cb.recordFailure(.duckDuckGo)
        let allowed = await cb.shouldAttempt(.duckDuckGo)
        XCTAssertFalse(allowed, "Three failures should trip the breaker")
    }

    // MARK: - Success resets

    func testSuccessResetsFailureCount() async {
        let cb = CircuitBreaker()
        await cb.recordFailure(.brave)
        await cb.recordFailure(.brave)
        // Two failures, one more would trip — but success resets.
        await cb.recordSuccess(.brave)
        await cb.recordFailure(.brave)
        let allowed = await cb.shouldAttempt(.brave)
        XCTAssertTrue(allowed, "Success should reset failure count")
    }

    // MARK: - Independence between engines

    func testEnginesAreIndependent() async {
        let cb = CircuitBreaker()
        // Trip DuckDuckGo.
        for _ in 0..<3 { await cb.recordFailure(.duckDuckGo) }
        // Brave should still work.
        let ddgAllowed = await cb.shouldAttempt(.duckDuckGo)
        let braveAllowed = await cb.shouldAttempt(.brave)
        XCTAssertFalse(ddgAllowed)
        XCTAssertTrue(braveAllowed)
    }

    // MARK: - GlobalCircuitBreaker singleton

    func testGlobalSingletonWorks() async {
        // Just verify it's accessible and functions.
        let allowed = await GlobalCircuitBreaker.shared.shouldAttempt(.google)
        XCTAssertTrue(allowed)
        await GlobalCircuitBreaker.shared.recordSuccess(.google)
    }
}
