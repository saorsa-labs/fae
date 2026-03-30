import Foundation

// MARK: - CycleState

/// States of the autonomous self-improvement cycle.
///
/// The state machine is linear with error recovery to `idle`:
/// ```
/// idle -> collecting -> training -> evaluating -> proposing -> deploying -> idle
///                 \           \           \           \           \
///                  `-> idle    `-> idle    `-> idle    `-> idle    `-> idle
/// ```
/// Any failure resets to `idle`. The coordinator persists state to `ImprovementStore`
/// at every transition so recovery after a crash resumes from the last known state.
enum CycleState: String, Sendable {
    case idle
    case collecting
    case training
    case evaluating
    case proposing
    case deploying

    /// Valid successor states (forward progress or error recovery to idle).
    var validSuccessors: Set<CycleState> {
        switch self {
        case .idle:       return [.collecting]
        case .collecting: return [.training, .idle]
        case .training:   return [.evaluating, .idle]
        case .evaluating: return [.proposing, .idle]
        case .proposing:  return [.deploying, .idle]
        case .deploying:  return [.idle]
        }
    }
}

// MARK: - Errors

/// Errors produced by the improvement cycle coordinator.
enum ImprovementCycleError: Error, Sendable {
    /// Attempted an invalid state transition.
    case invalidTransition(from: CycleState, to: CycleState)
    /// The ImprovementStore is not available.
    case storeNotAvailable
    /// Insufficient data to run a training cycle.
    case insufficientData(feedbackCount: Int, correctionCount: Int)
    /// The training cycle appears stuck (started more than maxDuration ago).
    case stuckDetected(startedAt: String)
}

// MARK: - ImprovementCycleCoordinator

