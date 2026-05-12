import XCTest
@testable import Fae

// MARK: - DimensionScores Tests

final class DimensionScoresTests: XCTestCase {

    func testImprovementComputesPositiveDelta() {
        let baseline = DimensionScores(toolCalling: 0.80, faeCapability: 0.70, assistantFit: 0.60, serialization: 0.90)
        let after = DimensionScores(toolCalling: 0.85, faeCapability: 0.75, assistantFit: 0.65, serialization: 0.95)
        let delta = after.improvement(over: baseline)
        XCTAssertEqual(delta.toolCalling!, 0.05, accuracy: 0.001)
        XCTAssertEqual(delta.faeCapability!, 0.05, accuracy: 0.001)
        XCTAssertEqual(delta.assistantFit!, 0.05, accuracy: 0.001)
        XCTAssertEqual(delta.serialization!, 0.05, accuracy: 0.001)
    }

    func testImprovementComputesNegativeDelta() {
        let baseline = DimensionScores(toolCalling: 0.90, faeCapability: 0.80, assistantFit: 0.70, serialization: 0.60)
        let after = DimensionScores(toolCalling: 0.85, faeCapability: 0.75, assistantFit: 0.65, serialization: 0.55)
        let delta = after.improvement(over: baseline)
        XCTAssertEqual(delta.toolCalling!, -0.05, accuracy: 0.001)
    }

    func testAnyRegressionDetectsLargeRegression() {
        let baseline = DimensionScores(toolCalling: 0.90, faeCapability: 0.80, assistantFit: 0.70, serialization: 0.60)
        let after = DimensionScores(toolCalling: 0.84, faeCapability: 0.80, assistantFit: 0.70, serialization: 0.60)
        XCTAssertTrue(after.anyRegression(over: baseline, threshold: 0.05))
    }

    func testAnyRegressionIgnoresSmallRegression() {
        let baseline = DimensionScores(toolCalling: 0.90, faeCapability: 0.80, assistantFit: 0.70, serialization: 0.60)
        let after = DimensionScores(toolCalling: 0.87, faeCapability: 0.80, assistantFit: 0.70, serialization: 0.60)
        XCTAssertFalse(after.anyRegression(over: baseline, threshold: 0.05))
    }

    func testImprovedDetectsTargetDimensionGain() {
        let baseline = DimensionScores(toolCalling: 0.80, faeCapability: 0.70, assistantFit: 0.60, serialization: 0.90)
        let after = DimensionScores(toolCalling: 0.82, faeCapability: 0.70, assistantFit: 0.60, serialization: 0.90)
        XCTAssertTrue(after.improved(dimension: .toolCalling, over: baseline, threshold: 0.01))
        XCTAssertFalse(after.improved(dimension: .faeCapability, over: baseline, threshold: 0.01))
    }

    func testNilDimensionsHandledGracefully() {
        let baseline = DimensionScores(toolCalling: nil, faeCapability: 0.80, assistantFit: nil, serialization: 0.60)
        let after = DimensionScores(toolCalling: nil, faeCapability: 0.85, assistantFit: nil, serialization: 0.55)
        let delta = after.improvement(over: baseline)
        XCTAssertNil(delta.toolCalling)
        XCTAssertEqual(delta.faeCapability!, 0.05, accuracy: 0.001)
        XCTAssertNil(delta.assistantFit)
    }

    func testFromTrainingBenchmarkResult() {
        let result = TrainingBenchmarkResult(
            toolCallingAccuracy: 0.90,
            faeCapabilityAccuracy: 0.85,
            assistantFitAccuracy: 0.80,
            serializationAccuracy: 0.75,
            avgThroughputTPS: 42.0,
            modelId: "test",
            adapterPath: nil
        )
        let scores = DimensionScores.from(result)
        XCTAssertEqual(scores.toolCalling, 0.90)
        XCTAssertEqual(scores.faeCapability, 0.85)
        XCTAssertEqual(scores.assistantFit, 0.80)
        XCTAssertEqual(scores.serialization, 0.75)
    }
}

// MARK: - MetaOptHypothesisGenerator Tests

final class MetaOptHypothesisGeneratorTests: XCTestCase {

    private func makeFeedbackEvent(
        signalType: String,
        userInput: String? = nil,
        assistantOutput: String? = nil
    ) -> FeedbackEvent {
        FeedbackEvent(
            id: nil,
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            signalType: signalType,
            turnFingerprint: UUID().uuidString,
            userInput: userInput,
            assistantOutput: assistantOutput,
            sentimentScore: nil,
            consumed: false
        )
    }

