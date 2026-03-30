import Foundation

// MARK: - EvalOutcome

/// The outcome of comparing a base model response against an adapter response.
enum EvalOutcome: String, Sendable, CaseIterable {
    /// The base model produced a better response.
    case baseWins = "base_wins"
    /// The adapter produced a better response.
    case adapterWins = "adapter_wins"
    /// Neither response was clearly better.
    case tie
}

// MARK: - ShadowEvalResult

/// Aggregated result from a shadow evaluation run.
struct ShadowEvalResult: Sendable {
    /// Number of episodes evaluated in this run.
    let episodesEvaluated: Int
    /// Adapter wins as a fraction of evaluated episodes (0.0–1.0).
    let adapterWinRate: Double
    /// Whether the adapter passes the promotion gate.
    let promotionGatePassed: Bool
    /// ISO-8601 timestamp of the evaluation run.
    let evaluatedAt: String
}

// MARK: - ShadowEvaluatorError

/// Errors produced by `ShadowEvaluator`.
enum ShadowEvaluatorError: Error, Sendable {
    /// No episodes are available for evaluation.
    case noEpisodesAvailable
    /// The evaluator was called outside the allowed overnight window.
    case outsideOvernightWindow
    /// The response generator is not configured.
    case responseGeneratorNotSet
}

// MARK: - ShadowEvaluator

