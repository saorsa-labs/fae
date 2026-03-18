import XCTest
@testable import Fae

final class KeywordSpotterTests: XCTestCase {

    // MARK: - Exact Matching

    func testExactMatchDetectsInterruptPhrase() async {
        let spotter = KeywordSpotter(config: .default)
        let match = await spotter.check(partialTranscript: "please stop")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.category, .interrupt)
        XCTAssertEqual(match?.configuredKeyword, "stop")
        XCTAssertFalse(match?.isFuzzy ?? true)
    }

    func testExactMatchDetectsWakePhrase() async {
        let spotter = KeywordSpotter(config: .default)
        let match = await spotter.check(partialTranscript: "hey fae what time is it")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.category, .wake)
        XCTAssertEqual(match?.configuredKeyword, "hey fae")
    }

    func testNoMatchForUnrelatedText() async {
        let spotter = KeywordSpotter(config: .default)
        let match = await spotter.check(partialTranscript: "what is the weather today")
        XCTAssertNil(match)
    }

    // MARK: - Word Boundary

    func testWordBoundaryPositive() async {
        let spotter = KeywordSpotter(config: .default)
        let match = await spotter.check(partialTranscript: "stop the music")
        XCTAssertNotNil(match)
    }

    func testWordBoundaryNegative() async {
        let config = KeywordBiasConfig(interruptPhrases: ["stop"], wakePhrases: [], fuzzyMatching: false)
        let spotter = KeywordSpotter(config: config)
        let match = await spotter.check(partialTranscript: "nonstop music")
        XCTAssertNil(match)
    }

    // MARK: - Fuzzy Matching

    func testFuzzyMatchEnabled() async {
        let config = KeywordBiasConfig(interruptPhrases: ["stop"], wakePhrases: [], fuzzyMatching: true)
        let spotter = KeywordSpotter(config: config)
        let match = await spotter.check(partialTranscript: "please stopp")
        XCTAssertNotNil(match)
        XCTAssertTrue(match?.isFuzzy ?? false)
    }

    func testFuzzyMatchDisabled() async {
        let config = KeywordBiasConfig(interruptPhrases: ["stop"], wakePhrases: [], fuzzyMatching: false)
        let spotter = KeywordSpotter(config: config)
        let match = await spotter.check(partialTranscript: "please stopp")
        XCTAssertNil(match)
    }

    func testFuzzyMatchTooDistant() async {
        let config = KeywordBiasConfig(interruptPhrases: ["stop"], wakePhrases: [], fuzzyMatching: true)
        let spotter = KeywordSpotter(config: config)
        let match = await spotter.check(partialTranscript: "please stamp")
        XCTAssertNil(match)
    }

    func testFuzzyMatchMultiWordSkipped() async {
        let config = KeywordBiasConfig(interruptPhrases: [], wakePhrases: ["hey fae"], fuzzyMatching: true)
        let spotter = KeywordSpotter(config: config)
        let match = await spotter.check(partialTranscript: "hey fay")
        XCTAssertNil(match)
    }

    func testFuzzyInterruptRejectsChannelAsCancel() async {
        let spotter = KeywordSpotter(config: .default)
        let match = await spotter.check(partialTranscript: "join the discord channel for me")
        // "channel" is Levenshtein distance 2 from "cancel" — interrupt fuzzy
        // matching uses max distance 1, so this must NOT trigger an interrupt.
        XCTAssertNil(match)
    }

    func testFuzzyWakeAllowsDistance2() async {
        let config = KeywordBiasConfig(interruptPhrases: [], wakePhrases: ["silence"], fuzzyMatching: true)
        let spotter = KeywordSpotter(config: config)
        // "salence" is distance 2 from "silence" — wake words allow distance 2 for >5 char phrases.
        let match = await spotter.check(partialTranscript: "hey salence")
        XCTAssertNotNil(match)
        XCTAssertTrue(match?.isFuzzy ?? false)
    }

    // MARK: - Case Sensitivity

    func testCaseInsensitiveMatch() async {
        let spotter = KeywordSpotter(config: .default)
        let match = await spotter.check(partialTranscript: "STOP")
        XCTAssertNotNil(match)
    }

    func testCaseSensitiveMatch() async {
        let config = KeywordBiasConfig(interruptPhrases: ["stop"], wakePhrases: [], caseInsensitive: false)
        let spotter = KeywordSpotter(config: config)
        let match = await spotter.check(partialTranscript: "STOP")
        XCTAssertNil(match)
    }

    // MARK: - Multi-Word Phrases

    func testMultiWordExactMatch() async {
        let spotter = KeywordSpotter(config: .default)
        let match = await spotter.check(partialTranscript: "I said hey fae please help")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.configuredKeyword, "hey fae")
    }

    func testMultiWordSubstringContainment() async {
        let config = KeywordBiasConfig(interruptPhrases: [], wakePhrases: ["hey fae"], fuzzyMatching: false)
        let spotter = KeywordSpotter(config: config)
        let match = await spotter.check(partialTranscript: "hey there")
        XCTAssertNil(match)
    }

    // MARK: - Duplicate Prevention

    func testDuplicatePrevention() async {
        let spotter = KeywordSpotter(config: .default)
        let match1 = await spotter.check(partialTranscript: "stop")
        XCTAssertNotNil(match1)
        let match2 = await spotter.check(partialTranscript: "stop the music")
        XCTAssertNil(match2)
    }

    func testDifferentKeywordsSameSegment() async {
        let config = KeywordBiasConfig(interruptPhrases: ["stop", "quiet"], wakePhrases: [], fuzzyMatching: false)
        let spotter = KeywordSpotter(config: config)
        let match1 = await spotter.check(partialTranscript: "stop")
        XCTAssertNotNil(match1)
        let match2 = await spotter.check(partialTranscript: "stop and be quiet")
        XCTAssertNotNil(match2)
        XCTAssertEqual(match2?.configuredKeyword, "quiet")
    }

    // MARK: - Reset

    func testResetAllowsRedetection() async {
        let spotter = KeywordSpotter(config: .default)
        let match1 = await spotter.check(partialTranscript: "stop")
        XCTAssertNotNil(match1)
        await spotter.reset()
        let match2 = await spotter.check(partialTranscript: "stop again")
        XCTAssertNotNil(match2)
    }

    // MARK: - Transcript Growth

    func testGrowingTranscriptIncrementalSearch() async {
        let config = KeywordBiasConfig(interruptPhrases: ["stop"], wakePhrases: [], fuzzyMatching: false)
        let spotter = KeywordSpotter(config: config)
        let match1 = await spotter.check(partialTranscript: "I was")
        XCTAssertNil(match1)
        let match2 = await spotter.check(partialTranscript: "I was thinking")
        XCTAssertNil(match2)
        let match3 = await spotter.check(partialTranscript: "I was thinking stop")
        XCTAssertNotNil(match3)
    }

    // MARK: - Transcript Correction

    func testTranscriptCorrectionResetsDetected() async {
        let config = KeywordBiasConfig(interruptPhrases: ["stop", "cancel"], wakePhrases: [], fuzzyMatching: false)
        let spotter = KeywordSpotter(config: config)
        let match1 = await spotter.check(partialTranscript: "please stop")
        XCTAssertNotNil(match1)
        let match2 = await spotter.check(partialTranscript: "just cancel it")
        XCTAssertNotNil(match2)
        XCTAssertEqual(match2?.configuredKeyword, "cancel")
    }

    // MARK: - Config Update

    func testUpdateConfigChangesKeywords() async {
        let spotter = KeywordSpotter(config: .default)
        let match1 = await spotter.check(partialTranscript: "banana")
        XCTAssertNil(match1)
        await spotter.reset()
        await spotter.updateConfig(KeywordBiasConfig(interruptPhrases: ["banana"], wakePhrases: []))
        let match2 = await spotter.check(partialTranscript: "banana")
        XCTAssertNotNil(match2)
    }

    // MARK: - Levenshtein Distance

    func testLevenshteinIdentical() {
        let spotter = KeywordSpotter(config: .default)
        XCTAssertEqual(spotter.levenshteinDistance("fae", "fae"), 0)
    }

    func testLevenshteinInsertion() {
        let spotter = KeywordSpotter(config: .default)
        XCTAssertEqual(spotter.levenshteinDistance("fae", "faee"), 1)
    }

    func testLevenshteinDeletion() {
        let spotter = KeywordSpotter(config: .default)
        XCTAssertEqual(spotter.levenshteinDistance("fae", "fa"), 1)
    }

    func testLevenshteinSubstitution() {
        let spotter = KeywordSpotter(config: .default)
        XCTAssertEqual(spotter.levenshteinDistance("fae", "fay"), 1)
    }

    func testLevenshteinEmpty() {
        let spotter = KeywordSpotter(config: .default)
        XCTAssertEqual(spotter.levenshteinDistance("", "abc"), 3)
        XCTAssertEqual(spotter.levenshteinDistance("abc", ""), 3)
        XCTAssertEqual(spotter.levenshteinDistance("", ""), 0)
    }

    func testLevenshteinComplex() {
        let spotter = KeywordSpotter(config: .default)
        XCTAssertEqual(spotter.levenshteinDistance("kitten", "sitting"), 3)
    }

    // MARK: - Confidence Threshold

    func testBelowConfidenceThresholdIgnored() async {
        let config = KeywordBiasConfig(interruptPhrases: ["stop"], wakePhrases: [], minimumConfidence: 0.5)
        let spotter = KeywordSpotter(config: config)
        let match = await spotter.check(partialTranscript: "stop", confidence: 0.3)
        XCTAssertNil(match)
    }

    func testAtConfidenceThresholdAccepted() async {
        let config = KeywordBiasConfig(interruptPhrases: ["stop"], wakePhrases: [], minimumConfidence: 0.5)
        let spotter = KeywordSpotter(config: config)
        let match = await spotter.check(partialTranscript: "stop", confidence: 0.8)
        XCTAssertNotNil(match)
    }

    // MARK: - Callback

    func testOnKeywordDetectedCallback() async {
        let spotter = KeywordSpotter(config: .default)
        let callbackFired = expectation(description: "callback fired")
        await spotter.setCallback { _ in callbackFired.fulfill() }
        let result = await spotter.check(partialTranscript: "stop")
        XCTAssertNotNil(result)
        await fulfillment(of: [callbackFired], timeout: 1.0)
    }

    // MARK: - Interrupt Priority

    func testInterruptPriorityOverWake() async {
        let config = KeywordBiasConfig(interruptPhrases: ["stop"], wakePhrases: ["fae"])
        let spotter = KeywordSpotter(config: config)
        let match = await spotter.check(partialTranscript: "fae stop")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.category, .interrupt)
    }

    // MARK: - Single Word Wake

    func testSingleWordWakePhrase() async {
        let spotter = KeywordSpotter(config: .default)
        let match = await spotter.check(partialTranscript: "hello fae")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.category, .wake)
        XCTAssertEqual(match?.configuredKeyword, "fae")
    }

    // MARK: - Edge Cases

    func testEmptyTranscript() async {
        let spotter = KeywordSpotter(config: .default)
        let match = await spotter.check(partialTranscript: "")
        XCTAssertNil(match)
    }

    func testWhitespaceOnlyTranscript() async {
        let spotter = KeywordSpotter(config: .default)
        let match = await spotter.check(partialTranscript: "   ")
        XCTAssertNil(match)
    }

    // MARK: - Data Types

    func testStreamingSTTResultDefaults() {
        let result = StreamingSTTResult(text: "hello", isFinal: false)
        XCTAssertEqual(result.text, "hello")
        XCTAssertFalse(result.isFinal)
        XCTAssertNil(result.confidence)
    }

    func testStreamingSTTResultEquality() {
        let a = StreamingSTTResult(text: "hello", isFinal: false, confidence: 0.9)
        let b = StreamingSTTResult(text: "hello", isFinal: false, confidence: 0.9)
        XCTAssertEqual(a, b)
    }

    func testKeywordBiasConfigCodableRoundTrip() throws {
        let config = KeywordBiasConfig(
            interruptPhrases: ["stop", "halt"],
            wakePhrases: ["hey fae"],
            minimumConfidence: 0.5,
            caseInsensitive: true,
            fuzzyMatching: false
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(KeywordBiasConfig.self, from: data)
        XCTAssertEqual(decoded.interruptPhrases, ["stop", "halt"])
        XCTAssertEqual(decoded.wakePhrases, ["hey fae"])
        XCTAssertEqual(decoded.minimumConfidence, 0.5)
        XCTAssertFalse(decoded.fuzzyMatching)
    }

    func testDefaultConfigHasExpectedValues() {
        let config = KeywordBiasConfig.default
        XCTAssertTrue(config.interruptPhrases.contains("stop"))
        XCTAssertTrue(config.wakePhrases.contains("hey fae"))
        XCTAssertTrue(config.caseInsensitive)
        XCTAssertTrue(config.fuzzyMatching)
    }
}
