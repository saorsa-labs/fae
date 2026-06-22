import CryptoKit
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
    /// A deploy was attempted with no pending candidate to promote (P9/C4 W3).
    case noPendingCandidate
    /// A deploy was attempted with no verifying gate receipt for the candidate (P9/C4 W4).
    /// Carries a short reason for the audit trail.
    case gateReceiptRejected(String)
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

    /// When set, the training step targets the **llama.cpp daemon** brain: it
    /// trains a portable PEFT adapter and converts it to a GGUF the daemon loads
    /// via `engine.reload` (P3/C3), instead of producing an mlx-tune
    /// `.safetensors` adapter the daemon cannot consume. `nil` keeps the legacy
    /// MLX path. Carries the base model the daemon serves so the GGUF tensor
    /// layout matches at reload.
    private var daemonTrainingBaseModel: String?

    /// Interim evaluation seam (P9/C4). When set, supplies the **measured**
    /// `EvalDelta` for the evaluating phase in place of the FaeBenchmark bridge.
    /// W7's `AdapterEvaluator` becomes the production implementation behind this
    /// seam; until then it lets the gate + verdict handling be exercised with a
    /// real measured delta without a FaeBenchmark binary. `nil` ⇒ fall through to
    /// the bridge benchmark, else `.unmeasured` (fail-closed).
    private var injectedMeasuredDelta: EvalDelta?

    /// Test override of the gate-receipt HMAC key (P9/C4 W4). When set, the deploy gate
    /// verifies receipts with this key instead of the per-install Keychain key, so unit
    /// tests can mint + verify receipts without Keychain access. `nil` in production.
    private var injectedGateKey: SymmetricKey?

    /// The adapter kinds for which a real evaluator is available (P9/C4 W6). The training
    /// step refuses to train a lane whose kind is absent here — without an evaluator the
    /// candidate could never pass the deploy gate (W4), so training would only burn a run.
    /// Populated by W7 when the `AdapterEvaluator`s are wired; empty until then (so the loop
    /// refuses to train, the intended conservative state).
    private var availableEvaluatorKinds: Set<AdapterKind> = []

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

    /// Target the llama.cpp daemon brain for training (P3/C3): the training step
    /// trains a PEFT adapter and converts it to a daemon-loadable GGUF against
    /// `baseModel`. Called by FaeScheduler when the daemon LLM lane is active.
    /// Passing `nil` reverts to the legacy mlx-tune (`.safetensors`) path.
    func setDaemonTrainingBaseModel(_ baseModel: String?) {
        daemonTrainingBaseModel = baseModel
    }

    /// Inject a measured `EvalDelta` for the evaluating phase (P9/C4 interim seam;
    /// see `injectedMeasuredDelta`). Used by tests until W7 wires the real
    /// `AdapterEvaluator`. Passing `nil` clears it (fall through to the bridge).
    func setInjectedMeasuredDelta(_ delta: EvalDelta?) {
        injectedMeasuredDelta = delta
    }

    /// Inject the gate-receipt HMAC key for tests (P9/C4 W4; see `injectedGateKey`).
    func setInjectedGateKey(_ key: SymmetricKey?) {
        injectedGateKey = key
    }

    /// Declare which adapter kinds have a real evaluator available (P9/C4 W6). Called by
    /// FaeScheduler/W7 when the evaluators are wired. Empty ⇒ refuse to train any lane.
    func setAvailableEvaluatorKinds(_ kinds: Set<AdapterKind>) {
        availableEvaluatorKinds = kinds
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
            // P9/C4 (W3): discard any candidate from the wedged cycle. The deployed
            // `currentAdapterPath` is untouched (training only writes pending), so a
            // crash/stuck mid-cycle can never leave an un-evaluated candidate live.
            resetState.pendingAdapterPath = nil
            resetState.pendingAdapterKind = nil
            resetState.pendingCycleId = nil
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

        // P9/C4 (W3): a fresh cycle starts from idle, which must never carry a stale
        // pending candidate (invariant: idle ⇒ pendingAdapterPath == nil). Discard any
        // leftover from a prior interrupted cycle BEFORE proceeding, so every early
        // exit below (insufficient data, meta-opt-only) preserves the invariant.
        let startState = try await store.readState()
        if startState.pendingAdapterPath != nil || startState.pendingAdapterKind != nil {
            var cleared = startState
            cleared.pendingAdapterPath = nil
            cleared.pendingAdapterKind = nil
            cleared.pendingCycleId = nil
            try await store.writeState(cleared)
            NSLog("ImprovementCycleCoordinator: cleared stale pending candidate at cycle start")
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

            // P9/C4 (W6, F14): refuse to train a lane that has no available evaluator —
            // without one the candidate could never pass the deploy gate (W4), so training
            // would only burn a run. (Q4: refuse-to-train, not train-then-block.) The lane
            // is the daemon/gguf lane when a daemon base model is set, else the mlx-dir lane.
            // availableEvaluatorKinds is populated by W7; empty ⇒ refuse (conservative).
            let laneKind: AdapterKind = daemonTrainingBaseModel != nil ? .gguf : .mlxDir
            guard availableEvaluatorKinds.contains(laneKind) else {
                NSLog(
                    "ImprovementCycleCoordinator: no evaluator for %@ lane — refusing to train (lane_no_evaluator)",
                    laneKind.rawValue
                )
                // Surface the refusal in the morning briefing (companion language), in
                // addition to the audited lastCycleError that health reporting reads.
                let refuseNote = "I held off on training this time — I don't have an evaluator for " +
                    "the \(laneKind.rawValue) model lane yet, so I couldn't safely check a new version."
                pendingMetaOptNarrative = [pendingMetaOptNarrative, refuseNote]
                    .compactMap { $0 }.joined(separator: " ")
                try? await forceIdle(error: "lane_no_evaluator:\(laneKind.rawValue)")
                return
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

            // 5b–5c. Produce a deployable adapter via the selected TrainingBackend
            // (P9/C1 seam). Daemon lane → PEFT adapter converted to a GGUF the
            // llama.cpp daemon loads (P3/C3); otherwise the legacy detached
            // mlx-tune dir lane (`.safetensors`, MLX-only). The candidate's `kind`
            // drives the lane-appropriate eval gate + deploy path (P9/C4).
            let backend: TrainingBackend
            if let daemonBase = daemonTrainingBaseModel {
                backend = PeftDaemonBackend(bridge: bridge, baseModel: daemonBase)
            } else {
                backend = MlxTuneBackend(bridge: bridge)
            }
            NSLog("ImprovementCycleCoordinator: training via %@ backend", backend.id)
            let candidate = try await backend.trainAdapter(export: exportResult)
            let adapterPath = candidate.path
            producedAdapterPath = adapterPath
            NSLog(
                "ImprovementCycleCoordinator: training complete — adapter at %@ (kind=%@)",
                adapterPath, candidate.kind.rawValue)

            // 5d. Store the candidate as the PENDING adapter (P9/C4 W3).
            // Training NEVER writes the deployed `currentAdapterPath`; the candidate
            // lives in `pendingAdapterPath` until a gated deploy promotes it. This is
            // what keeps an un-evaluated candidate from ever polluting the live
            // adapter — on the block/reject/abort paths, or after a crash mid-cycle.
            try await store.ensureStateRow()
            var state = try await store.readState()
            state.pendingAdapterPath = adapterPath
            state.pendingAdapterKind = candidate.kind.rawValue
            // P9/C4 (W4): bind this candidate to a cycle id. The evaluator (W7) mints a
            // gate receipt keyed by this id; the deploy gate requires that receipt.
            state.pendingCycleId = UUID().uuidString
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
        } catch let error as TrainingBackendError {
            // Preserve the pre-P9 diagnostic for the daemon-lane missing dataset
            // case (surfaced via health reporting as `lastCycleError`).
            if case .missingDataset("sft_export") = error {
                NSLog("ImprovementCycleCoordinator: no sft_export path in export result")
                try? await forceIdle(error: "missing_sft_export")
            } else {
                NSLog("ImprovementCycleCoordinator: training failed: %@", error.description)
                try? await forceIdle(error: "training_failed: \(error.description)")
            }
            return
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

            // P9/C4 (W1): the gate certifies ONLY real, measured deltas. A
            // non-measurement (no FaeBenchmark evaluator configured, or a
            // benchmark failure) is fail-closed — it yields `.unmeasured`, never a
            // synthetic zero-delta "pass". The loss-based proxy is advisory only
            // and never gates (it cannot populate measured dimensions).
            let evalDelta: EvalDelta
            if let injected = injectedMeasuredDelta {
                NSLog("ImprovementCycleCoordinator: using injected measured eval delta (P9/C4 interim seam)")
                evalDelta = injected
            } else if let bridge = trainingBridge, let adapterPath = producedAdapterPath,
               await bridge.isBenchmarkAvailable {
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
                    // Loss-proxy is advisory-only (logged, never gates). Eval is unmeasured.
                    if let advisory = try? await lossBasedEvalDelta(bridge: bridge, adapterPath: adapterPath) {
                        NSLog(
                            "ImprovementCycleCoordinator: benchmark failed (%@); loss-proxy advisory only (does NOT gate): tools=%.1f%%",
                            error.localizedDescription, advisory.toolCallingDelta ?? 0
                        )
                    } else {
                        NSLog("ImprovementCycleCoordinator: benchmark failed (%@); eval unmeasured", error.localizedDescription)
                    }
                    evalDelta = .unmeasured
                }
            } else {
                NSLog("ImprovementCycleCoordinator: no FaeBenchmark evaluator available — eval unmeasured (fail-closed)")
                evalDelta = .unmeasured
            }

            // P9/C4 (W1, F1/F2/F16): fail-closed gate. A candidate with no COMPLETE
            // measurement (any correctness dimension unmeasured, or nothing
            // improved) is blocked BEFORE the external review gate — the external
            // providers must never get a chance to PASS an un-evaluated candidate.
            // `failClosed` discards the pending candidate; the deployed
            // `currentAdapterPath` is untouched (W3). (The audited `candidate_blocked`
            // security event + the receipt deploy gate land in W4.)
            if AdapterGate.decide(evalDelta.measuredDeltas) == .blockedNoMeasurement {
                NSLog("ImprovementCycleCoordinator: candidate_blocked — no measured improvement; fail-closed (no review, no deploy)")
                await failClosed(reason: "candidate_blocked: no_measured_improvement")
                return
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
                    await failClosed(reason: "max_deferrals_reached")
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
                    // P9/C4 (W5, F5): shadow eval A/Bs the DEPLOYED adapter vs base — never
                    // the pending candidate. Pin it to the deployed `currentAdapterPath`
                    // explicitly so the state split can never re-point it at pending.
                    let deployedForShadow = (try? await store.readState())?.currentAdapterPath
                    await shadowEvaluator.setCurrentAdapterPath(deployedForShadow)
                    do {
                        let evalResult = try await shadowEvaluator.runEvaluation(ignoreWindow: true)
                        if !evalResult.promotionGatePassed {
                            NSLog(
                                "ImprovementCycleCoordinator: shadow eval gate FAILED (%.1f%% win rate)",
                                evalResult.adapterWinRate * 100
                            )
                            await failClosed(reason: "shadow_eval_gate_failed")
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
                await failClosed(reason: "review_concern_deferred")
                return
            case .fail:
                NSLog("ImprovementCycleCoordinator: review FAIL — aborting cycle")
                try await store.resetDeferrals()
                await failClosed(reason: "review_failed: \(reviewResult.summary)")
                return
            }
        } catch {
            NSLog("ImprovementCycleCoordinator: evaluating failed: %@", error.localizedDescription)
            await failClosed(reason: "evaluating_failed: \(error.localizedDescription)")
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
                await failClosed(reason: "auto_deploy_failed: \(error.localizedDescription)")
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
                await failClosed(reason: "proposing_failed: \(error.localizedDescription)")
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
        // P9/C4 (W3): validate the candidate BEFORE moving to .deploying, so a
        // missing candidate leaves the machine in .proposing (recoverable by a later
        // approve/reject) rather than stuck in .deploying.
        guard try await store.readState().pendingAdapterPath != nil else {
            throw ImprovementCycleError.noPendingCandidate
        }
        try await transition(to: .deploying)
        do {
            try await performDeploy(approved: true)
        } catch {
            // P9/C4 (W4): the deploy was refused (e.g. no/invalid gate receipt). Fail
            // closed — discard the candidate and return to idle, then surface the error
            // to the caller (UI) rather than leaving the machine stuck in .deploying.
            await failClosed(reason: "deploy_rejected: \(error)")
            throw error
        }
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
        // P9/C4 (W3): discard the candidate. `currentAdapterPath` (the deployed
        // adapter) is untouched — training only ever wrote `pendingAdapterPath` — so
        // a rejected candidate simply never deploys.
        state.pendingAdapterPath = nil
        state.pendingAdapterKind = nil
        state.pendingCycleId = nil
        state.cycleState = CycleState.idle.rawValue
        state.completedCycles += 1
        state.lastCycleAt = ISO8601DateFormatter().string(from: Date())
        state.trainingStartedAt = nil
        try await store.writeState(state)
        NSLog("ImprovementCycleCoordinator: deployment rejected — discarded pending candidate, returned to idle")
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

        // P9/C4 (W3): promote the gated candidate. The candidate lives in
        // `pendingAdapterPath`; deploy is the ONLY place `currentAdapterPath` is
        // written. current → previous (the real rollback target), pending → current,
        // then clear pending. This also fixes the prior rollback-lineage bug where
        // `previousAdapterPath` was set to the candidate itself.
        guard let candidate = state.pendingAdapterPath else {
            // Fail-closed: a deploy with no gated candidate is an error, not a silent
            // no-op — surfacing it prevents a caller from treating it as a success.
            NSLog("ImprovementCycleCoordinator: performDeploy called with no pending candidate — refusing")
            throw ImprovementCycleError.noPendingCandidate
        }

        // P9/C4 (W4): REQUIRE a verifying, unconsumed gate receipt for THIS exact
        // candidate before promoting it. No receipt ⇒ no deploy (fail-closed). Receipts
        // are minted by the evaluator (W7); without an evaluator the loop blocks here,
        // which is the intended conservative behaviour (no auto-deploy until a real eval
        // gate exists).
        let receipt = try await requireGateReceipt(for: state, candidate: candidate)

        // Receipt ↔ candidate consistency: the receipt's kind must match what the training
        // step recorded for this pending candidate.
        if let pendingKind = state.pendingAdapterKind, receipt.kind.rawValue != pendingKind {
            throw ImprovementCycleError.gateReceiptRejected(
                "receipt_kind_mismatch: receipt=\(receipt.kind.rawValue) pending=\(pendingKind)"
            )
        }
        // Kind ↔ engine consistency: the daemon lane loads a GGUF; the MLX lane loads an
        // adapter directory. A mismatch means the candidate cannot load on the active
        // engine — block rather than ship a dead adapter.
        let expectedKind: AdapterKind = daemonTrainingBaseModel != nil ? .gguf : .mlxDir
        guard receipt.kind == expectedKind else {
            throw ImprovementCycleError.gateReceiptRejected(
                "kind_engine_mismatch: receipt=\(receipt.kind.rawValue) expected=\(expectedKind.rawValue)"
            )
        }

        guard let cycleId = state.pendingCycleId else {
            throw ImprovementCycleError.gateReceiptRejected("no_pending_cycle_id")
        }
        state.previousAdapterPath = state.currentAdapterPath
        state.currentAdapterPath = candidate
        state.pendingAdapterPath = nil
        state.pendingAdapterKind = nil
        state.pendingCycleId = nil
        state.userApprovedCycles += 1
        // P9/C4 (W4): promote + consume ATOMICALLY. The consume requires a stored,
        // unconsumed receipt (UPDATE … WHERE consumed_at IS NULL, exactly one row) or the
        // whole transaction rolls back — so the deploy can never commit without spending a
        // real receipt, and the receipt can never be double-spent.
        try await store.promoteAndConsumeReceipt(
            state: state, cycleId: cycleId, at: ISO8601DateFormatter().string(from: Date())
        )

        // Notify pipeline — nil until FaeCore wires it in.
        adapterPatchCallback?(state.currentAdapterPath)
        NSLog(
            "ImprovementCycleCoordinator: adapter deployed (userApprovedCycles=%d)",
            state.userApprovedCycles
        )
    }

    /// Fetch + verify the gate receipt that authorizes deploying `candidate` (P9/C4 W4).
    /// Fail-closed: throws `gateReceiptRejected` if there is no bound cycle id, no receipt,
    /// the receipt is already consumed, or it fails cryptographic/digest verification.
    private func requireGateReceipt(
        for state: ImprovementState, candidate: String
    ) async throws -> GateReceipt {
        guard let cycleId = state.pendingCycleId else {
            throw ImprovementCycleError.gateReceiptRejected("no_pending_cycle_id")
        }
        guard let receipt = try await store.gateReceipt(forCycleId: cycleId) else {
            throw ImprovementCycleError.gateReceiptRejected("no_receipt")
        }
        if try await store.isGateReceiptConsumed(cycleId: cycleId) {
            throw ImprovementCycleError.gateReceiptRejected("receipt_already_consumed")
        }
        do {
            if let key = injectedGateKey {
                try GateReceiptVerifier.verify(receipt, expectedCandidatePath: candidate, using: key)
            } else {
                try GateReceiptVerifier.verify(receipt, expectedCandidatePath: candidate)
            }
        } catch {
            throw ImprovementCycleError.gateReceiptRejected("verify_failed: \(error)")
        }
        return receipt
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
        // P9/C4 (W3): returning to idle always discards any pending candidate, so an
        // idle state can never coexist with a stale candidate that a later path
        // might deploy. (Invariant: idle ⇒ pendingAdapterPath == nil.)
        state.pendingAdapterPath = nil
        state.pendingAdapterKind = nil
        state.pendingCycleId = nil
        try await store.writeState(state)
    }

    /// Persist a terminal "blocked / not deployed" outcome for this cycle (P9/C4 W3).
    ///
    /// Discards the un-deployed candidate by clearing `pendingAdapterPath`. Because
    /// the training step writes the candidate ONLY to the pending pointer (never the
    /// deployed `currentAdapterPath`), clearing it is sufficient — no path or crash
    /// can leave an un-evaluated candidate advertised as the live adapter. Preserves
    /// all other state fields (e.g. a just-incremented/just-reset `deferralCount`).
    private func failClosed(reason: String) async {
        do {
            try await store.ensureStateRow()
            var state = try await store.readState()
            state.pendingAdapterPath = nil
            state.pendingAdapterKind = nil
            state.pendingCycleId = nil
            state.cycleState = CycleState.idle.rawValue
            state.trainingStartedAt = nil
            state.lastCycleError = reason
            try await store.writeState(state)
        } catch {
            NSLog("ImprovementCycleCoordinator: failClosed persist failed: %@", error.localizedDescription)
        }
    }

    /// P9/C4 (W5, F11): repair a stale non-idle state left by a crash or a pre-P9 upgrade.
    ///
    /// A `.proposing`/`.deploying` state whose pending candidate still has a STORED,
    /// unconsumed, verifying gate receipt is legitimately resumable (the user can still
    /// approve/reject it) and is kept. Any other non-idle state — an interrupted
    /// collecting/training/evaluating cycle, or a proposing/deploying state WITHOUT a valid
    /// receipt (incl. pre-P9 rows where the candidate was written to currentAdapterPath
    /// pre-eval) — is reset to idle, its pending candidate discarded, and the event audited.
    /// Fail-closed: an ungated in-flight candidate never survives a restart as deployable.
    func recoverStaleStateIfNeeded() async {
        do {
            try await store.ensureStateRow()
            let state = try await store.readState()
            guard let cycle = CycleState(rawValue: state.cycleState), cycle != .idle else { return }

            // Only a `.proposing` state is resumable after a restart — the user can still
            // approve/reject it. A `.deploying` state is NOT resumable (no path advances it),
            // so it falls through to a fail-closed reset. Resumable requires a stored,
            // unconsumed, verifying receipt for the pending candidate.
            if cycle == .proposing,
               let candidate = state.pendingAdapterPath,
               let cycleId = state.pendingCycleId,
               await hasResumableReceipt(cycleId: cycleId, candidate: candidate) {
                NSLog("ImprovementCycleCoordinator: recovered resumable proposing (valid receipt) — keeping")
                return
            }

            var repaired = state
            repaired.cycleState = CycleState.idle.rawValue
            repaired.trainingStartedAt = nil
            repaired.pendingAdapterPath = nil
            repaired.pendingAdapterKind = nil
            repaired.pendingCycleId = nil
            // A pre-P9 row wrote the candidate to currentAdapterPath BEFORE eval and has no
            // gate receipt at all. A post-P9 deployed currentAdapterPath ALWAYS has a
            // consumed receipt (from promoteAndConsumeReceipt) — including the crash window
            // after a promote commits but before the .idle transition, where current is the
            // just-promoted (legit) candidate and pending is already cleared. So roll the
            // current pointer back ONLY when it has NO consumed-receipt provenance (the
            // pre-P9 un-gated case); a deployed/promoted current is always kept.
            // Only when NO pending candidate is recorded (so currentAdapterPath might itself
            // be a candidate, not the deployed adapter) AND current has no consumed-receipt
            // provenance (⇒ pre-P9 un-gated, not a just-promoted post-P9 candidate).
            // INTENDED TRADEOFF: a pre-P9 LEGITIMATELY-deployed current also has no receipt,
            // so a crash mid-cycle on the first post-upgrade run rolls it back to the previous
            // adapter. That is fail-closed (we cannot distinguish a pre-P9 deployed adapter
            // from a pre-P9 un-gated candidate — neither has a receipt — so we prefer the
            // known-prior adapter). The user keeps a working personalized adapter; the next
            // cycle re-evaluates. This only affects the narrow first-upgrade crash window.
            if state.pendingAdapterPath == nil,
               let current = state.currentAdapterPath,
               cycle == .evaluating || cycle == .proposing || cycle == .deploying,
               (try? await store.hasConsumedReceipt(forCandidatePath: current)) != true {
                repaired.currentAdapterPath = state.previousAdapterPath
            }
            repaired.lastCycleError = "recovered_stale_\(cycle.rawValue)"
            try await store.writeState(repaired)
            NSLog(
                "ImprovementCycleCoordinator: recovered stale %@ → idle (discarded pending candidate)",
                cycle.rawValue
            )
        } catch {
            NSLog("ImprovementCycleCoordinator: recoverStaleStateIfNeeded failed: %@", error.localizedDescription)
        }
    }

    /// Whether the pending candidate for `cycleId` has a stored, unconsumed, verifying
    /// receipt (i.e. a `.proposing` state is safe to resume after a restart).
    private func hasResumableReceipt(cycleId: String, candidate: String) async -> Bool {
        guard let receipt = try? await store.gateReceipt(forCycleId: cycleId) else { return false }
        // Fail-closed: any store error reading the consumed flag ⇒ not resumable.
        guard let consumed = try? await store.isGateReceiptConsumed(cycleId: cycleId), !consumed else {
            return false
        }
        do {
            if let key = injectedGateKey {
                try GateReceiptVerifier.verify(receipt, expectedCandidatePath: candidate, using: key)
            } else {
                try GateReceiptVerifier.verify(receipt, expectedCandidatePath: candidate)
            }
            return true
        } catch {
            return false
        }
    }
}