    func testNoHypothesesWithInsufficientEvents() {
        let events = [makeFeedbackEvent(signalType: "praise")]
        let hypotheses = MetaOptHypothesisGenerator.generate(
            from: events,
            currentDirective: nil,
            currentTemperature: 0.7,
            currentMaxRecall: 6
        )
        XCTAssertTrue(hypotheses.isEmpty)
    }

    func testToolCorrectionsGenerateTemperatureHypothesis() {
        let events = (0..<5).map { _ in
            makeFeedbackEvent(
                signalType: "correction",
                assistantOutput: "I used the calendar tool but got the wrong result"
            )
        }
        let hypotheses = MetaOptHypothesisGenerator.generate(
            from: events,
            currentDirective: nil,
            currentTemperature: 0.7,
            currentMaxRecall: 6
        )
        let configHypothesis = hypotheses.first { $0.surface == .configKnob }
        XCTAssertNotNil(configHypothesis)
        if case .configAdjustment(let key, _, _) = configHypothesis?.change {
            XCTAssertEqual(key, "llm.temperature")
        } else {
            XCTFail("Expected configAdjustment")
        }
    }

    func testReAsksGenerateRecallAndDirectiveHypotheses() {
        let events = (0..<5).map { _ in makeFeedbackEvent(signalType: "re_ask") }
        let hypotheses = MetaOptHypothesisGenerator.generate(
            from: events,
            currentDirective: nil,
            currentTemperature: 0.7,
            currentMaxRecall: 6
        )
        XCTAssertTrue(hypotheses.count >= 2, "Expected at least 2 hypotheses (config + directive)")
        let surfaces = Set(hypotheses.map(\.surface))
        XCTAssertTrue(surfaces.contains(.configKnob))
        XCTAssertTrue(surfaces.contains(.directive))
    }

    func testDirectiveSizeLimitPreventsAmendment() {
        let longDirective = String(repeating: "x", count: 3950)
        let events = (0..<5).map { _ in makeFeedbackEvent(signalType: "interruption") }
        let hypotheses = MetaOptHypothesisGenerator.generate(
            from: events,
            currentDirective: longDirective,
            currentTemperature: 0.7,
            currentMaxRecall: 6
        )
        let directiveHypotheses = hypotheses.filter { $0.surface == .directive }
        XCTAssertTrue(directiveHypotheses.isEmpty, "Should not generate directive amendment when near size limit")
    }

    func testDuplicateDirectiveKeywordsSkipped() {
        let existingDirective = "Keep responses concise and brief."
        let events = (0..<5).map { _ in makeFeedbackEvent(signalType: "interruption") }
        let hypotheses = MetaOptHypothesisGenerator.generate(
            from: events,
            currentDirective: existingDirective,
            currentTemperature: 0.7,
            currentMaxRecall: 6
        )
        let directiveHypotheses = hypotheses.filter { $0.surface == .directive }
        XCTAssertTrue(directiveHypotheses.isEmpty, "Should skip directive when keywords already present")
    }

    func testLowTemperatureSkipsTemperatureHypothesis() {
        let events = (0..<5).map { _ in
            makeFeedbackEvent(signalType: "correction", assistantOutput: "tool_call failed")
        }
        let hypotheses = MetaOptHypothesisGenerator.generate(
            from: events,
            currentDirective: nil,
            currentTemperature: 0.3,
            currentMaxRecall: 6
        )
        let tempHypotheses = hypotheses.filter {
            if case .configAdjustment(let key, _, _) = $0.change { return key == "llm.temperature" }
            return false
        }
        XCTAssertTrue(tempHypotheses.isEmpty, "Should not reduce temperature below 0.4")
    }

    func testHypothesesSortedByEvidenceCount() {
        var events: [FeedbackEvent] = []
        // 3 corrections (tool-related)
        events += (0..<3).map { _ in
            makeFeedbackEvent(signalType: "correction", assistantOutput: "calendar tool")
        }
        // 5 re-asks
        events += (0..<5).map { _ in makeFeedbackEvent(signalType: "re_ask") }
        // 4 interruptions
        events += (0..<4).map { _ in makeFeedbackEvent(signalType: "interruption") }

        let hypotheses = MetaOptHypothesisGenerator.generate(
            from: events,
            currentDirective: nil,
            currentTemperature: 0.7,
            currentMaxRecall: 6
        )
        // Should be sorted descending by evidence count.
        for i in 0..<(hypotheses.count - 1) {
            XCTAssertGreaterThanOrEqual(hypotheses[i].evidenceCount, hypotheses[i + 1].evidenceCount)
        }
    }
}

