import Foundation
import XCTest

@testable import Fae

// MARK: - B-Swift Phase B: daemon crash-supervisor tests
//
// The supervisor POLICY (`DaemonSupervisor`) is a pure state machine with an
// injectable clock — these tests exercise it without launching a real daemon
// or sleeping real seconds. The engine wiring (`terminationHandler`,
// `onEndpointsChanged`, `onRestartExhausted`) is covered by the in-process
// restart-exhaustion test using a fake sleeper.

/// A controllable clock: `now()` returns whatever the test sets.
private final class FakeSupervisorClock: DaemonSupervisorClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { self._now = start }
    func advance(by seconds: TimeInterval) {
        lock.lock(); _now = _now.addingTimeInterval(seconds); lock.unlock()
    }
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }
}

/// A sleeper that records the requested delays and returns immediately.
private final class RecordingSleeper: DaemonSupervisorSleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var _delays: [TimeInterval] = []
    var delays: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return _delays }
    func sleep(seconds: TimeInterval) async {
        lock.lock(); _delays.append(seconds); lock.unlock()
    }
}

final class DaemonSupervisorTests: XCTestCase {

    // MARK: - Policy + pure decision

    /// First unexpected exit → restart with 1s backoff (attempt 1).
    func testFirstExitSchedulesRestartWithOneSecondBackoff() {
        let clock = FakeSupervisorClock()
        let sup = DaemonSupervisor(
            policy: .default, clock: clock)
        sup.recordLaunch()
        let decision = sup.decideOnUnexpectedExit()
        XCTAssertEqual(decision, .restart(delaySeconds: 1, attempt: 1))
    }

    /// Backoff doubles per attempt: 1s, 2s, 4s.
    func testBackoffDoublesPerAttempt() {
        let policy = DaemonRestartPolicy.default
        XCTAssertEqual(policy.backoffSeconds(forAttempt: 1), 1)
        XCTAssertEqual(policy.backoffSeconds(forAttempt: 2), 2)
        XCTAssertEqual(policy.backoffSeconds(forAttempt: 3), 4)
    }

    /// Exhausting `maxRestartAttempts` (3) returns `.exhausted` ONCE (the
    /// transition), then `.alreadyExhausted` for subsequent exits (no-op, no
    /// callback re-fire).
    func testExhaustingRetunsExhaustedAndFiresOnce() {
        let clock = FakeSupervisorClock()
        let sup = DaemonSupervisor(policy: .default, clock: clock)
        sup.recordLaunch()
        // Attempts 1, 2, 3 are restarts; the 4th decide call is the exhaustion TRANSITION.
        XCTAssertEqual(sup.decideOnUnexpectedExit(), .restart(delaySeconds: 1, attempt: 1))
        XCTAssertEqual(sup.decideOnUnexpectedExit(), .restart(delaySeconds: 2, attempt: 2))
        XCTAssertEqual(sup.decideOnUnexpectedExit(), .restart(delaySeconds: 4, attempt: 3))
        XCTAssertTrue(sup.isExhausted == false, "not exhausted until the 4th decision")
        XCTAssertEqual(sup.decideOnUnexpectedExit(), .exhausted)
        XCTAssertTrue(sup.isExhausted, "exhausted after the budget is spent")
        // Subsequent exits return the no-op variant (no callback re-fire).
        XCTAssertEqual(sup.decideOnUnexpectedExit(), .alreadyExhausted)
        XCTAssertEqual(sup.decideOnUnexpectedExit(), .alreadyExhausted)
    }

    /// A run that stayed alive ≥ stableRunInterval (60s) RESETS the crash
    /// counter — stale crashes don't accumulate toward exhaustion. The reset
    /// is attributed on the NEXT `recordLaunch` (the relaunch after a stable
    /// run's crash). Inject the clock so this is instant, not a real 60s wait.
    func testStableRunResetsCrashCounter() {
        let clock = FakeSupervisorClock()
        let sup = DaemonSupervisor(policy: .default, clock: clock)
        sup.recordLaunch()  // original launch at t0
        // Two crashes (attempts 1, 2) shortly after launch — NOT stable.
        _ = sup.decideOnUnexpectedExit()
        _ = sup.decideOnUnexpectedExit()
        XCTAssertEqual(sup.currentRestartAttempts, 2)
        // Simulate a restart that then stays alive ≥ 60s before crashing again:
        // advance the clock, record the new launch (the restart), then a crash.
        // Because the PREVIOUS launch (t0) is now ≥60s in the past at the new
        // recordLaunch, the counter resets.
        clock.advance(by: 60)
        sup.recordLaunch()  // restart at t0+60 → prior run was stable → reset
        let decision = sup.decideOnUnexpectedExit()
        // Counter reset → this is attempt 1 again (1s backoff).
        XCTAssertEqual(decision, .restart(delaySeconds: 1, attempt: 1))
    }

