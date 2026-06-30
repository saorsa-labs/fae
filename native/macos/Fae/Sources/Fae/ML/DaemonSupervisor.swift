import Foundation

// MARK: - B-Swift Phase B: daemon crash-supervisor
//
// Ports the `RustUiShellController` orb-shell supervisor pattern
// (`terminationHandler` + bounded retries + exponential backoff +
// `stableRunInterval` counter reset + exhaustion → Retry/Quit) to the daemon
// LLM lane. Today `DaemonLLMEngine.launchAndConnect` launches `fae-daemon`
// with NO `terminationHandler`, so a post-startup crash is never revived.
// This makes the daemon lane self-healing, with the exhaust path surfacing as
// a deliberate Retry/Quit (mirroring the orb shell). NOTE: there is NO
// automatic post-startup MLX continuity on exhaustion — the initial launch
// failure still falls back to MLX via `FaeCore.start()` catch, but a
// post-startup crash storm leaves the lane terminal until Retry.
//
// The decision logic is a PURE, injectable state machine (`DaemonSupervisor`)
// with NO `Process` dependency and NO real sleep — it takes a `Clock` and
// returns a `RestartDecision`, so the policy is unit-tested without launching a
// real daemon or sleeping real seconds. `DaemonLLMEngine` wires the real
// `terminationHandler` + a real sleeper around it.

// MARK: - Injectable time (testability)

/// A monotonic time source the supervisor consults for `stableRunInterval`
/// accounting. Production uses the wall clock; tests inject a fake so a "stable
/// 60-second run" is a single tick, not a real wait.
protocol DaemonSupervisorClock: Sendable {
    func now() -> Date
}

/// Default wall-clock implementation.
struct WallClockDaemonSupervisor: DaemonSupervisorClock {
    func now() -> Date { Date() }
}

/// An injectable async sleeper the restart path uses for backoff. Production
/// sleeps for real; tests inject a fake that records the requested delay and
/// returns immediately (so the bounded-restart sequence is exercised without
/// real `2^n`-second waits).
protocol DaemonSupervisorSleeper: Sendable {
    func sleep(seconds: TimeInterval) async
}

/// Default real sleeper.
struct RealDaemonSupervisorSleeper: DaemonSupervisorSleeper {
    func sleep(seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        // nanoseconds clamped to UInt64; backoff is small (1/2/4s) so this is
        // never near the limit, but guard defensively.
        let ns = UInt64(min(seconds, TimeInterval(UInt64.max) / 1_000_000_000) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: ns)
    }
}

// MARK: - Restart policy + decision

/// The bounded-restart policy (mirrors `RustUiShellController`). Exponential
/// backoff: attempt N waits `2^(N-1)` seconds (1, 2, 4). A run that stays alive
/// at least `stableRunInterval` resets the counter so a transient flurry of
/// crashes days apart doesn't accumulate toward exhaustion.
struct DaemonRestartPolicy: Sendable, Equatable {
    let maxRestartAttempts: Int
    let stableRunInterval: TimeInterval

    static let `default` = DaemonRestartPolicy(
        maxRestartAttempts: 3,
        stableRunInterval: 60
    )

    /// The backoff delay (seconds) before the `attempt`-th restart (1-based:
    /// the first retry is `attempt == 1` → 1s, then 2s, then 4s).
    func backoffSeconds(forAttempt attempt: Int) -> TimeInterval {
        // Guard against negative/zero exponents; `attempt` is always ≥1 from the
        // caller, but a defensive `max(0, attempt-1)` keeps the math total.
        pow(2.0, max(0, Double(attempt - 1)))
    }
}

/// The supervisor's answer to "the daemon just exited unexpectedly." Pure value
/// — no I/O. The engine acts on it (schedule a real sleep+relaunch, or surface
/// exhaustion).
enum DaemonRestartDecision: Equatable {
    /// Relaunch after `delaySeconds` (this is restart `attempt`, 1-based).
    case restart(delaySeconds: TimeInterval, attempt: Int)
    /// The bounded-restart budget is exhausted (the TRANSITION); the engine
    /// fails loud (clears endpoints, marks `loadState = .failed`, surfaces
    /// Retry/Quit). Fires the exhaustion callback.
    case exhausted
    /// Already exhausted (a later exit after the transition). The engine treats
    /// it as terminal but does NOT re-fire the exhaustion callback — prevents
    /// repeated user-facing alerts if the dead daemon's terminationHandler
    /// fires more than once.
    case alreadyExhausted
}

// MARK: - Supervisor state machine (pure)

/// The crash-restart state machine for the daemon LLM lane. Pure: consults an
/// injected `Clock`, mutates only its own fields, returns `DaemonRestartDecision`
/// values for the engine to act on. The engine owns the real `Process` +
/// `terminationHandler` + sleeper; this owns ONLY the policy.
///
/// Lifecycle (driven by the engine):
///   1. `recordLaunch(at:)` when a daemon process starts (sets the stability
///      baseline; the first exit after this is compared against it).
///   2. `recordStableRun(at:)` when a run exceeds `stableRunInterval` (resets
///      the crash counter — stale crashes don't accumulate).
///   3. `decideOnUnexpectedExit(at:)` on an unexpected `terminationHandler`
///      fire → returns `.restart(delay, attempt)` or `.exhausted`.
///   4. `recordIntentionalStop()` during `shutdown()` → permanently disarms
///      restart until reset (an intentional stop must NEVER trigger a restart).
///   5. `retryAfterExhausted()` from a Retry button → resets the counter for a
///      fresh attempt.
///
/// Thread safety: the engine hops every `terminationHandler` callback back into
/// its own actor (`Task { await self.handleDaemonExit(status:) }`), so this
/// state machine is only ever touched from the engine's actor. It is NOT
/// `Sendable`-annotated because it carries mutable state; it lives behind the
/// actor.
final class DaemonSupervisor {
    private let policy: DaemonRestartPolicy
    private let clock: DaemonSupervisorClock

