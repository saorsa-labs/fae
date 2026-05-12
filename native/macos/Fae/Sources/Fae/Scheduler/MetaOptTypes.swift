import Foundation

// MARK: - EvalDimension

/// A single benchmark evaluation dimension.
///
/// Each dimension corresponds to an eval suite in FaeBenchmark:
/// - `toolCalling`: Tool call structure, name, and argument accuracy (10 tests)
/// - `faeCapability`: Tool judgment, instruction following, summarization, memory (20 MCQs)
/// - `assistantFit`: Advanced tool judgment, memory discipline, result handling (25 MCQs)
/// - `serialization`: JSON/XML/YAML structured output (9 tests)
enum EvalDimension: String, Codable, Sendable, CaseIterable {
    case toolCalling
    case faeCapability
    case assistantFit
    case serialization
}

// MARK: - DimensionScores

/// Benchmark scores across all evaluated dimensions (0.0–1.0 each).
///
/// Used as both absolute scores and deltas. When representing deltas,
/// positive values indicate improvement.
struct DimensionScores: Codable, Sendable {
    let toolCalling: Double?
    let faeCapability: Double?
    let assistantFit: Double?
    let serialization: Double?

    /// Compute per-dimension delta (self - baseline). Positive = improvement.
    func improvement(over baseline: DimensionScores) -> DimensionScores {
        DimensionScores(
            toolCalling: numericDelta(self.toolCalling, baseline.toolCalling),
            faeCapability: numericDelta(self.faeCapability, baseline.faeCapability),
            assistantFit: numericDelta(self.assistantFit, baseline.assistantFit),
            serialization: numericDelta(self.serialization, baseline.serialization)
        )
    }

    /// True if any measured dimension regressed more than the threshold.
    func anyRegression(over baseline: DimensionScores, threshold: Double = 0.05) -> Bool {
        let delta = improvement(over: baseline)
        return [delta.toolCalling, delta.faeCapability, delta.assistantFit, delta.serialization]
            .compactMap { $0 }
            .contains { $0 < -threshold }
    }

    /// True if the target dimension improved by at least the threshold.
    func improved(
        dimension: EvalDimension,
        over baseline: DimensionScores,
        threshold: Double = 0.01
    ) -> Bool {
        let delta = improvement(over: baseline)
        let value: Double?
        switch dimension {
        case .toolCalling:   value = delta.toolCalling
        case .faeCapability: value = delta.faeCapability
        case .assistantFit:  value = delta.assistantFit
        case .serialization: value = delta.serialization
        }
        return (value ?? 0) >= threshold
    }

    /// Construct from a `TrainingBenchmarkResult`.
    static func from(_ result: TrainingBenchmarkResult) -> DimensionScores {
        DimensionScores(
            toolCalling: result.toolCallingAccuracy,
            faeCapability: result.faeCapabilityAccuracy,
            assistantFit: result.assistantFitAccuracy,
            serialization: result.serializationAccuracy
        )
    }

    /// All-nil scores (for when no benchmark is available).
    static let empty = DimensionScores(
        toolCalling: nil, faeCapability: nil, assistantFit: nil, serialization: nil
    )

    private func numericDelta(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b else { return nil }
        return a - b
    }
}

// MARK: - MetaOptSurface

/// A runtime-mutable surface that the meta-optimizer can modify.
enum MetaOptSurface: String, Codable, Sendable {
    /// Append or modify instructions in directive.md (Layer 4 of prompt stack).
    case directive
    /// Adjust a config.toml knob via FaeCore.patchConfig().
    case configKnob
    /// Create or modify an instruction-only skill (Layer 7-8 of prompt stack).
    case skill
    /// Seed a strategic meta-memory that shapes LLM behavior via recall (Layer 5).
    case memorySeed
}

// MARK: - MetaOptChange

/// A concrete change to apply to a mutable surface.
enum MetaOptChange: Sendable {
    /// Append text to directive.md.
    case directiveAmendment(String)
    /// Set a config key to a new value, remembering the old value for rollback.
    case configAdjustment(key: String, oldValue: String, newValue: String)
    /// Create an instruction-only skill and activate it.
    case skillCreation(name: String, description: String, body: String)
    /// Insert a strategic fact into memory that shapes recall-driven behavior.
    case memorySeedInsertion(text: String, tags: [String])
}

// MARK: - MetaOptHypothesis

