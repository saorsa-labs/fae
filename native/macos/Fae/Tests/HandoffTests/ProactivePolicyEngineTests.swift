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
        let first = ProactivePolicyEngine.decide(urgency: .low, digestEligibleCount: 1, now: now)
        let second = ProactivePolicyEngine.decide(urgency: .low, digestEligibleCount: 2, now: now)
        XCTAssertEqual(first.mode, .suppress)
        XCTAssertEqual(first.reason, "quiet_hours_suppress")
        XCTAssertEqual(second.mode, .digest)
        XCTAssertEqual(second.reason, "quiet_hours_digest")
    }

    func testNormalHoursStayImmediateUntilRepetitionThresholdThenDigest() {
        var c = DateComponents(); c.year = 2026; c.month = 1; c.day = 1; c.hour = 14
        let now = Calendar.current.date(from: c) ?? Date()

        let first = ProactivePolicyEngine.decide(urgency: .low, digestEligibleCount: 1, now: now)
        let second = ProactivePolicyEngine.decide(urgency: .medium, digestEligibleCount: 2, now: now)
        let third = ProactivePolicyEngine.decide(urgency: .low, digestEligibleCount: 3, now: now)

        XCTAssertEqual(first.mode, .immediate)
        XCTAssertEqual(first.reason, "normal_immediate")
        XCTAssertEqual(second.mode, .immediate)
        XCTAssertEqual(second.reason, "normal_immediate")
        XCTAssertEqual(third.mode, .digest)
        XCTAssertEqual(third.reason, "repetition_digest")
    }
}