// MARK: - MetaOptBudget Tests

final class MetaOptBudgetTests: XCTestCase {

    func testStandardBudgetHasReasonableDefaults() {
        let budget = MetaOptBudget.standard
        XCTAssertEqual(budget.maxBenchmarkRuns, 10)
        XCTAssertEqual(budget.maxWallClockSeconds, 1800)
        XCTAssertEqual(budget.maxConsecutiveDiscards, 3)
        XCTAssertEqual(budget.minImprovementThreshold, 0.01)
        XCTAssertEqual(budget.regressionThreshold, 0.05)
    }
}

// MARK: - ConfigBound Tests

final class ConfigBoundTests: XCTestCase {

    func testAllBoundsHaveValidRanges() {
        for bound in ConfigBound.all {
            XCTAssertLessThan(bound.min, bound.max, "Invalid bounds for \(bound.key)")
            XCTAssertGreaterThan(bound.step, 0, "Step must be positive for \(bound.key)")
        }
    }

    func testTemperatureBoundExists() {
        let temp = ConfigBound.all.first { $0.key == "llm.temperature" }
        XCTAssertNotNil(temp)
        XCTAssertEqual(temp?.min, 0.1)
        XCTAssertEqual(temp?.max, 1.0)
    }

    func testRecallBoundExists() {
        let recall = ConfigBound.all.first { $0.key == "memory.maxRecallResults" }
        XCTAssertNotNil(recall)
        XCTAssertEqual(recall?.min, 2)
        XCTAssertEqual(recall?.max, 12)
    }
}

// MARK: - CycleState Tests

final class CycleStateMetaOptTests: XCTestCase {

    func testMetaOptimizingStateExists() {
        let state = CycleState.metaOptimizing
        XCTAssertEqual(state.rawValue, "metaOptimizing")
    }

    func testCollectingCanTransitionToMetaOptimizing() {
        XCTAssertTrue(CycleState.collecting.validSuccessors.contains(.metaOptimizing))
    }

    func testMetaOptimizingCanTransitionToTrainingOrIdle() {
        let successors = CycleState.metaOptimizing.validSuccessors
        XCTAssertTrue(successors.contains(.training))
        XCTAssertTrue(successors.contains(.idle))
        XCTAssertEqual(successors.count, 2)
    }

    func testCollectingNoLongerTransitionsDirectlyToTraining() {
        // collecting now goes through metaOptimizing, not directly to training.
        XCTAssertFalse(CycleState.collecting.validSuccessors.contains(.training))
    }
}

// MARK: - ImprovementStore Meta-Opt Tests

final class ImprovementStoreMetaOptTests: XCTestCase {

    private var store: ImprovementStore!
    private var tempURL: URL!

    override func setUp() async throws {
        store = ImprovementStore()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_meta_opt_\(UUID().uuidString).db")
        try await store.open(at: tempURL)
    }

    override func tearDown() async throws {
        await store.close()
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testMetaOptFieldsInStateDefault() async throws {
        try await store.ensureStateRow()
        let state = try await store.readState()
        XCTAssertEqual(state.metaOptKeptTotal, 0)
        XCTAssertEqual(state.metaOptTestedTotal, 0)
        XCTAssertNil(state.metaOptLastRunAt)
        XCTAssertEqual(state.metaOptConsecutiveNoImprovement, 0)
    }

    func testMetaOptFieldsRoundTrip() async throws {
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.metaOptKeptTotal = 5
        state.metaOptTestedTotal = 15
        state.metaOptLastRunAt = "2026-04-04T03:00:00Z"
        state.metaOptConsecutiveNoImprovement = 2
        try await store.writeState(state)

        let read = try await store.readState()
        XCTAssertEqual(read.metaOptKeptTotal, 5)
        XCTAssertEqual(read.metaOptTestedTotal, 15)
        XCTAssertEqual(read.metaOptLastRunAt, "2026-04-04T03:00:00Z")
        XCTAssertEqual(read.metaOptConsecutiveNoImprovement, 2)
    }

    func testInsertAndReadMetaOptResult() async throws {
        try await store.insertMetaOptResult(
            cycleNumber: 1,
            hypothesisId: "test-uuid",
            surface: "directive",
            description: "Test hypothesis",
            targetDimension: "toolCalling",
            beforeScores: "{\"toolCalling\":0.8}",
            afterScores: "{\"toolCalling\":0.85}",
            delta: "{\"toolCalling\":0.05}",
            kept: true,
            reason: "improvement",
            createdAt: "2026-04-04T03:05:00Z"
        )

        let results = try await store.recentMetaOptResults(limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0]["surface"] as? String, "directive")
        XCTAssertEqual(results[0]["kept"] as? Bool, true)
        XCTAssertEqual(results[0]["reason"] as? String, "improvement")
    }
}