/// A candidate change proposed by the hypothesis generator.
struct MetaOptHypothesis: Sendable {
    /// Unique identifier for this hypothesis.
    let id: UUID
    /// Which mutable surface this targets.
    let surface: MetaOptSurface
    /// Human-readable description of what this change does and why.
    let description: String
    /// Which benchmark dimension this change is expected to improve.
    let targetDimension: EvalDimension
    /// The actual change to apply.
    let change: MetaOptChange
    /// Number of feedback events supporting this hypothesis (higher = try first).
    let evidenceCount: Int
}

// MARK: - MetaOptDecision

/// The decision made about a tested hypothesis.
enum MetaOptDecision: Sendable {
    /// Keep the change — it improved scores.
    case keep(reason: String)
    /// Discard the change — it regressed, was neutral, or exceeded budget.
    case discard(reason: String)
}

// MARK: - MetaOptResult

/// The outcome of testing a single hypothesis.
struct MetaOptResult: Sendable {
    /// Which hypothesis was tested.
    let hypothesisId: UUID
    /// Which surface was modified.
    let surface: MetaOptSurface
    /// Human-readable description from the hypothesis.
    let description: String
    /// Which benchmark dimension this change targeted.
    let targetDimension: EvalDimension
    /// Scores before the change was applied.
    let beforeScores: DimensionScores
    /// Scores after the change was applied.
    let afterScores: DimensionScores
    /// Per-dimension delta (after - before).
    let delta: DimensionScores
    /// Whether the change was kept.
    let kept: Bool
    /// Reason for the decision.
    let reason: String
    /// When this test was performed.
    let timestamp: Date
}

// MARK: - MetaOptSummary

/// Summary of a complete meta-optimization phase.
struct MetaOptSummary: Sendable {
    /// Number of hypotheses that were tested.
    let hypothesesTested: Int
    /// Number of changes that were kept.
    let keptCount: Int
    /// Number of changes that were discarded.
    let discardedCount: Int
    /// Total benchmark evaluation runs consumed.
    let totalBenchmarkRuns: Int
    /// Wall-clock time for the entire phase (seconds).
    let wallClockSeconds: TimeInterval
    /// Individual results for each tested hypothesis.
    let results: [MetaOptResult]
}

// MARK: - MetaOptBudget

/// Resource budget for a single meta-optimization phase.
struct MetaOptBudget: Sendable {
    /// Maximum number of benchmark evaluation runs per cycle.
    let maxBenchmarkRuns: Int
    /// Maximum wall-clock time for the meta-optimization phase (seconds).
    let maxWallClockSeconds: TimeInterval
    /// Stop after N consecutive discarded candidates (plateau detection).
    let maxConsecutiveDiscards: Int
    /// Minimum improvement on the target dimension to keep a change (as fraction, e.g. 0.01 = 1%).
    let minImprovementThreshold: Double
    /// Regression on any dimension exceeding this threshold triggers automatic discard (as fraction).
    let regressionThreshold: Double

    /// Default budget for nightly meta-optimization.
    static let standard = MetaOptBudget(
        maxBenchmarkRuns: 10,
        maxWallClockSeconds: 1800,    // 30 minutes
        maxConsecutiveDiscards: 3,
        minImprovementThreshold: 0.01, // 1 percentage point
        regressionThreshold: 0.05      // 5 percentage points
    )
}

// MARK: - ConfigBound

/// Safe bounds for a tunable config knob.
struct ConfigBound: Sendable {
    /// Config key path (e.g. "llm.temperature").
    let key: String
    /// Minimum allowed value.
    let min: Double
    /// Maximum allowed value.
    let max: Double
    /// Minimum step size for adjustments.
    let step: Double
    /// Which benchmark dimension this knob primarily affects.
    let targetDimension: EvalDimension

    /// All tunable config knobs with their safe bounds.
    static let all: [ConfigBound] = [
        ConfigBound(key: "llm.temperature", min: 0.1, max: 1.0, step: 0.1, targetDimension: .toolCalling),
        ConfigBound(key: "memory.maxRecallResults", min: 2, max: 12, step: 1, targetDimension: .faeCapability),
    ]
}

// MARK: - MetaOptError

/// Errors from the meta-optimization phase.
enum MetaOptError: Error, Sendable {
    /// Benchmark evaluation is not available (no FaeBenchmark binary configured).
    case benchmarkNotAvailable
    /// The training bridge is not set.
    case trainingBridgeNotAvailable
    /// Failed to read or write the directive.
    case directiveIOError(String)
    /// Failed to apply a config change.
    case configChangeError(String)
    /// Failed to create, activate, or delete a skill.
    case skillError(String)
    /// Failed to insert or delete a memory seed.
    case memorySeedError(String)
}
