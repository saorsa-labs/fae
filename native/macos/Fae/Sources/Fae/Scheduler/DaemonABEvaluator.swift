import CryptoKit
import Foundation

// MARK: - DaemonABEvaluator (gguf lane, P9/C4 W7b)

/// Errors specific to the daemon-lane A/B evaluator. Mapped to
/// `AdapterEvaluatorError` at the `AdapterEvaluator.evaluate` boundary so the
/// coordinator's fail-closed handling stays uniform.
enum DaemonABEvaluatorError: Error, CustomStringConvertible {
    /// The bundled held-out eval suite is missing or fails its SHA-256 lock.
    case evalSuiteUnavailable(String)
    /// The A/B exceeded its wall-clock bound. The deployed adapter is restored first.
    case timedOut(seconds: Int)
    /// The live daemon could not be confirmed back on the deployed adapter after eval.
    /// This is the deploy-without-receipt hole — a daemon left on the un-gated
    /// candidate — and is therefore loud and fail-closed.
    case restoreUnconfirmed(expected: String, found: String)

    var description: String {
        switch self {
        case .evalSuiteUnavailable(let why): return "daemon A/B eval suite unavailable: \(why)"
        case .timedOut(let s): return "daemon A/B eval timed out after \(s)s"
        case .restoreUnconfirmed(let expected, let found):
            return "daemon A/B eval could not restore deployed adapter "
                + "(expected \(expected), daemon reports \(found))"
        }
    }
}

// MARK: - Daemon client seam (testable)

/// The single inference result the evaluator scores: the model's spoken text plus
/// any structured tool calls it emitted (name + argument keys are enough for the
/// deterministic tool-call scorers).
struct DaemonABInference: Sendable, Equatable {
    let text: String
    let toolCalls: [ToolCallSummary]

    struct ToolCallSummary: Sendable, Equatable {
        let name: String
        let argKeys: [String]
    }
}

/// The narrow surface the daemon-lane A/B evaluator needs. Abstracted so unit
/// tests inject a fake that returns canned outputs and records the
/// reload/scale/infer call sequence — the ONLY way to test the A/B orchestration
/// + restore-on-every-exit safety property without a live daemon.
protocol DaemonABClient: Sendable {
    /// Reload the sidecar with a personal adapter GGUF (or `nil` for base). A
    /// non-nil path also activates the adapter (scale 1.0), per the daemon lane.
    func reload(path: String?) async throws
    /// Set the personal-LoRA scale on the running sidecar (0.0 = base, 1.0 = on).
    func setScale(_ scale: Float) async throws
    /// Run one held-out eval example and return text + tool-call structure.
    func infer(_ example: DaemonEvalExample) async throws -> DaemonABInference
    /// The adapter the sidecar currently serves (`nil` = base model). Used to
    /// CONFIRM the deployed adapter was restored after eval.
    func loadedAdapterPath() async throws -> String?
}

/// Production `DaemonABClient` wrapping the live `DaemonLLMEngine`. Translates the
/// held-out example into a plain text turn with the example's tools.
struct LiveDaemonABClient: DaemonABClient {
    let engine: DaemonLLMEngine
    /// Generation cap per eval prompt — eval answers are short; keeps the A/B bounded.
    let maxTokens: Int

    init(engine: DaemonLLMEngine, maxTokens: Int = 256) {
        self.engine = engine
        self.maxTokens = maxTokens
    }

    func reload(path: String?) async throws {
        try await engine.reloadAdapter(path: path)
    }

    func setScale(_ scale: Float) async throws {
        try await engine.setAdapterScale(scale)
    }

    func infer(_ example: DaemonEvalExample) async throws -> DaemonABInference {
        let options = GenerationOptions(
            temperature: 0.0,
            maxTokens: maxTokens,
            suppressThinking: true,
            tools: example.toolSpecs
        )
        let turn = try await engine.inferForEval(
            messages: [LLMMessage(role: .user, content: example.prompt)],
            systemPrompt: example.system,
            options: options
        )
        let calls = turn.toolCalls.map {
            DaemonABInference.ToolCallSummary(name: $0.name, argKeys: Array($0.arguments.keys))
        }
        return DaemonABInference(text: turn.text, toolCalls: calls)
    }

    func loadedAdapterPath() async throws -> String? {
        try await engine.runtimeStatus()?.path
    }
}

// MARK: - Held-out eval suite (SHA-locked bundled resource)

