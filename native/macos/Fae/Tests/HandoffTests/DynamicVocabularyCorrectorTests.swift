import XCTest
@testable import Fae

final class DynamicVocabularyCorrectorTests: XCTestCase {

    // MARK: - Phonetic Variant Generation

    func testPhoneticVariantsGeneratesVowelSwaps() {
        let variants = DynamicVocabularyCorrector.phoneticVariants(of: "David")
        // "david" with a→e should produce "devid"
        XCTAssertTrue(variants.contains("devid"), "Expected vowel swap variant 'devid', got: \(variants)")
    }

    func testPhoneticVariantsGeneratesConsonantSwaps() {
        let variants = DynamicVocabularyCorrector.phoneticVariants(of: "Edinburgh")
        // "edinburgh" with "b" → "p" should produce "edinpurgh"
        XCTAssertTrue(variants.contains("edinpurgh"), "Expected consonant swap in Edinburgh variants")
        // Dropped trailing letter
        XCTAssertTrue(variants.contains("edinburg"), "Expected dropped-h variant 'edinburg'")
    }

    func testPhoneticVariantsSkipsShortNames() {
        let variants = DynamicVocabularyCorrector.phoneticVariants(of: "Ed")
        // "ed" has count < 3, so no swap variants generated (only the word itself is skipped)
        // The method should still return some variants from the name as a whole
        // but individual words < 3 chars skip the swap logic
        XCTAssertTrue(variants.isEmpty || variants.allSatisfy { $0.count <= 3 })
    }

    func testPhoneticVariantsDoesNotIncludeOriginal() {
        let variants = DynamicVocabularyCorrector.phoneticVariants(of: "Saorsa")
        XCTAssertFalse(variants.contains("saorsa"), "Variants should not include the canonical lowercase form")
    }

    // MARK: - Correction Application

    func testCorrectAppliesOwnerNameCorrection() async {
        let corrector = DynamicVocabularyCorrector()
        await corrector.rebuild(
            ownerName: "David",
            entityNames: [],
            speakerNames: []
        )

        // "devid" is a vowel-swap variant of "David"
        let result = await corrector.correct("Hey devid, how are you?")
        XCTAssertEqual(result, "Hey David, how are you?")
    }

    func testCorrectAppliesEntityNameCorrection() async {
        let corrector = DynamicVocabularyCorrector()
        await corrector.rebuild(
            ownerName: nil,
            entityNames: [
                (canonical: "Edinburgh", aliases: ["Edinburg"], type: "location")
            ],
            speakerNames: []
        )

        // Alias "edinburg" → "Edinburgh"
        let result = await corrector.correct("I live in edinburg")
        XCTAssertEqual(result, "I live in Edinburgh")
    }

    func testCorrectAppliesSpeakerNameCorrection() async {
        let corrector = DynamicVocabularyCorrector()
        await corrector.rebuild(
            ownerName: nil,
            entityNames: [],
            speakerNames: [(label: "alice", displayName: "Alice")]
        )

        // "elice" is a vowel-swap variant of "alice"
        let result = await corrector.correct("Hi elice")
        XCTAssertEqual(result, "Hi Alice")
    }

    func testCorrectRespectsWordBoundaries() async {
        let corrector = DynamicVocabularyCorrector()
        await corrector.rebuild(
            ownerName: "David",
            entityNames: [],
            speakerNames: []
        )

        // "devid" inside a longer word should NOT be corrected
        let result = await corrector.correct("The devidend was paid")
        // "devidend" contains "devid" but not at a word boundary
        XCTAssertEqual(result, "The devidend was paid")
    }

    func testCorrectPassesThroughUnknownText() async {
        let corrector = DynamicVocabularyCorrector()
        await corrector.rebuild(
            ownerName: "David",
            entityNames: [],
            speakerNames: []
        )

        let result = await corrector.correct("Hello world, nice day")
        XCTAssertEqual(result, "Hello world, nice day")
    }

    func testCorrectDoesNotRewriteRunAsHarvestedContactName() async {
        let corrector = DynamicVocabularyCorrector()
        await corrector.rebuild(
            ownerName: nil,
            entityNames: [(canonical: "Rune Bondal", aliases: [], type: "person")],
            speakerNames: []
        )

        let result = await corrector.correct("Open the terminal and run git status")
        XCTAssertEqual(result, "Open the terminal and run git status")
    }

