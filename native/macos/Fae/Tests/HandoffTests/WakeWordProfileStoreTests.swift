import XCTest
@testable import Fae

final class WakeWordProfileStoreTests: XCTestCase {

    func testLearnedAliasPromotesAfterTwoSamples() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-wake-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storePath = tempDir.appendingPathComponent("wake_lexicon.json")
        let store = WakeWordProfileStore(storePath: storePath)

        await store.recordAliasCandidate("faeye", source: "test")
        var aliases = await store.allAliases()
        XCTAssertFalse(aliases.contains("faeye"), "single sample should not promote alias")

        await store.recordAliasCandidate("faeye", source: "test")
        aliases = await store.allAliases()
        XCTAssertTrue(aliases.contains("faeye"), "alias should promote after repeated sightings")
    }
}