// MARK: - Phase 2: MetaOptSkillGenerator Tests

final class MetaOptSkillGeneratorTests: XCTestCase {

    private func makeEvent(
        signalType: String,
        userInput: String? = nil,
        assistantOutput: String? = nil
    ) -> FeedbackEvent {
        FeedbackEvent(
            id: nil,
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            signalType: signalType,
            turnFingerprint: UUID().uuidString,
            userInput: userInput,
            assistantOutput: assistantOutput,
            sentimentScore: nil,
            consumed: false
        )
    }

    // MARK: - Template-Based Generation

    func testTemplatesHaveValidCategories() {
        for template in MetaOptSkillGenerator.templates {
            XCTAssertFalse(template.category.isEmpty, "Template category must not be empty")
            XCTAssertFalse(template.skillName.isEmpty, "Template skill name must not be empty")
            XCTAssertFalse(template.description.isEmpty, "Template description must not be empty")
            XCTAssertTrue(
                template.body.count <= MetaOptSkillGenerator.maxSkillBodySize,
                "Template '\(template.skillName)' body exceeds max size (\(template.body.count) > \(MetaOptSkillGenerator.maxSkillBodySize))"
            )
        }
    }

    func testTemplateSkillNamesAreUnique() {
        let names = MetaOptSkillGenerator.templates.map(\.skillName)
        let unique = Set(names)
        XCTAssertEqual(names.count, unique.count, "Duplicate template skill names found")
    }

    func testGeneratesHypothesisFromCapabilityGap() {
        let gap = CapabilityGap(
            id: 1,
            detectedAt: "2026-04-04T00:00:00Z",
            category: "tool_selection",
            description: "User frequently asks to use specific tools",
            evidenceCount: 5,
            priority: "high",
            addressed: false
        )

        let hypotheses = MetaOptSkillGenerator.generateHypotheses(
            from: [gap],
            events: [],
            existingSkillNames: []
        )

        XCTAssertEqual(hypotheses.count, 1)
        XCTAssertEqual(hypotheses[0].surface, .skill)
        XCTAssertEqual(hypotheses[0].targetDimension, .toolCalling)

        if case .skillCreation(let name, _, _) = hypotheses[0].change {
            XCTAssertTrue(name.hasPrefix(MetaOptSkillGenerator.autoSkillPrefix))
            XCTAssertEqual(name, "auto-smart-tool-routing")
        } else {
            XCTFail("Expected skillCreation change")
        }
    }

    func testSkipsGapWithInsufficientEvidence() {
        let gap = CapabilityGap(
            id: 1,
            detectedAt: "2026-04-04T00:00:00Z",
            category: "tool_selection",
            description: "Occasional tool issue",
            evidenceCount: 1,  // Below minimum of 3
            priority: "low",
            addressed: false
        )

        let hypotheses = MetaOptSkillGenerator.generateHypotheses(
            from: [gap],
            events: [],
            existingSkillNames: []
        )
        XCTAssertTrue(hypotheses.isEmpty)
    }

    func testSkipsAlreadyExistingSkill() {
        let gap = CapabilityGap(
            id: 1,
            detectedAt: "2026-04-04T00:00:00Z",
            category: "tool_selection",
            description: "Tool routing issues",
            evidenceCount: 5,
            priority: "high",
            addressed: false
        )

        let hypotheses = MetaOptSkillGenerator.generateHypotheses(
            from: [gap],
            events: [],
            existingSkillNames: ["auto-smart-tool-routing"]  // Already exists
        )
        XCTAssertTrue(hypotheses.isEmpty, "Should skip when skill already exists")
    }

    func testSkipsAddressedGap() {
        let gap = CapabilityGap(
            id: 1,
            detectedAt: "2026-04-04T00:00:00Z",
            category: "tool_selection",
            description: "Tool routing issues",
            evidenceCount: 5,
            priority: "high",
            addressed: true  // Already addressed
        )

        let hypotheses = MetaOptSkillGenerator.generateHypotheses(
            from: [gap],
            events: [],
            existingSkillNames: []
        )
        XCTAssertTrue(hypotheses.isEmpty, "Should skip addressed gaps")
    }

    // MARK: - Feedback-Based Generation

