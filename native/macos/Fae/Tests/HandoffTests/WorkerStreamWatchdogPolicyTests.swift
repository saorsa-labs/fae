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

    func testLoadCommandTimeoutAllowsFirstRunDownloads() {
        XCTAssertGreaterThan(
            WorkerCommandTimeoutPolicy.timeout(for: "load"),
            WorkerCommandTimeoutPolicy.timeout(for: "warmup")
        )
        XCTAssertGreaterThan(
            WorkerCommandTimeoutPolicy.timeout(for: "load"),
            WorkerCommandTimeoutPolicy.timeout(for: "generate")
        )
    }

    func testControlCommandsKeepFastTimeouts() {
        XCTAssertEqual(
            WorkerCommandTimeoutPolicy.timeout(for: "generate"),
            WorkerCommandTimeoutPolicy.defaultTimeoutNanoseconds
        )
        XCTAssertEqual(
            WorkerCommandTimeoutPolicy.timeout(for: "cancel"),
            WorkerCommandTimeoutPolicy.defaultTimeoutNanoseconds
        )
        XCTAssertEqual(
            WorkerCommandTimeoutPolicy.timeout(for: "warmup"),
            WorkerCommandTimeoutPolicy.warmupTimeoutNanoseconds
        )
    }
}
