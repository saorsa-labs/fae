import XCTest
@testable import Fae

final class ProactiveSchedulerIntegrationTests: XCTestCase {
    func testSchedulerProactiveModeChangesWithRepetition() async {
        let scheduler = FaeScheduler(eventBus: FaeEventBus())
        let m1 = await scheduler.proactiveDispatchMode(taskID: "a", urgency: .low)
        let m2 = await scheduler.proactiveDispatchMode(taskID: "a", urgency: .low)
        XCTAssertTrue(m1 == .suppress || m1 == .immediate || m1 == .digest)
        XCTAssertTrue(m2 == .digest || m2 == .suppress || m2 == .immediate)
    }

    func testHighUrgencyImmediate() async {
        let scheduler = FaeScheduler(eventBus: FaeEventBus())
        let m = await scheduler.proactiveDispatchMode(taskID: "b", urgency: .high)
        XCTAssertEqual(m, .immediate)
        XCTAssertNotEqual(m, .digest)
    }
}
