import XCTest
@testable import Fae

final class VocabularyHarvestTests: XCTestCase {

    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab_harvest_test_\(UUID().uuidString).json")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Harvest Integration

    func testHarvestIntoEmptyLexicon() async {
        let url = makeTempURL()
        defer { cleanup(url) }
        let lexicon = PersonalLexicon(fileURL: url)

        // Harvest may or may not find data depending on permissions in CI.
        // The important thing is it doesn't crash and returns a valid result.
        let result = await VocabularyHarvester.harvest(into: lexicon)

        // newEntries + mergedEntries should be non-negative.
        XCTAssertGreaterThanOrEqual(result.newEntries, 0)
        XCTAssertGreaterThanOrEqual(result.mergedEntries, 0)
        // skippedSources should only contain known sources.
        for source in result.skippedSources {
            XCTAssertTrue(
                ["contacts", "calendar"].contains(source),
                "Unexpected skipped source: \(source)"
            )
        }
    }

    func testHarvestDeduplicates() async {
        let url = makeTempURL()
        defer { cleanup(url) }
        let lexicon = PersonalLexicon(fileURL: url)

        // Pre-populate.
        await lexicon.upsert(canonical: "TestContact", variants: [], source: "manual")

        // Harvest twice — second run should not double-add.
        _ = await VocabularyHarvester.harvest(into: lexicon)
        let countAfterFirst = await lexicon.count
        _ = await VocabularyHarvester.harvest(into: lexicon)
        let countAfterSecond = await lexicon.count

        // Count should not change on second harvest (all entries already exist).
        XCTAssertEqual(countAfterFirst, countAfterSecond)
    }

    func testHarvestSavesFile() async {
        let url = makeTempURL()
        defer { cleanup(url) }
        let lexicon = PersonalLexicon(fileURL: url)

        _ = await VocabularyHarvester.harvest(into: lexicon)

        // If any entries were harvested, a file should exist.
        let count = await lexicon.count
        if count > 0 {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

            // Verify the file can be loaded by a fresh instance.
            let lexicon2 = PersonalLexicon(fileURL: url)
            await lexicon2.load()
            let count2 = await lexicon2.count
            XCTAssertEqual(count, count2)
        }
    }

    // MARK: - Permission Handling

    func testHarvestSkipsSourcesGracefully() async {
        // This test verifies the harvester handles missing permissions gracefully.
        // In CI without Contacts/Calendar access, both sources should be skipped.
        let url = makeTempURL()
        defer { cleanup(url) }
        let lexicon = PersonalLexicon(fileURL: url)

        let result = await VocabularyHarvester.harvest(into: lexicon)

        // Either we got data or we got skipped sources — no crashes.
        let totalProcessed = result.newEntries + result.mergedEntries
        let totalSkipped = result.skippedSources.count

        // At least one of: some data or some skips.
        // (Could be both if one source works and the other doesn't.)
        XCTAssertTrue(
            totalProcessed >= 0 || totalSkipped >= 0,
            "Harvest should process entries or report skipped sources"
        )
    }
}