    func testGeneratesToolSkillFromCorrections() {
        let events = (0..<5).map { _ in
            makeEvent(signalType: "correction", assistantOutput: "calendar tool returned error")
        }

        let hypotheses = MetaOptSkillGenerator.generateHypotheses(
            from: [],
            events: events,
            existingSkillNames: []
        )

        let toolSkill = hypotheses.first {
            if case .skillCreation(let name, _, _) = $0.change {
                return name == "auto-smart-tool-routing"
            }
            return false
        }
        XCTAssertNotNil(toolSkill, "Should generate tool routing skill from corrections")
    }

    func testGeneratesSerializationSkillFromCorrections() {
        let events = (0..<4).map { _ in
            makeEvent(signalType: "correction", userInput: "The JSON output was invalid")
        }

        let hypotheses = MetaOptSkillGenerator.generateHypotheses(
            from: [],
            events: events,
            existingSkillNames: []
        )

        let fmtSkill = hypotheses.first {
            if case .skillCreation(let name, _, _) = $0.change {
                return name == "auto-precise-formatting"
            }
            return false
        }
        XCTAssertNotNil(fmtSkill, "Should generate formatting skill from serialization corrections")
    }

    func testNoDuplicateSkillHypotheses() {
        // Gap-based and feedback-based could produce the same skill.
        let gap = CapabilityGap(
            id: 1,
            detectedAt: "2026-04-04T00:00:00Z",
            category: "tool_selection",
            description: "Tool issues",
            evidenceCount: 5,
            priority: "high",
            addressed: false
        )
        let events = (0..<5).map { _ in
            makeEvent(signalType: "correction", assistantOutput: "tool_call failed")
        }

        let hypotheses = MetaOptSkillGenerator.generateHypotheses(
            from: [gap],
            events: events,
            existingSkillNames: []
        )

        let toolRouting = hypotheses.filter {
            if case .skillCreation(let name, _, _) = $0.change {
                return name == "auto-smart-tool-routing"
            }
            return false
        }
        XCTAssertEqual(toolRouting.count, 1, "Should not generate duplicate skill hypotheses")
    }

    func testHypothesesSortedByEvidence() {
        let gaps = [
            CapabilityGap(
                id: 1, detectedAt: "2026-04-04T00:00:00Z",
                category: "tool_selection", description: "Tool issues",
                evidenceCount: 3, priority: "medium", addressed: false
            ),
            CapabilityGap(
                id: 2, detectedAt: "2026-04-04T00:00:00Z",
                category: "structured_output", description: "Format issues",
                evidenceCount: 8, priority: "high", addressed: false
            ),
        ]

        let hypotheses = MetaOptSkillGenerator.generateHypotheses(
            from: gaps,
            events: [],
            existingSkillNames: []
        )

        guard hypotheses.count >= 2 else {
            XCTFail("Expected at least 2 hypotheses")
            return
        }
        XCTAssertGreaterThanOrEqual(hypotheses[0].evidenceCount, hypotheses[1].evidenceCount)
    }

    // MARK: - MetaOptChange.skillCreation

    func testSkillCreationChangeProperties() {
        let change = MetaOptChange.skillCreation(
            name: "auto-test-skill",
            description: "A test skill",
            body: "# Test\nDo the thing."
        )

        if case .skillCreation(let name, let desc, let body) = change {
            XCTAssertEqual(name, "auto-test-skill")
            XCTAssertEqual(desc, "A test skill")
            XCTAssertTrue(body.contains("# Test"))
        } else {
            XCTFail("Expected skillCreation")
        }
    }

    // MARK: - All Gap Categories Have Templates

    func testAllTemplateCategoriesCoverCommonGaps() {
        let templateCategories = Set(MetaOptSkillGenerator.templates.map(\.category))
        // These are the categories we expect to be covered.
        let expectedCategories: Set<String> = [
            "tool_selection",
            "structured_output",
            "memory_discipline",
            "instruction_following",
            "conversation_quality",
        ]
        for expected in expectedCategories {
            XCTAssertTrue(
                templateCategories.contains(expected),
                "Missing template for gap category '\(expected)'"
            )
        }
    }

    func testUnknownGapCategoryIsSkipped() {
        let gap = CapabilityGap(
            id: 1, detectedAt: "2026-04-04T00:00:00Z",
            category: "quantum_computing", // No template for this
            description: "Quantum issues",
            evidenceCount: 10, priority: "high", addressed: false
        )

        let hypotheses = MetaOptSkillGenerator.generateHypotheses(
            from: [gap],
            events: [],
            existingSkillNames: []
        )
        XCTAssertTrue(hypotheses.isEmpty, "Should skip gaps with no matching template")
    }
}

