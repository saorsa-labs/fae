import XCTest
@testable import Fae

final class VocabularyLearningTests: XCTestCase {

    // MARK: - addCorrectionPair

    func testAddCorrectionPairDirectMapping() async {
        let corrector = DynamicVocabularyCorrector()
        await corrector.addCorrectionPair(wrong: "allison", correct: "Alice")

        let count = await corrector.correctionCount
        XCTAssertGreaterThan(count, 0, "Should have correction entries after addCorrectionPair")

        // The direct mapping should correct "allison" → "Alice".
        let result = await corrector.correct("Hey allison, how are you?")
        XCTAssertEqual(result, "Hey Alice, how are you?")
    }

    func testAddCorrectionPairGeneratesPhoneticVariants() async {
        let corrector = DynamicVocabularyCorrector()
        await corrector.addCorrectionPair(wrong: nil, correct: "TestUser")

        let count = await corrector.correctionCount
        // Should have phonetic variants even without a wrong name.
        XCTAssertGreaterThan(count, 0, "Should generate phonetic variants for correct name")
    }

    func testAddCorrectionPairSkipsEmptyCorrect() async {
        let corrector = DynamicVocabularyCorrector()
        await corrector.addCorrectionPair(wrong: "something", correct: "")

        let count = await corrector.correctionCount
        XCTAssertEqual(count, 0, "Should not add entries for empty correct name")
    }

    func testAddCorrectionPairSkipsSingleChar() async {
        let corrector = DynamicVocabularyCorrector()
        await corrector.addCorrectionPair(wrong: "x", correct: "A")

        let count = await corrector.correctionCount
        XCTAssertEqual(count, 0, "Should not add entries for single-char names")
    }

    func testAddCorrectionPairDeduplicatesAgainstExisting() async {
        let corrector = DynamicVocabularyCorrector()
        await corrector.rebuild(
            ownerName: "Bob",
            entityNames: [],
            speakerNames: []
        )
        let countBefore = await corrector.correctionCount

        // Adding a correction for Bob should not create duplicates.
        await corrector.addCorrectionPair(wrong: nil, correct: "Bob")
        let countAfter = await corrector.correctionCount

        XCTAssertEqual(countBefore, countAfter, "Should not add duplicate entries")
    }

    func testAddCorrectionPairPrependsHighPriority() async {
        let corrector = DynamicVocabularyCorrector()

        // First, rebuild with an entity.
        await corrector.rebuild(
            ownerName: nil,
            entityNames: [
                (canonical: "TestUser", aliases: [], type: "person"),
            ],
            speakerNames: []
        )

        // Now add a correction — it should have higher priority.
        await corrector.addCorrectionPair(wrong: "testgust", correct: "TestGuest")

        // Direct mapping "testgust" → "TestGuest" should work.
        let result = await corrector.correct("hello testgust")
        XCTAssertEqual(result, "hello TestGuest")
    }

    // MARK: - Correction→Vocabulary Integration

    func testNameCorrectionFeedsVocabulary() async {
        // Simulate the full flow: detect correction → add to vocabulary.
        let text = "My name is Alice not Allison"
        let correction = CorrectionDetector.detect(in: text)
        XCTAssertNotNil(correction)
        XCTAssertEqual(correction?.kind, .nameError)

        let corrector = DynamicVocabularyCorrector()
        if let c = correction, c.kind == .nameError, let correct = c.correctedValue {
            await corrector.addCorrectionPair(wrong: c.originalValue, correct: correct)
        }

        // Now the corrector should fix "allison" → "Alice".
        let result = await corrector.correct("Hey allison, good morning")
        XCTAssertEqual(result, "Hey Alice, good morning")
    }

    func testNonNameCorrectionDoesNotFeedVocabulary() async {
        let text = "You interrupted me"
        let correction = CorrectionDetector.detect(in: text)
        XCTAssertNotNil(correction)
        XCTAssertEqual(correction?.kind, .interruption)

        let corrector = DynamicVocabularyCorrector()
        // Interruption corrections should NOT feed vocabulary.
        if let c = correction, c.kind == .nameError, let correct = c.correctedValue {
            await corrector.addCorrectionPair(wrong: c.originalValue, correct: correct)
        }

        let count = await corrector.correctionCount
        XCTAssertEqual(count, 0, "Non-name corrections should not add vocabulary entries")
    }
}
