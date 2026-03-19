import XCTest
@testable import Fae

// MARK: - ChannelHealthStatus Tests

final class ChannelHealthStatusTests: XCTestCase {

    func testConnectedIsHealthy() {
        let status = ChannelHealthStatus.connected
        XCTAssertTrue(status.isHealthy)
        XCTAssertEqual(status.description, "connected")
    }

    func testDisconnectedIsNotHealthy() {
        let status = ChannelHealthStatus.disconnected
        XCTAssertFalse(status.isHealthy)
        XCTAssertEqual(status.description, "disconnected")
    }

    func testReconnectingIsNotHealthy() {
        let status = ChannelHealthStatus.reconnecting(attempt: 3)
        XCTAssertFalse(status.isHealthy)
        XCTAssertTrue(status.description.contains("attempt 3"))
    }

    func testErrorIsNotHealthy() {
        let status = ChannelHealthStatus.error("connection refused")
        XCTAssertFalse(status.isHealthy)
        XCTAssertTrue(status.description.contains("connection refused"))
    }

    func testStatusEquality() {
        XCTAssertEqual(ChannelHealthStatus.connected, ChannelHealthStatus.connected)
        XCTAssertEqual(ChannelHealthStatus.disconnected, ChannelHealthStatus.disconnected)
        XCTAssertNotEqual(ChannelHealthStatus.connected, ChannelHealthStatus.disconnected)
        XCTAssertEqual(
            ChannelHealthStatus.reconnecting(attempt: 1),
            ChannelHealthStatus.reconnecting(attempt: 1)
        )
        XCTAssertNotEqual(
            ChannelHealthStatus.reconnecting(attempt: 1),
            ChannelHealthStatus.reconnecting(attempt: 2)
        )
    }
}

// MARK: - ChannelHealthMonitor Tests

final class ChannelHealthMonitorTests: XCTestCase {

    func testStartSetsAllAdaptersToConnected() async {
        let monitor = ChannelHealthMonitor(
            eventBus: FaeEventBus(),
            config: ChannelHealthMonitor.Config(checkIntervalSeconds: 999)
        )

        let adapter = HealthTestAdapter(kind: .discord)
        await monitor.start(adapters: [.discord: adapter])

        let status = await monitor.status(for: .discord)
        XCTAssertEqual(status, .connected)

        await monitor.stop()
    }

    func testStatusReturnsNilForUnmonitoredChannel() async {
        let monitor = ChannelHealthMonitor(eventBus: FaeEventBus())

        let status = await monitor.status(for: .discord)
        XCTAssertNil(status)
    }

    func testReportErrorChangesStatus() async {
        let monitor = ChannelHealthMonitor(
            eventBus: FaeEventBus(),
            config: ChannelHealthMonitor.Config(checkIntervalSeconds: 999)
        )

        let adapter = HealthTestAdapter(kind: .whatsapp)
        await monitor.start(adapters: [.whatsapp: adapter])

        await monitor.reportError(kind: .whatsapp, error: "connection lost")

        let status = await monitor.status(for: .whatsapp)
        XCTAssertEqual(status, .error("connection lost"))

        await monitor.stop()
    }

    func testReportConnectedResetsStatus() async {
        let monitor = ChannelHealthMonitor(
            eventBus: FaeEventBus(),
            config: ChannelHealthMonitor.Config(checkIntervalSeconds: 999)
        )

        let adapter = HealthTestAdapter(kind: .discord)
        await monitor.start(adapters: [.discord: adapter])

        await monitor.reportError(kind: .discord, error: "test error")
        await monitor.reportConnected(kind: .discord)

        let status = await monitor.status(for: .discord)
        XCTAssertEqual(status, .connected)

        await monitor.stop()
    }

    func testReportDisconnectedChangesStatus() async {
        let monitor = ChannelHealthMonitor(
            eventBus: FaeEventBus(),
            config: ChannelHealthMonitor.Config(checkIntervalSeconds: 999)
        )

        let adapter = HealthTestAdapter(kind: .imessage)
        await monitor.start(adapters: [.imessage: adapter])

        await monitor.reportDisconnected(kind: .imessage)

        let status = await monitor.status(for: .imessage)
        XCTAssertEqual(status, .disconnected)

        await monitor.stop()
    }

    func testAllStatusesReturnsAllAdapterStatuses() async {
        let monitor = ChannelHealthMonitor(
            eventBus: FaeEventBus(),
            config: ChannelHealthMonitor.Config(checkIntervalSeconds: 999)
        )

        let discord = HealthTestAdapter(kind: .discord)
        let whatsapp = HealthTestAdapter(kind: .whatsapp)
        await monitor.start(adapters: [.discord: discord, .whatsapp: whatsapp])

        await monitor.reportError(kind: .discord, error: "test")

        let statuses = await monitor.allStatuses
        XCTAssertEqual(statuses.count, 2)
        XCTAssertEqual(statuses[.discord], .error("test"))
        XCTAssertEqual(statuses[.whatsapp], .connected)

        await monitor.stop()
    }

    func testAttemptReconnectSucceeds() async {
        let monitor = ChannelHealthMonitor(
            eventBus: FaeEventBus(),
            config: ChannelHealthMonitor.Config(
                checkIntervalSeconds: 999,
                baseRetryDelay: 0.01,
                maxRetryDelay: 0.01
            )
        )

        let adapter = HealthTestAdapter(kind: .discord)
        await monitor.start(adapters: [.discord: adapter])
        await monitor.reportDisconnected(kind: .discord)

        let result = await monitor.attemptReconnect(kind: .discord)

        XCTAssertTrue(result)
        let status = await monitor.status(for: .discord)
        XCTAssertEqual(status, .connected)

        // Adapter should have been restarted.
        XCTAssertEqual(adapter.startCount, 1)
        XCTAssertEqual(adapter.stopCount, 1)

        await monitor.stop()
    }