// MARK: - Phase 3: MetaOptMemorySeedGenerator Tests

final class MetaOptMemorySeedGeneratorTests: XCTestCase {

    private func makeEvent(
        signalType: String,
        userInput: String? = nil,
        assistantOutput: String? = nil
    ) -> FeedbackEvent {
        FeedbackEvent(
            id: nil,
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            signalType: signalType,
            turnFingerprint: UUID().uuidString,
            userInput: userInput,
            assistantOutput: assistantOutput,
            sentimentScore: nil,
            consumed: false
        )
    }

    func testTemplatesHaveValidContent() {
        for template in MetaOptMemorySeedGenerator.templates {
            XCTAssertFalse(template.pattern.isEmpty)
            XCTAssertFalse(template.text.isEmpty)
            XCTAssertTrue(template.tags.contains(MetaOptMemorySeedGenerator.seedTag),
                          "Template '\(template.pattern)' missing seedTag")
        }
    }

    func testTemplatePatternsAreUnique() {
        let patterns = MetaOptMemorySeedGenerator.templates.map(\.pattern)
        XCTAssertEqual(patterns.count, Set(patterns).count, "Duplicate template patterns")
    }

    func testNoHypothesesWithInsufficientEvents() {
        let events = [makeEvent(signalType: "correction", assistantOutput: "tool error")]
        let hypotheses = MetaOptMemorySeedGenerator.generateHypotheses(
            from: events,
            existingSeedCount: 0
        )
        XCTAssertTrue(hypotheses.isEmpty)
    }

    func testToolCorrectionsGenerateToolSeed() {
        let events = (0..<5).map { _ in
            makeEvent(signalType: "correction", assistantOutput: "calendar tool failed")
        }
        let hypotheses = MetaOptMemorySeedGenerator.generateHypotheses(
            from: events,
            existingSeedCount: 0
        )
        let toolSeed = hypotheses.first { $0.surface == .memorySeed && $0.targetDimension == .toolCalling }
        XCTAssertNotNil(toolSeed, "Should generate tool preference seed")
    }

    func testInterruptionsGenerateBrevitySeed() {
        let events = (0..<5).map { _ in makeEvent(signalType: "interruption") }
        let hypotheses = MetaOptMemorySeedGenerator.generateHypotheses(
            from: events,
            existingSeedCount: 0
        )
        let brevitySeed = hypotheses.first {
            if case .memorySeedInsertion(let text, _) = $0.change {
                return text.contains("concise")
            }
            return false
        }
        XCTAssertNotNil(brevitySeed, "Should generate brevity seed from interruptions")
    }

    func testMaxSeedCapRespected() {
        // Already at max seeds — should generate nothing.
        let events = (0..<10).map { _ in makeEvent(signalType: "interruption") }
        let hypotheses = MetaOptMemorySeedGenerator.generateHypotheses(
            from: events,
            existingSeedCount: MetaOptMemorySeedGenerator.maxActiveSeeds
        )
        XCTAssertTrue(hypotheses.isEmpty, "Should not exceed max active seeds")
    }

    func testRemainingSlotsCap() {
        // 8 existing seeds, max 10, so only 2 slots available.
        var events: [FeedbackEvent] = []
        events += (0..<5).map { _ in makeEvent(signalType: "interruption") }
        events += (0..<5).map { _ in makeEvent(signalType: "abandonment") }
        events += (0..<5).map { _ in
            makeEvent(signalType: "correction", assistantOutput: "tool error")
        }

        let hypotheses = MetaOptMemorySeedGenerator.generateHypotheses(
            from: events,
            existingSeedCount: 8
        )
        XCTAssertLessThanOrEqual(hypotheses.count, 2, "Should cap at remaining slots")
    }

    func testHypothesesSortedByEvidence() {
        var events: [FeedbackEvent] = []
        events += (0..<4).map { _ in makeEvent(signalType: "interruption") }      // 4 events
        events += (0..<8).map { _ in makeEvent(signalType: "abandonment") }        // 8 events

        let hypotheses = MetaOptMemorySeedGenerator.generateHypotheses(
            from: events,
            existingSeedCount: 0
        )
        guard hypotheses.count >= 2 else {
            XCTFail("Expected at least 2 hypotheses")
            return
        }
        XCTAssertGreaterThanOrEqual(hypotheses[0].evidenceCount, hypotheses[1].evidenceCount)
    }

