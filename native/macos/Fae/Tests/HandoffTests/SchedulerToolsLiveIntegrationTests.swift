import XCTest
@testable import Fae

final class SchedulerToolsLiveIntegrationTests: XCTestCase {
    func testStatusAllContainsToggledTask() async {
        let scheduler = FaeScheduler(eventBus: FaeEventBus())
        await scheduler.setTaskEnabled(id: "task_a", enabled: false)
        let all = await scheduler.statusAll()
        XCTAssertTrue(all.contains { ($0["id"] as? String) == "task_a" })
        XCTAssertTrue(all.contains { ($0["id"] as? String) == "task_a" && ($0["enabled"] as? Bool) == false })
    }
}
