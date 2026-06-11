import XCTest
@testable import Fae

final class MetaOptTypesTests: XCTestCase {

    // MARK: - EvalDimension

    func testEvalDimensionCaseIterable() {
        XCTAssertEqual(EvalDimension.allCases.count, 4)
        XCTAssertTrue(EvalDimension.allCases.contains(.toolCalling))
        XCTAssertTrue(EvalDimension.allCases.contains(.faeCapability))
        XCTAssertTrue(EvalDimension.allCases.contains(.assistantFit))
        XCTAssertTrue(EvalDimension.allCases.contains(.serialization))
    }

    func testEvalDimensionRawValue() {
        XCTAssertEqual(EvalDimension.toolCalling.rawValue, "toolCalling")
        XCTAssertEqual(EvalDimension.faeCapability.rawValue, "faeCapability")
        XCTAssertEqual(EvalDimension.assistantFit.rawValue, "assistantFit")
        XCTAssertEqual(EvalDimension.serialization.rawValue, "serialization")
    }

    func testEvalDimensionCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for dim in EvalDimension.allCases {
            let data = try encoder.encode(dim)
            let decoded = try decoder.decode(EvalDimension.self, from: data)
            XCTAssertEqual(decoded, dim)
        }
    }

    // MARK: - DimensionScores

    func testDimensionScoresImprovement() {
        let baseline = DimensionScores(toolCalling: 0.7, faeCapability: 0.8, assistantFit: 0.6, serialization: 0.9)
        let after = DimensionScores(toolCalling: 0.8, faeCapability: 0.75, assistantFit: 0.65, serialization: 0.85)

        let delta = after.improvement(over: baseline)
        // Double subtraction carries rounding error — compare with accuracy.
        XCTAssertEqual(delta.toolCalling ?? .nan, 0.1, accuracy: 1e-9)
        XCTAssertEqual(delta.faeCapability ?? .nan, -0.05, accuracy: 1e-9)
        XCTAssertEqual(delta.assistantFit ?? .nan, 0.05, accuracy: 1e-9)
        XCTAssertEqual(delta.serialization ?? .nan, -0.05, accuracy: 1e-9)
    }

    func testDimensionScoresImprovementWithNil() {
        let baseline = DimensionScores(toolCalling: nil, faeCapability: 0.8, assistantFit: nil, serialization: 0.9)
        let after = DimensionScores(toolCalling: nil, faeCapability: 0.9, assistantFit: 0.7, serialization: 0.9)

        let delta = after.improvement(over: baseline)
        XCTAssertNil(delta.toolCalling) // both nil → nil
        XCTAssertEqual(delta.faeCapability ?? .nan, 0.1, accuracy: 1e-9)
        XCTAssertNil(delta.assistantFit) // one nil → nil
        XCTAssertEqual(delta.serialization ?? .nan, 0.0, accuracy: 1e-9)
    }

    func testDimensionScoresAnyRegression() {
        let baseline = DimensionScores(toolCalling: 0.8, faeCapability: 0.9, assistantFit: 0.7, serialization: 0.85)
        // toolCalling dropped by 0.1 (> 0.05 threshold)
        let regressed = DimensionScores(toolCalling: 0.7, faeCapability: 0.92, assistantFit: 0.72, serialization: 0.88)
        XCTAssertTrue(regressed.anyRegression(over: baseline, threshold: 0.05))
    }

    func testDimensionScoresNoRegression() {
        let baseline = DimensionScores(toolCalling: 0.8, faeCapability: 0.9, assistantFit: 0.7, serialization: 0.85)
        // All improved or unchanged
        let improved = DimensionScores(toolCalling: 0.82, faeCapability: 0.91, assistantFit: 0.71, serialization: 0.86)
        XCTAssertFalse(improved.anyRegression(over: baseline, threshold: 0.05))
    }

    func testDimensionScoresSmallRegressionBelowThreshold() {
        let baseline = DimensionScores(toolCalling: 0.8, faeCapability: 0.9, assistantFit: 0.7, serialization: 0.85)
        // toolCalling dropped by only 0.03 (< 0.05 threshold)
        let slightDrop = DimensionScores(toolCalling: 0.77, faeCapability: 0.91, assistantFit: 0.71, serialization: 0.86)
        XCTAssertFalse(slightDrop.anyRegression(over: baseline, threshold: 0.05))
    }

    func testDimensionScoresImproved() {
        let baseline = DimensionScores(toolCalling: 0.7, faeCapability: 0.8, assistantFit: 0.6, serialization: 0.9)
        let after = DimensionScores(toolCalling: 0.75, faeCapability: 0.8, assistantFit: 0.6, serialization: 0.9)

        XCTAssertTrue(after.improved(dimension: .toolCalling, over: baseline, threshold: 0.01))
        XCTAssertFalse(after.improved(dimension: .faeCapability, over: baseline, threshold: 0.01))
    }

    func testDimensionScoresImprovedWithNilDelta() {
        let baseline = DimensionScores(toolCalling: nil, faeCapability: 0.8, assistantFit: 0.6, serialization: 0.9)
        let after = DimensionScores(toolCalling: nil, faeCapability: 0.85, assistantFit: 0.6, serialization: 0.9)

        // Nil delta treated as 0, which is < threshold → not improved
        XCTAssertFalse(after.improved(dimension: .toolCalling, over: baseline, threshold: 0.01))
    }

    func testDimensionScoresEmpty() {
        let empty = DimensionScores.empty
        XCTAssertNil(empty.toolCalling)
        XCTAssertNil(empty.faeCapability)
        XCTAssertNil(empty.assistantFit)
        XCTAssertNil(empty.serialization)
    }

    func testDimensionScoresCodable() throws {
        let scores = DimensionScores(toolCalling: 0.85, faeCapability: 0.92, assistantFit: nil, serialization: 0.78)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(scores)
        let decoded = try decoder.decode(DimensionScores.self, from: data)
        XCTAssertEqual(decoded.toolCalling, scores.toolCalling)
        XCTAssertEqual(decoded.faeCapability, scores.faeCapability)
        XCTAssertEqual(decoded.assistantFit, scores.assistantFit)
        XCTAssertEqual(decoded.serialization, scores.serialization)
    }

    // MARK: - MetaOptSurface

    func testMetaOptSurfaceRawValues() {
        XCTAssertEqual(MetaOptSurface.directive.rawValue, "directive")
        XCTAssertEqual(MetaOptSurface.configKnob.rawValue, "configKnob")
        XCTAssertEqual(MetaOptSurface.skill.rawValue, "skill")
        XCTAssertEqual(MetaOptSurface.memorySeed.rawValue, "memorySeed")
    }

    func testMetaOptSurfaceFromRawValue() {
        XCTAssertEqual(MetaOptSurface(rawValue: "directive"), .directive)
        XCTAssertEqual(MetaOptSurface(rawValue: "configKnob"), .configKnob)
        XCTAssertEqual(MetaOptSurface(rawValue: "skill"), .skill)
        XCTAssertEqual(MetaOptSurface(rawValue: "memorySeed"), .memorySeed)
        XCTAssertNil(MetaOptSurface(rawValue: "unknown"))
    }

    // MARK: - MetaOptChange

    func testMetaOptChangeDirectiveAmendment() {
        let change = MetaOptChange.directiveAmendment("Be more concise")
        switch change {
        case .directiveAmendment(let text):
            XCTAssertEqual(text, "Be more concise")
        default:
            XCTFail("Expected directiveAmendment")
        }
    }

    func testMetaOptChangeConfigAdjustment() {
        let change = MetaOptChange.configAdjustment(key: "llm.temperature", oldValue: "0.7", newValue: "0.5")
        switch change {
        case .configAdjustment(let key, let old, let new):
            XCTAssertEqual(key, "llm.temperature")
            XCTAssertEqual(old, "0.7")
            XCTAssertEqual(new, "0.5")
        default:
            XCTFail("Expected configAdjustment")
        }
    }

    func testMetaOptChangeSkillCreation() {
        let change = MetaOptChange.skillCreation(name: "test-skill", description: "A test skill", body: "# Test\nBody here")
        switch change {
        case .skillCreation(let name, let desc, let body):
            XCTAssertEqual(name, "test-skill")
            XCTAssertEqual(desc, "A test skill")
            XCTAssertEqual(body, "# Test\nBody here")
        default:
            XCTFail("Expected skillCreation")
        }
    }

    func testMetaOptChangeMemorySeedInsertion() {
        let change = MetaOptChange.memorySeedInsertion(text: "User prefers concise answers", tags: ["brevity"])
        switch change {
        case .memorySeedInsertion(let text, let tags):
            XCTAssertEqual(text, "User prefers concise answers")
            XCTAssertEqual(tags, ["brevity"])
        default:
            XCTFail("Expected memorySeedInsertion")
        }
    }

    // MARK: - MetaOptDecision

    func testMetaOptDecisionKeep() {
        let decision: MetaOptDecision = .keep(reason: "improvement")
        switch decision {
        case .keep(let reason):
            XCTAssertEqual(reason, "improvement")
        case .discard:
            XCTFail("Expected keep")
        }
    }

    func testMetaOptDecisionDiscard() {
        let decision: MetaOptDecision = .discard(reason: "regression")
        switch decision {
        case .keep:
            XCTFail("Expected discard")
        case .discard(let reason):
            XCTAssertEqual(reason, "regression")
        }
    }

    // MARK: - MetaOptBudget

    func testMetaOptBudgetStandard() {
        let budget = MetaOptBudget.standard
        XCTAssertEqual(budget.maxBenchmarkRuns, 10)
        XCTAssertEqual(budget.maxWallClockSeconds, 1800)
        XCTAssertEqual(budget.maxConsecutiveDiscards, 3)
        XCTAssertEqual(budget.minImprovementThreshold, 0.01)
        XCTAssertEqual(budget.regressionThreshold, 0.05)
    }

    func testMetaOptBudgetCustom() {
        let budget = MetaOptBudget(
            maxBenchmarkRuns: 5,
            maxWallClockSeconds: 600,
            maxConsecutiveDiscards: 2,
            minImprovementThreshold: 0.02,
            regressionThreshold: 0.03
        )
        XCTAssertEqual(budget.maxBenchmarkRuns, 5)
        XCTAssertEqual(budget.maxWallClockSeconds, 600)
        XCTAssertEqual(budget.maxConsecutiveDiscards, 2)
        XCTAssertEqual(budget.minImprovementThreshold, 0.02)
        XCTAssertEqual(budget.regressionThreshold, 0.03)
    }

    // MARK: - ConfigBound

    func testConfigBoundAll() {
        let bounds = ConfigBound.all
        XCTAssertFalse(bounds.isEmpty)
        XCTAssertTrue(bounds.contains { $0.key == "llm.temperature" })
        XCTAssertTrue(bounds.contains { $0.key == "memory.maxRecallResults" })
    }

    func testConfigBoundTemperature() {
        let tempBound = ConfigBound.all.first { $0.key == "llm.temperature" }!
        XCTAssertEqual(tempBound.min, 0.1)
        XCTAssertEqual(tempBound.max, 1.0)
        XCTAssertEqual(tempBound.step, 0.1)
        XCTAssertEqual(tempBound.targetDimension, .toolCalling)
    }

    func testConfigBoundMaxRecall() {
        let recallBound = ConfigBound.all.first { $0.key == "memory.maxRecallResults" }!
        XCTAssertEqual(recallBound.min, 2)
        XCTAssertEqual(recallBound.max, 12)
        XCTAssertEqual(recallBound.step, 1)
        XCTAssertEqual(recallBound.targetDimension, .faeCapability)
    }

    // MARK: - MetaOptSummary

    func testMetaOptSummary() {
        let summary = MetaOptSummary(
            hypothesesTested: 5,
            keptCount: 2,
            discardedCount: 3,
            totalBenchmarkRuns: 6,
            wallClockSeconds: 120.5,
            results: []
        )
        XCTAssertEqual(summary.hypothesesTested, 5)
        XCTAssertEqual(summary.keptCount, 2)
        XCTAssertEqual(summary.discardedCount, 3)
        XCTAssertEqual(summary.totalBenchmarkRuns, 6)
        XCTAssertEqual(summary.wallClockSeconds, 120.5)
    }

    // MARK: - MetaOptHypothesis

    func testMetaOptHypothesis() {
        let hypothesis = MetaOptHypothesis(
            id: UUID(),
            surface: .configKnob,
            description: "Reduce temperature",
            targetDimension: .toolCalling,
            change: .configAdjustment(key: "llm.temperature", oldValue: "0.7", newValue: "0.5"),
            evidenceCount: 5
        )
        XCTAssertEqual(hypothesis.surface, .configKnob)
        XCTAssertEqual(hypothesis.targetDimension, .toolCalling)
        XCTAssertEqual(hypothesis.evidenceCount, 5)
    }

    // MARK: - MetaOptError

    func testMetaOptErrorCases() {
        let err1: MetaOptError = .benchmarkNotAvailable
        let err2: MetaOptError = .trainingBridgeNotAvailable
        let err3: MetaOptError = .directiveIOError("file not found")
        let err4: MetaOptError = .configChangeError("invalid value")
        let err5: MetaOptError = .skillError("creation failed")
        let err6: MetaOptError = .memorySeedError("insert failed")

        _ = err1 // Verify all cases compile
        _ = err2
        _ = err3
        _ = err4
        _ = err5
        _ = err6
    }

    // MARK: - MetaOptNarrator

    func testMetaOptNarrateNoChanges() {
        let summary = MetaOptSummary(
            hypothesesTested: 0, keptCount: 0, discardedCount: 0,
            totalBenchmarkRuns: 0, wallClockSeconds: 0, results: []
        )
        XCTAssertNil(MetaOptNarrator.narrate(summary))
    }

    func testMetaOptNarrateAllDiscarded() {
        let result = MetaOptResult(
            hypothesisId: UUID(), surface: .configKnob, description: "test",
            targetDimension: .toolCalling, beforeScores: .empty, afterScores: .empty,
            delta: .empty, kept: false, reason: "neutral", timestamp: Date()
        )
        let summary = MetaOptSummary(
            hypothesesTested: 1, keptCount: 0, discardedCount: 1,
            totalBenchmarkRuns: 1, wallClockSeconds: 10, results: [result]
        )
        XCTAssertNil(MetaOptNarrator.narrate(summary))
    }

    func testMetaOptNarrateSingleChange() {
        let result = MetaOptResult(
            hypothesisId: UUID(), surface: .directive, description: "Be more concise",
            targetDimension: .toolCalling, beforeScores: .empty, afterScores: .empty,
            delta: .empty, kept: true, reason: "improvement", timestamp: Date()
        )
        let summary = MetaOptSummary(
            hypothesesTested: 1, keptCount: 1, discardedCount: 0,
            totalBenchmarkRuns: 1, wallClockSeconds: 10, results: [result]
        )
        let narrative = MetaOptNarrator.narrate(summary)
        XCTAssertNotNil(narrative)
        XCTAssertTrue(narrative!.contains("small adjustment"))
        XCTAssertTrue(narrative!.contains("undo"))
    }

    func testMetaOptNarrateMultipleChanges() {
        let results = (1...3).map { _ in
            MetaOptResult(
                hypothesisId: UUID(), surface: .configKnob, description: "test",
                targetDimension: .toolCalling, beforeScores: .empty, afterScores: .empty,
                delta: .empty, kept: true, reason: "improvement", timestamp: Date()
            )
        }
        let summary = MetaOptSummary(
            hypothesesTested: 3, keptCount: 3, discardedCount: 0,
            totalBenchmarkRuns: 3, wallClockSeconds: 30, results: results
        )
        let narrative = MetaOptNarrator.narrate(summary)
        XCTAssertNotNil(narrative)
        XCTAssertTrue(narrative!.contains("couple of adjustments"))
    }

    func testMetaOptTimelineEntryKept() {
        let result = MetaOptResult(
            hypothesisId: UUID(), surface: .configKnob, description: "temperature",
            targetDimension: .toolCalling, beforeScores: .empty, afterScores: .empty,
            delta: .empty, kept: true, reason: "improvement", timestamp: Date()
        )
        let entry = MetaOptNarrator.timelineEntry(result)
        XCTAssertFalse(entry.isEmpty)
    }

    func testMetaOptTimelineEntryDiscarded() {
        let result = MetaOptResult(
            hypothesisId: UUID(), surface: .configKnob, description: "test",
            targetDimension: .toolCalling, beforeScores: .empty, afterScores: .empty,
            delta: .empty, kept: false, reason: "neutral", timestamp: Date()
        )
        let entry = MetaOptNarrator.timelineEntry(result)
        XCTAssertTrue(entry.contains("reverted") || entry.contains("didn't help"))
    }

    func testMetaOptNoChangesNarrative() {
        XCTAssertNil(MetaOptNarrator.noChangesNarrative())
    }

    func testMetaOptDescribeRollbackTemperature() {
        let msg = MetaOptNarrator.describeRollback("Reduce temperature from 0.7 to 0.5")
        XCTAssertTrue(msg.contains("reverted") || msg.contains("undone"))
    }

    func testMetaOptDescribeRollbackBrevity() {
        let msg = MetaOptNarrator.describeRollback("Add conciseness directive for interruptions")
        XCTAssertTrue(msg.contains("brevity") || msg.contains("detailed"))
    }

    func testMetaOptDescribeRollbackSkill() {
        let msg = MetaOptNarrator.describeRollback("Create tool-routing skill")
        XCTAssertTrue(msg.contains("routine"))
    }

    func testMetaOptDescribeRollbackMemory() {
        let msg = MetaOptNarrator.describeRollback("Seed memory note about preferences")
        XCTAssertTrue(msg.contains("mental note") || msg.contains("forgotten"))
    }

    func testMetaOptDescribeRollbackGeneric() {
        let msg = MetaOptNarrator.describeRollback("Some unknown change happened")
        XCTAssertTrue(msg.contains("undone") || msg.contains("reverted"))
    }

    // MARK: - MetaOptNarrator TimelineItem

    func testMetaOptSurfaceDisplayName() {
        XCTAssertEqual(MetaOptNarrator.surfaceDisplayName(.directive), "Habit")
        XCTAssertEqual(MetaOptNarrator.surfaceDisplayName(.configKnob), "Thinking")
        XCTAssertEqual(MetaOptNarrator.surfaceDisplayName(.skill), "Routine")
        XCTAssertEqual(MetaOptNarrator.surfaceDisplayName(.memorySeed), "Mental Note")
    }

    func testMetaOptSurfaceIcon() {
        XCTAssertEqual(MetaOptNarrator.surfaceIcon(.directive), "brain.head.profile")
        XCTAssertEqual(MetaOptNarrator.surfaceIcon(.configKnob), "slider.horizontal.3")
        XCTAssertEqual(MetaOptNarrator.surfaceIcon(.skill), "sparkles")
        XCTAssertEqual(MetaOptNarrator.surfaceIcon(.memorySeed), "note.text")
    }

    func testMetaOptTimelineItem() {
        let item = MetaOptNarrator.TimelineItem(
            id: "test-id",
            date: Date(),
            description: "Test entry",
            surface: .directive,
            kept: true,
            hypothesisId: "hyp-123"
        )
        XCTAssertEqual(item.id, "test-id")
        XCTAssertEqual(item.surface, .directive)
        XCTAssertTrue(item.kept)
        XCTAssertEqual(item.hypothesisId, "hyp-123")
    }

    // MARK: - Decision logic (from MetaOptimizer)

    func testDecisionRegressionDiscard() {
        let baseline = DimensionScores(toolCalling: 0.8, faeCapability: 0.9, assistantFit: 0.7, serialization: 0.85)
        let after = DimensionScores(toolCalling: 0.7, faeCapability: 0.92, assistantFit: 0.72, serialization: 0.88)
        // toolCalling dropped by 0.1 > 0.05 threshold → regression
        XCTAssertTrue(after.anyRegression(over: baseline, threshold: MetaOptBudget.standard.regressionThreshold))
    }

    func testDecisionImprovementKeep() {
        let baseline = DimensionScores(toolCalling: 0.7, faeCapability: 0.8, assistantFit: 0.6, serialization: 0.9)
        let after = DimensionScores(toolCalling: 0.75, faeCapability: 0.82, assistantFit: 0.62, serialization: 0.91)

        // No regression
        XCTAssertFalse(after.anyRegression(over: baseline, threshold: MetaOptBudget.standard.regressionThreshold))
        // toolCalling improved by 0.05 >= 0.01 threshold
        XCTAssertTrue(after.improved(dimension: .toolCalling, over: baseline, threshold: MetaOptBudget.standard.minImprovementThreshold))
    }

    func testDecisionNeutralDiscard() {
        let baseline = DimensionScores(toolCalling: 0.7, faeCapability: 0.8, assistantFit: 0.6, serialization: 0.9)
        let after = DimensionScores(toolCalling: 0.705, faeCapability: 0.801, assistantFit: 0.602, serialization: 0.899)

        // No regression (all changes < 0.05)
        XCTAssertFalse(after.anyRegression(over: baseline, threshold: MetaOptBudget.standard.regressionThreshold))
        // toolCalling improved by only 0.005 < 0.01 threshold → neutral
        XCTAssertFalse(after.improved(dimension: .toolCalling, over: baseline, threshold: MetaOptBudget.standard.minImprovementThreshold))
    }
}
