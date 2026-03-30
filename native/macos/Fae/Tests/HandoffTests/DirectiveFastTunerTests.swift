import XCTest
@testable import Fae

final class DirectiveFastTunerTests: XCTestCase {

    // MARK: - Helpers

    private func makeTuner() -> DirectiveFastTuner {
        DirectiveFastTuner()
    }

    private func makeEvents(signalType: String, count: Int) -> [FeedbackEvent] {
        (0..<count).map { i in
            FeedbackEvent(
                id: Int64(i + 1),
                recordedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(i))),
                signalType: signalType,
                turnFingerprint: "fp-\(signalType)-\(i)",
                userInput: "user input \(i)",
                assistantOutput: "assistant output \(i)",
                sentimentScore: nil,
                consumed: false
            )
        }
    }

    /// Configure the tuner with capture closures.
    private func configureCapture(
        tuner: DirectiveFastTuner,
        initialContent: String? = nil,
        writeCapture: @escaping (String, Bool) -> Void = { _, _ in }
    ) async {
        await tuner.setDirectiveReader { initialContent }
        await tuner.setDirectiveWriter { content, append in writeCapture(content, append) }
    }

    // MARK: - No Feedback Data

    func testRunFastTuningThrowsWhenNoFeedbackLoader() async throws {
        let tuner = makeTuner()
        // No feedbackLoader set → should throw noFeedbackData.
        do {
            _ = try await tuner.runFastTuning()
            XCTFail("Expected noFeedbackData error")
        } catch let error as DirectiveFastTunerError {
            if case .noFeedbackData = error {
                // Expected.
            } else {
                XCTFail("Expected .noFeedbackData, got \(error)")
            }
        }
    }

    func testRunFastTuningThrowsWhenInsufficientEvents() async throws {
        let tuner = makeTuner()
        await tuner.setFeedbackLoader { self.makeEvents(signalType: "correction", count: 5) }
        do {
            _ = try await tuner.runFastTuning()
            XCTFail("Expected noFeedbackData error for insufficient events")
        } catch let error as DirectiveFastTunerError {
            if case .noFeedbackData = error {
                // Expected.
            } else {
                XCTFail("Expected .noFeedbackData, got \(error)")
            }
        }
    }

    // MARK: - Pattern Detection: Re-Ask

    func testReAskPatternDetected() async {
        let tuner = makeTuner()
        let events = makeEvents(signalType: "re_ask", count: 3)
        let patterns = await tuner.detectPatterns(from: events)
        let reaskPattern = patterns.first { $0.type == .verbosityTooHigh }
        XCTAssertNotNil(reaskPattern, "Should detect verbosityTooHigh from 3+ re_ask events")
        XCTAssertGreaterThanOrEqual(reaskPattern?.evidenceCount ?? 0, 2)
    }

    func testOneReAskDoesNotTriggerPattern() async {
        let tuner = makeTuner()
        let events = makeEvents(signalType: "re_ask", count: 1)
        let patterns = await tuner.detectPatterns(from: events)
        let reaskPattern = patterns.first { $0.type == .verbosityTooHigh }
        XCTAssertNil(reaskPattern, "Single re_ask should not trigger pattern")
    }

    // MARK: - Pattern Detection: Interruptions

    func testInterruptionPatternDetected() async {
        let tuner = makeTuner()
        let events = makeEvents(signalType: "interruption", count: 3)
        let patterns = await tuner.detectPatterns(from: events)
        let interruptPattern = patterns.first { $0.type == .verbosityTooHigh && $0.evidenceCount == 3 }
        XCTAssertNotNil(interruptPattern, "3+ interruptions should detect verbosityTooHigh pattern")
    }

    // MARK: - Pattern Detection: Corrections

    func testCorrectionPatternDetected() async {
        let tuner = makeTuner()
        let events = makeEvents(signalType: "correction", count: 5)
        let patterns = await tuner.detectPatterns(from: events)
        let correctionPattern = patterns.first { $0.type == .systematicMisunderstanding }
        XCTAssertNotNil(correctionPattern)
        XCTAssertEqual(correctionPattern?.evidenceCount, 5)
    }

    func testTwoCorrectionsDoesNotTriggerPattern() async {
        let tuner = makeTuner()
        let events = makeEvents(signalType: "correction", count: 2)
        let patterns = await tuner.detectPatterns(from: events)
        let correctionPattern = patterns.first { $0.type == .systematicMisunderstanding }
        XCTAssertNil(correctionPattern, "2 corrections below minimum of 3")
    }

    // MARK: - Pattern Detection: Abandonment

    func testAbandonmentPatternDetected() async {
        let tuner = makeTuner()
        let events = makeEvents(signalType: "abandonment", count: 2)
        let patterns = await tuner.detectPatterns(from: events)
        let abandonPattern = patterns.first { $0.type == .toneMismatch }
        XCTAssertNotNil(abandonPattern, "2+ abandonments should detect toneMismatch pattern")
    }

    // MARK: - Amendment Application

    func testHighConfidencePatternAppliesAmendment() async throws {
        let tuner = makeTuner()
        var writtenContent = ""
        var appendMode = false

        // Load enough re_ask events to trigger high-confidence pattern.
        await tuner.setFeedbackLoader { self.makeEvents(signalType: "re_ask", count: 10) }
        await tuner.setDirectiveReader { nil }
        await tuner.setDirectiveWriter { content, append in
            writtenContent += content
            appendMode = append
        }

        let result = try await tuner.runFastTuning()

        XCTAssertFalse(result.appliedAmendments.isEmpty, "Should apply at least one amendment")
        XCTAssertFalse(writtenContent.isEmpty, "Directive writer should be called")
        XCTAssertTrue(appendMode, "Amendments should append to directive")
    }

    func testLowConfidencePatternNotApplied() async throws {
        let tuner = makeTuner()
        var writeCallCount = 0

        // 2 re_asks → confidence = 2/10 = 0.2, below 0.70 threshold.
        let events = makeEvents(signalType: "re_ask", count: 2)
            + makeEvents(signalType: "praise", count: 8) // Pad to meet minimum
        await tuner.setFeedbackLoader { events }
        await tuner.setDirectiveReader { nil }
        await tuner.setDirectiveWriter { _, _ in writeCallCount += 1 }

        let result = try await tuner.runFastTuning()

        // The re_ask pattern is detected but confidence is too low OR evidence count too low.
        XCTAssertTrue(result.appliedAmendments.isEmpty || writeCallCount == 0,
                      "Low confidence/evidence patterns should not be applied")
    }

    // MARK: - Previous Directive Capture

    func testPreviousDirectiveCapturedForRollback() async throws {
        let tuner = makeTuner()
        let originalDirective = "Original directive content."

        await tuner.setFeedbackLoader { self.makeEvents(signalType: "re_ask", count: 15) }
        await tuner.setDirectiveReader { originalDirective }
        await tuner.setDirectiveWriter { _, _ in } // no-op

        let result = try await tuner.runFastTuning()
        XCTAssertEqual(result.previousDirective, originalDirective)
    }

    func testPreviousDirectiveNilWhenNoDirective() async throws {
        let tuner = makeTuner()

        await tuner.setFeedbackLoader { self.makeEvents(signalType: "correction", count: 10) }
        await tuner.setDirectiveReader { nil }
        await tuner.setDirectiveWriter { _, _ in }

        let result = try await tuner.runFastTuning()
        XCTAssertNil(result.previousDirective)
    }

    // MARK: - Rollback

    func testRollbackOverwritesDirective() async throws {
        let tuner = makeTuner()
        var writtenContent = ""
        var appendMode = true // Start as true to verify rollback sets false.

        await tuner.setDirectiveWriter { content, append in
            writtenContent = content
            appendMode = append
        }

        let originalContent = "Restore this content."
        try await tuner.rollback(to: originalContent)

        XCTAssertEqual(writtenContent, originalContent)
        XCTAssertFalse(appendMode, "Rollback must overwrite (not append)")
    }

    func testRollbackWithNilClearsDirective() async throws {
        let tuner = makeTuner()
        var writtenContent = "unchanged"

        await tuner.setDirectiveWriter { content, _ in writtenContent = content }

        try await tuner.rollback(to: nil)
        XCTAssertEqual(writtenContent, "", "Rollback with nil should write empty string")
    }

    // MARK: - TuningResult

    func testTuningResultHasTunedAtTimestamp() async throws {
        let tuner = makeTuner()
        await tuner.setFeedbackLoader { self.makeEvents(signalType: "re_ask", count: 10) }
        await tuner.setDirectiveReader { nil }
        await tuner.setDirectiveWriter { _, _ in }

        let result = try await tuner.runFastTuning()
        XCTAssertFalse(result.tunedAt.isEmpty)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: result.tunedAt))
    }
}