    func testMemorySeedChangeType() {
        let change = MetaOptChange.memorySeedInsertion(
            text: "Test seed text",
            tags: ["meta_opt_seed", "test"]
        )
        if case .memorySeedInsertion(let text, let tags) = change {
            XCTAssertEqual(text, "Test seed text")
            XCTAssertEqual(tags.count, 2)
            XCTAssertTrue(tags.contains("meta_opt_seed"))
        } else {
            XCTFail("Expected memorySeedInsertion")
        }
    }

    func testStaleAfterSecsIs30Days() {
        let expected: UInt64 = 30 * 24 * 3600
        XCTAssertEqual(MetaOptMemorySeedGenerator.staleAfterSecs, expected)
    }
}

// MARK: - MetaOptNarrator Tests

final class MetaOptNarratorTests: XCTestCase {

    private func makeResult(
        surface: MetaOptSurface,
        description: String,
        kept: Bool
    ) -> MetaOptResult {
        MetaOptResult(
            hypothesisId: UUID(),
            surface: surface,
            description: description,
            targetDimension: .faeCapability,
            beforeScores: .empty,
            afterScores: .empty,
            delta: .empty,
            kept: kept,
            reason: kept ? "improvement" : "regression",
            timestamp: Date()
        )
    }

    // MARK: - Narrative Generation

    func testNarrateReturnsNilForNoKeptChanges() {
        let summary = MetaOptSummary(
            hypothesesTested: 3,
            keptCount: 0,
            discardedCount: 3,
            totalBenchmarkRuns: 4,
            wallClockSeconds: 120,
            results: [
                makeResult(surface: .directive, description: "Test", kept: false),
            ]
        )
        XCTAssertNil(MetaOptNarrator.narrate(summary))
    }

    func testNarrateReturnsSingleChangeNarrative() {
        let summary = MetaOptSummary(
            hypothesesTested: 1,
            keptCount: 1,
            discardedCount: 0,
            totalBenchmarkRuns: 2,
            wallClockSeconds: 60,
            results: [
                makeResult(surface: .directive, description: "Frequent interruptions — add brevity directive", kept: true),
            ]
        )
        let narrative = MetaOptNarrator.narrate(summary)
        XCTAssertNotNil(narrative)
        XCTAssertTrue(narrative!.contains("small adjustment"), "Single change should say 'small adjustment'")
        XCTAssertTrue(narrative!.contains("undo"), "Should always offer undo")
    }

    func testNarrateReturnsMultiChangeNarrative() {
        let summary = MetaOptSummary(
            hypothesesTested: 3,
            keptCount: 2,
            discardedCount: 1,
            totalBenchmarkRuns: 4,
            wallClockSeconds: 180,
            results: [
                makeResult(surface: .directive, description: "Frequent interruptions — add brevity directive", kept: true),
                makeResult(surface: .configKnob, description: "Reduce temperature from 0.7 to 0.4", kept: true),
                makeResult(surface: .directive, description: "Test", kept: false),
            ]
        )
        let narrative = MetaOptNarrator.narrate(summary)
        XCTAssertNotNil(narrative)
        XCTAssertTrue(narrative!.contains("couple of adjustments"), "Multiple changes should say 'couple'")
    }

    func testNarrateContainsNoTechnicalJargon() {
        let summary = MetaOptSummary(
            hypothesesTested: 2,
            keptCount: 2,
            discardedCount: 0,
            totalBenchmarkRuns: 3,
            wallClockSeconds: 90,
            results: [
                makeResult(surface: .configKnob, description: "Reduce temperature from 0.7 to 0.4", kept: true),
                makeResult(surface: .skill, description: "Create auto-smart-tool-routing skill", kept: true),
            ]
        )
        let narrative = MetaOptNarrator.narrate(summary)!
        // Should NOT contain technical terms.
        XCTAssertFalse(narrative.contains("temperature"), "Should not mention 'temperature'")
        XCTAssertFalse(narrative.contains("benchmark"), "Should not mention 'benchmark'")
        XCTAssertFalse(narrative.contains("hypothesis"), "Should not mention 'hypothesis'")
        XCTAssertFalse(narrative.contains("dimension"), "Should not mention 'dimension'")
        XCTAssertFalse(narrative.contains("EvalDelta"), "Should not mention 'EvalDelta'")
    }

    // MARK: - Surface Descriptions

    func testDirectiveDescriptionForBrevity() {
        let result = makeResult(
            surface: .directive,
            description: "Frequent interruptions — add brevity directive",
            kept: true
        )
        let entry = MetaOptNarrator.timelineEntry(result)
        XCTAssertTrue(entry.contains("shorter") || entry.contains("concise") || entry.contains("brief"),
                      "Brevity directive should mention shorter/concise: \(entry)")
    }

