import XCTest
@testable import Fae

final class WorkerStreamWatchdogPolicyTests: XCTestCase {
    func testInitialResponseTimeoutIsLongerThanActiveStreamTimeout() {
        XCTAssertGreaterThan(
            WorkerStreamWatchdogPolicy.timeout(for: .awaitingFirstEvent),
            WorkerStreamWatchdogPolicy.timeout(for: .streamingActive)
        )
    }

    func testWatchdogPhaseDescriptionsRemainUserReadable() {
        XCTAssertEqual(WorkerStreamWatchdogPhase.awaitingFirstEvent.description, "waiting for first token")
        XCTAssertEqual(WorkerStreamWatchdogPhase.streamingActive.description, "stream stalled")
    }
}
