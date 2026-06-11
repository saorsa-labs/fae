import XCTest
@testable import Fae

final class AwarenessThrottleTests: XCTestCase {

    // MARK: - shouldReduceFrequency

    func testShouldReduceFrequencyNeverSeen() {
        XCTAssertTrue(AwarenessThrottle.shouldReduceFrequency(lastUserSeenAt: nil))
    }

    func testShouldReduceFrequencyRecentlySeen() {
        let recently = Date().addingTimeInterval(-60) // 1 minute ago
        XCTAssertFalse(AwarenessThrottle.shouldReduceFrequency(lastUserSeenAt: recently))
    }

    func testShouldReduceFrequencyLongAgo() {
        let longAgo = Date().addingTimeInterval(-3600) // 1 hour ago
        XCTAssertTrue(AwarenessThrottle.shouldReduceFrequency(lastUserSeenAt: longAgo))
    }

    func testShouldReduceFrequencyBoundary() {
        // Just inside the 30-minute boundary. Testing exactly AT the boundary
        // is inherently flaky: wall-clock time advances between constructing
        // the date and evaluating it, tipping elapsed time past 30 minutes.
        let boundary = Date().addingTimeInterval(-(30 * 60 - 1))
        XCTAssertFalse(AwarenessThrottle.shouldReduceFrequency(lastUserSeenAt: boundary))
    }

    func testShouldReduceFrequencyJustOverBoundary() {
        // Just over 30 minutes
        let overBoundary = Date().addingTimeInterval(-(30 * 60 + 1))
        XCTAssertTrue(AwarenessThrottle.shouldReduceFrequency(lastUserSeenAt: overBoundary))
    }

    // MARK: - randomJitter

    func testRandomJitterInRange() {
        for _ in 0..<20 {
            let jitter = AwarenessThrottle.randomJitter()
            XCTAssertGreaterThanOrEqual(jitter, -5.0)
            XCTAssertLessThanOrEqual(jitter, 5.0)
        }
    }

    // MARK: - isQuietHours

    func testIsQuietHours() {
        // We can't control the system clock, but we can verify it returns a Bool
        let _ = AwarenessThrottle.isQuietHours()
        // Just verify it doesn't crash
    }

    // MARK: - check (ThrottleDecision)

    func testCheckTier1WithLiteEnabled() {
        var config = FaeConfig.AwarenessConfig()
        config.proactiveLiteEnabled = true
        let decision = AwarenessThrottle.check(
            config: config, taskId: "enhanced_morning_briefing"
        )
        // Should not skip (tier 1 with lite enabled)
        switch decision {
        case .skip:
            XCTFail("Should not skip tier 1 task with lite enabled")
        default:
            break
        }
    }

    func testCheckTier2Disabled() {
        var config = FaeConfig.AwarenessConfig()
        config.enabled = false
        let decision = AwarenessThrottle.check(
            config: config, taskId: "camera_presence_check"
        )
        switch decision {
        case .skip:
            break // Expected
        default:
            XCTFail("Should skip tier 2 task when awareness disabled")
        }
    }

    func testCheckTier1Disabled() {
        var config = FaeConfig.AwarenessConfig()
        config.proactiveLiteEnabled = false
        config.enabled = false
        let decision = AwarenessThrottle.check(
            config: config, taskId: "enhanced_morning_briefing"
        )
        switch decision {
        case .skip:
            break // Expected
        default:
            XCTFail("Should skip tier 1 task when lite disabled and no consent")
        }
    }

    func testCheckBatterySkip() {
        var config = FaeConfig.AwarenessConfig()
        config.enabled = true
        config.consentGrantedAt = "2025-01-01T00:00:00Z"
        config.pauseOnBattery = true
        // Note: isOnBattery() depends on actual system state — if on battery, should skip
        let decision = AwarenessThrottle.check(
            config: config, taskId: "camera_presence_check"
        )
        // Decision depends on actual battery state — just verify it doesn't crash
        _ = decision
    }

    // MARK: - ThrottleDecision cases

    func testThrottleDecisionCases() {
        let skip = ThrottleDecision.skip(reason: "test")
        switch skip {
        case .skip(let reason):
            XCTAssertEqual(reason, "test")
        default: break
        }

        let silent = ThrottleDecision.silentOnly
        switch silent {
        case .silentOnly: break
        default: XCTFail("Expected silentOnly")
        }

        let normal = ThrottleDecision.normal
        switch normal {
        case .normal: break
        default: XCTFail("Expected normal")
        }
    }
}
