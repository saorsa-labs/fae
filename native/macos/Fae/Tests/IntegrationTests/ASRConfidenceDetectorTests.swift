import XCTest
@testable import Fae

final class ASRConfidenceDetectorTests: XCTestCase {

    // MARK: - Basic Detection

    func testNoDetectionWithTooFewTranscriptions() async {
        let detector = ASRConfidenceDetector()

        // Only 2 transcriptions — not enough.
        let r1 = await detector.recordAndDetect("Hello Seamus")
        XCTAssertNil(r1)
        let r2 = await detector.recordAndDetect("Hi Shaimus")
        XCTAssertNil(r2)
    }

    func testDetectsDivergentSpellings() async {
        let detector = ASRConfidenceDetector()

        // Feed three transcriptions with divergent spellings of a name.
        _ = await detector.recordAndDetect("Hello Seamus how are you")
        _ = await detector.recordAndDetect("What did Shaimus say about that")
        let result = await detector.recordAndDetect("Tell Shamus I said hello")

        // Should detect divergence.
        XCTAssertNotNil(result)
        if let uncertain = result {
            XCTAssertGreaterThanOrEqual(uncertain.divergenceCount, 2)
            XCTAssertFalse(uncertain.variants.isEmpty)
        }
    }

    func testNoDetectionForConsistentSpellings() async {
        let detector = ASRConfidenceDetector()

        // Same spelling each time — no divergence.
        _ = await detector.recordAndDetect("Hello David")
        _ = await detector.recordAndDetect("David is here")
        let result = await detector.recordAndDetect("Tell David hello")

        XCTAssertNil(result)
    }

    // MARK: - Prompt Limits

    func testMaxOnePromptPerConversation() async {
        let detector = ASRConfidenceDetector()

        // First divergence detected.
        _ = await detector.recordAndDetect("Hello Seamus")
        _ = await detector.recordAndDetect("Hi Shaimus")
        let first = await detector.recordAndDetect("Tell Shamus hello")

        // Feed more divergent names — should not trigger a second prompt.
        _ = await detector.recordAndDetect("Meeting with Caoimhe")
        _ = await detector.recordAndDetect("Call Keeva please")
        let second = await detector.recordAndDetect("Ask Kiva about it")

        if first != nil {
            // If the first detection fired, the second should be nil (max 1 per conversation).
            XCTAssertNil(second)
        }
    }

    func testResetAllowsNewDetection() async {
        let detector = ASRConfidenceDetector()

        // Trigger first detection.
        _ = await detector.recordAndDetect("Hello Seamus")
        _ = await detector.recordAndDetect("Hi Shaimus")
        _ = await detector.recordAndDetect("Tell Shamus hello")

        // Reset for new conversation.
        await detector.resetForNewConversation()

        // Should be able to detect again.
        let canPrompt = await detector.canPrompt
        XCTAssertTrue(canPrompt)
    }

    // MARK: - Word Extraction

    func testIgnoresCommonWords() async {
        let detector = ASRConfidenceDetector()

        // Common words like "The" and "And" should not trigger detection
        // even if they appear in different contexts.
        _ = await detector.recordAndDetect("The meeting was good")
        _ = await detector.recordAndDetect("And the call went well")
        let result = await detector.recordAndDetect("But the review is pending")

        XCTAssertNil(result)
    }

    func testIgnoresShortWords() async {
        let detector = ASRConfidenceDetector()

        // Words shorter than 3 chars should not be tracked.
        _ = await detector.recordAndDetect("Hi Al")
        _ = await detector.recordAndDetect("Hey Al")
        let result = await detector.recordAndDetect("See Al later")

        XCTAssertNil(result)
    }

    // MARK: - Typed Correction Integration

    func testTypedCorrectionFeedsLexicon() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("asr_conf_test_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let lexicon = PersonalLexicon(fileURL: url)
        let dvc = DynamicVocabularyCorrector()

        // Simulate what PipelineCoordinator.applyTypedSpellingCorrection does.
        let correctSpelling = "Seamus"
        let variants = ["Shaimus", "Shamus"]

        await lexicon.upsert(
            canonical: correctSpelling,
            variants: variants.filter { $0.lowercased() != correctSpelling.lowercased() },
            source: "typed_correction"
        )
        await lexicon.save()

        for variant in variants where variant.lowercased() != correctSpelling.lowercased() {
            await dvc.addCorrectionPair(wrong: variant, correct: correctSpelling)
        }

        // Verify the DVC now corrects the wrong spellings.
        let corrected1 = await dvc.correct("I spoke to Shaimus yesterday")
        XCTAssertEqual(corrected1, "I spoke to Seamus yesterday")

        let corrected2 = await dvc.correct("Shamus called me")
        XCTAssertEqual(corrected2, "Seamus called me")

        // Verify the lexicon was saved.
        let lexicon2 = PersonalLexicon(fileURL: url)
        await lexicon2.load()
        let entry = await lexicon2.lookup(canonical: "Seamus")
        XCTAssertNotNil(entry)
        let hasShamus = entry?.variants.contains("Shamus") ?? false
        XCTAssertTrue(hasShamus)
    }
}