/// Compares base model and adapter responses on stored conversation episodes.
///
/// `ShadowEvaluator` runs as the shadow evaluation sub-phase of the improvement
/// cycle. It replays stored `ShadowEvalEpisode` records, generates both a base
/// response and an adapter response for each episode, scores each pair, and
/// records the outcome back to `ImprovementStore`.
///
/// ## Overnight-Only Policy
/// The evaluator enforces an overnight-only window (22:00–06:00 local time) to
/// avoid interfering with daytime conversations. Call `runEvaluation()` at any
/// time — if called outside the window it throws `outsideOvernightWindow`. Pass
/// `ignoreWindow: true` in tests.
///
/// ## Promotion Gate
/// After scoring, the evaluator computes an adapter win rate. If the adapter wins
/// on ≥ 60% of evaluated episodes, `ShadowEvalResult.promotionGatePassed` is
/// `true` — a signal to the `ImprovementCycleCoordinator` that the adapter is
/// ready for deployment consideration.
///
/// ## Injectable Scorer
/// Production uses a sentence-length heuristic (shorter, more-complete answers
/// score better on assistant-fit tasks). Tests inject a custom scorer to control
/// outcomes deterministically.
///
/// ## Usage
/// ```swift
/// let evaluator = ShadowEvaluator(store: improvementStore)
/// await evaluator.setResponseGenerator { episode, adapterPath in
///     // call MLXLLMEngine with adapter overlay
///     return "adapter response"
/// }
/// let result = try await evaluator.runEvaluation(ignoreWindow: false)
/// ```
actor ShadowEvaluator {

    // MARK: - Configuration

    /// Minimum adapter win rate required to pass the promotion gate.
    static let promotionWinRateThreshold: Double = 0.60

    /// Maximum number of episodes to evaluate in a single run.
    static let maxEpisodesPerRun = 50

    /// Overnight window start hour (22 = 22:00).
    static let overnightStartHour = 22

    /// Overnight window end hour (6 = 06:00).
    static let overnightEndHour = 6

    // MARK: - Dependencies

    private let store: ImprovementStore

    /// Generates an adapter response for a given episode.
    ///
    /// Receives the episode and the current adapter path (nil = base model).
    /// Returns the generated response string.
    var responseGenerator: ((_ episode: ShadowEvalEpisode, _ adapterPath: String?) async throws -> String)?

    /// Scores two responses for the same episode. Returns the `EvalOutcome`.
    ///
    /// Injectable so tests can control outcomes deterministically.
    /// Default uses the built-in heuristic scorer.
    var scorer: ((_ episode: ShadowEvalEpisode, _ baseResponse: String, _ adapterResponse: String) -> EvalOutcome)?

    /// Path to the current adapter under evaluation (nil = base model only → all ties).
    var currentAdapterPath: String?

    // MARK: - Init

    /// Create a shadow evaluator backed by the given store.
    init(store: ImprovementStore) {
        self.store = store
    }

    // MARK: - Configuration Setters

    /// Set the response generator. Called by tests or `ImprovementCycleCoordinator`.
    func setResponseGenerator(
        _ generator: @escaping (_ episode: ShadowEvalEpisode, _ adapterPath: String?) async throws -> String
    ) {
        responseGenerator = generator
    }

    /// Set the scorer. Called by tests to control outcomes deterministically.
    func setScorer(_ scorer: @escaping (_ episode: ShadowEvalEpisode, _ base: String, _ adapter: String) -> EvalOutcome) {
        self.scorer = scorer
    }

    /// Set the adapter path under evaluation.
    func setCurrentAdapterPath(_ path: String?) {
        currentAdapterPath = path
    }

    // MARK: - Overnight Window

    /// Returns `true` if the current local time falls in the overnight window (22:00–06:00).
    func isOvernightWindow() -> Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= Self.overnightStartHour || hour < Self.overnightEndHour
    }

    // MARK: - Main Entry Point

    /// Run a shadow evaluation pass.
    ///
    /// Fetches unevaluated episodes from the store, generates base and adapter
    /// responses for each, scores them, records the outcomes, and returns an
    /// aggregated `ShadowEvalResult`.
    ///
    /// - Parameter ignoreWindow: If `true`, skip the overnight-window check (for testing).
    /// - Returns: `ShadowEvalResult` with win rates and promotion gate verdict.
    /// - Throws: `ShadowEvaluatorError.outsideOvernightWindow` if called during the day.
    ///           `ShadowEvaluatorError.noEpisodesAvailable` if no episodes to evaluate.
    ///           `ShadowEvaluatorError.responseGeneratorNotSet` if generator not configured.
    func runEvaluation(ignoreWindow: Bool = false) async throws -> ShadowEvalResult {
        if !ignoreWindow && !isOvernightWindow() {
            throw ShadowEvaluatorError.outsideOvernightWindow
        }

        guard let generator = responseGenerator else {
            throw ShadowEvaluatorError.responseGeneratorNotSet
        }

        let episodes = try await store.unevaluatedEpisodes(limit: Self.maxEpisodesPerRun)
        guard !episodes.isEmpty else {
            throw ShadowEvaluatorError.noEpisodesAvailable
        }

        var adapterWins = 0
        var evaluated = 0

        for episode in episodes {
            guard let episodeID = episode.id else { continue }

            let baseResponse: String
            let adapterResponse: String

            do {
                // Generate base response (no adapter overlay).
                baseResponse = try await generator(episode, nil)
                // Generate adapter response.
                adapterResponse = try await generator(episode, currentAdapterPath)
            } catch {
                NSLog("ShadowEvaluator: skipping episode %lld — generator error: %@",
                      episodeID, error.localizedDescription)
                continue
            }

            let outcome = scoreResponses(
                episode: episode,
                baseResponse: baseResponse,
                adapterResponse: adapterResponse
            )

            do {
                try await store.recordEvalOutcome(id: episodeID, outcome: outcome.rawValue)
            } catch {
                NSLog("ShadowEvaluator: failed to record outcome for episode %lld — %@",
                      episodeID, error.localizedDescription)
                continue
            }

            if outcome == .adapterWins {
                adapterWins += 1
            }
            evaluated += 1
        }

        let winRate = evaluated > 0 ? Double(adapterWins) / Double(evaluated) : 0.0
        let passed = winRate >= Self.promotionWinRateThreshold

        NSLog(
            "ShadowEvaluator: evaluated %d episodes, adapter won %d (%.1f%%), gate %@",
            evaluated, adapterWins, winRate * 100,
            passed ? "PASSED" : "FAILED"
        )

        return ShadowEvalResult(
            episodesEvaluated: evaluated,
            adapterWinRate: winRate,
            promotionGatePassed: passed,
            evaluatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    // MARK: - Scoring

    /// Score a base/adapter response pair for an episode.
    ///
    /// Uses the injected scorer if set; otherwise falls back to the built-in heuristic.
    private func scoreResponses(
        episode: ShadowEvalEpisode,
        baseResponse: String,
        adapterResponse: String
    ) -> EvalOutcome {
        if let scorer {
            return scorer(episode, baseResponse, adapterResponse)
        }
        return Self.heuristicScore(
            episode: episode,
            baseResponse: baseResponse,
            adapterResponse: adapterResponse
        )
    }

    // MARK: - Built-In Heuristic Scorer

    /// Compare two responses using simple heuristics.
    ///
    /// Rules (in priority order):
    /// 1. If adapter response is significantly shorter (≤ 80% of base) and non-empty → adapter wins
    ///    (rewards conciseness, which is the primary improvement target).
    /// 2. If adapter response is significantly longer (≥ 120% of base) → base wins
    ///    (penalises verbosity regression).
    /// 3. Otherwise → tie.
    ///
    /// These heuristics intentionally favour conciseness since that is the most
    /// common user complaint captured by `re_ask` and `interruption` signals.
    static func heuristicScore(
        episode: ShadowEvalEpisode,
        baseResponse: String,
        adapterResponse: String
    ) -> EvalOutcome {
        let baseLen = Double(baseResponse.count)
        let adapterLen = Double(adapterResponse.count)

        guard baseLen > 0, adapterLen > 0 else {
            return .tie
        }

        let ratio = adapterLen / baseLen

        if ratio <= 0.80 {
            return .adapterWins
        }
        if ratio >= 1.20 {
            return .baseWins
        }
        return .tie
    }
}
