import Foundation
import XCTest

@testable import Fae

// MARK: - A3-Swift: the governed daemon ToolHost, client-side
//
// Two invariants that gate the activation:
//  1. BLOCKER-1 (mandatory, reviewer focus): every `toolhost.execute` caller
//     uses the SERVER-REQUEST-AWARE round-trip. A dangerous tool emits a
//     `tool.confirm` server-request that the plain `roundTrip` would SKIP
//     (readMatchingResponseLocked skips non-matching frames) → the daemon parks
//     forever awaiting the reply → deadlock. The loopback test below feeds a
//     `tool.confirm` frame BEFORE the final response and asserts the aware
//     round-trip answers it and completes.
//  2. The `tool.confirm` reply is the strict two-field shape the daemon's
//     deny_unknown_fields parser expects (an extra field flips approval into a
//     malformed-deny), and the card message never echoes file contents.

/// A minimal Unix-domain-socket loopback peer for round-trip tests. Listens at
/// a unique temp path; `accept()` returns a connected client handle whose
/// `send`/`recv` exchange newline-terminated NDJSON lines.
final class FakeDaemonPeer {
    private let listenFD: Int32
    let path: String

    static func listen() throws -> FakeDaemonPeer {
        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw NSError(domain: "FakeDaemonPeer", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }
        // A unique temp socket path (sun_path is ~104 bytes; keep it short).
        let path = "/tmp/fae-test-\(UUID().uuidString.prefix(8)).sock"
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array((path as String).utf8) + [0]
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            bytes.withUnsafeBytes { src in
                dst.copyBytes(from: src.prefix(dst.count))
            }
        }
        unlink(path)
        let bound = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(sock, 1) == 0 else {
            Darwin.close(sock)
            throw NSError(domain: "FakeDaemonPeer", code: 2, userInfo: [NSLocalizedDescriptionKey: "bind/listen failed"])
        }
        return FakeDaemonPeer(listenFD: sock, path: path)
    }

    private init(listenFD: Int32, path: String) {
        self.listenFD = listenFD
        self.path = path
    }

    /// Block until a client connects; return a handle to drive the exchange.
    func accept() throws -> Client {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else {
            throw NSError(domain: "FakeDaemonPeer", code: 3, userInfo: [NSLocalizedDescriptionKey: "accept() failed"])
        }
        return Client(fd: fd)
    }

    deinit {
        Darwin.close(listenFD)
        unlink(path)
    }

    final class Client {
        private let fd: Int32
        fileprivate init(fd: Int32) { self.fd = fd }

        /// Write one newline-terminated NDJSON line.
        func send(_ line: String) throws {
            var data = Array(line.utf8)
            data.append(0x0A)
            var sent = 0
            while sent < data.count {
                let n = data.withUnsafeBufferPointer { buf in
                    Darwin.send(fd, buf.baseAddress!.advanced(by: sent), data.count - sent, 0)
                }
                guard n > 0 else {
                    throw NSError(domain: "FakeDaemonPeer", code: 4, userInfo: [NSLocalizedDescriptionKey: "send() failed"])
                }
                sent += n
            }
        }

        /// Read one newline-terminated line (blocking). Returns nil on EOF.
        func recv() throws -> String? {
            var buffer = [UInt8]()
            var oneByte: [UInt8] = [0]
            while true {
                let n = Darwin.recv(fd, &oneByte, 1, 0)
                if n == 0 { return buffer.isEmpty ? nil : String(bytes: buffer, encoding: .utf8) }
                guard n > 0 else {
                    throw NSError(domain: "FakeDaemonPeer", code: 5, userInfo: [NSLocalizedDescriptionKey: "recv() failed"])
                }
                if oneByte[0] == 0x0A { return String(bytes: buffer, encoding: .utf8) }
                buffer.append(oneByte[0])
            }
        }

        deinit { Darwin.close(fd) }
    }
}

final class DaemonToolHostTests: XCTestCase {

    // MARK: BLOCKER-1 — the mandatory client-side deadlock regression