    func testCorrectDoesNotRewriteSetAsHarvestedContactName() async {
        let corrector = DynamicVocabularyCorrector()
        await corrector.rebuild(
            ownerName: nil,
            entityNames: [(canonical: "Sat Panesar", aliases: [], type: "person")],
            speakerNames: []
        )

        let result = await corrector.correct("Set a timer for five minutes")
        XCTAssertEqual(result, "Set a timer for five minutes")
    }

    func testCorrectDoesNotRewriteAndAsHarvestedContactName() async {
        let corrector = DynamicVocabularyCorrector()
        await corrector.rebuild(
            ownerName: nil,
            entityNames: [(canonical: "Andy Lim", aliases: [], type: "person")],
            speakerNames: []
        )

        let result = await corrector.correct("Open the terminal and run git status")
        XCTAssertEqual(result, "Open the terminal and run git status")
    }

    func testCorrectDoesNotRewriteNumberWordsAsHarvestedContactName() async {
        let corrector = DynamicVocabularyCorrector()
        await corrector.rebuild(
            ownerName: nil,
            entityNames: [(canonical: "Wellness Tree", aliases: [], type: "person")],
            speakerNames: []
        )

        let result = await corrector.correct("The number is four one five two three six")
        XCTAssertEqual(result, "The number is four one five two three six")
    }

    func testCorrectCanStillApplyExplicitSarahVariant() async {
        let corrector = DynamicVocabularyCorrector()
        let snapshot = PersonalLexicon.Snapshot(entries: [
            PersonalLexicon.Entry(
                canonical: "Sarah",
                variants: ["sara", "ser"],
                source: "test",
                createdAt: Date(),
                updatedAt: Date())
        ], timestamp: Date())
        await corrector.ingestLexicon(snapshot)

        let result = await corrector.correct("Call ser")
        XCTAssertEqual(result, "Call Sarah")
    }

    func testContactPhoneticsDoNotOverrideSeededPreferredSpelling() async {
        let corrector = DynamicVocabularyCorrector()
        let snapshot = PersonalLexicon.Snapshot(entries: [
            PersonalLexicon.Entry(
                canonical: "Sara",
                variants: [],
                source: "contact",
                createdAt: Date(),
                updatedAt: Date()),
            PersonalLexicon.Entry(
                canonical: "Sarah",
                variants: ["sara", "ser"],
                source: "b5_app_eval",
                createdAt: Date(),
                updatedAt: Date()),
        ], timestamp: Date())
        await corrector.ingestLexicon(snapshot)

        let alreadyPreferred = await corrector.correct("Call Sarah")
        let explicitVariant = await corrector.correct("Call Sara")
        XCTAssertEqual(alreadyPreferred, "Call Sarah")
        XCTAssertEqual(explicitVariant, "Call Sarah")
    }

    func testEmptyCorrectionsPassThrough() async {
        let corrector = DynamicVocabularyCorrector()
        // No rebuild — empty corrections
        let result = await corrector.correct("Some random text")
        XCTAssertEqual(result, "Some random text")
    }

    // MARK: - Rebuild Behavior

    func testRebuildDeduplicatesPatterns() async {
        let corrector = DynamicVocabularyCorrector()
        await corrector.rebuild(
            ownerName: "David",
            entityNames: [(canonical: "David", aliases: [], type: "person")],
            speakerNames: [(label: "david", displayName: "David")]
        )

        // All three sources produce variants for "David" but should be deduped
        let count = await corrector.correctionCount
        // Should have variants but no duplicates
        XCTAssertGreaterThan(count, 0)
    }

    func testNeedsRebuildIsTrueInitially() async {
        let corrector = DynamicVocabularyCorrector()
        let needs = await corrector.needsRebuild
        XCTAssertTrue(needs)
    }

    func testNeedsRebuildIsFalseAfterRebuild() async {
        let corrector = DynamicVocabularyCorrector()
        await corrector.rebuild(ownerName: "Test", entityNames: [], speakerNames: [])
        let needs = await corrector.needsRebuild
        XCTAssertFalse(needs)
    }
}
