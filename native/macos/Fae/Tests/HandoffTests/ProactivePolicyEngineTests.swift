import XCTest
@testable import Fae

final class ProactivePolicyEngineTests: XCTestCase {
    func testUrgencyOverrideImmediate() {
        let d = ProactivePolicyEngine.decide(urgency: .high, digestEligibleCount: 0)
        XCTAssertEqual(d.mode, .immediate)
        XCTAssertEqual(d.reason, "urgency_override")
    }

    func testQuietHoursSuppressThenDigest() {
        var c = DateComponents(); c.year = 2026; c.month = 1; c.day = 1; c.hour = 23
        let now = Calendar.current.date(from: c) ?? Date()
        let a = ProactivePolicyEngine.decide(urgency: .low, digestEligibleCount: 1, now: now)
        let b = ProactivePolicyEngine.decide(urgency: .low, digestEligibleCount: 2, now: now)
        XCTAssertEqual(a.mode, .suppress)
        XCTAssertEqual(b.mode, .digest)
    }
}