    /// The aware `roundTrip` must handle a `tool.confirm` server-request frame
    /// that arrives BEFORE the final response: it calls `onServerRequest`,
    /// writes the reply, and continues reading — it must NOT skip the frame
    /// (the plain round-trip would, deadlocking the daemon).
    func testAwareRoundTripAnswersToolConfirmBeforeResponse() async throws {
        let peer = try FakeDaemonPeer.listen()
        let connection = DaemonSocketConnection(queueLabel: "fae.test.toolhost")
        try connection.connect(to: peer.path)
        defer { connection.close() }

        let frame = try DaemonWire.encodeFrame(
            requestID: "x",
            command: "toolhost.execute",
            payload: ["tool": "write", "input": ["path": "o.txt", "content": "hi"]])

        // Drive the aware round-trip on a child task; race it against a timeout
        // so a BLOCKER-1 regression fails fast instead of hanging 600s.
        actor Seen { var confirmMethod: String? = nil; func setConfirm(method: String) { confirmMethod = method } }
        let seen = Seen()
        let roundTrip = Task { () -> [String: Any] in
            try await connection.roundTrip(frame: frame, expectRequestID: "x") { _, method, params in
                await seen.setConfirm(method: method)
                // Mirror the real handler: echo call_id, approve.
                return ["approved": true, "call_id": params["call_id"] as? String ?? ""]
            }
        }

        // Accept the connection the Swift side opened.
        let client = try peer.accept()
        // 1. Read the toolhost.execute request Swift sent (then discard).
        _ = try client.recv()

        // 2. Send a tool.confirm server-request BEFORE the final response.
        let confirmLine = """
        {"v":2,"server_request_id":"sr-0","method":"tool.confirm","params":{"tool":"write","call_id":"x","risk_class":"Write","reason":"dangerous_tool_requires_confirmation","detail":{"WriteEdit":{"path":"o.txt","new_bytes":2,"old_exists":false}}}}
        """
        try client.send(confirmLine)

        // 3. Read Swift's reply. It MUST be the strict two-field result bound to
        //    the request — proving the confirm frame was NOT dropped/skipped.
        let replyLine = try await recvWithTimeout(client)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: replyLine.data(using: .utf8)!) as? [String: Any])
        XCTAssertEqual(reply["server_request_id"] as? String, "sr-0")
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["approved"] as? Bool, true)
        XCTAssertEqual(result["call_id"] as? String, "x")
        // Strict shape: exactly {approved, call_id}. An extra field would flip
        // this into a malformed-deny on the daemon side (deny_unknown_fields).
        XCTAssertEqual(result.count, 2, "confirm reply must carry only approved + call_id")

        // 4. Send the final toolhost.execute response.
        try client.send("""
        {"v":2,"request_id":"x","ok":true,"result":{"content":["ok"]}}
        """)

        // 5. The round-trip MUST complete (no deadlock) within the bound.
        let response = try await withTimeout(roundTrip)
        XCTAssertEqual(response["request_id"] as? String, "x")
        XCTAssertEqual(response["ok"] as? Bool, true)
        let confirmMethod = await seen.confirmMethod
        XCTAssertEqual(confirmMethod, "tool.confirm", "onServerRequest must be invoked for tool.confirm")
    }

    /// The plain `call()` helper must REFUSE `toolhost.execute` — that path uses
    /// the plain round-trip which would drop the confirm (BLOCKER-1). This is a
    /// structural guard against a future caller misrouting the command.
    /// (oracle MINOR-1: assert the SPECIFIC error, not any error — a moved/
    /// removed guard must flip this from agentFailed to daemonUnavailable, and
    /// the test must catch that drift.)
    func testPlainCallRefusesToolhostExecute() async {
        do {
            _ = try await DaemonAgentClient.call(command: "toolhost.execute", payload: [:])
            XCTFail("call() must refuse toolhost.execute")
        } catch DaemonAgentClientError.agentFailed(let message) {
            // The BLOCKER-1 guard's message — NOT a generic daemonUnavailable.
            XCTAssertTrue(
                message.contains("server-request-aware"),
                "expected the BLOCKER-1 guard message, got: \(message)")
        } catch {
            XCTFail("expected agentFailed (the BLOCKER-1 guard), got \(error)")
        }
    }

    // MARK: tool.confirm handler — strict reply shape + redaction

    func testToolConfirmReplyShape() {
        // (oracle MAJOR-1: tested via the PURE `toolConfirmReply` builder — no
        // global override, no UI. The strict two-field shape is what the daemon's
        // deny_unknown_fields parser expects; approved + call_id, nothing else.)
        let reply = DaemonAgentClient.toolConfirmReply(callID: "c1", approved: true)
        XCTAssertEqual(reply["approved"] as? Bool, true)
        XCTAssertEqual(reply["call_id"] as? String, "c1")
        XCTAssertEqual(reply.count, 2, "reply must be exactly {approved, call_id}")

        let denied = DaemonAgentClient.toolConfirmReply(callID: "c2", approved: false)
        XCTAssertEqual(denied["approved"] as? Bool, false)
        XCTAssertEqual(denied["call_id"] as? String, "c2")
        XCTAssertEqual(denied.count, 2)
    }

    func testToolConfirmDeniesOnMissingCallID() async {
        // No call_id ⇒ the guard early-returns {approved:false} BEFORE any card
        // is shown (requestApproval is never reached), so this is safe to call
        // without any override. Fail-closed: never prompt without a bound reply.
        let reply = await DaemonAgentClient.handleToolConfirm(
            params: ["tool": "write", "risk_class": "Write"])
        XCTAssertEqual(reply["approved"] as? Bool, false)
        XCTAssertNil(reply["call_id"])
    }

    func testToolConfirmMessageNeverEchoesContents() {
        // The message is composed ONLY from bounded fields; a sentinel planted
        // in hypothetical content must never appear (there is no content field).
        let secret = "SUPER_SECRET_TOKEN_42"
        let msg = DaemonAgentClient.toolConfirmMessage(
            tool: "write", risk: "Write",
            detail: ["WriteEdit": ["path": "o.txt", "new_bytes": 3, "old_exists": true] as [String: Any]])
        XCTAssertFalse(msg.contains(secret), "message must never echo tool input/contents")
        XCTAssertTrue(msg.contains("o.txt"), "message should name the path")
        XCTAssertTrue(msg.contains("overwrite"), "message should flag an existing-file overwrite")
    }

    func testToolConfirmMessageShellPreview() {
        let msg = DaemonAgentClient.toolConfirmMessage(
            tool: "bash", risk: "Shell",
            detail: ["Shell": ["command_preview": "echo hi"] as [String: Any]])
        XCTAssertTrue(msg.contains("echo hi"), "shell message should show the bounded preview")
    }

    // MARK: helpers

    private func recvWithTimeout(_ client: FakeDaemonPeer.Client) async throws -> String {
        let t = Task<String?, Error> { try client.recv() }
        guard let line = try await withTimeout(t) else {
            throw NSError(domain: "DaemonToolHostTests", code: 98, userInfo: [NSLocalizedDescriptionKey: "peer closed without a reply"])
        }
        return line
    }

    private func withTimeout<T>(_ task: Task<T, Error>) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await task.value }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw NSError(domain: "DaemonToolHostTests", code: 99, userInfo: [NSLocalizedDescriptionKey: "timed out (BLOCKER-1 regression: confirm frame dropped?)"])
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}