/// One scored held-out example. `dimension` maps it to a `GateDimension`; `scoring`
/// is a purely rule-based key (NO LLM re-judging).
struct DaemonEvalExample: Sendable, Codable {
    let id: String
    let dimension: String
    let system: String
    let prompt: String
    let tools: [ToolSpec]?
    let scoring: Scoring

    /// A minimal tool spec (daemon flattens it to `{name, description, parameters}`).
    struct ToolSpec: Sendable, Codable {
        let name: String
        let description: String
        let parameters: JSONValue
    }

    /// The deterministic scoring rule for an example.
    ///
    /// Every field is `Optional` so older suites (which omit the v2 additions)
    /// still decode — only the fields a given `type` consults are read.
    struct Scoring: Sendable, Codable {
        let type: String
        let name: String?
        let requiredArgs: [String]?
        let prefix: String?
        let minLines: Int?
        let keys: [String]?
        let minCount: Int?
        let anyOf: [String]?
        let forbidden: [String]?
        /// v2: ALL of these substrings must be present (case-insensitive). Distinct
        /// from `anyOf`'s OR-semantics — used to require multiple discriminating
        /// tokens co-present. If both `allOf` and `anyOf` are given, an answer
        /// passes only when every `allOf` token AND at least one `anyOf` token hit.
        let allOf: [String]?
        /// v2: `expectConcise` upper bound on character count (inclusive).
        let maxChars: Int?
        /// v2: `expectConcise` upper bound on non-empty line count (inclusive).
        let maxLines: Int?
    }

    /// Tools in the MLX/daemon ToolSpec wire shape (`{type, function:{...}}`) the
    /// engine expects in `GenerationOptions.tools`.
    var toolSpecs: [[String: any Sendable]]? {
        guard let tools, !tools.isEmpty else { return nil }
        return tools.map { spec in
            [
                "type": "function",
                "function": [
                    "name": spec.name,
                    "description": spec.description,
                    "parameters": spec.parameters.anyValue,
                ] as [String: Any],
            ] as [String: any Sendable]
        }
    }

    /// The `GateDimension` this example contributes to, or nil for an unknown label.
    var gateDimension: GateDimension? {
        GateDimension(rawValue: dimension)
    }
}

/// A JSON value that round-trips arbitrary tool-parameter schemas through Codable.
/// (`[String: Any]` is not Codable; tool parameter schemas are nested/arbitrary.)
enum JSONValue: Sendable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .object(let o): return o.mapValues { $0.anyValue }
        case .array(let a): return a.map { $0.anyValue }
        case .null: return NSNull()
        }
    }
}

/// The bundled, SHA-locked held-out eval set. Loading it verifies the on-disk
/// bytes against `lockedSHA256` so the gate is reproducible: a drifted suite is
/// rejected rather than silently changing what a pass means.
struct DaemonEvalSuite: Sendable {
    let suiteVersion: String
    let examples: [DaemonEvalExample]

    /// Resource name + SHA-256 lock of the bundled eval set. A mismatch fails
    /// closed (the evaluator reports unavailable, leaving the lane blocked).
    static let resourceName = "daemon-ab-eval-v2"
    static let lockedSHA256 = "6cfc1140a82bc0e4c618ccfb0259663e011ad809460bee5b9800cb886a25b32b"

    private struct Wire: Codable {
        let suiteVersion: String
        let examples: [DaemonEvalExample]
    }

    /// Load + SHA-verify the bundled eval suite. Returns nil only via a thrown
    /// `evalSuiteUnavailable` (so the caller fails closed loudly, never silently).
    static func loadBundled() throws -> DaemonEvalSuite {
        guard let url = Bundle.faeResources.url(
            forResource: resourceName, withExtension: "json", subdirectory: "Models")
        else {
            throw DaemonABEvaluatorError.evalSuiteUnavailable("bundled resource not found: \(resourceName).json")
        }
        return try load(contentsOf: url)
    }

    /// Load from an explicit URL (tests point this at a temp file with a matching lock).
    static func load(contentsOf url: URL, expectedSHA256: String = lockedSHA256) throws -> DaemonEvalSuite {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw DaemonABEvaluatorError.evalSuiteUnavailable("could not read \(url.path)")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256 else {
            throw DaemonABEvaluatorError.evalSuiteUnavailable(
                "eval-suite SHA mismatch (expected \(expectedSHA256), got \(digest))")
        }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw DaemonABEvaluatorError.evalSuiteUnavailable("decode failed: \(error)")
        }
        guard !wire.examples.isEmpty else {
            throw DaemonABEvaluatorError.evalSuiteUnavailable("eval suite has no examples")
        }
        // Every example must map to a real gate dimension and cover all four — a
        // partial suite could never produce a COMPLETE measurement (W1 fail-closed).
        let covered = Set(wire.examples.compactMap { $0.gateDimension })
        guard covered == Set(GateDimension.allCases) else {
            throw DaemonABEvaluatorError.evalSuiteUnavailable(
                "eval suite does not cover every gate dimension (covered: \(covered.map(\.rawValue).sorted()))")
        }
        return DaemonEvalSuite(suiteVersion: wire.suiteVersion, examples: wire.examples)
    }
}

