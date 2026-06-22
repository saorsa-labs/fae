import CryptoKit
import XCTest
@testable import Fae

/// P9/C4 W7b — the daemon-lane A/B evaluator (`.gguf`) and the receipt it produces.
///
/// These tests encode WHY the daemon A/B gates the way it does:
/// - the baseline MUST be the DEPLOYED adapter via reload-per-phase (NOT scale-0,
///   which is the base model) so the delta measures improvement over what is live;
/// - the LIVE daemon MUST be restored to the deployed adapter on EVERY exit path
///   (success, throw, timeout) — a daemon left on the un-gated candidate is the
///   deploy-without-receipt hole this series closes;
/// - scoring is purely deterministic (NO LLM re-judging) so the gate is reproducible;
/// - a passing measurement MUST mint a `.gguf` gate receipt the W4 deploy gate accepts.
final class DaemonABEvaluatorTests: XCTestCase {

    private let gateTestKey = SymmetricKey(data: Data(repeating: 0x42, count: 32))

    // MARK: - Recording fake daemon client

    /// A fake `DaemonABClient` that records the reload/scale/infer call sequence and
    /// returns canned per-(adapter, exampleId) inferences. `loadedAdapterPath`
    /// reflects the LAST reload so restore-confirmation can be asserted (or forced
    /// to mismatch). The ONLY way to test the A/B orchestration without a live daemon.
    private actor FakeDaemonABClient: DaemonABClient {
        enum Call: Equatable {
            case reload(String?)
            case setScale(Float)
            case infer(String)            // exampleId
            case status
        }

        private(set) var calls: [Call] = []
        private var loaded: String?
        /// exampleId → text answer under the CANDIDATE adapter; baseline answers
        /// are wrong unless listed in `baselineCorrect`.
        private let candidateText: [String: String]
        private let candidateToolCalls: [String: [DaemonABInference.ToolCallSummary]]
        private let baselineText: [String: String]
        private let baselineToolCalls: [String: [DaemonABInference.ToolCallSummary]]
        /// When set, `infer` throws on this exampleId (models a mid-A/B failure).
        private let throwOnInferExampleId: String?
        /// When true, `loadedAdapterPath` lies (reports nil) so restore can't confirm.
        private let breakRestoreConfirmation: Bool
        private let candidatePath: String

        init(
            candidatePath: String,
            candidateText: [String: String] = [:],
            candidateToolCalls: [String: [DaemonABInference.ToolCallSummary]] = [:],
            baselineText: [String: String] = [:],
            baselineToolCalls: [String: [DaemonABInference.ToolCallSummary]] = [:],
            throwOnInferExampleId: String? = nil,
            breakRestoreConfirmation: Bool = false
        ) {
            self.candidatePath = candidatePath
            self.candidateText = candidateText
            self.candidateToolCalls = candidateToolCalls
            self.baselineText = baselineText
            self.baselineToolCalls = baselineToolCalls
            self.throwOnInferExampleId = throwOnInferExampleId
            self.breakRestoreConfirmation = breakRestoreConfirmation
        }

        func reload(path: String?) async throws {
            calls.append(.reload(path))
            loaded = path
        }

        func setScale(_ scale: Float) async throws {
            calls.append(.setScale(scale))
        }

        func infer(_ example: DaemonEvalExample) async throws -> DaemonABInference {
            calls.append(.infer(example.id))
            if let id = throwOnInferExampleId, id == example.id {
                throw DaemonABEvaluatorError.evalSuiteUnavailable("forced infer failure")
            }
            let onCandidate = loaded == candidatePath
            let text = onCandidate ? (candidateText[example.id] ?? "") : (baselineText[example.id] ?? "")
            let calls = onCandidate
                ? (candidateToolCalls[example.id] ?? [])
                : (baselineToolCalls[example.id] ?? [])
            return DaemonABInference(text: text, toolCalls: calls)
        }

        func loadedAdapterPath() async throws -> String? {
            calls.append(.status)
            return breakRestoreConfirmation ? nil : loaded
        }

        var recordedCalls: [Call] { calls }
    }

    // MARK: - Helpers

