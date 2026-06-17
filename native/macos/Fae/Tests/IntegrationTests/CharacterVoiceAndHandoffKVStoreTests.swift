import XCTest
import FaeHandoffKit
@testable import Fae

/// Coverage for two 0%-covered files made testable via storage injection:
/// - CharacterVoiceLibrary: injectable fileURL (temp path, not ~/Library).
/// - HandoffKVStore: HandoffKeyValueStoring protocol + in-memory fake store
///   (no NSUbiquitousKeyValueStore.default / iCloud in tests).
final class CharacterVoiceAndHandoffKVStoreTests: XCTestCase {

    // MARK: - CharacterVoiceLibrary

    private func tempVoiceURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-cvl-\(UUID().uuidString).json")
    }

    func testCharacterVoiceListStartsEmpty() async {
        let lib = CharacterVoiceLibrary(fileURL: tempVoiceURL())
        let list = await lib.list()
        XCTAssertTrue(list.isEmpty)
    }

    func testCharacterVoiceSaveAndFindCaseInsensitive() async throws {
        let lib = CharacterVoiceLibrary(fileURL: tempVoiceURL())
        await lib.save(CharacterVoiceEntry(name: "Zelda", voiceInstruct: "calm", presetSpeaker: nil,
                                           refAudioPath: nil, refText: nil, tags: ["hero"]))
        let found = await lib.find(name: "zelda") // case-insensitive
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.voiceInstruct, "calm")
    }

    func testCharacterVoiceListSortedByName() async {
        let lib = CharacterVoiceLibrary(fileURL: tempVoiceURL())
        await lib.save(CharacterVoiceEntry(name: "Cobra", voiceInstruct: nil, presetSpeaker: nil,
                                           refAudioPath: nil, refText: nil))
        await lib.save(CharacterVoiceEntry(name: "alpha", voiceInstruct: nil, presetSpeaker: nil,
                                           refAudioPath: nil, refText: nil))
        await lib.save(CharacterVoiceEntry(name: "Bravo", voiceInstruct: nil, presetSpeaker: nil,
                                           refAudioPath: nil, refText: nil))
        let names = await lib.list().map(\.name)
        // Sorted case-insensitively.
        XCTAssertEqual(names, ["alpha", "Bravo", "Cobra"])
    }

    func testCharacterVoiceSaveUpdatesExistingEntry() async {
        let lib = CharacterVoiceLibrary(fileURL: tempVoiceURL())
        await lib.save(CharacterVoiceEntry(name: "Aria", voiceInstruct: "v1", presetSpeaker: nil,
                                           refAudioPath: nil, refText: nil))
        await lib.save(CharacterVoiceEntry(name: "aria", voiceInstruct: "v2-updated", presetSpeaker: nil,
                                           refAudioPath: nil, refText: nil))
        let list = await lib.list()
        XCTAssertEqual(list.count, 1, "same-name save should update, not append")
        XCTAssertEqual(list.first?.voiceInstruct, "v2-updated")
    }

    func testCharacterVoiceDelete() async {
        let lib = CharacterVoiceLibrary(fileURL: tempVoiceURL())
        await lib.save(CharacterVoiceEntry(name: "ToDelete", voiceInstruct: nil, presetSpeaker: nil,
                                           refAudioPath: nil, refText: nil))
        await lib.delete(name: "todelete")
        let found = await lib.find(name: "ToDelete")
        XCTAssertNil(found)
    }

    func testCharacterVoicePersistsAcrossInstances() async throws {
        let url = tempVoiceURL()
        let lib1 = CharacterVoiceLibrary(fileURL: url)
        await lib1.save(CharacterVoiceEntry(name: "Persisted", voiceInstruct: "x", presetSpeaker: nil,
                                            refAudioPath: nil, refText: nil, tags: ["a"]))
        // A new instance pointing at the same file should reload the entry.
        let lib2 = CharacterVoiceLibrary(fileURL: url)
        let list = await lib2.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.name, "Persisted")
    }

    // MARK: - HandoffKVStore

    /// In-memory fake for HandoffKeyValueStoring — no iCloud touched.
    private final class FakeKVStore: HandoffKVStore.HandoffKeyValueStoring {
        var storage: [String: Data] = [:]
        var synchronizeResult = true
        func set(_ data: Data, forKey key: String) { storage[key] = data }
        func data(forKey key: String) -> Data? { storage[key] }
        func removeObject(forKey key: String) { storage.removeValue(forKey: key) }
        func synchronize() -> Bool { synchronizeResult }
    }

    private func makeSnapshot() -> ConversationSnapshot {
        ConversationSnapshot(
            entries: [SnapshotEntry(role: "user", content: "hello")],
            orbMode: "idle",
            orbFeeling: "calm",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testHandoffSaveLoadRoundTrip() {
        let store = FakeKVStore()
        let snapshot = makeSnapshot()
        HandoffKVStore.save(snapshot, store: store)
        let loaded = HandoffKVStore.load(store: store)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded, snapshot)
    }

    func testHandoffClearRemovesSnapshot() {
        let store = FakeKVStore()
        HandoffKVStore.save(makeSnapshot(), store: store)
        XCTAssertNotNil(HandoffKVStore.load(store: store))
        HandoffKVStore.clear(store: store)
        XCTAssertNil(HandoffKVStore.load(store: store))
    }

    func testHandoffLoadReturnsNilForMissingKey() {
        let store = FakeKVStore()
        XCTAssertNil(HandoffKVStore.load(store: store))
    }

    func testHandoffLoadReturnsNilForInvalidData() {
        let store = FakeKVStore()
        // Plant corrupt data under the snapshot key.
        store.set(Data([0x00, 0x01, 0x02]), forKey: "fae.handoff.snapshot")
        XCTAssertNil(HandoffKVStore.load(store: store))
    }

    func testHandoffSaveNoCrashWhenSynchronizeFails() {
        let store = FakeKVStore()
        store.synchronizeResult = false
        // Should log + not crash even when synchronize() returns false.
        HandoffKVStore.save(makeSnapshot(), store: store)
        // Data still written before synchronize is checked.
        XCTAssertNotNil(store.data(forKey: "fae.handoff.snapshot"))
    }
}
