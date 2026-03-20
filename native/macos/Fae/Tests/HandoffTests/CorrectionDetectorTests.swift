import XCTest
@testable import Fae

final class CorrectionDetectorTests: XCTestCase {

    // MARK: - Name Error Detection

    func testDetectsMyNameIsXNotY() {
        let result = CorrectionDetector.detect(in: "My name is Alice not Allison")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .nameError)
        XCTAssertEqual(result?.correctedValue, "Alice")
        XCTAssertEqual(result?.originalValue, "Allison")
    }

    func testDetectsMyNameIsXOnly() {
        let result = CorrectionDetector.detect(in: "My name is Bob")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .nameError)
        XCTAssertEqual(result?.correctedValue, "Bob")
        XCTAssertNil(result?.originalValue)
    }

    func testDetectsItsXNotY() {
        let result = CorrectionDetector.detect(in: "It's Alice not Allison")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .nameError)
        XCTAssertEqual(result?.correctedValue, "Alice")
        XCTAssertEqual(result?.originalValue, "Allison")
    }

    func testDetectsItIsXNotY() {
        let result = CorrectionDetector.detect(in: "It is Bob not Alice")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .nameError)
        XCTAssertEqual(result?.correctedValue, "Bob")
        XCTAssertEqual(result?.originalValue, "Alice")
    }

    func testDetectsWrongName() {
        let result = CorrectionDetector.detect(in: "That's not my name")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .nameError)
    }

    func testDetectsGotMyNameWrong() {
        let result = CorrectionDetector.detect(in: "You got my name wrong")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .nameError)
    }

    // MARK: - Mishearing Detection

    func testDetectsISaidX() {
        let result = CorrectionDetector.detect(in: "I said hello world")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .mishearing)
        XCTAssertEqual(result?.correctedValue, "Hello world")
    }

    func testDetectsISaidXNotY() {
        let result = CorrectionDetector.detect(in: "I said search not surge")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .mishearing)
        XCTAssertEqual(result?.correctedValue, "Search")
        XCTAssertEqual(result?.originalValue, "Surge")
    }

    func testDetectsYouMisheard() {
        let result = CorrectionDetector.detect(in: "You misheard me completely")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .mishearing)
    }

    func testDetectsThatsNotWhatISaid() {
        let result = CorrectionDetector.detect(in: "That's not what I said at all")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .mishearing)
    }

    // MARK: - Interruption Detection

    func testDetectsYouInterruptedMe() {
        let result = CorrectionDetector.detect(in: "You interrupted me")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .interruption)
    }

    func testDetectsIWasntFinished() {
        let result = CorrectionDetector.detect(in: "I wasn't finished speaking")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .interruption)
    }

    func testDetectsLetMeFinish() {
        let result = CorrectionDetector.detect(in: "Let me finish please")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .interruption)
    }

    func testDetectsDontInterrupt() {
        let result = CorrectionDetector.detect(in: "Don't interrupt me when I'm talking")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .interruption)
    }

    func testDetectsStopInterrupting() {
        let result = CorrectionDetector.detect(in: "Stop interrupting me please")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .interruption)
    }

    // MARK: - Wrong Action Detection

    func testDetectsThatWasWrong() {
        let result = CorrectionDetector.detect(in: "That was wrong, try again")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .wrongAction)
    }

    func testDetectsThatsNotWhatIMeant() {
        let result = CorrectionDetector.detect(in: "That's not what I meant")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .wrongAction)
    }

    func testDetectsUndoThat() {
        let result = CorrectionDetector.detect(in: "Undo that right now")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .wrongAction)
    }

    func testDetectsThatsIncorrect() {
        let result = CorrectionDetector.detect(in: "That's incorrect information")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .wrongAction)
    }

    // MARK: - False Positive Prevention

    func testIgnoresShortText() {
        let result = CorrectionDetector.detect(in: "hi")
        XCTAssertNil(result)
    }

    func testIgnoresNormalConversation() {
        let result = CorrectionDetector.detect(in: "What's the weather like today?")
        XCTAssertNil(result)
    }

    func testIgnoresNonCorrectionWithSimilarWords() {
        // "wrong" by itself in a sentence that isn't a correction pattern
        let result = CorrectionDetector.detect(in: "Is there something wrong with the server?")
        XCTAssertNil(result)
    }

    func testIgnoresEmptyString() {
        let result = CorrectionDetector.detect(in: "")
        XCTAssertNil(result)
    }

    // MARK: - CorrectionRecord

    func testCorrectionRecordNameErrorMemoryText() {
        let correction = CorrectionDetector.Correction(
            kind: .nameError,
            correctedValue: "Alice",
            originalValue: "Allison",
            rawText: "My name is Alice not Allison"
        )
        let record = CorrectionRecord(
            correction: correction,
            lastAssistantText: nil,
            speakerLabel: nil,
            timestamp: Date()
        )
        XCTAssertTrue(record.memoryText.contains("Alice"))
        XCTAssertTrue(record.memoryText.contains("Allison"))
        XCTAssertEqual(record.memoryKind, .profile)
        XCTAssertTrue(record.memoryTags.contains("correction"))
        XCTAssertTrue(record.memoryTags.contains("nameError"))
    }

    func testCorrectionRecordInterruptionMemoryText() {
        let correction = CorrectionDetector.Correction(
            kind: .interruption,
            correctedValue: nil,
            originalValue: nil,
            rawText: "You interrupted me"
        )
        let record = CorrectionRecord(
            correction: correction,
            lastAssistantText: "I was saying...",
            speakerLabel: nil,
            timestamp: Date()
        )
        XCTAssertTrue(record.memoryText.contains("interrupted"))
        XCTAssertEqual(record.memoryKind, .episode)
        XCTAssertTrue(record.memoryTags.contains("interruption"))
    }

    func testCorrectionRecordMishearingWithValue() {
        let correction = CorrectionDetector.Correction(
            kind: .mishearing,
            correctedValue: "Hello",
            originalValue: nil,
            rawText: "I said hello"
        )
        let record = CorrectionRecord(
            correction: correction,
            lastAssistantText: nil,
            speakerLabel: nil,
            timestamp: Date()
        )
        XCTAssertTrue(record.memoryText.contains("Hello"))
        XCTAssertTrue(record.memoryTags.contains("has_corrected_value"))
    }

    func testCorrectionRecordWrongActionMemoryText() {
        let correction = CorrectionDetector.Correction(
            kind: .wrongAction,
            correctedValue: nil,
            originalValue: nil,
            rawText: "That was wrong"
        )
        let record = CorrectionRecord(
            correction: correction,
            lastAssistantText: nil,
            speakerLabel: nil,
            timestamp: Date()
        )
        XCTAssertTrue(record.memoryText.contains("wrong"))
        XCTAssertEqual(record.memoryKind, .episode)
    }
}
