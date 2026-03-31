import XCTest
@testable import Fae

final class PersonalLexiconTests: XCTestCase {

    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("personal_lexicon_test_\(UUID().uuidString).json")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - CRUD

    func testUpsertAndLookup() async {
        let url = makeTempURL()
        defer { cleanup(url) }
        let lexicon = PersonalLexicon(fileURL: url)

        await lexicon.upsert(canonical: "Seamus", variants: ["shamus", "shaimus"], source: "correction")

        let entry = await lexicon.lookup(canonical: "Seamus")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.canonical, "Seamus")
        let variantCount = entry?.variants.count ?? 0
        XCTAssertEqual(variantCount, 2)
        let hasShamus = entry?.variants.contains("shamus") ?? false
        XCTAssertTrue(hasShamus)
        XCTAssertEqual(entry?.source, "correction")
    }

    func testUpsertMergesVariants() async {
        let url = makeTempURL()
        defer { cleanup(url) }
        let lexicon = PersonalLexicon(fileURL: url)

        await lexicon.upsert(canonical: "Niamh", variants: ["neev"], source: "contact")
        await lexicon.upsert(canonical: "Niamh", variants: ["neev", "neve", "neave"], source: "contact")

        let entry = await lexicon.lookup(canonical: "niamh")
        XCTAssertNotNil(entry)
        // "neev" was already there, so only "neve" and "neave" should be added.
        let variantCount = entry?.variants.count ?? 0
        XCTAssertEqual(variantCount, 3)
        let hasNeve = entry?.variants.contains("neve") ?? false
        XCTAssertTrue(hasNeve)
        let hasNeave = entry?.variants.contains("neave") ?? false
        XCTAssertTrue(hasNeave)
    }

    func testUpsertCaseInsensitiveLookup() async {
        let url = makeTempURL()
        defer { cleanup(url) }
        let lexicon = PersonalLexicon(fileURL: url)

        await lexicon.upsert(canonical: "Caoimhe", variants: [], source: "contact")

        let lower = await lexicon.lookup(canonical: "caoimhe")
        XCTAssertNotNil(lower)
        let upper = await lexicon.lookup(canonical: "CAOIMHE")
        XCTAssertNotNil(upper)
        let mixed = await lexicon.lookup(canonical: "Caoimhe")
        XCTAssertNotNil(mixed)
    }

    func testRemove() async {
        let url = makeTempURL()
        defer { cleanup(url) }
        let lexicon = PersonalLexicon(fileURL: url)

        await lexicon.upsert(canonical: "Oisin", variants: ["osheen"], source: "entity")

        let removed = await lexicon.remove(canonical: "Oisin")
        XCTAssertNotNil(removed)
        XCTAssertEqual(removed?.canonical, "Oisin")

        let after = await lexicon.lookup(canonical: "Oisin")
        XCTAssertNil(after)
        let count = await lexicon.count
        XCTAssertEqual(count, 0)
    }

    func testRemoveNonexistentReturnsNil() async {
        let url = makeTempURL()
        defer { cleanup(url) }
        let lexicon = PersonalLexicon(fileURL: url)

        let removed = await lexicon.remove(canonical: "Nobody")
        XCTAssertNil(removed)
    }

    func testEmptyCanonicalIgnored() async {
        let url = makeTempURL()
        defer { cleanup(url) }
        let lexicon = PersonalLexicon(fileURL: url)

        await lexicon.upsert(canonical: "", variants: ["x"], source: "test")
        let count = await lexicon.count
        XCTAssertEqual(count, 0)
    }

    func testCanonicalNotAddedAsVariant() async {
        let url = makeTempURL()
        defer { cleanup(url) }
        let lexicon = PersonalLexicon(fileURL: url)

        await lexicon.upsert(canonical: "David", variants: ["david", "Dave"], source: "test")

        let entry = await lexicon.lookup(canonical: "David")
        // "david" (same as canonical lowercased) should be filtered out.
        XCTAssertEqual(entry?.variants, ["Dave"])
    }

    // MARK: - Persistence

    func testSaveAndLoad() async {
        let url = makeTempURL()
        defer { cleanup(url) }

        // Write.
        let lexicon1 = PersonalLexicon(fileURL: url)
        await lexicon1.upsert(canonical: "Aoife", variants: ["eefa"], source: "contact")
        await lexicon1.upsert(canonical: "Saoirse", variants: ["seersha", "sursha"], source: "calendar")
        await lexicon1.save()

        // Read in a fresh instance.
        let lexicon2 = PersonalLexicon(fileURL: url)
        await lexicon2.load()

        let count = await lexicon2.count
        XCTAssertEqual(count, 2)
        let aoife = await lexicon2.lookup(canonical: "Aoife")
        XCTAssertNotNil(aoife)
        XCTAssertEqual(aoife?.variants, ["eefa"])

        let saoirse = await lexicon2.lookup(canonical: "Saoirse")
        XCTAssertNotNil(saoirse)
        let hasSeersha = saoirse?.variants.contains("seersha") ?? false
        XCTAssertTrue(hasSeersha)
    }

    func testLoadFromNonexistentFileStartsEmpty() async {
        let url = makeTempURL()
        defer { cleanup(url) }
        let lexicon = PersonalLexicon(fileURL: url)
        await lexicon.load()
        let count = await lexicon.count
        XCTAssertEqual(count, 0)
    }

    func testSaveNoOpWhenClean() async {
        let url = makeTempURL()
        defer { cleanup(url) }
        let lexicon = PersonalLexicon(fileURL: url)
        // No changes — save should be a no-op and not create a file.
        await lexicon.save()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Snapshot

    func testSnapshot() async {
        let url = makeTempURL()
        defer { cleanup(url) }
        let lexicon = PersonalLexicon(fileURL: url)

        await lexicon.upsert(canonical: "Fionnuala", variants: ["finola"], source: "contact")
        await lexicon.upsert(canonical: "Ciaran", variants: ["keeron"], source: "contact")

        let snap = await lexicon.snapshot()
        XCTAssertEqual(snap.entries.count, 2)
        let hasFionnuala = snap.entries.contains(where: { $0.canonical == "Fionnuala" })
        XCTAssertTrue(hasFionnuala)
        let hasCiaran = snap.entries.contains(where: { $0.canonical == "Ciaran" })
        XCTAssertTrue(hasCiaran)
    }

    // MARK: - Bulk Operations

    func testMergeAll() async {
        let url = makeTempURL()
        defer { cleanup(url) }
        let lexicon = PersonalLexicon(fileURL: url)

        await lexicon.upsert(canonical: "Existing", variants: [], source: "test")

        let added = await lexicon.mergeAll([
            (canonical: "Existing", variants: ["ex"], source: "harvest"),
            (canonical: "NewName", variants: ["new name"], source: "harvest"),
            (canonical: "Another", variants: [], source: "harvest"),
        ])

        XCTAssertEqual(added, 2, "Should report 2 new entries (Existing was already there)")
        let count = await lexicon.count
        XCTAssertEqual(count, 3)
    }

    // MARK: - DVC Integration

    func testDVCIngestsLexiconEntries() async {
        let url = makeTempURL()
        defer { cleanup(url) }
        let lexicon = PersonalLexicon(fileURL: url)

        await lexicon.upsert(canonical: "Padraig", variants: ["podrig", "parig"], source: "contact")

        let dvc = DynamicVocabularyCorrector()
        let snap = await lexicon.snapshot()
        await dvc.ingestLexicon(snap)

        // The DVC should now correct "podrig" to "Padraig".
        let corrected = await dvc.correct("I spoke to podrig yesterday")
        XCTAssertEqual(corrected, "I spoke to Padraig yesterday")
    }

    func testDVCIngestsAfterRebuild() async {
        let url = makeTempURL()
        defer { cleanup(url) }
        let lexicon = PersonalLexicon(fileURL: url)

        await lexicon.upsert(canonical: "Grainne", variants: ["gronya"], source: "contact")

        let dvc = DynamicVocabularyCorrector()
        // First rebuild with standard sources (empty).
        await dvc.rebuild(ownerName: nil, entityNames: [], speakerNames: [])
        // Then ingest lexicon on top.
        let snap = await lexicon.snapshot()
        await dvc.ingestLexicon(snap)

        let corrected = await dvc.correct("gronya said hello")
        XCTAssertEqual(corrected, "Grainne said hello")
    }
}