    /// Crash count since the last stable run / reset. Incremented on each
    /// unexpected exit; cleared by a stable run or an intentional reset.
    private var restartAttempts = 0
    /// The launch time of the currently-running process, used to decide whether
    /// an exiting run was "stable" (≥ `stableRunInterval`) → reset the counter.
    private var lastLaunchDate: Date?
    /// Set by `recordIntentionalStop()` — permanently disarms restart until
    /// `retryAfterExhausted()` / `reset()`. Prevents a `shutdown()`-time exit
    /// from scheduling a zombie relaunch.
    private var isStoppingIntentionally = false
    /// `true` once `decideOnUnexpectedExit` has returned `.exhausted`. Guards a
    /// single exhaustion callback fire per exhaustion cycle.
    private var didFireExhaustion = false

    init(policy: DaemonRestartPolicy = .default, clock: DaemonSupervisorClock = WallClockDaemonSupervisor()) {
        self.policy = policy
        self.clock = clock
    }

    // MARK: Read-only state (for assertions / UI)

    var currentRestartAttempts: Int { restartAttempts }
    var isExhausted: Bool { didFireExhaustion }
    var isDisarmed: Bool { isStoppingIntentionally }

    // MARK: Lifecycle hooks

    /// Record that a daemon process was launched at `date` (defaults to now).
    /// Establishes the stability baseline for the next exit. Clears the
    /// single-exhaustion-fire guard (a fresh launch is a fresh cycle).
    ///
    /// If the PREVIOUS run stayed alive ≥ `stableRunInterval`, resets the crash
    /// counter — earlier crashes are stale (mirrors the orb-shell supervisor's
    /// `scheduleRestartAfterCrash` stable-run check). This is checked on launch,
    /// not on exit, so the reset is attributed to the run that earned it.
    func recordLaunch(at date: Date? = nil) {
        let launchDate = date ?? clock.now()
        if let prior = lastLaunchDate,
           launchDate.timeIntervalSince(prior) >= policy.stableRunInterval
        {
            restartAttempts = 0
        }
        lastLaunchDate = launchDate
        didFireExhaustion = false
    }

    /// Record that the current run has been alive at least `stableRunInterval`.
    /// Convenience hook for proactive reset mid-run (the launch-time check in
    /// `recordLaunch` is the authoritative reset). Idempotent.
    func recordStableRun(at date: Date? = nil) {
        let now = date ?? clock.now()
        if let lastLaunchDate, now.timeIntervalSince(lastLaunchDate) >= policy.stableRunInterval {
            restartAttempts = 0
        }
    }

    /// Permanently disarms restart (intentional shutdown). Any subsequent
    /// `decideOnUnexpectedExit` returns `.exhausted`-equivalent no-op (the
    /// engine must not act on it). Used by `internalShutdown`.
    func recordIntentionalStop() {
        isStoppingIntentionally = true
    }

    /// Reset the crash counter and re-arm restart — used by the Retry alert
    /// action after exhaustion, or to start a fresh supervision cycle.
    func retryAfterExhausted() {
        restartAttempts = 0
        isStoppingIntentionally = false
        didFireExhaustion = false
        lastLaunchDate = clock.now()
    }

    /// Decide what to do after a SUPERVISED RELAUNCH itself failed (the
    // process wouldn't start or the socket never came up). Distinct from
    // `decideOnUnexpectedExit`: a relaunch failure is NOT a new crash of an
    // already-counted attempt — it IS the next launch attempt, so increment
    // once here and decide. Without this split, a failed relaunch would be
    // double-counted (the crash already incremented for this attempt).
    func decideAfterFailedRelaunch() -> DaemonRestartDecision {
        if isStoppingIntentionally { return .exhausted }
        if didFireExhaustion { return .alreadyExhausted }
        guard restartAttempts < policy.maxRestartAttempts else {
            didFireExhaustion = true
            return .exhausted
        }
        restartAttempts += 1
        let delay = policy.backoffSeconds(forAttempt: restartAttempts)
        return .restart(delaySeconds: delay, attempt: restartAttempts)
    }

    /// Decide what to do after an unexpected exit. Pure: returns a decision the
    /// engine acts on; does NOT launch or sleep. Returns `.exhausted` once the
    /// budget is spent OR the supervisor is disarmed; the exhaustion guard
    /// ensures the engine fires its exhaustion callback exactly once per cycle.
    func decideOnUnexpectedExit(at date: Date? = nil) -> DaemonRestartDecision {
        // Intentional stop during shutdown: never restart. Return `.exhausted`
        // so the engine treats it as terminal (it will have already cleared
        // state), but do NOT set `didFireExhaustion` (no user-facing callback
        // for an intentional quit).
        if isStoppingIntentionally { return .exhausted }

        // Already exhausted: return the no-op variant so the engine does not
        // re-fire the exhaustion callback on repeated exits. The transition
        // (below) returns `.exhausted` exactly once.
        if didFireExhaustion { return .alreadyExhausted }

        // The stable-run reset happens in `recordLaunch` (attributed to the
        // run that earned it); no reset here.

        guard restartAttempts < policy.maxRestartAttempts else {
            didFireExhaustion = true
            return .exhausted
        }
        restartAttempts += 1
        let delay = policy.backoffSeconds(forAttempt: restartAttempts)
        return .restart(delaySeconds: delay, attempt: restartAttempts)
    }
}
