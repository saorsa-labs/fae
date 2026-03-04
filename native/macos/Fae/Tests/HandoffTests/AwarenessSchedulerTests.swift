import XCTest
@testable import Fae

final class AwarenessSchedulerTests: XCTestCase {

    func testScreenContextCoalescingByHash() async {
        let scheduler = FaeScheduler(eventBus: FaeEventBus())

        let first = await scheduler.shouldPersistScreenContext(contentHash: "hash-a")
        let duplicate = await scheduler.shouldPersistScreenContext(contentHash: "hash-a")
        let changed = await scheduler.shouldPersistScreenContext(contentHash: "hash-b")

        XCTAssertTrue(first)
        XCTAssertFalse(duplicate)
        XCTAssertTrue(changed)
    }
}