    func testAttemptReconnectFailsOnAdapterError() async {
        let monitor = ChannelHealthMonitor(
            eventBus: FaeEventBus(),
            config: ChannelHealthMonitor.Config(
                checkIntervalSeconds: 999,
                baseRetryDelay: 0.01,
                maxRetryDelay: 0.01
            )
        )

        let adapter = HealthTestAdapter(kind: .discord, shouldFailStart: true)
        await monitor.start(adapters: [.discord: adapter])
        await monitor.reportDisconnected(kind: .discord)

        let result = await monitor.attemptReconnect(kind: .discord)

        XCTAssertFalse(result)
        let status = await monitor.status(for: .discord)
        if case .error = status {
            // Expected.
        } else {
            XCTFail("Expected error status after failed reconnect, got \(String(describing: status))")
        }

        await monitor.stop()
    }

    func testMaxReconnectAttemptsExceeded() async {
        let monitor = ChannelHealthMonitor(
            eventBus: FaeEventBus(),
            config: ChannelHealthMonitor.Config(
                checkIntervalSeconds: 999,
                maxReconnectAttempts: 2,
                baseRetryDelay: 0.01,
                maxRetryDelay: 0.01
            )
        )

        let adapter = HealthTestAdapter(kind: .discord, shouldFailStart: true)
        await monitor.start(adapters: [.discord: adapter])
        await monitor.reportDisconnected(kind: .discord)

        // Attempt 1.
        _ = await monitor.attemptReconnect(kind: .discord)
        // Attempt 2.
        _ = await monitor.attemptReconnect(kind: .discord)
        // Attempt 3 — should be rejected.
        let result = await monitor.attemptReconnect(kind: .discord)

        XCTAssertFalse(result)
        let status = await monitor.status(for: .discord)
        if case .error(let msg) = status {
            XCTAssertTrue(msg.contains("Max reconnect attempts"))
        } else {
            XCTFail("Expected max-attempts error, got \(String(describing: status))")
        }

        await monitor.stop()
    }

    func testStopClearsState() async {
        let monitor = ChannelHealthMonitor(
            eventBus: FaeEventBus(),
            config: ChannelHealthMonitor.Config(checkIntervalSeconds: 999)
        )

        let adapter = HealthTestAdapter(kind: .discord)
        await monitor.start(adapters: [.discord: adapter])
        await monitor.stop()

        let status = await monitor.status(for: .discord)
        XCTAssertNil(status)
    }
}

// MARK: - Gateway Health Integration Tests

final class GatewayHealthIntegrationTests: XCTestCase {

    func testGatewayStartReportsHealthy() async {
        let monitor = ChannelHealthMonitor(
            eventBus: FaeEventBus(),
            config: ChannelHealthMonitor.Config(checkIntervalSeconds: 999)
        )
        let gateway = ChannelGateway(
            eventBus: FaeEventBus(),
            healthMonitor: monitor
        )

        let adapter = HealthTestAdapter(kind: .discord)
        await gateway.registerAdapter(adapter)
        await gateway.start()

        let status = await monitor.status(for: .discord)
        XCTAssertEqual(status, .connected)

        await gateway.stop()
    }

    func testGatewayStartReportsErrorForFailedAdapter() async {
        let monitor = ChannelHealthMonitor(
            eventBus: FaeEventBus(),
            config: ChannelHealthMonitor.Config(checkIntervalSeconds: 999)
        )
        let gateway = ChannelGateway(
            eventBus: FaeEventBus(),
            healthMonitor: monitor
        )

        let adapter = HealthTestAdapter(kind: .discord, shouldFailStart: true)
        await gateway.registerAdapter(adapter)
        await gateway.start()

        let status = await monitor.status(for: .discord)
        if case .error = status {
            // Expected — adapter start failed.
        } else {
            XCTFail("Expected error status for failed adapter start, got \(String(describing: status))")
        }

        await gateway.stop()
    }

    func testGatewayExposesHealthMonitor() async {
        let gateway = ChannelGateway(eventBus: FaeEventBus())
        let monitor = await gateway.health
        let statuses = await monitor.allStatuses
        XCTAssertTrue(statuses.isEmpty)
    }
}

// MARK: - Test Adapter

private final class HealthTestAdapter: ChannelAdapter, @unchecked Sendable {
    let kind: ChannelKind
    var onMessage: (@Sendable (ChannelMessage) async -> String?)?

    private let lock = NSLock()
    private var _startCount = 0
    private var _stopCount = 0
    private let shouldFailStart: Bool

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _startCount
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _stopCount
    }

    init(kind: ChannelKind, shouldFailStart: Bool = false) {
        self.kind = kind
        self.shouldFailStart = shouldFailStart
    }

    func start() async throws {
        lock.lock()
        _startCount += 1
        lock.unlock()

        if shouldFailStart {
            throw NSError(domain: "test", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "simulated start failure",
            ])
        }
    }

    func stop() async {
        lock.lock()
        _stopCount += 1
        lock.unlock()
    }

    func send(response: String, to message: ChannelMessage) async throws {}
}
