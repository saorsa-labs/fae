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
}
