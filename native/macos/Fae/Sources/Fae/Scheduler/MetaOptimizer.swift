import Foundation

// MARK: - MetaOptimizer

/// Core meta-optimization loop inspired by AutoAgent's hill-climbing methodology.
///
/// The meta-optimizer tests candidate changes to Fae's runtime-mutable surfaces
/// (directive, config knobs) against FaeBenchmark scores. Changes that improve
/// the target dimension without regressing others are kept; all others are
/// rolled back immediately.
///
/// ## Integration
/// Called by `ImprovementCycleCoordinator` during the `metaOptimizing` state,
/// between `collecting` and `training`. Runs every cycle (not just every 7th).
///
/// ## Budget
/// Each cycle operates within a strict budget (`MetaOptBudget`) to keep the
/// phase fast (target: < 30 minutes). Benchmark runs are the primary cost.
///
/// ## Rollback
/// Every applied change captures a rollback closure. If the benchmark shows
/// regression or no improvement, the closure is invoked immediately. No
/// change persists without measured improvement.
///
/// ## Logging
/// All results are persisted to `meta_optimization_log` in improvement.db
/// for historical analysis and morning briefing reporting.
actor MetaOptimizer {

    // MARK: - Dependencies

    /// The improvement store for persisting results.
    private let store: ImprovementStore

    /// Closure to read the current directive text.
    var directiveReader: (() throws -> String?)?

    /// Closure to write new directive text (overwrite mode).
    var directiveWriter: ((_ text: String) throws -> Void)?

    /// Closure to read a config value by key. Returns string representation.
    var configReader: ((_ key: String) -> String?)?

    /// Closure to apply a config change. Takes key and new value string.
    var configWriter: ((_ key: String, _ value: String) throws -> Void)?

    /// Training bridge for running benchmark evaluations.
    private var trainingBridge: TrainingBridge?

    /// Skill manager for creating/activating/deleting auto-generated skills.
    private var skillManager: SkillManager?

    /// Memory store for seeding strategic facts.
    private var memoryStore: SQLiteMemoryStore?

    /// Current adapter path (nil = base model).
    var currentAdapterPath: String?

    /// Rollback closure for the most recently kept change.
    /// Used by the "undo the last change" voice command via SelfConfigTool.
    private var lastKeptRollback: (() async throws -> Void)?

    /// Human-readable description of the most recently kept change.
    private var lastKeptDescription: String?

    // MARK: - Init

    init(store: ImprovementStore) {
        self.store = store
    }

    func setTrainingBridge(_ bridge: TrainingBridge) {
        trainingBridge = bridge
    }

    func setDirectiveReader(_ reader: @escaping () throws -> String?) {
        directiveReader = reader
    }

    func setDirectiveWriter(_ writer: @escaping (_ text: String) throws -> Void) {
        directiveWriter = writer
    }

    func setConfigReader(_ reader: @escaping (_ key: String) -> String?) {
        configReader = reader
    }

    func setConfigWriter(_ writer: @escaping (_ key: String, _ value: String) throws -> Void) {
        configWriter = writer
    }

    func setSkillManager(_ manager: SkillManager) {
        skillManager = manager
    }

    func setMemoryStore(_ store: SQLiteMemoryStore) {
        memoryStore = store
    }

    // MARK: - Main Loop

    /// Run the meta-optimization phase.
    ///
    /// - Parameters:
    ///   - events: Feedback events collected for this cycle.
    ///   - budget: Resource budget for this phase.
    /// - Returns: Summary of the optimization phase.
    func run(
        events: [FeedbackEvent],
        budget: MetaOptBudget = .standard
    ) async throws -> MetaOptSummary {
        let startTime = Date()

        // Step 1: Check benchmark availability.
        guard let bridge = trainingBridge, await bridge.isBenchmarkAvailable else {
            NSLog("MetaOptimizer: benchmark not available, skipping meta-optimization")
            return MetaOptSummary(
                hypothesesTested: 0, keptCount: 0, discardedCount: 0,
                totalBenchmarkRuns: 0, wallClockSeconds: 0, results: []
            )
        }

        // Step 2: Cache baseline scores (one full benchmark run).
        NSLog("MetaOptimizer: running baseline benchmark")
        let baselineResult = try await bridge.runBenchmark(adapterPath: currentAdapterPath)
        var baseline = DimensionScores.from(baselineResult)
        var benchmarkRunsUsed = 1
        NSLog(
            "MetaOptimizer: baseline — tools=%.0f%% fae=%.0f%% fit=%.0f%% ser=%.0f%%",
            (baseline.toolCalling ?? 0) * 100,
            (baseline.faeCapability ?? 0) * 100,
            (baseline.assistantFit ?? 0) * 100,
            (baseline.serialization ?? 0) * 100
        )

        // Step 3: Generate hypotheses.
        let currentDirective = try? directiveReader?()
        let currentTemp = Double(configReader?("llm.temperature") ?? "0.7") ?? 0.7
        let currentMaxRecall = Int(configReader?("memory.maxRecallResults") ?? "6") ?? 6

        var hypotheses = MetaOptHypothesisGenerator.generate(
            from: events,
            currentDirective: currentDirective,
            currentTemperature: currentTemp,
            currentMaxRecall: currentMaxRecall
        )

        // Phase 2: Generate skill hypotheses from capability gaps and feedback patterns.
        let skillHypotheses = await generateSkillHypotheses(events: events)
        hypotheses.append(contentsOf: skillHypotheses)

        // Phase 3: Generate memory seed hypotheses from feedback patterns.
        let seedHypotheses = await generateMemorySeedHypotheses(events: events)
        hypotheses.append(contentsOf: seedHypotheses)

        // Re-sort by evidence count after merging.
        hypotheses.sort { $0.evidenceCount > $1.evidenceCount }

        guard !hypotheses.isEmpty else {
            NSLog("MetaOptimizer: no hypotheses generated, skipping")
            return MetaOptSummary(
                hypothesesTested: 0, keptCount: 0, discardedCount: 0,
                totalBenchmarkRuns: benchmarkRunsUsed,
                wallClockSeconds: Date().timeIntervalSince(startTime),
                results: []
            )
        }

        NSLog("MetaOptimizer: generated %d hypotheses", hypotheses.count)

        // Step 4: Test each hypothesis within budget.
        var keptCount = 0
        var discardedCount = 0
        var consecutiveDiscards = 0
        var results: [MetaOptResult] = []

        for hypothesis in hypotheses {
            // Budget checks.
            guard benchmarkRunsUsed < budget.maxBenchmarkRuns else {
                NSLog("MetaOptimizer: benchmark run budget exhausted (%d/%d)", benchmarkRunsUsed, budget.maxBenchmarkRuns)
                break
            }
            guard Date().timeIntervalSince(startTime) < budget.maxWallClockSeconds else {
                NSLog("MetaOptimizer: wall-clock budget exhausted (%.0fs)", Date().timeIntervalSince(startTime))
                break
            }
            guard consecutiveDiscards < budget.maxConsecutiveDiscards else {
                NSLog("MetaOptimizer: plateau detected (%d consecutive discards)", consecutiveDiscards)
                break
            }

            NSLog("MetaOptimizer: testing hypothesis — %@", hypothesis.description)

            // Apply change and capture rollback.
            let rollback: () async throws -> Void
            do {
                rollback = try await applyChange(hypothesis.change)
            } catch {
                NSLog("MetaOptimizer: failed to apply change: %@", error.localizedDescription)
                continue
            }

            // Run benchmark for target dimension.
            let afterResult: TrainingBenchmarkResult
            do {
                afterResult = try await bridge.runBenchmark(adapterPath: currentAdapterPath)
                benchmarkRunsUsed += 1
            } catch {
                NSLog("MetaOptimizer: benchmark failed: %@", error.localizedDescription)
                try? await rollback()
                continue
            }

            let afterScore = DimensionScores.from(afterResult)
            let delta = afterScore.improvement(over: baseline)

            // Decision.
            let decision = decide(
                hypothesis: hypothesis,
                baseline: baseline,
                afterScore: afterScore,
                budget: budget
            )

            let kept: Bool
            let reason: String

            switch decision {
            case .keep(let r):
                kept = true
                reason = r
                keptCount += 1
                consecutiveDiscards = 0
                // Update baseline for next iteration — the new state includes this change.
                baseline = afterScore
                // Store rollback for "undo the last change" voice command.
                lastKeptRollback = rollback
                lastKeptDescription = hypothesis.description
                NSLog(
                    "MetaOptimizer: KEPT — %@ (Δ: tools=%+.1f%% fae=%+.1f%% fit=%+.1f%% ser=%+.1f%%)",
                    hypothesis.description,
                    (delta.toolCalling ?? 0) * 100,
                    (delta.faeCapability ?? 0) * 100,
                    (delta.assistantFit ?? 0) * 100,
                    (delta.serialization ?? 0) * 100
                )

            case .discard(let r):
                kept = false
                reason = r
                discardedCount += 1
                consecutiveDiscards += 1
                // Rollback the change.
                do {
                    try await rollback()
                } catch {
                    NSLog("MetaOptimizer: rollback failed: %@", error.localizedDescription)
                }
                NSLog(
                    "MetaOptimizer: DISCARDED (%@) — %@ (Δ: tools=%+.1f%% fae=%+.1f%% fit=%+.1f%% ser=%+.1f%%)",
                    r, hypothesis.description,
                    (delta.toolCalling ?? 0) * 100,
                    (delta.faeCapability ?? 0) * 100,
                    (delta.assistantFit ?? 0) * 100,
                    (delta.serialization ?? 0) * 100
                )
            }

            let result = MetaOptResult(
                hypothesisId: hypothesis.id,
                surface: hypothesis.surface,
                description: hypothesis.description,
                targetDimension: hypothesis.targetDimension,
                beforeScores: baseline,
                afterScores: afterScore,
                delta: delta,
                kept: kept,
                reason: reason,
                timestamp: Date()
            )
            results.append(result)

            // Persist result to improvement store.
            try? await persistResult(result, cycleNumber: currentCycleNumber())
        }

        // Update meta-opt tracking in improvement state.
        try? await updateMetaOptState(keptCount: keptCount, testedCount: results.count)

        let summary = MetaOptSummary(
            hypothesesTested: results.count,
            keptCount: keptCount,
            discardedCount: discardedCount,
            totalBenchmarkRuns: benchmarkRunsUsed,
            wallClockSeconds: Date().timeIntervalSince(startTime),
            results: results
        )

        NSLog(
            "MetaOptimizer: phase complete — tested %d, kept %d, discarded %d, %d benchmark runs, %.0fs",
            summary.hypothesesTested, summary.keptCount, summary.discardedCount,
            summary.totalBenchmarkRuns, summary.wallClockSeconds
        )

        return summary
    }

    // MARK: - Decision Logic

    /// Decide whether to keep or discard a tested hypothesis.
    private func decide(
        hypothesis: MetaOptHypothesis,
        baseline: DimensionScores,
        afterScore: DimensionScores,
        budget: MetaOptBudget
    ) -> MetaOptDecision {
        // Rule 1: Any dimension regressed > threshold → always discard.
        if afterScore.anyRegression(over: baseline, threshold: budget.regressionThreshold) {
            return .discard(reason: "regression")
        }

        // Rule 2: Target dimension improved ≥ threshold → keep.
        if afterScore.improved(
            dimension: hypothesis.targetDimension,
            over: baseline,
            threshold: budget.minImprovementThreshold
        ) {
            return .keep(reason: "improvement")
        }

        // Rule 3: No significant change → discard.
        return .discard(reason: "neutral")
    }

    // MARK: - Rollback API

    /// Undo the most recently kept meta-optimization change.
    ///
    /// Called by SelfConfigTool when the user says "undo the last change."
    /// Returns a human-readable confirmation message.
    func rollbackLastChange() async -> String {
        guard let rollback = lastKeptRollback, let description = lastKeptDescription else {
            return "There's nothing to undo — I haven't made any recent adjustments."
        }

        do {
            try await rollback()
            let narrative = MetaOptNarrator.describeRollback(description)
            lastKeptRollback = nil
            lastKeptDescription = nil
            NSLog("MetaOptimizer: user-requested rollback of '%@'", description)
            return narrative
        } catch {
            NSLog("MetaOptimizer: rollback failed: %@", error.localizedDescription)
            return "I tried to undo the change but ran into a problem. You can try clearing the directive with 'clear my directive' as a workaround."
        }
    }

    // MARK: - Skill Hypothesis Generation

    /// Generate skill creation hypotheses from capability gaps and feedback patterns.
    private func generateSkillHypotheses(events: [FeedbackEvent]) async -> [MetaOptHypothesis] {
        // Collect existing skill names to avoid duplicates.
        var existingNames: Set<String> = []
        if let manager = skillManager {
            let discovered = await manager.discoverSkills()
            existingNames = Set(discovered.map(\.name))
        }

        // Load unaddressed capability gaps.
        let gaps = (try? await store.unaddressedGaps()) ?? []

        return MetaOptSkillGenerator.generateHypotheses(
            from: gaps,
            events: events,
            existingSkillNames: existingNames
        )
    }

    // MARK: - Memory Seed Hypothesis Generation

    /// Generate memory seed hypotheses from feedback patterns.
    private func generateMemorySeedHypotheses(events: [FeedbackEvent]) async -> [MetaOptHypothesis] {
        // Count existing seeds to respect the cap.
        let existingSeedCount: Int
        if let store = memoryStore {
            existingSeedCount = (try? await store.countRecords(
                kind: .fact,
                withTag: MetaOptMemorySeedGenerator.seedTag
            )) ?? 0
        } else {
            existingSeedCount = 0
        }

        return MetaOptMemorySeedGenerator.generateHypotheses(
            from: events,
            existingSeedCount: existingSeedCount
        )
    }

    // MARK: - Change Application

    /// Apply a change and return an async rollback closure.
    private func applyChange(_ change: MetaOptChange) async throws -> (() async throws -> Void) {
        switch change {
        case .directiveAmendment(let amendment):
            guard let reader = directiveReader, let writer = directiveWriter else {
                throw MetaOptError.directiveIOError("Directive reader/writer not configured")
            }
            let currentDirective = (try? reader()) ?? ""

            // Guard: check directive size limit.
            guard currentDirective.count + amendment.count <= MetaOptHypothesisGenerator.maxDirectiveSize else {
                throw MetaOptError.directiveIOError("Directive would exceed \(MetaOptHypothesisGenerator.maxDirectiveSize) char limit")
            }

            let newDirective = currentDirective + amendment
            try writer(newDirective)

            return { try writer(currentDirective) }

        case .configAdjustment(let key, let oldValue, let newValue):
            guard let writer = configWriter else {
                throw MetaOptError.configChangeError("Config writer not configured")
            }

            // Guard: validate against safe bounds.
            if let bound = ConfigBound.all.first(where: { $0.key == key }) {
                guard let numericValue = Double(newValue),
                      numericValue >= bound.min,
                      numericValue <= bound.max else {
                    throw MetaOptError.configChangeError("Value \(newValue) outside bounds [\(bound.min), \(bound.max)] for \(key)")
                }
            }

            try writer(key, newValue)

            return { try writer(key, oldValue) }

        case .skillCreation(let name, let description, let body):
            guard let manager = skillManager else {
                throw MetaOptError.skillError("SkillManager not configured")
            }

            // Create the instruction-only skill.
            let metadata = try await manager.createSkill(
                name: name,
                description: description,
                body: body
            )
            NSLog("MetaOptimizer: created skill '%@' at %@", name, metadata.directoryURL.path)

            // Activate it so it's included in the prompt stack for benchmark evaluation.
            _ = await manager.activate(skillName: name)

            return { [manager] in
                // Deactivate and delete on rollback.
                await manager.deactivate(skillName: name)
                try await manager.deleteSkill(name: name)
                NSLog("MetaOptimizer: rolled back skill '%@'", name)
            }

        case .memorySeedInsertion(let text, let tags):
            guard let store = memoryStore else {
                throw MetaOptError.memorySeedError("MemoryStore not configured")
            }

            let record = try await store.insertRecord(
                kind: .fact,
                text: text,
                confidence: 0.8,
                sourceTurnId: nil,
                tags: tags,
                staleAfterSecs: MetaOptMemorySeedGenerator.staleAfterSecs
            )
            let recordId = record.id
            NSLog("MetaOptimizer: seeded memory '%@' (id=%@)", String(text.prefix(60)), recordId)

            return { [store] in
                try await store.deleteRecord(id: recordId)
                NSLog("MetaOptimizer: rolled back memory seed (id=%@)", recordId)
            }
        }
    }

    // MARK: - Persistence Helpers

    /// Persist a single result to the meta_optimization_log table.
    private func persistResult(_ result: MetaOptResult, cycleNumber: Int) async throws {
        try await store.insertMetaOptResult(
            cycleNumber: cycleNumber,
            hypothesisId: result.hypothesisId.uuidString,
            surface: result.surface.rawValue,
            description: result.description,
            targetDimension: result.targetDimension.rawValue,
            beforeScores: Self.encodeScores(result.beforeScores),
            afterScores: Self.encodeScores(result.afterScores),
            delta: Self.encodeScores(result.delta),
            kept: result.kept,
            reason: result.reason,
            createdAt: ISO8601DateFormatter().string(from: result.timestamp)
        )
    }

    /// Read the current cycle number from improvement state.
    private func currentCycleNumber() async -> Int {
        (try? await store.readState().completedCycles) ?? 0
    }

    /// Update meta-opt tracking fields in improvement state.
    private func updateMetaOptState(keptCount: Int, testedCount: Int) async throws {
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.metaOptKeptTotal += keptCount
        state.metaOptTestedTotal += testedCount
        state.metaOptLastRunAt = ISO8601DateFormatter().string(from: Date())
        if keptCount == 0 {
            state.metaOptConsecutiveNoImprovement += 1
        } else {
            state.metaOptConsecutiveNoImprovement = 0
        }
        try await store.writeState(state)
    }

    /// Encode DimensionScores to a JSON string for storage.
    static func encodeScores(_ scores: DimensionScores) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(scores),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
