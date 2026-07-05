import XCTest
@testable import Fae

/// Coverage for two production-readiness audit fixes:
/// - R-H1: `FaeCore.waitUntilIdle` timeout path (respawn-when-idle budget).
/// - CR-H3: `DaemonEventSubscriber.stop()` returns promptly while the read loop
///   is blocked in `recv()` (previously a `queue.sync` deadlock).
final class AuditFixesTests: XCTestCase {

    /// Reference-typed counter so the poll closure can mutate across `await`
    /// without a captured-var concurrency warning.
    private final class Counter: @unchecked Sendable { var n = 0 }

    // MARK: - R-H1: waitUntilIdle

    func testWaitUntilIdleReturnsTrueImmediatelyWhenIdle() async {
        let counter = Counter()
        let ok = await FaeCore.waitUntilIdle(maxPolls: 5, pollNanos: 1_000_000) {
            counter.n += 1
            return true
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(counter.n, 1, "should stop polling as soon as idle")
    }

    func testWaitUntilIdleTimesOutWhenAlwaysBusy() async {
        let counter = Counter()
        let ok = await FaeCore.waitUntilIdle(maxPolls: 4, pollNanos: 1_000_000) {
            counter.n += 1
            return false
        }
        XCTAssertFalse(ok, "exhausting the budget while busy must report timeout")
        XCTAssertEqual(counter.n, 4, "should poll exactly maxPolls times")
    }

    func testWaitUntilIdleSucceedsWhenIdleMidway() async {
        let counter = Counter()
        let ok = await FaeCore.waitUntilIdle(maxPolls: 10, pollNanos: 1_000_000) {
            counter.n += 1
            return counter.n >= 3
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(counter.n, 3, "should return on the first idle observation")
    }

    // MARK: - CR-H3: DaemonEventSubscriber.stop() promptness

    func testStopReturnsPromptlyWhileReadLoopBlocked() throws {
        // Stand up a minimal fake daemon on a Unix socket that acks
        // session.authenticate + conversation.subscribe, then stays silent so the
        // subscriber's read loop parks in recv(). stop() must return promptly (it no
        // longer deadlocks on queue.sync against the blocked loop).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-sub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sockPath = dir.appendingPathComponent("d.sock").path
        let tokenPath = dir.appendingPathComponent("token").path
        try "test-token".write(toFile: tokenPath, atomically: true, encoding: .utf8)

        let listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listenFD, 0)
        defer { Darwin.close(listenFD) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        var pathBytes = Array(sockPath.utf8)
        pathBytes.append(0)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBytes { src in
                dst.copyBytes(from: src.prefix(dst.count))
            }
        }
        let bindRes = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindRes, 0, "bind failed: \(String(cString: strerror(errno)))")
        XCTAssertEqual(Darwin.listen(listenFD, 1), 0)

        // Keep the accepted connection alive for the test's duration.
        let connLock = NSLock()
        var connFD: Int32 = -1

        let server = DispatchQueue(label: "fake-daemon")
        server.async {
            let conn = Darwin.accept(listenFD, nil, nil)
            guard conn >= 0 else { return }
            connLock.lock(); connFD = conn; connLock.unlock()

            func readLine() {
                var acc = [UInt8]()
                var byte: UInt8 = 0
                while true {
                    let n = Darwin.recv(conn, &byte, 1, 0)
                    if n <= 0 { return }
                    if byte == 0x0A { return }
                    acc.append(byte)
                }
            }
            func sendOK() {
                var line = Array("{\"ok\":true}\n".utf8)
                _ = line.withUnsafeBytes { raw in
                    Darwin.send(conn, raw.baseAddress, raw.count, 0)
                }
            }
            readLine()  // session.authenticate frame
            sendOK()
            readLine()  // conversation.subscribe frame
            sendOK()
            // Then stay silent — the subscriber's read loop now blocks in recv().
        }
        defer {
            connLock.lock()
            let c = connFD
            connLock.unlock()
            if c >= 0 { Darwin.close(c) }
        }

        let subscriber = DaemonEventSubscriber(
            socketPath: sockPath,
            tokenPath: tokenPath,
            deliveryQueue: DispatchQueue(label: "delivery"),
            delivery: { _ in }
        )

        // start() is async; drive it synchronously with a semaphore.
        let started = expectation(description: "subscriber started")
        Task {
            do {
                try await subscriber.start()
                started.fulfill()
            } catch {
                XCTFail("subscriber.start() failed: \(error)")
                started.fulfill()
            }
        }
        wait(for: [started], timeout: 5.0)

        // Give the read loop a beat to reach the blocking recv().
        Thread.sleep(forTimeInterval: 0.1)

        // stop() must return promptly. Run it off the test thread so a regression
        // (deadlock) fails via timeout instead of hanging the whole process.
        let stopped = expectation(description: "stop returned")
        DispatchQueue.global().async {
            subscriber.stop()
            subscriber.stop()  // idempotent: safe to call multiple times
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 3.0)
    }
}