/// Orchestrates the autonomous self-improvement loop.
///
/// The coordinator runs as a nightly scheduled task (02:00-05:00 window) and drives
/// the improvement cycle through a deterministic state machine. Each transition is
/// persisted to `ImprovementStore` so the cycle can resume after a crash.
///
/// ## Minimum Data Thresholds
/// - At least 20 unconsumed feedback events
/// - At least 5 correction-type events among them
///
/// ## Stuck Detection
/// If `trainingStartedAt` is more than 2 hours old, the coordinator force-resets
/// to `idle` to prevent permanent wedging.
///
/// ## Usage
/// ```swift
/// let coordinator = ImprovementCycleCoordinator(store: improvementStore)
/// try await coordinator.runCycle()
/// ```
actor ImprovementCycleCoordinator {

    // MARK: - Configuration

    /// Minimum number of unconsumed feedback events required to start a cycle.
    static let minFeedbackEvents = 20

    /// Minimum number of correction-type events required to start a cycle.
    static let minCorrectionEvents = 5

    /// Maximum duration (in seconds) before a training cycle is considered stuck.
    static let maxTrainingDurationSeconds: TimeInterval = 2 * 3600 // 2 hours

    // MARK: - Dependencies

    private let store: ImprovementStore

    // MARK: - Init

    /// Create a coordinator backed by the given improvement store.
    ///
    /// - Parameter store: The `ImprovementStore` that persists cycle state and feedback data.
    init(store: ImprovementStore) {
        self.store = store
    }

    // MARK: - State Machine

    /// Read the current cycle state from the store.
    ///
    /// Returns `.idle` if the state row has not been initialised yet.
    func currentState() async throws -> CycleState {
        do {
            let state = try await store.readState()
            return CycleState(rawValue: state.cycleState) ?? .idle
        } catch let error as ImprovementStoreError {
            if case .stateNotInitialised = error {
                return .idle
            }
            throw error
        }
    }

    /// Transition the state machine to a new state, persisting to the store.
    ///
    /// - Parameter newState: The target state.
    /// - Throws: `ImprovementCycleError.invalidTransition` if the transition is not valid.
    func transition(to newState: CycleState) async throws {
        let current = try await currentState()
        guard current.validSuccessors.contains(newState) else {
            throw ImprovementCycleError.invalidTransition(from: current, to: newState)
        }
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.cycleState = newState.rawValue
        if newState == .training {
            state.trainingStartedAt = ISO8601DateFormatter().string(from: Date())
        }
        if newState == .idle && current != .idle {
            // Completed a full cycle or recovered from error.
            if current == .deploying {
                state.completedCycles += 1
                state.lastCycleAt = ISO8601DateFormatter().string(from: Date())
            }
            state.trainingStartedAt = nil
        }
        try await store.writeState(state)
    }

    // MARK: - Stuck Detection

    /// Check if a training cycle has been running longer than the maximum allowed duration.
    ///
    /// - Returns: `true` if stuck (trainingStartedAt exists and is older than 2 hours).
    func isStuck() async throws -> Bool {
        let storeState: ImprovementState
        do {
            storeState = try await store.readState()
        } catch {
            return false
        }
        guard let startedStr = storeState.trainingStartedAt else { return false }
        guard let started = ISO8601DateFormatter().date(from: startedStr) else { return false }
        return Date().timeIntervalSince(started) > Self.maxTrainingDurationSeconds
    }

    // MARK: - Main Loop

    /// Run one improvement cycle.
    ///
    /// This method is the main entry point called by the scheduler. It:
    /// 1. Checks for stuck state and recovers if needed
    /// 2. Verifies the cycle is in `idle` state
    /// 3. Checks minimum data thresholds
    /// 4. Drives the state machine through collecting -> training -> evaluating -> proposing -> deploying -> idle
    ///
    /// Each step delegates to the appropriate subsystem (training skill, eval benchmark, etc.)
    /// via future integration points. For now, steps after collecting are stubbed with
    /// state transitions to establish the framework.
    ///
    /// - Throws: `ImprovementCycleError` on threshold failures or state issues.
    func runCycle() async throws {
        // Step 0: Ensure state row exists.
        try await store.ensureStateRow()

        // Step 1: Stuck detection — force reset if training is wedged.
        if try await isStuck() {
            let storeState = try await store.readState()
            NSLog(
                "ImprovementCycleCoordinator: stuck detected (started %@), resetting to idle",
                storeState.trainingStartedAt ?? "unknown"
            )
            var resetState = storeState
            resetState.cycleState = CycleState.idle.rawValue
            resetState.trainingStartedAt = nil
            resetState.lastCycleError = "stuck_detected"
            try await store.writeState(resetState)
        }

        // Step 2: Must be idle to start a new cycle.
        let current = try await currentState()
        guard current == .idle else {
            NSLog(
                "ImprovementCycleCoordinator: not idle (state=%@), skipping",
                current.rawValue
            )
            return
        }

        // Step 3: Check minimum data thresholds.
        let pendingEvents = try await store.pendingFeedbackEvents()
        let totalCount = pendingEvents.count
        let correctionCount = pendingEvents.filter { $0.signalType == "correction" }.count

        guard totalCount >= Self.minFeedbackEvents else {
            NSLog(
                "ImprovementCycleCoordinator: insufficient data (%d/%d events), skipping",
                totalCount, Self.minFeedbackEvents
            )
            return
        }
        guard correctionCount >= Self.minCorrectionEvents else {
            NSLog(
                "ImprovementCycleCoordinator: insufficient corrections (%d/%d), skipping",
                correctionCount, Self.minCorrectionEvents
            )
            return
        }

        // Step 4: COLLECTING — gather feedback events.
        do {
            try await transition(to: .collecting)
            let eventIDs = pendingEvents.compactMap(\.id)
            // Mark as consumed so they are not re-processed in the next cycle.
            try await store.markConsumed(ids: eventIDs)
            NSLog(
                "ImprovementCycleCoordinator: collected %d events (%d corrections)",
                totalCount, correctionCount
            )
        } catch {
            NSLog("ImprovementCycleCoordinator: collecting failed: %@", error.localizedDescription)
            try? await forceIdle(error: "collecting_failed: \(error.localizedDescription)")
            return
        }

        // Step 5: TRAINING — delegate to training skill.
        // (Actual training integration deferred to Phase 2.3+; this establishes the state flow.)
        do {
            try await transition(to: .training)
            NSLog("ImprovementCycleCoordinator: training phase (stub — no adapter produced yet)")
            // TODO: delegate to training-orchestrator skill
        } catch {
            NSLog("ImprovementCycleCoordinator: training failed: %@", error.localizedDescription)
            try? await forceIdle(error: "training_failed: \(error.localizedDescription)")
            return
        }

        // Step 6: EVALUATING — run eval benchmark.
        do {
            try await transition(to: .evaluating)
            NSLog("ImprovementCycleCoordinator: evaluating phase (stub)")
            // TODO: run FaeBenchmark --adapter comparison
        } catch {
            NSLog("ImprovementCycleCoordinator: evaluating failed: %@", error.localizedDescription)
            try? await forceIdle(error: "evaluating_failed: \(error.localizedDescription)")
            return
        }

        // Step 7: PROPOSING — generate proposal for user.
        do {
            try await transition(to: .proposing)
            NSLog("ImprovementCycleCoordinator: proposing phase (stub)")
            // TODO: generate morning proposal message
        } catch {
            NSLog("ImprovementCycleCoordinator: proposing failed: %@", error.localizedDescription)
            try? await forceIdle(error: "proposing_failed: \(error.localizedDescription)")
            return
        }

        // Step 8: DEPLOYING — apply adapter (or defer to user approval).
        do {
            try await transition(to: .deploying)
            NSLog("ImprovementCycleCoordinator: deploying phase (stub)")
            // TODO: apply adapter via SelfConfigTool or defer to user approval
        } catch {
            NSLog("ImprovementCycleCoordinator: deploying failed: %@", error.localizedDescription)
            try? await forceIdle(error: "deploying_failed: \(error.localizedDescription)")
            return
        }

        // Step 9: Return to IDLE (cycle complete).
        try await transition(to: .idle)
        NSLog("ImprovementCycleCoordinator: cycle complete")
    }

    // MARK: - Recovery

    /// Force the state machine back to idle, recording an error message.
    private func forceIdle(error message: String) async throws {
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.cycleState = CycleState.idle.rawValue
        state.trainingStartedAt = nil
        state.lastCycleError = message
        try await store.writeState(state)
    }
}
