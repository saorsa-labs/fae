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
    case metaOptimizing
    case training
    case evaluating
    case proposing
    case deploying

    /// Valid successor states (forward progress or error recovery to idle).
    var validSuccessors: Set<CycleState> {
        switch self {
        case .idle:            return [.collecting]
        case .collecting:      return [.metaOptimizing, .idle]
        case .metaOptimizing:  return [.training, .idle]
        case .training:        return [.evaluating, .idle]
        case .evaluating:      return [.proposing, .idle]
        case .proposing:       return [.deploying, .idle]
        case .deploying:       return [.idle]
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

    /// Number of user-approved cycles required before auto-deploy is earned.
    static let minCyclesForAutoDeploy = 5

    /// Run directive-based fast tuning every N completed cycles.
    static let directiveTuningInterval = 7

    // MARK: - Dependencies

    private let store: ImprovementStore

    /// The review gate that validates adapters before deployment.
    private let reviewGate: ExternalReviewGate

    /// The shadow evaluator for A/B comparing base vs adapter responses.
    private let shadowEvaluator: ShadowEvaluator

    /// Optional callback to apply an adapter path change via FaeCore.patchConfig.
    ///
    /// Set by FaeCore after wiring. Receives the new adapter path (nil = unload).
    /// Left nil in tests unless specific patcher behaviour is needed.
    var adapterPatchCallback: ((String?) -> Void)?

    /// Closure to read the current directive text. Returns `nil` if no directive set.
    /// Injected to decouple from the file system.
    var directiveReader: (() throws -> String?)?

    /// Closure to write a new directive text.
    /// Injected to decouple from the file system.
    var directiveWriter: ((_ text: String) throws -> Void)?

    /// Training bridge for calling mlx-tune scripts (export, train, poll, evaluate).
    ///
    /// Set by FaeScheduler before running cycles. When nil, the training step
    /// is skipped gracefully (pre-Phase 2.3 behaviour).
    private var trainingBridge: TrainingBridge?

    /// Meta-optimizer for hill-climbing on directive and config knobs.
    ///
    /// Set by FaeScheduler during wiring. When nil, the meta-optimization step
    /// is skipped and the cycle proceeds directly to training.
    private var metaOptimizer: MetaOptimizer?

    /// The most recent meta-optimization narrative for the morning briefing.
    /// Set after each meta-optimization run, cleared when consumed by the briefing.
    private(set) var pendingMetaOptNarrative: String?

    /// Minimum SFT examples required before training proceeds.
    static let minSFTExamples = 10

    // MARK: - Init

    /// Create a coordinator backed by the given improvement store.
    ///
    /// - Parameters:
    ///   - store: The `ImprovementStore` that persists cycle state and feedback data.
    ///   - reviewGate: The `ExternalReviewGate` used to validate adapters. Defaults to a new instance.
    ///   - shadowEvaluator: The `ShadowEvaluator` for A/B comparison. Defaults to a new instance.
    init(
        store: ImprovementStore,
        reviewGate: ExternalReviewGate = ExternalReviewGate(),
        shadowEvaluator: ShadowEvaluator? = nil
    ) {
        self.store = store
        self.reviewGate = reviewGate
        self.shadowEvaluator = shadowEvaluator ?? ShadowEvaluator(store: store)
    }

    /// Set the adapter patch callback. Called by FaeCore after wiring.
    func setAdapterPatchCallback(_ callback: @escaping (String?) -> Void) {
        adapterPatchCallback = callback
    }

    /// Set the directive reader closure. Called by FaeCore or tests.
    func setDirectiveReader(_ reader: @escaping () throws -> String?) {
        directiveReader = reader
    }

    /// Set the directive writer closure. Called by FaeCore or tests.
    func setDirectiveWriter(_ writer: @escaping (_ text: String) throws -> Void) {
        directiveWriter = writer
    }

    /// Set the training bridge. Called by FaeScheduler after wiring.
    func setTrainingBridge(_ bridge: TrainingBridge) {
        trainingBridge = bridge
    }

    /// Set the meta-optimizer. Called by FaeScheduler after wiring.
    ///
    /// The optimizer should have its dependencies (directive reader/writer,
    /// config reader/writer, training bridge, skill manager) already configured.
    func setMetaOptimizer(_ optimizer: MetaOptimizer) {
        metaOptimizer = optimizer
    }

    /// Consume the pending meta-optimization narrative for the morning briefing.
    ///
    /// Returns the narrative string and clears it so it's only delivered once.
    func consumeMetaOptNarrative() -> String? {
        let narrative = pendingMetaOptNarrative
        pendingMetaOptNarrative = nil
        return narrative
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

    // MARK: - Directive Tuning

    /// Whether the next cycle should be a directive-tuning cycle instead of adapter training.
    ///
    /// Returns `true` every `directiveTuningInterval`th completed cycle.
    func isDirectiveTuningCycle() async throws -> Bool {
        let storeState: ImprovementState
        do {
            storeState = try await store.readState()
        } catch {
            return false
        }
        guard storeState.completedCycles > 0 else { return false }
        return storeState.completedCycles % Self.directiveTuningInterval == 0
    }

    /// Run the directive-tuning sub-cycle: detect patterns and apply amendments.
    ///
    /// - Parameter events: The collected feedback events for this cycle.
    /// - Returns: `true` if an amendment was applied, `false` otherwise.
    private func runDirectiveTuning(events: [FeedbackEvent]) async throws -> Bool {
        let patterns = DirectiveTuner.detectPatterns(events: events)
        guard let amendment = DirectiveTuner.generateAmendment(patterns: patterns) else {
            NSLog("ImprovementCycleCoordinator: directive tuning — no strong patterns found")
            return false
        }

        let currentDirective = try? directiveReader?()
        let updated = DirectiveTuner.applyAmendment(
            amendment: amendment,
            currentDirective: currentDirective
        )

        // Store previous directive for rollback.
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.previousDirective = currentDirective
        try await store.writeState(state)

        try directiveWriter?(updated)
        NSLog("ImprovementCycleCoordinator: directive tuning — amendment applied (%d patterns)", patterns.count)
        return true
    }

    /// Roll back the directive to the version before the last tuning amendment.
    ///
    /// Reads `previousDirective` from the improvement state and writes it back to the directive.
    /// Clears `previousDirective` after rollback.
    ///
    /// - Throws: If the store is unavailable or directive writing fails.
    func rollbackDirective() async throws {
        try await store.ensureStateRow()
        var state = try await store.readState()
        let previous = state.previousDirective
        try directiveWriter?(previous ?? "")
        state.previousDirective = nil
        try await store.writeState(state)
        NSLog("ImprovementCycleCoordinator: directive rolled back")
    }

    // MARK: - Shadow Evaluation

    /// Whether the current cycle should run shadow evaluation (alternating nights).
    ///
    /// Odd-numbered completed cycles run shadow eval; even-numbered run training.
    /// Directive tuning (every 7th) takes priority over this alternation.
    func isShadowEvalNight() async throws -> Bool {
        let storeState: ImprovementState
        do {
            storeState = try await store.readState()
        } catch {
            return false
        }
        guard storeState.completedCycles > 0 else { return false }
        // Directive tuning takes priority.
        if storeState.completedCycles % Self.directiveTuningInterval == 0 { return false }
        return storeState.completedCycles % 2 == 1
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
        // Note: correction count is checked later to decide whether to run training.
        // Meta-optimization can proceed with any feedback signals (re-asks, abandonments, etc.).

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

        // Step 4b: META-OPTIMIZATION — hill-climb on directive + config knobs.
        // Subsumes the legacy directive-tuning cycle. Runs every cycle (not just every 7th).
        var metaOptSummary: MetaOptSummary?
        do {
            try await transition(to: .metaOptimizing)
            if let optimizer = metaOptimizer {
                NSLog("ImprovementCycleCoordinator: starting meta-optimization phase")
                let summary = try await optimizer.run(events: pendingEvents)
                metaOptSummary = summary
                NSLog(
                    "ImprovementCycleCoordinator: meta-optimization complete — tested %d, kept %d (%.0fs)",
                    summary.hypothesesTested, summary.keptCount, summary.wallClockSeconds
                )
                // Generate human-readable narrative for morning briefing.
                pendingMetaOptNarrative = MetaOptNarrator.narrate(summary)
            } else if try await isDirectiveTuningCycle() {
                // Fallback: legacy directive tuning when MetaOptimizer is not wired.
                NSLog("ImprovementCycleCoordinator: directive tuning cycle (legacy, every %d cycles)", Self.directiveTuningInterval)
                let applied = try await runDirectiveTuning(events: pendingEvents)
                NSLog(
                    "ImprovementCycleCoordinator: directive tuning %@",
                    applied ? "applied" : "skipped (no patterns)"
                )
            }
        } catch {
            NSLog("ImprovementCycleCoordinator: meta-optimization failed: %@", error.localizedDescription)
            // Non-fatal: proceed to training regardless.
        }

        // Step 4c: Check if we should skip training (e.g., insufficient correction data).
        // Meta-optimization may be sufficient for this cycle.
        let skipTraining = correctionCount < Self.minCorrectionEvents
        if skipTraining {
            if let summary = metaOptSummary, summary.keptCount > 0 {
                // Meta-opt made changes — count as a completed cycle.
                var state = try await store.readState()
                state.completedCycles += 1
                state.lastCycleAt = ISO8601DateFormatter().string(from: Date())
                try await store.writeState(state)
                NSLog("ImprovementCycleCoordinator: meta-opt only cycle (insufficient corrections for training)")
            }
            try await transition(to: .idle)
            return
        }

        // Step 5: TRAINING — export data, launch mlx-tune, poll until complete.
        var producedAdapterPath: String?
        do {
            try await transition(to: .training)

            guard let bridge = trainingBridge else {
                NSLog("ImprovementCycleCoordinator: training bridge not available, skipping training")
                // Graceful degradation: proceed to evaluation with no adapter.
                producedAdapterPath = nil
                // Fall through to evaluation step.
                try await transition(to: .evaluating)
                // Jump past the training block.
                throw ImprovementCycleError.storeNotAvailable // caught below, triggers eval-only path
            }

            // 5a. Export training data from fae.db.
            NSLog("ImprovementCycleCoordinator: exporting training data")
            let exportResult = try await bridge.exportTrainingData()
            NSLog(
                "ImprovementCycleCoordinator: exported %d SFT examples, %d DPO pairs",
                exportResult.sftExamples, exportResult.dpoPairs
            )

            guard exportResult.sftExamples >= Self.minSFTExamples else {
                NSLog(
                    "ImprovementCycleCoordinator: insufficient SFT examples (%d/%d), skipping training",
                    exportResult.sftExamples, Self.minSFTExamples
                )
                try? await forceIdle(error: "insufficient_sft_data")
                return
            }

            // 5b. Choose training mode based on available data.
            let mode: TrainingMode = exportResult.dpoPairs >= 5 ? .dpo : .sft
            NSLog("ImprovementCycleCoordinator: launching %@ training", mode.rawValue)

            let launchResult = try await bridge.launchTraining(mode: mode)
            NSLog(
                "ImprovementCycleCoordinator: training started (pid=%d, model=%@, adapter=%@)",
                launchResult.pid, launchResult.modelId, launchResult.adapterPath
            )

            // 5c. Poll until the detached training worker completes.
            let adapterPath = try await bridge.pollUntilComplete()
            producedAdapterPath = adapterPath
            NSLog("ImprovementCycleCoordinator: training complete — adapter at %@", adapterPath)

            // 5d. Store adapter path in improvement state.
            try await store.ensureStateRow()
            var state = try await store.readState()
            state.currentAdapterPath = adapterPath
            try await store.writeState(state)
        } catch let error as ImprovementCycleError {
            // Rethrown from the bridge-nil path above — not a real failure.
            if case .storeNotAvailable = error {
                NSLog("ImprovementCycleCoordinator: no training bridge — proceeding with eval-only path")
            } else {
                NSLog("ImprovementCycleCoordinator: training failed: %@", error.localizedDescription)
                try? await forceIdle(error: "training_failed: \(error.localizedDescription)")
                return
            }
        } catch {
            NSLog("ImprovementCycleCoordinator: training failed: %@", error.localizedDescription)
            try? await forceIdle(error: "training_failed: \(error.localizedDescription)")
            return
        }

        // Step 6: EVALUATING — run eval benchmark + external review gate.
        do {
            // Transition may already have happened in the bridge-nil path above.
            let evalState = try await currentState()
            if evalState != .evaluating {
                try await transition(to: .evaluating)
            }
            NSLog("ImprovementCycleCoordinator: evaluating phase")

            // Build EvalDelta: prefer FaeBenchmark (real accuracy), fall back to loss-based proxy.
            // When no adapter was produced, deltas are zero (neutral — no regression, no gain).
            let evalDelta: EvalDelta
            if let bridge = trainingBridge, let adapterPath = producedAdapterPath {
                // Try real benchmark evaluation first (if FaeBenchmark binary is configured).
                if await bridge.isBenchmarkAvailable {
                    do {
                        NSLog("ImprovementCycleCoordinator: running FaeBenchmark baseline")
                        let baseline = try await bridge.runBenchmark(adapterPath: nil)
                        // Store baseline for historical comparison.
                        let pendingCount = (try? await store.pendingFeedbackEvents().count) ?? 0
                        try? await store.insertBaseline(baseline.toBaseline(feedbackEventCount: pendingCount))

                        NSLog("ImprovementCycleCoordinator: running FaeBenchmark with adapter")
                        let adapterResult = try await bridge.runBenchmark(adapterPath: adapterPath)

                        evalDelta = adapterResult.delta(from: baseline)
                        NSLog(
                            "ImprovementCycleCoordinator: benchmark delta — tools=%.1f%% fae=%.1f%% fit=%.1f%% ser=%.1f%%",
                            evalDelta.toolCallingDelta ?? 0, evalDelta.faeCapabilityDelta ?? 0,
                            evalDelta.assistantFitDelta ?? 0, evalDelta.serializationDelta ?? 0
                        )
                    } catch {
                        NSLog("ImprovementCycleCoordinator: benchmark failed (%@), falling back to loss-based eval", error.localizedDescription)
                        evalDelta = try await lossBasedEvalDelta(bridge: bridge, adapterPath: adapterPath)
                    }
                } else {
                    // No benchmark binary — use loss-based proxy.
                    evalDelta = try await lossBasedEvalDelta(bridge: bridge, adapterPath: adapterPath)
                }
            } else {
                evalDelta = EvalDelta(
                    toolCallingDelta: 0.0, faeCapabilityDelta: 0.0,
                    assistantFitDelta: 0.0, serializationDelta: 0.0, throughputDelta: nil
                )
            }

            // Run external review gate.
            let stateForReview = try await store.readState()
            let reviewResult: ReviewResult
            do {
                reviewResult = try await reviewGate.review(
                    evalDelta: evalDelta,
                    currentDeferralCount: stateForReview.deferralCount
                )
            } catch let error as ExternalReviewGateError {
                if case .maxDeferralsReached = error {
                    NSLog("ImprovementCycleCoordinator: max deferrals reached, aborting cycle")
                    try await store.resetDeferrals()
                    try? await forceIdle(error: "max_deferrals_reached")
                    return
                }
                throw error
            }

            switch reviewResult.verdict {
            case .pass:
                NSLog("ImprovementCycleCoordinator: review PASS")
                try await store.resetDeferrals()

                // Run shadow evaluation if this is a shadow eval night.
                if try await isShadowEvalNight() {
                    NSLog("ImprovementCycleCoordinator: running shadow evaluation")
                    do {
                        let evalResult = try await shadowEvaluator.runEvaluation(ignoreWindow: true)
                        if !evalResult.promotionGatePassed {
                            NSLog(
                                "ImprovementCycleCoordinator: shadow eval gate FAILED (%.1f%% win rate)",
                                evalResult.adapterWinRate * 100
                            )
                            try? await forceIdle(error: "shadow_eval_gate_failed")
                            return
                        }
                        NSLog(
                            "ImprovementCycleCoordinator: shadow eval gate PASSED (%.1f%% win rate)",
                            evalResult.adapterWinRate * 100
                        )
                    } catch let error as ShadowEvaluatorError {
                        switch error {
                        case .noEpisodesAvailable:
                            // Gracefully skip shadow eval on fresh installs.
                            NSLog("ImprovementCycleCoordinator: no shadow eval episodes, skipping")
                        case .responseGeneratorNotSet:
                            NSLog("ImprovementCycleCoordinator: shadow eval generator not set, skipping")
                        case .outsideOvernightWindow:
                            // Should not happen (ignoreWindow: true), but handle gracefully.
                            NSLog("ImprovementCycleCoordinator: outside overnight window, skipping shadow eval")
                        }
                    }
                }

                NSLog("ImprovementCycleCoordinator: proceeding to deploy")
            case .concern:
                NSLog("ImprovementCycleCoordinator: review CONCERN — deferring cycle")
                let newCount = try await store.incrementDeferral()
                NSLog("ImprovementCycleCoordinator: deferral count now %d", newCount)
                try? await forceIdle(error: "review_concern_deferred")
                return
            case .fail:
                NSLog("ImprovementCycleCoordinator: review FAIL — aborting cycle")
                try await store.resetDeferrals()
                try? await forceIdle(error: "review_failed: \(reviewResult.summary)")
                return
            }
        } catch {
            NSLog("ImprovementCycleCoordinator: evaluating failed: %@", error.localizedDescription)
            try? await forceIdle(error: "evaluating_failed: \(error.localizedDescription)")
            return
        }

        // Step 7: PROPOSING or AUTO-DEPLOY — check earned autonomy.
        let storeStateForPropose = (try? await store.readState()) ?? ImprovementState(
            id: nil, cycleState: "proposing", lastCycleAt: nil,
            completedCycles: 0, userApprovedCycles: 0,
            currentAdapterPath: nil, previousAdapterPath: nil,
            trainingStartedAt: nil, lastCycleError: nil,
            deferralCount: 0,
            previousDirective: nil,
            metaOptKeptTotal: 0, metaOptTestedTotal: 0,
            metaOptLastRunAt: nil, metaOptConsecutiveNoImprovement: 0
        )
        let approved = storeStateForPropose.userApprovedCycles >= Self.minCyclesForAutoDeploy

        if approved {
            // Earned autonomy: skip the user-approval pause.
            NSLog(
                "ImprovementCycleCoordinator: earned auto-deploy (%d approved cycles)",
                storeStateForPropose.userApprovedCycles
            )
            do {
                // Must go evaluating → proposing → deploying (state machine rules).
                try await transition(to: .proposing)
                try await transition(to: .deploying)
                try await performDeploy(approved: true)
            } catch {
                NSLog("ImprovementCycleCoordinator: auto-deploy failed: %@", error.localizedDescription)
                try? await forceIdle(error: "auto_deploy_failed: \(error.localizedDescription)")
                return
            }
        } else {
            // Needs user approval — pause in PROPOSING state.
            do {
                try await transition(to: .proposing)
                NSLog("ImprovementCycleCoordinator: paused in proposing — awaiting user approval")
                // runCycle() returns here. approveDeployment() / rejectDeployment() resume it.
            } catch {
                NSLog("ImprovementCycleCoordinator: proposing failed: %@", error.localizedDescription)
                try? await forceIdle(error: "proposing_failed: \(error.localizedDescription)")
            }
            return
        }

        // Step 9: Return to IDLE (only reached via auto-deploy path).
        try await transition(to: .idle)
        NSLog("ImprovementCycleCoordinator: cycle complete (auto-deploy)")
    }

    // MARK: - User Approval API

    /// Approve the pending adapter deployment.
    ///
    /// Must be called while the coordinator is in `proposing` state. Transitions
    /// through `deploying` → `idle`, increments `userApprovedCycles`, and tracks
    /// the rollback path.
    ///
    /// - Throws: `ImprovementCycleError.invalidTransition` if not in `proposing` state.
    func approveDeployment() async throws {
        let current = try await currentState()
        guard current == .proposing else {
            throw ImprovementCycleError.invalidTransition(from: current, to: .deploying)
        }
        try await transition(to: .deploying)
        try await performDeploy(approved: true)
        try await transition(to: .idle)
        NSLog("ImprovementCycleCoordinator: deployment approved — cycle complete")
    }

    /// Reject the pending adapter deployment.
    ///
    /// Must be called while the coordinator is in `proposing` state. Transitions
    /// directly to `idle` without deploying. The adapter candidate is discarded.
    ///
    /// - Throws: `ImprovementCycleError.invalidTransition` if not in `proposing` state.
    func rejectDeployment() async throws {
        let current = try await currentState()
        guard current == .proposing else {
            throw ImprovementCycleError.invalidTransition(from: current, to: .idle)
        }
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.cycleState = CycleState.idle.rawValue
        state.completedCycles += 1
        state.lastCycleAt = ISO8601DateFormatter().string(from: Date())
        state.trainingStartedAt = nil
        try await store.writeState(state)
        NSLog("ImprovementCycleCoordinator: deployment rejected — returned to idle")
    }

    /// Roll back the current adapter to the previous one.
    ///
    /// Swaps `currentAdapterPath` and `previousAdapterPath` in the store.
    /// Emits `adapter_rolled_back` via the `adapterPatchCallback`.
    ///
    /// - Throws: `ImprovementCycleError.storeNotAvailable` if store is unavailable.
    func rollback() async throws {
        try await store.ensureStateRow()
        var state = try await store.readState()
        let previous = state.previousAdapterPath
        state.previousAdapterPath = state.currentAdapterPath
        state.currentAdapterPath = previous
        try await store.writeState(state)
        adapterPatchCallback?(previous)
        NSLog(
            "ImprovementCycleCoordinator: rollback — adapter → %@",
            previous ?? "<base model>"
        )
    }

    // MARK: - Internal Deploy Helper

    /// Perform the actual adapter deployment: track rollback path, increment approved counter,
    /// and invoke the adapter patch callback.
    ///
    /// Note: `completedCycles` and `lastCycleAt` are managed by `transition(to: .idle)`;
    /// this method only handles the deployment-specific bookkeeping.
    private func performDeploy(approved: Bool) async throws {
        guard approved else { return }
        try await store.ensureStateRow()
        var state = try await store.readState()

        // Track rollback path: current → previous before updating.
        // currentAdapterPath was set during the training step with the real adapter directory.
        state.previousAdapterPath = state.currentAdapterPath
        state.userApprovedCycles += 1
        try await store.writeState(state)

        // Notify pipeline — nil until FaeCore wires it in.
        adapterPatchCallback?(state.currentAdapterPath)
        NSLog(
            "ImprovementCycleCoordinator: adapter deployed (userApprovedCycles=%d)",
            state.userApprovedCycles
        )
    }

    // MARK: - Loss-Based Eval Fallback

    /// Compute EvalDelta from the training loss-based proxy score.
    ///
    /// Used when FaeBenchmark is not available. Maps the 0.0–1.0 score
    /// from evaluate.py to a uniform delta across all dimensions.
    private func lossBasedEvalDelta(bridge: TrainingBridge, adapterPath: String) async throws -> EvalDelta {
        do {
            let evalResult = try await bridge.evaluateAdapter(adapterPath: adapterPath)
            let delta = (evalResult.score - 0.5) * 100.0
            NSLog(
                "ImprovementCycleCoordinator: loss-based eval score=%.2f loss=%.2f rec=%@ delta=%.1f",
                evalResult.score, evalResult.finalLoss, evalResult.recommendation, delta
            )
            return EvalDelta(
                toolCallingDelta: delta,
                faeCapabilityDelta: delta,
                assistantFitDelta: delta,
                serializationDelta: delta,
                throughputDelta: nil
            )
        } catch {
            NSLog("ImprovementCycleCoordinator: loss-based eval failed: %@ — using zero delta", error.localizedDescription)
            return EvalDelta(
                toolCallingDelta: 0.0, faeCapabilityDelta: 0.0,
                assistantFitDelta: 0.0, serializationDelta: 0.0, throughputDelta: nil
            )
        }
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