// MARK: - Deterministic scorers (pure, offline)

/// Rule-based pass/fail for one example given the model's inference. NO LLM
/// re-judging — every rule is a deterministic string/JSON check so the same
/// answer always scores the same way (reproducible gate).
enum DaemonEvalScorer {
    /// `true` ⇒ the model answered this example correctly under the rule.
    static func isCorrect(_ inference: DaemonABInference, scoring: DaemonEvalExample.Scoring) -> Bool {
        let text = inference.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        switch scoring.type {
        case "expectToolCall":
            guard let call = inference.toolCalls.first(where: { $0.name == scoring.name }) else {
                return false
            }
            let required = Set(scoring.requiredArgs ?? [])
            return required.isSubset(of: Set(call.argKeys))
        case "expectNoToolCall":
            return inference.toolCalls.isEmpty && !text.isEmpty
        case "expectLinesPrefixed":
            guard let prefix = scoring.prefix else { return false }
            let min = scoring.minLines ?? 1
            let matching = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix(prefix) }
            return matching.count >= min
        case "expectJSONKeys":
            guard let keys = scoring.keys, let obj = firstJSONObject(in: text) else { return false }
            return Set(keys).isSubset(of: Set(obj.keys))
        case "expectJSONArray":
            guard let array = firstJSONArray(in: text) else { return false }
            return array.count >= (scoring.minCount ?? 1)
        case "expectKeywords":
            if containsForbidden(lower, scoring.forbidden) { return false }
            // v2 `allOf`: EVERY listed substring must be present. When both `allOf`
            // and `anyOf` are given, require all-of AND at least one any-of.
            if let allOf = scoring.allOf, !allOf.isEmpty {
                guard allOf.allSatisfy({ lower.contains($0.lowercased()) }) else { return false }
            }
            let anyOf = scoring.anyOf ?? []
            guard !anyOf.isEmpty else {
                // No anyOf: pass on a satisfied allOf (above) or a non-empty answer.
                return !text.isEmpty
            }
            return anyOf.contains { lower.contains($0.lowercased()) }
        case "expectConcise":
            // Deterministic brevity check: a forbidden phrase still hard-fails, then
            // the answer must be non-empty and within the char/line bounds given.
            if containsForbidden(lower, scoring.forbidden) { return false }
            guard !text.isEmpty else { return false }
            if let maxChars = scoring.maxChars, text.count > maxChars { return false }
            if let maxLines = scoring.maxLines {
                let lines = text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if lines.count > maxLines { return false }
            }
            // v2: `expectConcise` may also assert keyword presence (anyOf/allOf) so a
            // concise-but-wrong answer fails — brevity alone is not correctness.
            if let allOf = scoring.allOf, !allOf.isEmpty {
                guard allOf.allSatisfy({ lower.contains($0.lowercased()) }) else { return false }
            }
            if let anyOf = scoring.anyOf, !anyOf.isEmpty {
                guard anyOf.contains(where: { lower.contains($0.lowercased()) }) else { return false }
            }
            return true
        case "expectNonEmpty":
            if containsForbidden(lower, scoring.forbidden) { return false }
            return !text.isEmpty
        default:
            return false
        }
    }

    private static func containsForbidden(_ lower: String, _ forbidden: [String]?) -> Bool {
        guard let forbidden, !forbidden.isEmpty else { return false }
        return forbidden.contains { lower.contains($0.lowercased()) }
    }

    /// Extract the first balanced `{...}` JSON object from possibly-fenced text.
    static func firstJSONObject(in text: String) -> [String: Any]? {
        firstJSON(in: text, open: "{", close: "}") as? [String: Any]
    }

    static func firstJSONArray(in text: String) -> [Any]? {
        firstJSON(in: text, open: "[", close: "]") as? [Any]
    }

    private static func firstJSON(in text: String, open: Character, close: Character) -> Any? {
        guard let start = text.firstIndex(of: open) else { return nil }
        var depth = 0
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == open { depth += 1 } else if ch == close {
                depth -= 1
                if depth == 0 {
                    let slice = String(text[start...idx])
                    if let data = slice.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) {
                        return obj
                    }
                    return nil
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    /// Per-dimension accuracy = correct / total (mirrors `parseBenchmarkOutput`).
    /// Returns nil for a dimension with no examples (cannot produce an accuracy).
    static func accuracyByDimension(
        results: [(dimension: GateDimension, correct: Bool)]
    ) -> [GateDimension: Double] {
        var counts: [GateDimension: (correct: Int, total: Int)] = [:]
        for r in results {
            var c = counts[r.dimension] ?? (0, 0)
            c.total += 1
            if r.correct { c.correct += 1 }
            counts[r.dimension] = c
        }
        var acc: [GateDimension: Double] = [:]
        for (dim, c) in counts where c.total > 0 {
            acc[dim] = Double(c.correct) / Double(c.total)
        }
        return acc
    }
}

// MARK: - DaemonABEvaluator

/// Evaluates a freshly-trained GGUF LoRA **candidate** against the **DEPLOYED**
/// adapter by A/B-testing the live llama.cpp daemon over a SHA-locked held-out
/// eval set, producing a measured `EvalDelta` (P9/C4 W7b).
///
/// ## Why reload-per-phase, not scale-toggle
/// The daemon holds ONE personal adapter at a time and `scale 0` is the BASE
/// model — NOT the deployed adapter. So the baseline (the deployed adapter) and
/// the candidate must each be reloaded in turn:
/// `reload(deployed) → score all → reload(candidate) → score all`. When nothing
/// is deployed (`baselinePath == nil`) the baseline is the base model
/// (`reload(nil)`, scale 0) — the only case scale-0 is the baseline.
///
/// ## Restore-on-every-exit is a SAFETY property
/// The evaluator mutates the LIVE daemon's loaded adapter. On EVERY exit path
/// (success, throw, timeout, cancellation) it reloads the originally-deployed
/// adapter and CONFIRMS via `runtime.status`, so the live daemon is never left
/// serving the un-gated candidate — the exact deploy-without-receipt hole this
/// series closes.
struct DaemonABEvaluator: AdapterEvaluator {
    let client: DaemonABClient
    let suite: DaemonEvalSuite
    /// Wall-clock bound for the whole A/B (both phases + restore).
    let timeoutSeconds: Int

    var kind: AdapterKind { .gguf }
    var evaluatorId: String { "DaemonABEvaluator" }
    var evalSuiteVersion: String { suite.suiteVersion }

    init(client: DaemonABClient, suite: DaemonEvalSuite, timeoutSeconds: Int = 900) {
        self.client = client
        self.suite = suite
        self.timeoutSeconds = timeoutSeconds
    }

    func isAvailable() async -> Bool {
        // The suite is loaded + SHA-verified at construction (a missing/drifted
        // suite means the evaluator was never registered), so availability tracks
        // the live daemon answering a status query. A throw ⇒ unavailable.
        do {
            _ = try await client.loadedAdapterPath()
            return true
        } catch {
            return false
        }
    }

    func evaluate(candidatePath: String, baselinePath: String?) async throws -> GateOutcome {
        // The deployed adapter to restore to on EVERY exit. This is the baseline
        // when one is deployed; nil ⇒ restore to base. We snapshot it up front so
        // restore targets exactly what the daemon served before eval.
        let deployedToRestore = baselinePath
        do {
            let outcome = try await withABTimeout(seconds: timeoutSeconds) {
                try await runAB(candidatePath: candidatePath, baselinePath: baselinePath)
            }
            // Restore + confirm before returning the measured pass.
            try await restoreDeployed(deployedToRestore)
            return outcome
        } catch {
            // Restore on the failure path too, then surface the failure so the
            // coordinator treats it as fail-closed (no mint, blocked).
            await restoreDeployedBestEffort(deployedToRestore)
            if let abError = error as? DaemonABEvaluatorError {
                throw AdapterEvaluatorError.measurementFailed(abError.description)
            }
            throw AdapterEvaluatorError.measurementFailed(String(describing: error))
        }
    }

    // MARK: - A/B core

    private func runAB(candidatePath: String, baselinePath: String?) async throws -> GateOutcome {
        // Phase 1 — baseline = the DEPLOYED adapter (or base model when none).
        try await client.reload(path: baselinePath)
        let baselineScores = try await scoreSuite()

        // Phase 2 — candidate.
        try await client.reload(path: candidatePath)
        let candidateScores = try await scoreSuite()

        let delta = Self.deltaPercentagePoints(
            baseline: baselineScores, candidate: candidateScores)
        // baseModelId records WHAT the candidate was scored against (the deployed
        // adapter path, or a base-model marker) so a receipt can never claim a pass
        // vs the wrong baseline.
        let baseModelId = baselinePath ?? "daemon-base-model"
        return GateOutcome(
            delta: delta, baseModelId: baseModelId, evalSuiteVersion: suite.suiteVersion)
    }

    /// Run every example under the currently-loaded adapter and return per-dimension
    /// accuracy. A partial run (any inference throws) propagates so the A/B is
    /// fail-closed rather than scoring against missing answers.
    private func scoreSuite() async throws -> [GateDimension: Double] {
        var results: [(dimension: GateDimension, correct: Bool)] = []
        for example in suite.examples {
            guard let dimension = example.gateDimension else { continue }
            try Task.checkCancellation()
            let inference = try await client.infer(example)
            let correct = DaemonEvalScorer.isCorrect(inference, scoring: example.scoring)
            results.append((dimension, correct))
        }
        return DaemonEvalScorer.accuracyByDimension(results: results)
    }

    /// Candidate minus baseline, per dimension, in PERCENTAGE POINTS (matching
    /// `EvalDelta`'s units). A dimension absent from either side yields `nil` so
    /// the W1 gate's "complete measurement" rule blocks an incomplete A/B.
    static func deltaPercentagePoints(
        baseline: [GateDimension: Double], candidate: [GateDimension: Double]
    ) -> EvalDelta {
        func delta(_ dim: GateDimension) -> Double? {
            guard let b = baseline[dim], let c = candidate[dim] else { return nil }
            return (c - b) * 100.0
        }
        return EvalDelta(
            toolCallingDelta: delta(.toolCalling),
            faeCapabilityDelta: delta(.faeCapability),
            assistantFitDelta: delta(.assistantFit),
            serializationDelta: delta(.serialization),
            throughputDelta: nil
        )
    }

    // MARK: - Restore (safety property)

    /// Reload the originally-deployed adapter and CONFIRM the daemon is back on it.
    /// An unconfirmed restore is loud + fail-closed (`restoreUnconfirmed`).
    private func restoreDeployed(_ deployed: String?) async throws {
        if let deployed {
            try await client.reload(path: deployed)
        } else {
            // Base model: scale 0 then drop the adapter (mirrors swapAdapter(nil)).
            try await client.setScale(0.0)
            try await client.reload(path: nil)
        }
        let loaded = try await client.loadedAdapterPath()
        guard Self.restoreMatches(expected: deployed, loaded: loaded) else {
            NSLog(
                "DaemonABEvaluator: FAILED to restore deployed adapter after eval — expected %@, daemon reports %@ (fail-closed)",
                deployed ?? "<base model>", loaded ?? "<base model>")
            throw DaemonABEvaluatorError.restoreUnconfirmed(
                expected: deployed ?? "<base model>", found: loaded ?? "<base model>")
        }
        NSLog("DaemonABEvaluator: restored deployed adapter after eval (%@)", deployed ?? "<base model>")
    }

    /// Best-effort restore for the failure path — we already have a failure to
    /// surface; a restore error here is logged, not thrown (it must not mask the
    /// original cause), but a daemon left on the candidate is logged LOUDLY.
    private func restoreDeployedBestEffort(_ deployed: String?) async {
        do {
            try await restoreDeployed(deployed)
        } catch {
            NSLog(
                "DaemonABEvaluator: best-effort restore after eval failure also failed (%@) — daemon may be on the un-gated candidate",
                String(describing: error))
        }
    }

    /// The daemon's loaded adapter matches what we deployed (both base, or same path).
    static func restoreMatches(expected: String?, loaded: String?) -> Bool {
        switch (expected, loaded) {
        case (nil, nil): return true
        case let (e?, l?): return e == l
        default: return false
        }
    }

    // MARK: - Timeout

    /// Run `body` with a wall-clock bound. On timeout the racing body task is
    /// cancelled (so `scoreSuite`'s `Task.checkCancellation` unwinds it) and
    /// `timedOut` is thrown — the caller then restores the deployed adapter.
    private func withABTimeout<T: Sendable>(
        seconds: Int, _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                throw DaemonABEvaluatorError.timedOut(seconds: seconds)
            }
            guard let result = try await group.next() else {
                throw DaemonABEvaluatorError.timedOut(seconds: seconds)
            }
            group.cancelAll()
            return result
        }
    }
}