    private func makeTempStore() async throws -> ImprovementStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-dab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ImprovementStore()
        try await store.open(at: dir.appendingPathComponent("improvement.db"))
        return store
    }

    private func makeGgufCandidate() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-gguf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("personal.gguf").path
        try "gguf-bytes".write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// The real bundled suite (SHA-locked) — proves the production resource loads.
    private func loadRealSuite() throws -> DaemonEvalSuite {
        try DaemonEvalSuite.loadBundled()
    }

    /// Build canned answers so the CANDIDATE scores 100% on every example and the
    /// BASELINE scores 0%, yielding a clean measured improvement on all four dims.
    private func perfectCandidateZeroBaseline(
        suite: DaemonEvalSuite
    ) -> (text: [String: String], tools: [String: [DaemonABInference.ToolCallSummary]]) {
        var text: [String: String] = [:]
        var tools: [String: [DaemonABInference.ToolCallSummary]] = [:]
        for ex in suite.examples {
            switch ex.scoring.type {
            case "expectToolCall":
                tools[ex.id] = [.init(name: ex.scoring.name ?? "", argKeys: ex.scoring.requiredArgs ?? [])]
                text[ex.id] = ""
            case "expectNoToolCall":
                text[ex.id] = "Sure, happy to help."
            case "expectLinesPrefixed":
                text[ex.id] = "\(ex.scoring.prefix ?? "STORE:") key = value"
            case "expectJSONKeys":
                let obj = Dictionary(uniqueKeysWithValues: (ex.scoring.keys ?? []).map { ($0, "x") })
                text[ex.id] = (try? String(
                    data: JSONSerialization.data(withJSONObject: obj), encoding: .utf8)) ?? "{}"
            case "expectJSONArray":
                text[ex.id] = "[\"red\",\"yellow\",\"blue\"]"
            case "expectKeywords":
                // Satisfy allOf (every token) + an anyOf token if present.
                let parts = (ex.scoring.allOf ?? []) + [(ex.scoring.anyOf?.first) ?? "ok"]
                text[ex.id] = parts.joined(separator: " ")
            case "expectConcise":
                let parts = (ex.scoring.allOf ?? []) + (ex.scoring.anyOf.map { Array($0.prefix(1)) } ?? [])
                text[ex.id] = parts.isEmpty ? "ok" : parts.joined(separator: " ")
            case "expectNonEmpty":
                text[ex.id] = "Here is a reply."
            default:
                text[ex.id] = ""
            }
        }
        return (text, tools)
    }

    // MARK: - Deterministic scorers (offline)

    func testScorerExpectToolCall() {
        let scoring = DaemonEvalExample.Scoring(
            type: "expectToolCall", name: "get_weather", requiredArgs: ["location"],
            prefix: nil, minLines: nil, keys: nil, minCount: nil, anyOf: nil, forbidden: nil,
            allOf: nil, maxChars: nil, maxLines: nil)
        let hit = DaemonABInference(text: "", toolCalls: [.init(name: "get_weather", argKeys: ["location"])])
        let wrongName = DaemonABInference(text: "", toolCalls: [.init(name: "set_timer", argKeys: ["seconds"])])
        let missingArg = DaemonABInference(text: "", toolCalls: [.init(name: "get_weather", argKeys: [])])
        XCTAssertTrue(DaemonEvalScorer.isCorrect(hit, scoring: scoring))
        XCTAssertFalse(DaemonEvalScorer.isCorrect(wrongName, scoring: scoring))
        XCTAssertFalse(DaemonEvalScorer.isCorrect(missingArg, scoring: scoring),
                       "Missing a required arg key ⇒ not a correct tool call")
    }

    func testScorerExpectNoToolCall() {
        let scoring = DaemonEvalExample.Scoring(
            type: "expectNoToolCall", name: nil, requiredArgs: nil, prefix: nil,
            minLines: nil, keys: nil, minCount: nil, anyOf: nil, forbidden: nil,
            allOf: nil, maxChars: nil, maxLines: nil)
        let answered = DaemonABInference(text: "My favourite colour is teal.", toolCalls: [])
        let calledTool = DaemonABInference(text: "", toolCalls: [.init(name: "get_weather", argKeys: ["location"])])
        let empty = DaemonABInference(text: "", toolCalls: [])
        XCTAssertTrue(DaemonEvalScorer.isCorrect(answered, scoring: scoring))
        XCTAssertFalse(DaemonEvalScorer.isCorrect(calledTool, scoring: scoring),
                       "Calling a tool when none should be ⇒ wrong")
        XCTAssertFalse(DaemonEvalScorer.isCorrect(empty, scoring: scoring),
                       "Empty answer with no tool ⇒ not a correct refusal")
    }

    func testScorerExpectLinesPrefixed() {
        let scoring = DaemonEvalExample.Scoring(
            type: "expectLinesPrefixed", name: nil, requiredArgs: nil, prefix: "STORE:",
            minLines: 1, keys: nil, minCount: nil, anyOf: nil, forbidden: nil,
            allOf: nil, maxChars: nil, maxLines: nil)
        let ok = DaemonABInference(text: "STORE: name = Ada\nSTORE: born = 1815", toolCalls: [])
        let prose = DaemonABInference(text: "Ada Lovelace was born in 1815.", toolCalls: [])
        XCTAssertTrue(DaemonEvalScorer.isCorrect(ok, scoring: scoring))
        XCTAssertFalse(DaemonEvalScorer.isCorrect(prose, scoring: scoring))
    }

    func testScorerExpectJSONKeysAndArray() {
        let keysScoring = DaemonEvalExample.Scoring(
            type: "expectJSONKeys", name: nil, requiredArgs: nil, prefix: nil, minLines: nil,
            keys: ["name", "age"], minCount: nil, anyOf: nil, forbidden: nil,
            allOf: nil, maxChars: nil, maxLines: nil)
        let okObj = DaemonABInference(text: "Here: {\"name\":\"Mira\",\"age\":34}", toolCalls: [])
        let badObj = DaemonABInference(text: "{\"name\":\"Mira\"}", toolCalls: [])
        XCTAssertTrue(DaemonEvalScorer.isCorrect(okObj, scoring: keysScoring),
                      "Embedded JSON object with all keys is extracted + accepted")
        XCTAssertFalse(DaemonEvalScorer.isCorrect(badObj, scoring: keysScoring))

        let arrScoring = DaemonEvalExample.Scoring(
            type: "expectJSONArray", name: nil, requiredArgs: nil, prefix: nil, minLines: nil,
            keys: nil, minCount: 3, anyOf: nil, forbidden: nil,
            allOf: nil, maxChars: nil, maxLines: nil)
        let okArr = DaemonABInference(text: "[\"red\",\"yellow\",\"blue\"]", toolCalls: [])
        let shortArr = DaemonABInference(text: "[\"red\",\"blue\"]", toolCalls: [])
        XCTAssertTrue(DaemonEvalScorer.isCorrect(okArr, scoring: arrScoring))
        XCTAssertFalse(DaemonEvalScorer.isCorrect(shortArr, scoring: arrScoring))
    }

    func testScorerExpectKeywordsWithForbidden() {
        let scoring = DaemonEvalExample.Scoring(
            type: "expectKeywords", name: nil, requiredArgs: nil, prefix: nil, minLines: nil,
            keys: nil, minCount: nil, anyOf: ["tokyo"], forbidden: ["as an ai"],
            allOf: nil, maxChars: nil, maxLines: nil)
        let right = DaemonABInference(text: "The capital is Tokyo.", toolCalls: [])
        let forbidden = DaemonABInference(text: "As an AI, the capital is Tokyo.", toolCalls: [])
        let wrong = DaemonABInference(text: "The capital is Kyoto.", toolCalls: [])
        XCTAssertTrue(DaemonEvalScorer.isCorrect(right, scoring: scoring))
        XCTAssertFalse(DaemonEvalScorer.isCorrect(forbidden, scoring: scoring),
                       "A forbidden phrase fails the example even with the right keyword")
        XCTAssertFalse(DaemonEvalScorer.isCorrect(wrong, scoring: scoring))
    }

    func testAccuracyAndDeltaMath() {
        let acc = DaemonEvalScorer.accuracyByDimension(results: [
            (.toolCalling, true), (.toolCalling, false),   // 0.5
            (.faeCapability, true), (.faeCapability, true), // 1.0
        ])
        XCTAssertEqual(try XCTUnwrap(acc[.toolCalling]), 0.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(acc[.faeCapability]), 1.0, accuracy: 1e-9)

        let delta = DaemonABEvaluator.deltaPercentagePoints(
            baseline: [.toolCalling: 0.5, .faeCapability: 0.5, .assistantFit: 0.5, .serialization: 0.5],
            candidate: [.toolCalling: 1.0, .faeCapability: 0.5, .assistantFit: 0.5, .serialization: 0.5])
        XCTAssertEqual(try XCTUnwrap(delta.toolCallingDelta), 50.0, accuracy: 1e-9,
                       "Candidate − baseline in PERCENTAGE POINTS")
        XCTAssertEqual(try XCTUnwrap(delta.faeCapabilityDelta), 0.0, accuracy: 1e-9)
    }

    func testIncompleteCoverageYieldsNilDelta() {
        // A dimension missing from EITHER side ⇒ nil delta ⇒ W1 gate blocks (incomplete).
        let delta = DaemonABEvaluator.deltaPercentagePoints(
            baseline: [.toolCalling: 0.5],
            candidate: [.toolCalling: 1.0])
        XCTAssertEqual(try XCTUnwrap(delta.toolCallingDelta), 50.0, accuracy: 1e-9)
        XCTAssertNil(delta.faeCapabilityDelta)
        XCTAssertEqual(AdapterGate.decide(delta.measuredDeltas), .blockedNoMeasurement)
    }

    // MARK: - Eval-suite loading (SHA lock + coverage)

    /// The PRODUCTION bundle is v2 (`loadBundled()` SHA-locked): 64 examples, 16 per
    /// dimension, covering all four gate dimensions. v2 replaced v1 as the live gate.
    func testBundledSuiteLoadsAndCoversAllDimensions() throws {
        let suite = try loadRealSuite()
        XCTAssertEqual(suite.suiteVersion, "daemon-ab-v2")
        XCTAssertEqual(suite.examples.count, 64, "v2 is 16 items × 4 dimensions")
        let covered = Set(suite.examples.compactMap { $0.gateDimension })
        XCTAssertEqual(covered, Set(GateDimension.allCases),
                       "The held-out suite must cover every gate dimension")
        var perDim: [GateDimension: Int] = [:]
        for ex in suite.examples {
            if let d = ex.gateDimension { perDim[d, default: 0] += 1 }
        }
        for dim in GateDimension.allCases {
            XCTAssertEqual(perDim[dim], 16, "Each dimension carries 16 items (\(dim.rawValue))")
        }
    }

    // MARK: - v2 scorer arms (expectConcise + allOf)

    /// `expectConcise` passes only for a non-empty answer within the char/line bounds.
    /// This is the deterministic "concise" check v2 leans on — a rambling answer fails.
    func testScorerExpectConciseCharAndLineBounds() {
        let chars = DaemonEvalExample.Scoring(
            type: "expectConcise", name: nil, requiredArgs: nil, prefix: nil, minLines: nil,
            keys: nil, minCount: nil, anyOf: nil, forbidden: nil,
            allOf: nil, maxChars: 20, maxLines: nil)
        XCTAssertTrue(DaemonEvalScorer.isCorrect(
            DaemonABInference(text: "Ready.", toolCalls: []), scoring: chars),
            "Short answer within maxChars passes")
        XCTAssertFalse(DaemonEvalScorer.isCorrect(
            DaemonABInference(text: String(repeating: "x", count: 21), toolCalls: []), scoring: chars),
            "Over maxChars fails")
        XCTAssertFalse(DaemonEvalScorer.isCorrect(
            DaemonABInference(text: "", toolCalls: []), scoring: chars),
            "Empty answer is never concise-correct")

        let lines = DaemonEvalExample.Scoring(
            type: "expectConcise", name: nil, requiredArgs: nil, prefix: nil, minLines: nil,
            keys: nil, minCount: nil, anyOf: nil, forbidden: nil,
            allOf: nil, maxChars: nil, maxLines: 1)
        XCTAssertTrue(DaemonEvalScorer.isCorrect(
            DaemonABInference(text: "One concise line.", toolCalls: []), scoring: lines),
            "Single non-empty line within maxLines passes")
        XCTAssertFalse(DaemonEvalScorer.isCorrect(
            DaemonABInference(text: "Line one.\nLine two.", toolCalls: []), scoring: lines),
            "Two lines exceeds maxLines:1")
    }

    /// `expectConcise` still hard-fails a forbidden phrase and a keyword miss, so a
    /// brief-but-broken or brief-but-wrong answer cannot pass on length alone.
    func testScorerExpectConciseForbiddenAndKeyword() {
        let scoring = DaemonEvalExample.Scoring(
            type: "expectConcise", name: nil, requiredArgs: nil, prefix: nil, minLines: nil,
            keys: nil, minCount: nil, anyOf: ["ready"], forbidden: ["as an ai"],
            allOf: nil, maxChars: 40, maxLines: nil)
        XCTAssertTrue(DaemonEvalScorer.isCorrect(
            DaemonABInference(text: "Ready.", toolCalls: []), scoring: scoring))
        XCTAssertFalse(DaemonEvalScorer.isCorrect(
            DaemonABInference(text: "As an AI, ready.", toolCalls: []), scoring: scoring),
            "Forbidden phrase fails even when short + keyword present")
        XCTAssertFalse(DaemonEvalScorer.isCorrect(
            DaemonABInference(text: "Sure.", toolCalls: []), scoring: scoring),
            "Concise but missing the required keyword fails")
    }

    /// `allOf` requires EVERY listed substring co-present (distinct from `anyOf`'s OR).
    /// This is how v2 forces a discriminating multi-token answer.
    func testScorerExpectKeywordsAllOf() {
        let scoring = DaemonEvalExample.Scoring(
            type: "expectKeywords", name: nil, requiredArgs: nil, prefix: nil, minLines: nil,
            keys: nil, minCount: nil, anyOf: nil, forbidden: nil,
            allOf: ["100", "21", "2"], maxChars: nil, maxLines: nil)
        XCTAssertTrue(DaemonEvalScorer.isCorrect(
            DaemonABInference(text: "100, 21, 11, 9, 2", toolCalls: []), scoring: scoring),
            "All required tokens present ⇒ pass")
        XCTAssertFalse(DaemonEvalScorer.isCorrect(
            DaemonABInference(text: "100, 11, 9", toolCalls: []), scoring: scoring),
            "One required token missing (21, 2) ⇒ fail")
    }

    /// When both `allOf` and `anyOf` are given, an answer passes only with every
    /// allOf token AND at least one anyOf token.
    func testScorerExpectKeywordsAllOfAndAnyOf() {
        let scoring = DaemonEvalExample.Scoring(
            type: "expectKeywords", name: nil, requiredArgs: nil, prefix: nil, minLines: nil,
            keys: nil, minCount: nil, anyOf: ["yes", "sure"], forbidden: nil,
            allOf: ["plan"], maxChars: nil, maxLines: nil)
        XCTAssertTrue(DaemonEvalScorer.isCorrect(
            DaemonABInference(text: "Yes, let's plan it.", toolCalls: []), scoring: scoring))
        XCTAssertFalse(DaemonEvalScorer.isCorrect(
            DaemonABInference(text: "Yes, absolutely.", toolCalls: []), scoring: scoring),
            "Missing the allOf token 'plan' ⇒ fail even with an anyOf hit")
        XCTAssertFalse(DaemonEvalScorer.isCorrect(
            DaemonABInference(text: "I'll plan it.", toolCalls: []), scoring: scoring),
            "Has allOf but no anyOf token ⇒ fail")
    }

    func testSuiteShaMismatchFailsClosed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fae-suite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("suite.json")
        try "{\"suiteVersion\":\"x\",\"examples\":[]}".write(to: url, atomically: true, encoding: .utf8)
        // Lock expects a different SHA ⇒ load must throw, never silently accept drift.
        XCTAssertThrowsError(try DaemonEvalSuite.load(contentsOf: url, expectedSHA256: String(repeating: "0", count: 64))) { error in
            guard case DaemonABEvaluatorError.evalSuiteUnavailable = error else {
                return XCTFail("Expected evalSuiteUnavailable, got \(error)")
            }
        }
    }

    // MARK: - A/B orchestration sequence

    /// Baseline MUST be reloaded first (the DEPLOYED adapter), then the candidate,
    /// then the deployed adapter restored — proving reload-per-phase, not scale-toggle.
    func testABReloadsDeployedThenCandidateThenRestores() async throws {
        let suite = try loadRealSuite()
        let candidate = try makeGgufCandidate()
        let canned = perfectCandidateZeroBaseline(suite: suite)
        let client = FakeDaemonABClient(
            candidatePath: candidate,
            candidateText: canned.text, candidateToolCalls: canned.tools)
        let evaluator = DaemonABEvaluator(client: client, suite: suite)

        let outcome = try await evaluator.evaluate(candidatePath: candidate, baselinePath: "/deployed/adapter.gguf")

        let calls = await client.recordedCalls
        let reloads = calls.compactMap { call -> String?? in
            if case .reload(let p) = call { return .some(p) }
            return nil
        }
        XCTAssertEqual(reloads.first, .some("/deployed/adapter.gguf"),
                       "Phase 1 reloads the DEPLOYED adapter as baseline (NOT scale-0)")
        XCTAssertTrue(reloads.contains(.some(candidate)), "Phase 2 reloads the candidate")
        XCTAssertEqual(reloads.last, .some("/deployed/adapter.gguf"),
                       "Final reload restores the deployed adapter")
        // Candidate beat baseline on every dimension ⇒ a measured pass.
        XCTAssertEqual(AdapterGate.decide(outcome.delta.measuredDeltas), .pass)
        XCTAssertEqual(outcome.baseModelId, "/deployed/adapter.gguf")
        XCTAssertEqual(outcome.evalSuiteVersion, "daemon-ab-v2")
    }

    /// With nothing deployed the baseline is the base model (`reload(nil)`); restore
    /// drops back to base via scale-0 + reload(nil).
    func testABBaselineIsBaseModelWhenNoneDeployed() async throws {
        let suite = try loadRealSuite()
        let candidate = try makeGgufCandidate()
        let canned = perfectCandidateZeroBaseline(suite: suite)
        let client = FakeDaemonABClient(
            candidatePath: candidate, candidateText: canned.text, candidateToolCalls: canned.tools)
        let evaluator = DaemonABEvaluator(client: client, suite: suite)

        let outcome = try await evaluator.evaluate(candidatePath: candidate, baselinePath: nil)

        let calls = await client.recordedCalls
        if case .reload(let first)? = calls.first {
            XCTAssertNil(first, "No deployed adapter ⇒ baseline is the base model (reload nil)")
        } else {
            XCTFail("First call must be a reload")
        }
        XCTAssertTrue(calls.contains(.setScale(0.0)), "Restore to base drops the scale to 0")
        XCTAssertEqual(calls.last, .status, "Restore is confirmed via runtime.status")
        XCTAssertEqual(outcome.baseModelId, "daemon-base-model")
    }

    // MARK: - Restore-on-every-exit (SAFETY property)

    /// An infer failure mid-A/B is fail-closed (throws measurementFailed) AND still
    /// restores the deployed adapter — the daemon is never left on the candidate.
    func testInferFailureRestoresDeployedAndFailsClosed() async throws {
        let suite = try loadRealSuite()
        let candidate = try makeGgufCandidate()
        // Throw on the FIRST example so the failure happens while the candidate (or
        // baseline) is loaded, before the natural restore.
        let firstId = suite.examples[0].id
        let client = FakeDaemonABClient(
            candidatePath: candidate, throwOnInferExampleId: firstId)
        let evaluator = DaemonABEvaluator(client: client, suite: suite)

        do {
            _ = try await evaluator.evaluate(candidatePath: candidate, baselinePath: "/deployed/adapter.gguf")
            XCTFail("A mid-A/B infer failure must throw")
        } catch let error as AdapterEvaluatorError {
            guard case .measurementFailed = error else {
                return XCTFail("Expected measurementFailed, got \(error)")
            }
        }

        let calls = await client.recordedCalls
        let reloads = calls.compactMap { call -> String?? in
            if case .reload(let p) = call { return .some(p) }
            return nil
        }
        XCTAssertEqual(reloads.last, .some("/deployed/adapter.gguf"),
                       "Even on the failure path the deployed adapter is restored last")
    }

    /// If restore cannot be CONFIRMED (status disagrees with what we reloaded), the
    /// evaluator fails closed loudly — a daemon possibly left on the candidate must
    /// never read as a clean measurement.
    func testUnconfirmedRestoreFailsClosed() async throws {
        let suite = try loadRealSuite()
        let candidate = try makeGgufCandidate()
        let canned = perfectCandidateZeroBaseline(suite: suite)
        let client = FakeDaemonABClient(
            candidatePath: candidate, candidateText: canned.text, candidateToolCalls: canned.tools,
            breakRestoreConfirmation: true)
        let evaluator = DaemonABEvaluator(client: client, suite: suite)

        do {
            _ = try await evaluator.evaluate(candidatePath: candidate, baselinePath: "/deployed/adapter.gguf")
            XCTFail("An unconfirmed restore must fail closed")
        } catch let error as AdapterEvaluatorError {
            guard case .measurementFailed(let why) = error else {
                return XCTFail("Expected measurementFailed, got \(error)")
            }
            XCTAssertTrue(why.contains("restore"), "Failure names the restore problem: \(why)")
        }
    }

    /// A measured regression on a dimension does NOT pass the gate (the A/B math +
    /// gate rule agree): candidate worse than baseline ⇒ concern/fail, never pass.
    func testRegressionDoesNotPass() async throws {
        let suite = try loadRealSuite()
        let candidate = try makeGgufCandidate()
        // Baseline scores 100% everywhere; candidate scores 0% ⇒ −100pt regression.
        let perfect = perfectCandidateZeroBaseline(suite: suite)
        let client = FakeDaemonABClient(
            candidatePath: candidate,
            candidateText: [:], candidateToolCalls: [:],     // candidate answers wrong
            baselineText: perfect.text, baselineToolCalls: perfect.tools) // baseline perfect
        let evaluator = DaemonABEvaluator(client: client, suite: suite)

        let outcome = try await evaluator.evaluate(candidatePath: candidate, baselinePath: "/deployed/adapter.gguf")
        XCTAssertEqual(AdapterGate.decide(outcome.delta.measuredDeltas), .fail,
                       "A large regression vs the deployed adapter must fail the gate")
    }

    // MARK: - End-to-end: gguf receipt mints + deploys through the REAL gate

    /// The full W7b path: a real `DaemonABEvaluator` (fake client, perfect candidate)
    /// drives the coordinator's REAL `evaluateViaAdapterEvaluator` → `mintAndStoreGateReceipt`,
    /// and the minted `.gguf` receipt deploys end to end through the W4 gate's REAL
    /// `GateReceiptVerifier`. Proves W7b un-blocks gated GGUF deploys (and only such).
    func testGgufEvaluatorMintedReceiptDeploysThroughRealGate() async throws {
        let store = try await makeTempStore()
        let suite = try loadRealSuite()
        let candidate = try makeGgufCandidate()   // a real on-disk gguf so the digest verifies

        try await store.ensureStateRow()
        var state = try await store.readState()
        state.currentAdapterPath = "/deployed/adapter.gguf"  // the live baseline
        state.pendingAdapterPath = candidate
        state.pendingAdapterKind = "gguf"
        state.pendingCycleId = "w7b-cyc"
        try await store.writeState(state)

        let canned = perfectCandidateZeroBaseline(suite: suite)
        let client = FakeDaemonABClient(
            candidatePath: candidate, candidateText: canned.text, candidateToolCalls: canned.tools)
        let evaluator = DaemonABEvaluator(client: client, suite: suite)

        var patchedPath: String? = "not-called"
        let coordinator = ImprovementCycleCoordinator(store: store)
        await coordinator.setAdapterEvaluator(evaluator)
        await coordinator.setAdapterPatchCallback { path in patchedPath = path }
        await coordinator.setInjectedGateKey(gateTestKey)
        await coordinator.setDaemonTrainingBaseModel("gemma-test")  // gguf lane ⇒ deploy expects .gguf

        // Drive the REAL eval phase + mint (exactly what the cycle runs).
        let result = await coordinator.evaluateViaAdapterEvaluator(adapterPath: candidate, kind: .gguf)
        XCTAssertEqual(AdapterGate.decide(result.delta.measuredDeltas), .pass, "Perfect candidate passes")
        let mint = try XCTUnwrap(result.mint, "A measured pass carries receipt provenance")
        XCTAssertEqual(mint.evaluatorId, "DaemonABEvaluator")
        XCTAssertEqual(mint.kind, .gguf)
        try await coordinator.mintAndStoreGateReceipt(context: mint, measured: result.delta.measuredDeltas)

        // Walk to proposing, approve — performDeploy verifies through the REAL gate.
        for s in [CycleState.collecting, .metaOptimizing, .training, .evaluating, .proposing] {
            try await coordinator.transition(to: s)
        }
        try await coordinator.approveDeployment()

        let deployed = try await store.readState()
        XCTAssertEqual(deployed.currentAdapterPath, candidate, "gguf candidate promoted through the real gate")
        XCTAssertEqual(deployed.previousAdapterPath, "/deployed/adapter.gguf", "Prior deployed is the rollback target")
        XCTAssertNil(deployed.pendingAdapterPath, "Pending cleared after deploy")
        XCTAssertEqual(patchedPath, candidate, "Pipeline notified of the deployed gguf adapter")
        let consumed = try await store.isGateReceiptConsumed(cycleId: "w7b-cyc")
        XCTAssertTrue(consumed, "Evaluator-minted gguf receipt consumed exactly once on deploy")
    }
}
