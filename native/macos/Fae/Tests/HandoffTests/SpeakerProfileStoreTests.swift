import Foundation
import XCTest
@testable import Fae

final class SpeakerProfileStoreTests: XCTestCase {

    private func makeTempStoreURL() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-speaker-store-tests-\(UUID().uuidString)", isDirectory: true)
        return root.appendingPathComponent("speakers.json")
    }

    func testPromoteSoleHumanProfileToOwnerIfUnambiguous() async {
        let store = SpeakerProfileStore(storePath: makeTempStoreURL())
        await store.enroll(label: "david", embedding: [0.1, 0.2, 0.3], role: .guest, displayName: "David")

        let promoted = await store.promoteSoleHumanProfileToOwnerIfUnambiguous()
        let hasOwner = await store.hasOwnerProfile()

        XCTAssertEqual(promoted, "david")
        XCTAssertTrue(hasOwner)
    }

    func testPromoteSoleHumanProfileSkipsAmbiguousMultiProfileCase() async {
        let store = SpeakerProfileStore(storePath: makeTempStoreURL())
        await store.enroll(label: "david", embedding: [0.1, 0.2, 0.3], role: .guest, displayName: "David")
        await store.enroll(label: "sam", embedding: [0.2, 0.1, 0.4], role: .guest, displayName: "Sam")

        let promoted = await store.promoteSoleHumanProfileToOwnerIfUnambiguous()
        let hasOwner = await store.hasOwnerProfile()

        XCTAssertNil(promoted)
        XCTAssertFalse(hasOwner)
    }

    func testPromoteToOwnerNeverPromotesFaeSelf() async {
        let store = SpeakerProfileStore(storePath: makeTempStoreURL())
        await store.enroll(label: "fae_self", embedding: [0.4, 0.1, 0.2], role: .faeSelf, displayName: "Fae")

        let promoted = await store.promoteToOwner(label: "fae_self")
        let hasOwner = await store.hasOwnerProfile()

        XCTAssertFalse(promoted)
        XCTAssertFalse(hasOwner)
    }

    func testClearAllProfilesRemovesEverything() async {
        let store = SpeakerProfileStore(storePath: makeTempStoreURL())
        await store.enroll(label: "owner", embedding: [0.1, 0.2, 0.3], role: .owner, displayName: "David")
        await store.enroll(label: "fae_self", embedding: [0.4, 0.5, 0.6], role: .faeSelf, displayName: "Fae")
        await store.enroll(label: "guest1", embedding: [0.7, 0.8, 0.9], role: .guest, displayName: "Alice")

        let labelsBefore = await store.enrolledLabels
        XCTAssertEqual(labelsBefore.count, 3)

        await store.clearAllProfiles()

        let labelsAfter = await store.enrolledLabels
        XCTAssertTrue(labelsAfter.isEmpty)
        let hasOwner = await store.hasOwnerProfile()
        XCTAssertFalse(hasOwner)
    }

    func testMatchExcludingRolesSkipsFaeSelf() async {
        let store = SpeakerProfileStore(storePath: makeTempStoreURL())
        // Two profiles with identical embeddings — fae_self should be skipped.
        let embedding: [Float] = [1.0, 0.0, 0.0]
        await store.enroll(label: "fae_self", embedding: embedding, role: .faeSelf, displayName: "Fae")
        await store.enroll(label: "owner", embedding: embedding, role: .owner, displayName: "David")

        let match = await store.match(embedding: embedding, threshold: 0.5, excludingRoles: [.faeSelf])

        XCTAssertNotNil(match)
        XCTAssertEqual(match?.label, "owner")
        XCTAssertEqual(match?.role, .owner)
    }

    func testMatchesFaeSelfReturnsSimilarity() async {
        let store = SpeakerProfileStore(storePath: makeTempStoreURL())
        let embedding: [Float] = [1.0, 0.0, 0.0]
        await store.enroll(label: "fae_self", embedding: embedding, role: .faeSelf, displayName: "Fae")

        let sim = await store.matchesFaeSelf(embedding: embedding, threshold: 0.5)
        XCTAssertNotNil(sim)
        XCTAssertEqual(sim!, 1.0, accuracy: 0.001)
    }

    func testMatchesFaeSelfReturnsNilBelowThreshold() async {
        let store = SpeakerProfileStore(storePath: makeTempStoreURL())
        await store.enroll(label: "fae_self", embedding: [1.0, 0.0, 0.0], role: .faeSelf, displayName: "Fae")

        // Orthogonal embedding — cosine similarity = 0.
        let sim = await store.matchesFaeSelf(embedding: [0.0, 1.0, 0.0], threshold: 0.5)
        XCTAssertNil(sim)
    }

    func testMatchesFaeSelfReturnsNilWhenNoFaeSelf() async {
        let store = SpeakerProfileStore(storePath: makeTempStoreURL())
        await store.enroll(label: "owner", embedding: [1.0, 0.0, 0.0], role: .owner, displayName: "David")

        let sim = await store.matchesFaeSelf(embedding: [1.0, 0.0, 0.0], threshold: 0.5)
        XCTAssertNil(sim)
    }
}