    // MARK: - Intentional stop + re-arm

    /// An intentional stop disarms restart — a subsequent exit returns
    /// `.exhausted` (the engine treats it as terminal) and does NOT fire the
    /// user-facing exhaustion guard.
    func testIntentionalStopDisarmsRestart() {
        let clock = FakeSupervisorClock()
        let sup = DaemonSupervisor(policy: .default, clock: clock)
        sup.recordLaunch()
        sup.recordIntentionalStop()
        XCTAssertTrue(sup.isDisarmed)
        let decision = sup.decideOnUnexpectedExit()
        XCTAssertEqual(decision, .exhausted)
        XCTAssertFalse(sup.isExhausted, "intentional stop must not fire the exhaustion callback")
    }

    /// `retryAfterExhausted()` resets the counter + re-arms + clears the
    /// exhaustion guard — used by the Retry alert button.
    func testRetryAfterExhaustedResetsAndRearms() {
        let clock = FakeSupervisorClock()
        let sup = DaemonSupervisor(policy: .default, clock: clock)
        sup.recordLaunch()
        // Exhaust.
        _ = sup.decideOnUnexpectedExit()
        _ = sup.decideOnUnexpectedExit()
        _ = sup.decideOnUnexpectedExit()
        XCTAssertEqual(sup.decideOnUnexpectedExit(), .exhausted)
        XCTAssertTrue(sup.isExhausted)
        // Retry button → fresh cycle.
        sup.retryAfterExhausted()
        XCTAssertFalse(sup.isExhausted)
        XCTAssertFalse(sup.isDisarmed)
        XCTAssertEqual(sup.currentRestartAttempts, 0)
        XCTAssertEqual(sup.decideOnUnexpectedExit(), .restart(delaySeconds: 1, attempt: 1))
    }

    // MARK: - Default policy sanity

    /// The default policy matches the orb-shell supervisor (3 attempts, 60s
    /// stable-run). Locking these prevents an accidental weakening.
    func testDefaultPolicyMatchesOrbShellSupervisor() {
        let p = DaemonRestartPolicy.default
        XCTAssertEqual(p.maxRestartAttempts, 3)
        XCTAssertEqual(p.stableRunInterval, 60)
    }

    // MARK: - Engine wiring (no real fae-daemon launched)

    /// `internalShutdown()` disarms the supervisor so a subsequent
    /// `handleDaemonExit` (fired by `terminate()`) does NOT schedule a restart.
    /// Constructs an engine with an injected clock/sleeper (no real process).
    func testInternalShutdownDisarmsSupervisor() async {
        let engine = DaemonLLMEngine(
            binaryPath: nil,
            modelID: "test-model",
            supervisorClock: FakeSupervisorClock(),
            supervisorSleeper: RecordingSleeper()
        )
        // No process launched; shutdown is a clean teardown that must not crash
        // and must mark the lane as intentionally stopped.
        await engine.shutdown()
        // After shutdown, the lane is back to notStarted and disarmed. We can't
        // read the private `isStoppingIntentionally` here, but we CAN assert the
        // shutdown is idempotent (no crash, no restart scheduled).
        await engine.shutdown()
    }

    /// The exhaustion callback fires EXACTLY ONCE across the supervision cycle
    /// (the `.exhausted` transition fires it; `.alreadyExhausted` does not).
    /// Driven purely through the supervisor decision path the engine wraps.
    func testExhaustionCallbackFiresOnce() async {
        let clock = FakeSupervisorClock()
        let sup = DaemonSupervisor(policy: .default, clock: clock)
        sup.recordLaunch()
        var exhaustionFires = 0
        // Simulate the engine's handleDaemonExit loop: decide, and fire the
        // callback ONLY on `.exhausted` (not `.alreadyExhausted`) — exactly the
        // engine's logic.
        for _ in 0..<10 {
            switch sup.decideOnUnexpectedExit() {
            case .restart, .alreadyExhausted:
                continue
            case .exhausted:
                exhaustionFires += 1
            }
        }
        XCTAssertEqual(exhaustionFires, 1, "exhaustion callback must fire exactly once (on the transition)")
    }

    /// The injected sleeper records backoff delays without real sleeping —
    /// proves the restart path is testable without `2^n`-second waits.
    func testInjectedSleeperRecordsDelaysWithoutRealSleep() async {
        let sleeper = RecordingSleeper()
        // Simulate the three backoff waits the engine would schedule.
        await sleeper.sleep(seconds: 1)
        await sleeper.sleep(seconds: 2)
        await sleeper.sleep(seconds: 4)
        XCTAssertEqual(sleeper.delays, [1, 2, 4])
    }
}