    func testConfigDescriptionForTemperature() {
        let result = makeResult(
            surface: .configKnob,
            description: "Reduce temperature from 0.7 to 0.4",
            kept: true
        )
        let entry = MetaOptNarrator.timelineEntry(result)
        XCTAssertFalse(entry.contains("temperature"), "Should not mention 'temperature'")
        XCTAssertTrue(entry.contains("careful") || entry.contains("precise"),
                      "Should describe effect, not mechanism: \(entry)")
    }

    func testSkillDescriptionForToolRouting() {
        let result = makeResult(
            surface: .skill,
            description: "Create auto-smart-tool-routing skill for capability gap",
            kept: true
        )
        let entry = MetaOptNarrator.timelineEntry(result)
        XCTAssertTrue(entry.contains("routine") || entry.contains("file") || entry.contains("local"),
                      "Tool routing should mention practical effect: \(entry)")
    }

    func testMemorySeedDescription() {
        let result = makeResult(
            surface: .memorySeed,
            description: "Seed memory: tool_preference_local",
            kept: true
        )
        let entry = MetaOptNarrator.timelineEntry(result)
        XCTAssertTrue(entry.contains("mental note") || entry.contains("note"),
                      "Memory seed should use 'note' language: \(entry)")
    }

    func testDiscardedEntryDescription() {
        let result = makeResult(surface: .directive, description: "Test change", kept: false)
        let entry = MetaOptNarrator.timelineEntry(result)
        XCTAssertTrue(entry.contains("didn't help") || entry.contains("reverted"),
                      "Discarded should explain it was reverted: \(entry)")
    }

    // MARK: - Timeline Builder

    func testBuildTimelineFromLogEntries() {
        let entries: [[String: Any]] = [
            [
                "surface": "directive",
                "description": "Add brevity directive",
                "created_at": "2026-04-05T03:00:00Z",
                "kept": true,
                "hypothesis_id": "test-1",
            ],
            [
                "surface": "configKnob",
                "description": "Reduce temperature",
                "created_at": "2026-04-05T03:01:00Z",
                "kept": false,
                "hypothesis_id": "test-2",
            ],
        ]
        let timeline = MetaOptNarrator.buildTimeline(from: entries)
        XCTAssertEqual(timeline.count, 2)
        XCTAssertEqual(timeline[0].surface, .directive)
        XCTAssertTrue(timeline[0].kept)
        XCTAssertEqual(timeline[1].surface, .configKnob)
        XCTAssertFalse(timeline[1].kept)
    }

    // MARK: - Surface Display Names

    func testSurfaceDisplayNames() {
        XCTAssertEqual(MetaOptNarrator.surfaceDisplayName(.directive), "Habit")
        XCTAssertEqual(MetaOptNarrator.surfaceDisplayName(.configKnob), "Thinking")
        XCTAssertEqual(MetaOptNarrator.surfaceDisplayName(.skill), "Routine")
        XCTAssertEqual(MetaOptNarrator.surfaceDisplayName(.memorySeed), "Mental Note")
    }

    func testSurfaceIconsAreValidSFSymbols() {
        for surface in [MetaOptSurface.directive, .configKnob, .skill, .memorySeed] {
            let icon = MetaOptNarrator.surfaceIcon(surface)
            XCTAssertFalse(icon.isEmpty, "Icon should not be empty for \(surface)")
        }
    }

    // MARK: - Rollback Descriptions

    func testRollbackDescriptionForTemperature() {
        let desc = MetaOptNarrator.describeRollback("Reduce temperature from 0.7 to 0.4")
        XCTAssertTrue(desc.contains("reverted"), "Should confirm revert: \(desc)")
        XCTAssertFalse(desc.contains("temperature"), "Should not mention temperature: \(desc)")
    }

    func testRollbackDescriptionForBrevity() {
        let desc = MetaOptNarrator.describeRollback("Add concise brevity directive")
        XCTAssertTrue(desc.contains("undone") || desc.contains("Done"), "Should confirm: \(desc)")
    }

    func testRollbackDescriptionForSkill() {
        let desc = MetaOptNarrator.describeRollback("Create auto-smart-tool-routing skill")
        XCTAssertTrue(desc.contains("routine") || desc.contains("removed"), "Should mention removal: \(desc)")
    }

    func testRollbackDescriptionFallback() {
        let desc = MetaOptNarrator.describeRollback("Some unknown change")
        XCTAssertTrue(desc.contains("undone") || desc.contains("Done"), "Should confirm: \(desc)")
    }
}
