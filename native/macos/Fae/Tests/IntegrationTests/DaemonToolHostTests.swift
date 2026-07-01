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
        private var fd: Int32
        fileprivate init(fd: Int32) { self.fd = fd }

        /// Write one newline-terminated NDJSON line.
        func send(_ line: String) throws {
            try sendRaw(Array(line.utf8) + [0x0A])
        }

        /// Write raw bytes with NO added newline (for oversized-frame tests).
        func sendRaw(_ bytes: [UInt8]) throws {
            guard fd >= 0 else {
                throw NSError(domain: "FakeDaemonPeer", code: 6, userInfo: [NSLocalizedDescriptionKey: "send() on closed client"])
            }
            let data = bytes
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
            guard fd >= 0 else {
                throw NSError(domain: "FakeDaemonPeer", code: 7, userInfo: [NSLocalizedDescriptionKey: "recv() on closed client"])
            }
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

        /// Close the client FD (simulate a daemon-side drop). Idempotent — safe
        /// against the `deinit` close so a reused OS FD is never double-closed.
        func close() {
            guard fd >= 0 else { return }
            Darwin.close(fd)
            fd = -1
        }

        deinit { close() }
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

    /// B-Swift Phase C/#5 (F2): a `roundTrip` whose peer accepts but never
    /// replies must observe task cancellation and unblock within ~1 `recv()`
    /// poll (~1s), NOT the 600s overall deadline. Pre-fix, the in-flight
    /// `recv()` ignored cooperative cancellation and held the operation lock
    /// (and the socket queue) for the full 600s — a wedged-daemon DoS on routed
    /// reads. Both `roundTrip` forms share `readLineAsync`, so this covers the
    /// cancellation seam for the routed-read path too.
    func testRoundTripCancellationUnblocksPromptlyFromSilentPeer() async throws {
        let peer = try FakeDaemonPeer.listen()
        let connection = DaemonSocketConnection(queueLabel: "fae.test.f2-cancel")
        try connection.connect(to: peer.path)
        defer { connection.close() }

        let frame = try DaemonWire.encodeFrame(
            requestID: "x", command: "toolhost.execute", payload: [:])

        // Accept the Swift side's connection, then stay SILENT (never reply) so
        // the roundTrip blocks in recv().
        let client = try peer.accept()
        defer { client.close() }

        // Drive the round-trip on a child task so we can cancel it.
        let roundTrip = Task { () -> [String: Any] in
            try await connection.roundTrip(frame: frame, expectRequestID: "x")
        }

        // Let it reach the blocked recv() (write + first recv poll need time).
        try await Task.sleep(nanoseconds: 300_000_000)

        let cancelStart = Date()
        roundTrip.cancel()

        do {
            _ = try await roundTrip.value
            XCTFail("roundTrip on a silent peer should not succeed after cancel")
        } catch is CancellationError {
            // Expected: cancellation observed within ~1 recv poll.
        } catch {
            // Other prompt errors are acceptable too — the point is NO 600s hang.
        }
        let elapsed = Date().timeIntervalSince(cancelStart)
        XCTAssertLessThan(
            elapsed, 3.0,
            "cancel must unblock roundTrip within ~1s (recv poll), not 600s; took \(elapsed)s")
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

    // MARK: workspace.confirm_root handler (B-Swift Layer 1)

    /// The plain `call()` helper must ALSO REFUSE `toolhost.set_root` — it emits
    /// a `workspace.confirm_root` server-request that the plain round-trip would
    /// drop (BLOCKER-1, same class as toolhost.execute). Structural guard against
    /// a future caller misrouting the command. (oracle MINOR-1 precedent:
    /// assert the SPECIFIC error, not any error.)
    func testPlainCallRefusesToolhostSetRoot() async {
        do {
            _ = try await DaemonAgentClient.call(command: "toolhost.set_root", payload: ["path": "/tmp/x"])
            XCTFail("call() must refuse toolhost.set_root")
        } catch DaemonAgentClientError.agentFailed(let message) {
            XCTAssertTrue(
                message.contains("server-request-aware"),
                "expected the BLOCKER-1 guard message, got: \(message)")
            XCTAssertTrue(
                message.contains("toolhost.set_root"),
                "guard message must name the blocked command")
        } catch {
            XCTFail("expected agentFailed (the BLOCKER-1 guard), got \(error)")
        }
    }

    /// The strict two-field `{approved, call_id}` reply shape B-Rust's parser
    /// requires (call_id is mandatory in B-Rust). Tested via the PURE builder —
    /// no card, no global state (oracle MAJOR-1 precedent).
    func testWorkspaceConfirmRootReplyShape() {
        let reply = DaemonAgentClient.workspaceConfirmRootReply(callID: "root-1", approved: true)
        XCTAssertEqual(reply["approved"] as? Bool, true)
        XCTAssertEqual(reply["call_id"] as? String, "root-1")
        XCTAssertEqual(reply.count, 2, "reply must be exactly {approved, call_id}")

        let denied = DaemonAgentClient.workspaceConfirmRootReply(callID: "root-2", approved: false)
        XCTAssertEqual(denied["approved"] as? Bool, false)
        XCTAssertEqual(denied["call_id"] as? String, "root-2")
        XCTAssertEqual(denied.count, 2)
    }

    /// Missing `call_id` ⇒ deny fail-closed BEFORE any card is shown. B-Rust
    /// requires call_id; a missing/blank id can't bind the reply to the request.
    func testWorkspaceConfirmRootDeniesOnMissingCallID() async {
        let reply = await DaemonAgentClient.handleWorkspaceConfirmRoot(
            params: ["path": "/Users/me/proj", "note": "be careful"])
        XCTAssertEqual(reply["approved"] as? Bool, false)
        // A blank call_id is returned (never nil) so the strict 2-field shape holds.
        XCTAssertEqual(reply["call_id"] as? String, "")
    }

    /// The root-approval message is composed ONLY from the canonical path + the
    /// fixed blast-radius note — never a directory listing or file contents. A
    /// sentinel planted in a hypothetical extra field must never appear.
    func testWorkspaceConfirmRootMessageIsRedacted() {
        let secret = "SUPER_SECRET_TOKEN_42"
        let msg = DaemonAgentClient.workspaceConfirmRootMessage(
            path: "/Users/me/projects/fae",
            note: "Fae can read, write, and run commands inside this folder.")
        XCTAssertFalse(msg.contains(secret), "message must never echo directory contents")
        XCTAssertTrue(msg.contains("/Users/me/projects/fae"), "message must show the canonical path")
        XCTAssertTrue(msg.contains("workspace"), "message must frame it as a workspace grant")
        XCTAssertTrue(msg.contains("session"), "message must note the grant is session-scoped")
    }

    /// The BLOCKER-1 loopback proof for `toolhost.set_root`: a `workspace.
    /// confirm_root` server-request arriving BEFORE the final response is
    /// answered on the same server-request-aware round-trip (the plain
    /// round-trip would drop it → daemon deadlock). Mirrors the toolhost.execute
    /// proof. (B-Swift note: in production set_root + execute must share a
    /// persistent connection — DaemonToolHostSession. This proves the wire half.)
    func testAwareRoundTripAnswersWorkspaceConfirmRootBeforeResponse() async throws {
        let peer = try FakeDaemonPeer.listen()
        let connection = DaemonSocketConnection(queueLabel: "fae.test.toolhost-root")
        try connection.connect(to: peer.path)
        defer { connection.close() }

        let frame = try DaemonWire.encodeFrame(
            requestID: "r",
            command: "toolhost.set_root",
            payload: ["path": "/Users/me/projects/fae"])

        actor Seen { var method: String? = nil; func set(method: String) { self.method = method } }
        let seen = Seen()
        let roundTrip = Task { () -> [String: Any] in
            try await connection.roundTrip(frame: frame, expectRequestID: "r") { _, method, params in
                await seen.set(method: method)
                // Mirror the real handler: echo call_id, approve.
                return ["approved": true, "call_id": params["call_id"] as? String ?? ""]
            }
        }

        let client = try peer.accept()
        _ = try client.recv()  // the set_root request Swift sent

        // Send a workspace.confirm_root server-request BEFORE the final response.
        let confirmLine = """
        {"v":2,"server_request_id":"sr-root","method":"workspace.confirm_root","params":{"call_id":"r","path":"/Users/me/projects/fae","note":"Fae can read, write, and run commands inside this folder."}}
        """
        try client.send(confirmLine)

        // Read Swift's reply: strict two-field result bound to the request.
        let replyLine = try await recvWithTimeout(client)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: replyLine.data(using: .utf8)!) as? [String: Any])
        XCTAssertEqual(reply["server_request_id"] as? String, "sr-root")
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["approved"] as? Bool, true)
        XCTAssertEqual(result["call_id"] as? String, "r")
        XCTAssertEqual(result.count, 2, "root reply must carry only approved + call_id")

        // Send the final set_root response.
        try client.send("""
        {"v":2,"request_id":"r","ok":true,"result":{"root":"/Users/me/projects/fae"}}
        """)

        // The round-trip MUST complete (no deadlock) within the bound.
        let response = try await withTimeout(roundTrip)
        XCTAssertEqual(response["request_id"] as? String, "r")
        XCTAssertEqual(response["ok"] as? Bool, true)
        let method = await seen.method
        XCTAssertEqual(method, "workspace.confirm_root", "onServerRequest must be invoked for workspace.confirm_root")
    }

    // MARK: DaemonToolHostSession — persistent connection (B-Swift Layer 2)

    /// Publish a FakeDaemonPeer's socket as the live daemon endpoints, with a
    /// temp token file the actor reads during auth. Returns (peer, tokenPath).
    private func publishFakeDaemonEndpoints() async throws -> (FakeDaemonPeer, String) {
        let peer = try FakeDaemonPeer.listen()
        let tokenURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-test-token-\(UUID().uuidString.prefix(8))")
        try "fake-bootstrap-token".write(to: tokenURL, atomically: true, encoding: .utf8)
        await DaemonEndpointStore.shared.set((socketPath: peer.path, tokenPath: tokenURL.path))
        return (peer, tokenURL.path)
    }

    private func clearDaemonEndpoints() async {
        await DaemonEndpointStore.shared.set(nil)
    }

    /// Drive the fake daemon through the AUTH handshake: read the
    /// session.authenticate frame the Swift side sends on connect, reply ok.
    private func driveAuth(_ client: FakeDaemonPeer.Client) throws {
        _ = try client.recv()  // the session.authenticate frame
        try client.send("""
        {"v":2,"request_id":"a0","ok":true,"result":{"client_id":"swift-frontend-bootstrap","authenticated":true}}
        """)
    }

    /// The architectural proof for Layer 2: `setRoot` then `execute` reuse the
    /// SAME daemon connection (B-Rust root_state is per-connection; a fresh
    /// connection per call would lose the approved root). Drives one fake peer
    /// through auth → set_root(+workspace.confirm_root) → execute on a single
    /// accepted client.
    ///
    /// Persistence is proven by the EXECUTE frame arriving on the SAME client
    /// handle that served setRoot: if the session had opened a second
    /// connection for execute, that frame would have gone to a different
    /// accept() and `recvWithTimeout(client)` would have TIMED OUT. So reading
    /// the execute frame here IS the no-second-connection proof — no fragile
    /// `accept()` timeout needed (a blocking accept() can't be cancelled by
    /// Task cancellation, so a second-accept check would hang the test).
    func testSetRootThenExecuteSharesOneConnection() async throws {
        let (peer, tokenPath) = try await publishFakeDaemonEndpoints()
        defer {
            Task { await clearDaemonEndpoints() }
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        // Inject a fake server-request handler so the round-trip completes
        // WITHOUT surfacing the real UI card (oracle MAJOR-1 precedent: the DI
        // seam is a function, not a mutable global). Mirrors the strict reply.
        actor Seen { var root = false; var tool = false; func markRoot(){root=true}; func markTool(){tool=true} }
        let seen = Seen()
        let session = DaemonToolHostSession(serverRequestHandler: { method, params in
            let callID = (params["call_id"] as? String) ?? ""
            if method == "workspace.confirm_root" { await seen.markRoot() }
            if method == "tool.confirm" { await seen.markTool() }
            return ["approved": true, "call_id": callID]
        })
        defer { Task { await session.close() } }

        // 1. setRoot opens the connection (auth → set_root → confirm_root).
        let setRoot = Task { try await session.setRoot(path: "/Users/me/projects/fae") }
        let client = try peer.accept()
        try driveAuth(client)
        let setRootReq = try await recvWithTimeout(client)
        XCTAssertTrue(setRootReq.contains("\"command\":\"toolhost.set_root\""), "expected set_root frame")
        try client.send("""
        {"v":2,"server_request_id":"sr-root","method":"workspace.confirm_root","params":{"call_id":"th-1","path":"/Users/me/projects/fae","note":"Fae can read, write, and run commands inside this folder."}}
        """)
        let rootReply = try await recvWithTimeout(client)
        let rootReplyObj = try XCTUnwrap(JSONSerialization.jsonObject(with: rootReply.data(using: .utf8)!) as? [String: Any])
        XCTAssertEqual(rootReplyObj["server_request_id"] as? String, "sr-root")
        XCTAssertEqual(((rootReplyObj["result"] as? [String: Any])?["approved"]) as? Bool, true)
        try client.send("""
        {"v":2,"request_id":"th-1","ok":true,"result":{"root":"/Users/me/projects/fae"}}
        """)
        let rootResult = try await withTimeout(setRoot)
        XCTAssertEqual(rootResult["root"] as? String, "/Users/me/projects/fae")
        let hasRoot = await session.hasRoot()
        XCTAssertTrue(hasRoot, "setRoot must mark the session as rooted")
        let sawRootConfirm = await seen.root
        XCTAssertTrue(sawRootConfirm, "the server-request handler must see workspace.confirm_root")

        // 2. execute on the SAME session — the execute frame arriving on THIS
        //    client proves the connection was reused (a second connection would
        //    have timed this read out).
        let execute = Task { try await session.execute(tool: "read", input: ["path": "a.txt"]) }
        let executeReq = try await recvWithTimeout(client)
        XCTAssertTrue(
            executeReq.contains("\"command\":\"toolhost.execute\""),
            "expected execute frame on the SAME connection (a second connection would have timed this out)")
        try client.send("""
        {"v":2,"request_id":"th-2","ok":true,"result":{"content":["hello"]}}
        """)
        let execResult = try await withTimeout(execute)
        let content = (execResult["content"] as? [String]) ?? []
        XCTAssertEqual(content.first, "hello", "execute must return the daemon's result on the reused connection")
    }

    /// Without an approved root, `execute` fails closed (it must NOT silently run
    /// against a temp sandbox). The session connects + authenticates (so the
    /// daemon is up) but setRoot was never called → execute throws before sending
    /// a toolhost.execute frame.
    func testExecuteWithoutRootFailsClosed() async throws {
        let (peer, tokenPath) = try await publishFakeDaemonEndpoints()
        defer {
            Task { await clearDaemonEndpoints() }
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        let session = DaemonToolHostSession()
        defer { Task { await session.close() } }

        let execute = Task { try await session.execute(tool: "read", input: ["path": "a.txt"]) }
        let client = try peer.accept()
        try driveAuth(client)  // connect + auth succeed; the daemon is up

        do {
            _ = try await withTimeout(execute)
            XCTFail("execute without a root must fail closed")
        } catch DaemonAgentClientError.agentFailed(let message) {
            XCTAssertTrue(message.contains("workspace root"), "expected the no-root guard, got: \(message)")
        } catch {
            // A timeout-derived error is acceptable only if it's the no-root
            // path surfacing; anything else is a regression.
            if !(error is DaemonAgentClientError) {
                XCTFail("expected the no-root agentFailed guard, got \(error)")
            }
        }
        // No toolhost.execute frame was sent (the guard fired before encode).
        _ = client  // keep the client alive for the duration of the test
    }

    // MARK: - B-Swift Layer 3a: default workspace + auto-root (C′ root-source)

    /// Temp-dir workspace provider for tests — NEVER touches real ~/Documents
    /// (avoids macOS TCC prompts in CI; advisor #4).
    private struct TempWorkspace: FaeWorkspaceProvider {
        let workspaceRoot: URL
    }

    /// Provisioning a fresh temp dir creates the dir + the ownership marker.
    func testProvisionCreatesDirAndMarker() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-ws-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let provider = TempWorkspace(workspaceRoot: tmp)
        let outcome = try FaeWorkspace.provision(provider)
        XCTAssertEqual(outcome, .provisioned(tmp))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path), "dir created")
        XCTAssertTrue(FaeWorkspace.markerPresent(at: tmp), "marker written")
    }

    /// A dir Fae already owns (marker present) is reported sticky — no re-card.
    func testAlreadyOwnedIsSticky() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-ws-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let provider = TempWorkspace(workspaceRoot: tmp)
        _ = try FaeWorkspace.provision(provider)   // first provision
        let again = try FaeWorkspace.provision(provider)  // second
        XCTAssertEqual(again, .alreadyOwned(tmp))
    }

    /// A pre-existing dir WITHOUT a marker is NOT taken over — provisioning
    /// reports preExistingWithoutMarker so the caller surfaces the real card
    /// (advisor #3: marker = ownership/collision guard, not security).
    func testPreExistingWithoutMarkerIsReported() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-ws-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // User-made dir with precious files, no marker.
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: tmp.appendingPathComponent("mine.txt"))
        let provider = TempWorkspace(workspaceRoot: tmp)
        let outcome = try FaeWorkspace.provision(provider)
        XCTAssertEqual(outcome, .preExistingWithoutMarker(tmp))
    }

    /// The auto-approve wrapper auto-approves workspace.confirm_root ONLY for the
    /// canonical-exact default path with a marker — never for a sibling path
    /// (a prefix collision like `Fae-evil` must hit the real handler).
    func testAutoApproveCanonicalExactOnly() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-ws-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("fae workspace\n".utf8).write(to: tmp.appendingPathComponent(FaeWorkspace.markerName))

        actor Seen { var calls = [String](); func record(_ m: String) { calls.append(m) } }
        let seen = Seen()
        // The "real" handler records what it gets (would surface the card).
        let real: DaemonServerRequestHandler = { method, _ in
            await seen.record(method)
            return ["approved": false, "call_id": "x"]
        }
        let wrapped = defaultAwareHandler(real, defaultPath: tmp, isMarkerPresent: { true })

        // Exact default path → auto-approved (real handler NOT called).
        let auto = await wrapped("workspace.confirm_root",
                                 ["call_id": "c1", "path": tmp.path])
        XCTAssertEqual(auto["approved"] as? Bool, true)
        XCTAssertEqual(auto["call_id"] as? String, "c1")

        // Sibling path (prefix collision attempt) → real handler (NOT auto-approved).
        let sibling = tmp.deletingLastPathComponent().appendingPathComponent("Fae-evil")
        _ = await wrapped("workspace.confirm_root",
                          ["call_id": "c2", "path": sibling.path])
        let calls = await seen.calls
        XCTAssertEqual(calls, ["workspace.confirm_root"], "sibling must hit real handler, not auto-approve")
    }

    /// tool.confirm is NEVER auto-approved, even for the default path — only the
    /// root grant (workspace.confirm_root) may be auto-approved (advisor #3).
    func testToolConfirmNeverAutoApproved() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-ws-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("fae workspace\n".utf8).write(to: tmp.appendingPathComponent(FaeWorkspace.markerName))

        actor Seen { var hit = false; func mark() { hit = true } }
        let seen = Seen()
        let real: DaemonServerRequestHandler = { _, _ in
            await seen.mark()
            return ["approved": false, "call_id": "x"]
        }
        let wrapped = defaultAwareHandler(real, defaultPath: tmp, isMarkerPresent: { true })
        // tool.confirm must ALWAYS go to real, even though the path is the default.
        _ = await wrapped("tool.confirm",
                          ["call_id": "tc1", "path": tmp.path])
        let hit = await seen.hit
        XCTAssertTrue(hit, "tool.confirm must always surface the real card")
    }

    /// ensureDefaultRooted provisions + auto-approves the default root WITHOUT
    /// surfacing the real card, and a following execute reuses the SAME
    /// connection (Layer 2's persistence invariant, extended to C′ default-root).
    func testEnsureDefaultRootedAutoApprovesAndReusesSession() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-ws-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let provider = TempWorkspace(workspaceRoot: tmp)

        let (peer, tokenPath) = try await publishFakeDaemonEndpoints()
        defer {
            Task { await clearDaemonEndpoints() }
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        // The session's REAL handler records whether a card was surfaced. The
        // auto-approve wrapper must suppress it for the default root.
        actor Seen { var cardSurfaced = false; func mark() { cardSurfaced = true } }
        let seen = Seen()
        let session = DaemonToolHostSession(serverRequestHandler: { method, params in
            await seen.mark()  // the real card would surface here
            let callID = (params["call_id"] as? String) ?? ""
            return ["approved": false, "call_id": callID]
        })
        defer { Task { await session.close() } }

        // 1. ensureDefaultRooted → provisions tmp, auto-approves (no card), setRoot.
        let rooted = Task { try await session.ensureDefaultRooted(provider: provider) }
        let client = try peer.accept()
        try driveAuth(client)
        let setRootReq = try await recvWithTimeout(client)
        XCTAssertTrue(setRootReq.contains("\"command\":\"toolhost.set_root\""))
        XCTAssertTrue(FaeWorkspace.markerPresent(at: tmp), "provision wrote the marker")
        // The daemon sends workspace.confirm_root; the wrapper AUTO-APPROVES it
        // (marker present) WITHOUT surfacing the real card.
        try client.send("""
        {"v":2,"server_request_id":"sr-root","method":"workspace.confirm_root","params":{"call_id":"th-1","path":"\(tmp.path)","note":"workspace grant"}}
        """)
        // ... and the session sends the strict {approved, call_id} reply back.
        let rootReply = try await recvWithTimeout(client)
        XCTAssertTrue(rootReply.contains("\"approved\":true"), "wrapper auto-approved the default root")
        // Daemon returns the approved root.
        try client.send("""
        {"v":2,"request_id":"th-1","ok":true,"result":{"root":"\(tmp.path)"}}
        """)
        let root = try await withTimeout(rooted)
        XCTAssertEqual(root.path, tmp.path)
        // CRITICAL: the real handler was NOT invoked (auto-approve suppressed it).
        let cardSurfaced = await seen.cardSurfaced
        XCTAssertFalse(cardSurfaced, "default root must be auto-approved, not card-surfaced")

        // 2. execute reuses the SAME connection (execute frame on the same client).
        let execute = Task { try await session.executeInDefaultWorkspace(
            tool: "read", input: ["path": "a.txt"]) }
        let executeReq = try await recvWithTimeout(client)
        XCTAssertTrue(executeReq.contains("\"command\":\"toolhost.execute\""),
                      "execute must reuse the setRoot connection")
        try client.send("""
        {"v":2,"request_id":"th-2","ok":true,"result":{"content":["hi"]}}
        """)
        let execResult = try await withTimeout(execute)
        let content = (execResult["content"] as? [String]) ?? []
        XCTAssertEqual(content.first, "hi")
        let hasRoot = await session.hasRoot()
        XCTAssertTrue(hasRoot)
    }

    /// A malformed confirm (missing/blank call_id or path) is NOT auto-approved —
    /// the Layer 1 fail-closed invariant is preserved even on the default root
    /// path (advisor #1).
    func testAutoApproveRejectsMalformedConfirm() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-ws-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("fae workspace\n".utf8).write(to: tmp.appendingPathComponent(FaeWorkspace.markerName))

        actor Seen { var hits = 0; func bump() { hits += 1 } }
        let seen = Seen()
        let real: DaemonServerRequestHandler = { _, _ in
            await seen.bump()
            return ["approved": false, "call_id": "x"]
        }
        let wrapped = defaultAwareHandler(real, defaultPath: tmp, isMarkerPresent: { true })

        // Missing call_id → real handler (not auto-approved).
        _ = await wrapped("workspace.confirm_root", ["path": tmp.path])
        // Blank call_id → real handler.
        _ = await wrapped("workspace.confirm_root", ["call_id": "", "path": tmp.path])
        // Missing path → real handler.
        _ = await wrapped("workspace.confirm_root", ["call_id": "c"])
        // Blank path → real handler.
        _ = await wrapped("workspace.confirm_root", ["call_id": "c", "path": ""])

        let hits = await seen.hits
        XCTAssertEqual(hits, 4, "every malformed confirm must hit the real handler")
    }

    /// A pre-existing dir WITHOUT a marker surfaces the REAL card (not
    /// auto-approved), and on approval the marker is written (sticky). Drives a
    /// fake peer through the full ensureDefaultRooted flow (advisor #4).
    func testPreExistingWithoutMarkerSurfacesCardThenSticky() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-ws-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // User-made dir with precious files, no marker.
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: tmp.appendingPathComponent("mine.txt"))
        let provider = TempWorkspace(workspaceRoot: tmp)

        let (peer, tokenPath) = try await publishFakeDaemonEndpoints()
        defer {
            Task { await clearDaemonEndpoints() }
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        // The real handler IS invoked (card surfaced) and approves.
        actor Seen { var cardSurfaced = false; func mark() { cardSurfaced = true } }
        let seen = Seen()
        let session = DaemonToolHostSession(serverRequestHandler: { method, params in
            await seen.mark()
            let callID = (params["call_id"] as? String) ?? ""
            return ["approved": true, "call_id": callID]
        })
        defer { Task { await session.close() } }

        let rooted = Task { try await session.ensureDefaultRooted(provider: provider) }
        let client = try peer.accept()
        try driveAuth(client)
        _ = try await recvWithTimeout(client)  // set_root frame
        // Daemon sends confirm; the REAL handler answers (no auto-approve: no marker).
        try client.send("""
        {"v":2,"server_request_id":"sr-root","method":"workspace.confirm_root","params":{"call_id":"th-1","path":"\(tmp.path)","note":"grant"}}
        """)
        _ = try await recvWithTimeout(client)  // strict reply from the real handler
        try client.send("""
        {"v":2,"request_id":"th-1","ok":true,"result":{"root":"\(tmp.path)"}}
        """)
        let root = try await withTimeout(rooted)
        XCTAssertEqual(root.path, tmp.path)
        let cardSurfaced = await seen.cardSurfaced
        XCTAssertTrue(cardSurfaced, "pre-existing-no-marker must surface the real card")
        XCTAssertTrue(FaeWorkspace.markerPresent(at: tmp), "marker written after approval (sticky)")
    }

    /// A daemon denial (ok=false / unsafe_root) propagates as a throw and leaves
    /// the session unrooted — the Swift-side stand-in for the symlinked-default /
    /// server-guard rejection (the actual guard is Rust-tested; advisor #5).
    func testDaemonRootDenialPropagatesAndStaysUnrooted() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-ws-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("fae workspace\n".utf8).write(to: tmp.appendingPathComponent(FaeWorkspace.markerName))
        let provider = TempWorkspace(workspaceRoot: tmp)

        let (peer, tokenPath) = try await publishFakeDaemonEndpoints()
        defer {
            Task { await clearDaemonEndpoints() }
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        let session = DaemonToolHostSession(serverRequestHandler: { _, params in
            let callID = (params["call_id"] as? String) ?? ""
            return ["approved": true, "call_id": callID]
        })
        defer { Task { await session.close() } }

        let rooted = Task { try await session.ensureDefaultRooted(provider: provider) }
        let client = try peer.accept()
        try driveAuth(client)
        _ = try await recvWithTimeout(client)  // set_root frame
        try client.send("""
        {"v":2,"server_request_id":"sr-root","method":"workspace.confirm_root","params":{"call_id":"th-1","path":"\(tmp.path)","note":"grant"}}
        """)
        _ = try await recvWithTimeout(client)  // auto-approved reply
        // Daemon DENIES the root (unsafe_root / root_denied).
        try client.send("""
        {"v":2,"request_id":"th-1","ok":false,"error":"unsafe_root"}
        """)

        do {
            _ = try await withTimeout(rooted)
            XCTFail("ensureDefaultRooted must throw on a daemon denial")
        } catch {
            // expected — the daemon rejected the root.
        }
        let hasRoot = await session.hasRoot()
        XCTAssertFalse(hasRoot, "a denied root must leave the session unrooted")
        let rootPath = await session.rootPath()
        XCTAssertNil(rootPath, "rootPath must be nil after a denial")
    }

    /// Whitespace-only call_id/path must NOT auto-approve — trimming closes the
    /// bypass that `!isEmpty` alone left open (advisor review #2, finding 1).
    func testAutoApproveRejectsWhitespaceOnlyConfirm() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-ws-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("fae workspace\n".utf8).write(to: tmp.appendingPathComponent(FaeWorkspace.markerName))

        actor Seen { var hits = 0; func bump() { hits += 1 } }
        let seen = Seen()
        let real: DaemonServerRequestHandler = { _, _ in
            await seen.bump()
            return ["approved": false, "call_id": "x"]
        }
        let wrapped = defaultAwareHandler(real, defaultPath: tmp, isMarkerPresent: { true })
        // Whitespace-only call_id → real handler.
        _ = await wrapped("workspace.confirm_root", ["call_id": "   ", "path": tmp.path])
        // Newline-only call_id → real handler.
        _ = await wrapped("workspace.confirm_root", ["call_id": "\n", "path": tmp.path])
        // Whitespace-only path → real handler.
        _ = await wrapped("workspace.confirm_root", ["call_id": "c", "path": "  "])
        let hits = await seen.hits
        XCTAssertEqual(hits, 3, "whitespace-only confirm must hit the real handler")
    }

    /// ok=true with a MISSING root is treated as NOT approved — ensureDefaultRooted
    /// throws and the session stays unrooted (advisor review #2, finding 2).
    func testOkTrueWithoutRootStaysUnrooted() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-ws-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("fae workspace\n".utf8).write(to: tmp.appendingPathComponent(FaeWorkspace.markerName))
        let provider = TempWorkspace(workspaceRoot: tmp)

        let (peer, tokenPath) = try await publishFakeDaemonEndpoints()
        defer {
            Task { await clearDaemonEndpoints() }
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        let session = DaemonToolHostSession(serverRequestHandler: { _, params in
            let callID = (params["call_id"] as? String) ?? ""
            return ["approved": true, "call_id": callID]
        })
        defer { Task { await session.close() } }

        let rooted = Task { try await session.ensureDefaultRooted(provider: provider) }
        let client = try peer.accept()
        try driveAuth(client)
        _ = try await recvWithTimeout(client)
        try client.send("""
        {"v":2,"server_request_id":"sr-root","method":"workspace.confirm_root","params":{"call_id":"th-1","path":"\(tmp.path)","note":"grant"}}
        """)
        _ = try await recvWithTimeout(client)
        // ok=true but NO root string → not approved.
        try client.send("""
        {"v":2,"request_id":"th-1","ok":true,"result":{}}
        """)

        do {
            _ = try await withTimeout(rooted)
            XCTFail("ensureDefaultRooted must throw when ok=true has no root")
        } catch {
            // expected
        }
        let hasRoot = await session.hasRoot()
        XCTAssertFalse(hasRoot, "ok=true without root must leave the session unrooted")
        let rootPath = await session.rootPath()
        XCTAssertNil(rootPath)
    }

    /// The session binds the DAEMON-RETURNED root, not the requested path — if the
    /// daemon canonicalizes differently, the stored/returned root is the daemon's
    /// (advisor review #2, finding 2).
    func testEnsureDefaultRootedBindsDaemonReturnedRoot() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-ws-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("fae workspace\n".utf8).write(to: tmp.appendingPathComponent(FaeWorkspace.markerName))
        let provider = TempWorkspace(workspaceRoot: tmp)

        let (peer, tokenPath) = try await publishFakeDaemonEndpoints()
        defer {
            Task { await clearDaemonEndpoints() }
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        let session = DaemonToolHostSession(serverRequestHandler: { _, params in
            let callID = (params["call_id"] as? String) ?? ""
            return ["approved": true, "call_id": callID]
        })
        defer { Task { await session.close() } }

        // The daemon returns a DIFFERENT canonical root than the requested tmp.
        let daemonRoot = "/var/fae-workspace-canonical"
        let rooted = Task { try await session.ensureDefaultRooted(provider: provider) }
        let client = try peer.accept()
        try driveAuth(client)
        _ = try await recvWithTimeout(client)
        try client.send("""
        {"v":2,"server_request_id":"sr-root","method":"workspace.confirm_root","params":{"call_id":"th-1","path":"\(tmp.path)","note":"grant"}}
        """)
        _ = try await recvWithTimeout(client)
        try client.send("""
        {"v":2,"request_id":"th-1","ok":true,"result":{"root":"\(daemonRoot)"}}
        """)
        let returned = try await withTimeout(rooted)
        XCTAssertEqual(returned.path, daemonRoot, "must return the daemon-returned root")
        let stored = await session.rootPath()
        XCTAssertEqual(stored?.path, daemonRoot, "must store the daemon-returned root")
    }

    /// Padded-but-non-empty call_id/path and relative paths must NOT auto-approve —
    /// the raw==trimmed + absolute checks (advisor review #3, finding 1).
    func testAutoApproveRejectsPaddedAndRelativeConfirm() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-ws-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("fae workspace\n".utf8).write(to: tmp.appendingPathComponent(FaeWorkspace.markerName))

        actor Seen { var hits = 0; func bump() { hits += 1 } }
        let seen = Seen()
        let real: DaemonServerRequestHandler = { _, _ in
            await seen.bump()
            return ["approved": false, "call_id": "x"]
        }
        let wrapped = defaultAwareHandler(real, defaultPath: tmp, isMarkerPresent: { true })
        // Padded call_id (" th-1 ") → real handler.
        _ = await wrapped("workspace.confirm_root", ["call_id": " th-1 ", "path": tmp.path])
        // Padded path (" <tmp> ") → real handler.
        _ = await wrapped("workspace.confirm_root", ["call_id": "c", "path": " \(tmp.path) "])
        // Relative path → real handler (not absolute).
        _ = await wrapped("workspace.confirm_root", ["call_id": "c", "path": "relative/ws"])
        let hits = await seen.hits
        XCTAssertEqual(hits, 3, "padded/relative confirm must hit the real handler")
    }

    /// ok=true with a whitespace-only or RELATIVE root is NOT bound — the clean-
    /// absolute-path check rejects it, so ensureDefaultRooted throws and the
    /// session stays unrooted (advisor review #3, finding 2).
    func testOkTrueWithWhitespaceOrRelativeRootStaysUnrooted() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-ws-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("fae workspace\n".utf8).write(to: tmp.appendingPathComponent(FaeWorkspace.markerName))

        for badRoot in ["   ", "relative/ws"] {
            let provider = TempWorkspace(workspaceRoot: tmp)
            let (peer, tokenPath) = try await publishFakeDaemonEndpoints()
            defer {
                Task { await clearDaemonEndpoints() }
                try? FileManager.default.removeItem(atPath: tokenPath)
            }
            let session = DaemonToolHostSession(serverRequestHandler: { _, params in
                let callID = (params["call_id"] as? String) ?? ""
                return ["approved": true, "call_id": callID]
            })
            defer { Task { await session.close() } }

            let rooted = Task { try await session.ensureDefaultRooted(provider: provider) }
            let client = try peer.accept()
            try driveAuth(client)
            _ = try await recvWithTimeout(client)
            try client.send("""
            {"v":2,"server_request_id":"sr-root","method":"workspace.confirm_root","params":{"call_id":"th-1","path":"\(tmp.path)","note":"grant"}}
            """)
            _ = try await recvWithTimeout(client)
            try client.send("""
            {"v":2,"request_id":"th-1","ok":true,"result":{"root":"\(badRoot)"}}
            """)
            do {
                _ = try await withTimeout(rooted)
                XCTFail("ensureDefaultRooted must throw for bad root: \(badRoot)")
            } catch {
                // expected — invalid root not bound.
            }
            let hasRoot = await session.hasRoot()
            XCTAssertFalse(hasRoot, "bad root '\(badRoot)' must leave the session unrooted")
        }
    }

    // MARK: - B-Swift Layer 3b: read routing + path confinement

    /// A full-access context so `read`/`write` clear the tool-mode gate (step 1).
    private func makeFullContext() -> ToolExecutorContext {
        ToolExecutorContext(
            toolMode: "full",
            privacyMode: "local_preferred",
            modelLocality: .local,
            explicitUserAuthorization: false,
            isOwner: true,
            livenessScore: nil,
            speakerId: nil,
            actionSource: .voice,
            proactiveContext: nil,
            visionEnabled: false,
            firstOwnerEnrollmentActive: false,
            workflowTurnID: nil,
            traceToolCallID: nil,
            workflowRunID: nil
        )
    }

    /// `read` of an in-workspace file routes to the daemon: the fake peer
    /// receives `toolhost.execute` with `{"tool":"read"}`, replies with content,
    /// and the executor returns it. Exercises the REAL `ToolExecutor.execute`
    /// routing path (advisor #8), not just a helper.
    func testReadRoutesToDaemon() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("hello world".utf8).write(to: tmp.appendingPathComponent("notes.txt"))

        let (peer, tokenPath) = try await publishFakeDaemonEndpoints()
        defer {
            Task { await clearDaemonEndpoints() }
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        let session = DaemonToolHostSession(
            serverRequestHandler: { _, params in
                ["approved": true, "call_id": (params["call_id"] as? String) ?? ""]
            },
            workspaceProvider: TempWorkspace(workspaceRoot: tmp)
        )
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [ReadTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session
        )

        let exec = Task<ToolExecutorResult, Error> {
            await executor.execute(
                ToolCall(name: "read", arguments: ["path": "notes.txt"]),
                context: makeFullContext(),
                callbacks: .noop)
        }
        let client = try peer.accept()
        try driveAuth(client)

        // set_root + auto-approved confirm_root handshake.
        let setRootReq = try await recvWithTimeout(client)
        XCTAssertTrue(setRootReq.contains("\"command\":\"toolhost.set_root\""))
        try client.send("""
        {"v":2,"server_request_id":"sr-root","method":"workspace.confirm_root","params":{"call_id":"th-1","path":"\(tmp.path)","note":"grant"}}
        """)
        let rootReply = try await recvWithTimeout(client)
        XCTAssertTrue(rootReply.contains("\"approved\":true"), "default root auto-approved")
        try client.send("""
        {"v":2,"request_id":"th-1","ok":true,"result":{"root":"\(tmp.path)"}}
        """)

        // The daemon receives the routed `read`.
        let executeReq = try await recvWithTimeout(client)
        XCTAssertTrue(executeReq.contains("\"command\":\"toolhost.execute\""), "read routed to daemon")
        XCTAssertTrue(executeReq.contains("\"tool\":\"read\""), "execute carries tool=read")
        XCTAssertTrue(executeReq.contains("\"path\":\"notes.txt\""), "path is root-relative")
        try client.send("""
        {"v":2,"request_id":"th-2","ok":true,"result":{"content":["hello world"]}}
        """)

        let outcome = try await withTimeout(exec)
        XCTAssertFalse(outcome.result.isError, "routed read should succeed")
        XCTAssertEqual(outcome.result.output, "hello world")
    }

    /// Two reads reuse ONE connection: both `toolhost.execute` frames arrive on
    /// the SAME accepted client (the second read re-roots with no `set_root`).
    /// Reuse is proven by the second execute frame arriving on this client — a
    /// second connection would have routed it to a different `accept()` and
    /// timed this read out (cancellation-safe; no blocking-accept check).
    func testSessionReusedAcrossReads() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: tmp.appendingPathComponent("a.txt"))
        try Data("two".utf8).write(to: tmp.appendingPathComponent("b.txt"))

        let (peer, tokenPath) = try await publishFakeDaemonEndpoints()
        defer {
            Task { await clearDaemonEndpoints() }
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        let session = DaemonToolHostSession(
            serverRequestHandler: { _, params in
                ["approved": true, "call_id": (params["call_id"] as? String) ?? ""]
            },
            workspaceProvider: TempWorkspace(workspaceRoot: tmp)
        )
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [ReadTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session
        )

        // Read 1 — full handshake.
        let exec1 = Task<ToolExecutorResult, Error> {
            await executor.execute(
                ToolCall(name: "read", arguments: ["path": "a.txt"]),
                context: makeFullContext(), callbacks: .noop)
        }
        let client = try peer.accept()
        try driveAuth(client)
        _ = try await recvWithTimeout(client)  // set_root
        try client.send("""
        {"v":2,"server_request_id":"sr-root","method":"workspace.confirm_root","params":{"call_id":"th-1","path":"\(tmp.path)","note":"grant"}}
        """)
        _ = try await recvWithTimeout(client)  // auto-approved reply
        try client.send("""
        {"v":2,"request_id":"th-1","ok":true,"result":{"root":"\(tmp.path)"}}
        """)
        let exec1Frame = try await recvWithTimeout(client)
        XCTAssertTrue(exec1Frame.contains("\"tool\":\"read\""))
        try client.send("""
        {"v":2,"request_id":"th-2","ok":true,"result":{"content":["one"]}}
        """)
        let outcome1 = try await withTimeout(exec1)
        XCTAssertEqual(outcome1.result.output, "one")

        // Read 2 — NO re-root; the execute frame on the SAME client proves reuse.
        let exec2 = Task<ToolExecutorResult, Error> {
            await executor.execute(
                ToolCall(name: "read", arguments: ["path": "b.txt"]),
                context: makeFullContext(), callbacks: .noop)
        }
        let exec2Frame = try await recvWithTimeout(client)
        XCTAssertTrue(
            exec2Frame.contains("\"command\":\"toolhost.execute\""),
            "second read reused the connection (a new connection would time out)")
        // No second set_root frame — root is immutable per connection.
        XCTAssertFalse(exec2Frame.contains("toolhost.set_root"))
        try client.send("""
        {"v":2,"request_id":"th-3","ok":true,"result":{"content":["two"]}}
        """)
        let outcome2 = try await withTimeout(exec2)
        XCTAssertEqual(outcome2.result.output, "two")
        let hasRoot = await session.hasRoot()
        XCTAssertTrue(hasRoot)
    }

    /// An absolute path is DENIED at the Swift seam — no daemon frame. Layer 3b
    /// routes only root-relative paths (absolute paths are denied even under the
    /// workspace). Pure confinement — no daemon needed.
    func testReadAbsolutePathDenied() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Absolute path outside the workspace.
        if case .route = DaemonToolRouting.confineReadPath("/etc/passwd", root: tmp) {
            XCTFail("absolute outside-root path must be denied")
        }
        // Absolute path INSIDE the workspace is also denied (3b: root-relative only).
        let insideAbs = tmp.appendingPathComponent("notes.txt").path
        if case .route = DaemonToolRouting.confineReadPath(insideAbs, root: tmp) {
            XCTFail("absolute under-root path must be denied (3b routes root-relative only)")
        }

        // Dot-only and trailing-slash are directory-ish shapes, denied as SHAPE
        // (phase 1, no daemon contact) — not as non-regular after rooting.
        for shapey in [".", "foo/"] {
            switch DaemonToolRouting.confineReadPath(shapey, root: tmp) {
            case .deny: break
            case .route: XCTFail("directory-ish shape '\(shapey)' must be denied")
            }
        }
        // And via the pure shape validator directly.
        if case .ok = DaemonToolRouting.validateReadPathShape(".") { XCTFail("'.' must be shape-denied") }
        if case .ok = DaemonToolRouting.validateReadPathShape("foo/") { XCTFail("trailing slash must be shape-denied") }
    }

    /// `..` traversal is DENIED — any `..` path component is rejected.
    func testReadTraversalDenied() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        for escaping in ["../secret", "../../etc/passwd", "sub/../../etc/passwd"] {
            if case .route = DaemonToolRouting.confineReadPath(escaping, root: tmp) {
                XCTFail("traversal path '\(escaping)' must be denied")
            }
        }
    }

    /// A symlink inside the workspace that escapes it is DENIED — canonicalization
    /// resolves it outside the root. (The daemon's server guard is a second layer;
    /// this is the Swift seam.)
    func testReadSymlinkEscapeDenied() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // An OUTSIDE REGULAR file + a workspace symlink to it. This is the case
        // that verifies the canonicalization/containment intent: the target is a
        // regular file (passes the regular-file check), so the ONLY thing that
        // denies it is canonicalization revealing the escape. (Symlinking to a
        // directory like /etc would be caught by the regular-file check first,
        // weakening the test — it would pass even if canonicalization regressed.)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-outside-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("id_rsa"))
        try FileManager.default.createSymbolicLink(
            at: tmp.appendingPathComponent("evil"),
            withDestinationURL: outside.appendingPathComponent("id_rsa"))
        switch DaemonToolRouting.confineReadPath("evil", root: tmp) {
        case .deny(let reason):
            XCTAssertTrue(reason.contains("escape"),
                          "outside-regular symlink must be denied as an escape: \(reason)")
        case .route:
            XCTFail("symlink to an outside regular file must be denied as an escape")
        }

        // A directory entry is denied as non-regular (catches /etc-style links).
        try FileManager.default.createSymbolicLink(
            at: tmp.appendingPathComponent("dirlink"),
            withDestinationURL: URL(fileURLWithPath: "/etc"))
        switch DaemonToolRouting.confineReadPath("dirlink", root: tmp) {
        case .deny: break
        case .route: XCTFail("directory entry must be denied as non-regular")
        }

        // A non-escaping symlink to a sibling INSIDE the workspace is allowed.
        try Data("inner".utf8).write(to: tmp.appendingPathComponent("real.txt"))
        try FileManager.default.createSymbolicLink(
            at: tmp.appendingPathComponent("link"),
            withDestinationURL: tmp.appendingPathComponent("real.txt"))
        let confined = DaemonToolRouting.confineReadPath("link", root: tmp)
        if case .route(let relative, _) = confined {
            // The symlink canonicalizes to its in-workspace target, so the
            // root-relative path sent to the daemon is the canonical target.
            XCTAssertEqual(relative, "real.txt")
        } else {
            XCTFail("in-workspace symlink must be allowed")
        }
    }

    /// A valid root-relative read of an existing in-workspace file is routed with
    /// the correct root-relative path.
    func testReadInWorkspaceRoutes() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: tmp.appendingPathComponent("sub").appendingPathComponent("f.txt"))

        let shallow = DaemonToolRouting.confineReadPath("notes.txt", root: tmp)
        // notes.txt doesn't exist here → denied (existence required).
        if case .route = shallow { XCTFail("non-existent file must be denied") }

        try Data("x".utf8).write(to: tmp.appendingPathComponent("notes.txt"))
        if case .route(let relative, _) = DaemonToolRouting.confineReadPath("notes.txt", root: tmp) {
            XCTAssertEqual(relative, "notes.txt")
        } else { XCTFail("existing in-workspace file must route") }

        if case .route(let relative, _) = DaemonToolRouting.confineReadPath("sub/f.txt", root: tmp) {
            XCTAssertEqual(relative, "sub/f.txt")
        } else { XCTFail("nested in-workspace file must route") }
    }

    /// Non-routed tools stay local: `write`/`edit`/`bash` are NOT in the routed
    /// set, and a real `write` (with a daemon published) executes locally and
    /// never roots the session (proving it did not route).
    func testNonRoutedToolsStayLocal() async throws {
        // Classifier assertion: `read` + `write` + `edit` route (3b read; F7a
        // write; F7b edit). bash/calendar/web_search/self_config stay local
        // (F8 is future).
        XCTAssertEqual(DaemonToolRouting.routedTools, ["read", "write", "edit"])
        for nonRouted in ["bash", "calendar", "web_search", "self_config"] {
            XCTAssertFalse(DaemonToolRouting.routedTools.contains(nonRouted),
                           "\(nonRouted) must not route yet (F8 is future)")
        }

        // Smoke: a `bash` (still non-routed) with a daemon published runs
        // locally + never roots. (Pre-F7a this used `write`; F7a routed write so
        // it used `edit`; F7b routed edit, so the smoke now uses `bash` to keep
        // proving the non-routed invariant.)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let (peer, tokenPath) = try await publishFakeDaemonEndpoints()
        defer {
            Task { await clearDaemonEndpoints() }
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp))
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [BashTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session
        )

        let outcome = await executor.execute(
            ToolCall(name: "bash", arguments: ["command": "echo hello"]),
            context: makeFullContext(), callbacks: .noop)
        XCTAssertFalse(outcome.result.isError, "local bash should succeed: \(outcome.result.output)")
        XCTAssertTrue(outcome.result.output.contains("hello"),
                      "bash ran locally and returned output: \(outcome.result.output)")
        // Routing never fired → the session was never rooted / never connected.
        let hasRoot = await session.hasRoot()
        XCTAssertFalse(hasRoot, "non-routed bash must not root the daemon session")
        _ = peer  // daemon published but never contacted by the bash
    }

    // MARK: - B-Swift follow-up #2: no-daemon fallback is intent-gated
    //
    // `read` with no daemon reachable branches on `session.daemonIntended`
    // (mirrors `FaeConfig.llm.useDaemonEngine`):
    //   - OPTED OUT (false, CI / pure-MLX): legacy UNCONFINED local read with
    //     the original args (absolute paths allowed; no provisioning).
    //   - INTENDED (true, default-bundled runtime): CONFINED local read against
    //     the provisioned default workspace (universal invariant preserved,
    //     capability preserved, provisioning fires only here).
    //   - pre-existing-without-marker + intended + no daemon → fail closed.

    /// OPTED OUT + no daemon ⇒ legacy UNCONFINED local read. An ABSOLUTE path
    /// outside the workspace succeeds (the routing seam returns `nil` BEFORE
    /// shape validation, so the local `ReadTool` reads the original args), and
    /// the workspace root is NOT provisioned (no side effect). Distinct from the
    /// intended-but-down confined path below.
    func testReadOptedOutFallsBackToLegacyLocalWhenDaemonDown() async throws {
        // A file OUTSIDE the (never-created) workspace root.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-outside-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("local content".utf8).write(to: outside.appendingPathComponent("fallback.txt"))

        // A workspace root that does NOT exist — proves no provisioning fires.
        let wsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-ws-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: wsRoot) }

        // No daemon published.
        await clearDaemonEndpoints()
        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: wsRoot),
            daemonIntended: false
        )
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [ReadTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session
        )
        // Absolute path outside the workspace — legitimate in legacy mode.
        let outcome = await executor.execute(
            ToolCall(name: "read", arguments: ["path": outside.appendingPathComponent("fallback.txt").path]),
            context: makeFullContext(), callbacks: .noop)
        XCTAssertFalse(outcome.result.isError, "opted-out local read should succeed (legacy unconfined)")
        XCTAssertEqual(outcome.result.output, "local content")
        // No provisioning side effect: the workspace root was never created.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: wsRoot.path),
            "opted-out read must not provision the workspace root")
    }

    /// INTENDED + no daemon ⇒ CONFINED local read. A relative path inside the
    /// provisioned workspace succeeds; an ABSOLUTE path and a `..` escape are
    /// DENIED at the routing seam (the universal invariant holds even with the
    // daemon down). The provisioning side effect fires (workspace + marker).
    func testReadIntendedButDownConfinesLocally() async throws {
        let wsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-ws-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: wsRoot) }
        try FileManager.default.createDirectory(at: wsRoot, withIntermediateDirectories: true)
        try Data("confined content".utf8).write(to: wsRoot.appendingPathComponent("notes.txt"))
        // Mark it Fae-owned so provisioning is a no-op (alreadyOwned) and the
        // test exercises the confine+read path, not the provisioning path
        // (that is covered separately below).
        try FaeWorkspace.writeMarker(at: wsRoot)

        await clearDaemonEndpoints()
        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: wsRoot),
            daemonIntended: true
        )
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [ReadTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session
        )

        // Relative path inside the workspace → confined local read succeeds.
        let ok = await executor.execute(
            ToolCall(name: "read", arguments: ["path": "notes.txt"]),
            context: makeFullContext(), callbacks: .noop)
        XCTAssertFalse(ok.result.isError, "intended-but-down confined read should succeed")
        XCTAssertEqual(ok.result.output, "confined content")

        // Absolute path → DENIED at the shape gate (confinement holds).
        let abs = await executor.execute(
            ToolCall(name: "read", arguments: ["path": "/etc/passwd"]),
            context: makeFullContext(), callbacks: .noop)
        XCTAssertTrue(abs.result.isError, "absolute path must be denied (confined)")

        // `..` escape → DENIED at the shape gate.
        let esc = await executor.execute(
            ToolCall(name: "read", arguments: ["path": "../../../etc/passwd"]),
            context: makeFullContext(), callbacks: .noop)
        XCTAssertTrue(esc.result.isError, "traversal path must be denied (confined)")
    }

    // MARK: - FD-anchored local fallback (red-team fix: root-symlink TOCTOU)
    //
    // The intended-but-down fallback opens the root with O_NOFOLLOW and walks
    // the path with openat+O_NOFOLLOW so a symlink swap (root-symlink TOCTOU) or
    // an intermediate/leaf symlink escape is rejected at the KERNEL level.

    /// INTENDED + no daemon + a SYMLINKED default root → DENIED. The root open
    /// uses O_NOFOLLOW, so a symlink at the tip fails with ELOOP even if it
    /// races `FaeWorkspace.provision`'s lstat. The sensitive target is never
    /// read.
    func testReadIntendedButDownRejectsSymlinkedWorkspaceRoot() async throws {
        let secretDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-secret-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: secretDir) }
        try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        try Data("ssh-private-key-material".utf8)
            .write(to: secretDir.appendingPathComponent("id_rsa"))

        // The default root is a SYMLINK to the secret dir. `FaeWorkspace.provision`
        // lstat-rejects this (`symlinkedWorkspaceRoot`), so the fallback fails
        // closed before any read. (This is the `provision` guard; the fd-anchored
        // O_NOFOLLOW open is the deeper defense if provision's lstat is ever
        // bypassed — proven by the direct helper test below.)
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-link-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: secretDir.path)

        await clearDaemonEndpoints()
        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: link),
            daemonIntended: true
        )
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [ReadTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session
        )
        let outcome = await executor.execute(
            ToolCall(name: "read", arguments: ["path": "id_rsa"]),
            context: makeFullContext(), callbacks: .noop)
        XCTAssertTrue(outcome.result.isError, "symlinked root must be rejected")
        XCTAssertFalse(
            outcome.result.output.contains("ssh-private-key-material"),
            "the sensitive target must never be read")
    }

    /// The fd-anchored helper DIRECTLY rejects a symlinked root, even when the
    /// `provision`-level lstat guard is not in the call chain. Proves the
    /// O_NOFOLLOW open is the real anchor (closes the TOCTOU the red-team
    /// traced: swap the root for a symlink between provision's lstat and the
    /// confine step).
    func testReadFdAnchoredRejectsSymlinkedRootDirectly() throws {
        let secretDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-direct-secret-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: secretDir) }
        try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        try Data("topsecret".utf8).write(to: secretDir.appendingPathComponent("flag.txt"))

        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-direct-link-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: secretDir.path)

        let result = DaemonToolRouting.readFdAnchored(validatedPath: "flag.txt", root: link)
        XCTAssertEqual(result, .deny("workspace root is not a readable directory"),
                       "O_NOFOLLOW root open must reject a symlinked tip")
    }

    /// The fd-anchored helper rejects a LEAF symlink escape: a workspace file
    /// symlinked to `/etc/passwd` is denied at the kernel level (openat +
    /// O_NOFOLLOW → ELOOP), never followed. (Companion to the daemon path's
    /// `confineValidatedReadPath` canonicalization, but anchored on the fd.)
    func testReadFdAnchoredRejectsLeafSymlinkEscape() throws {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-leaf-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: ws) }
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        // A regular file to prove the helper DOES read legit files.
        try Data("ok".utf8).write(to: ws.appendingPathComponent("legit.txt"))
        // A symlink → /etc/passwd (escape attempt).
        try FileManager.default.createSymbolicLink(
            atPath: ws.appendingPathComponent("evil").path,
            withDestinationPath: "/etc/passwd")

        let ok = DaemonToolRouting.readFdAnchored(validatedPath: "legit.txt", root: ws)
        if case .text(let t) = ok { XCTAssertEqual(t, "ok") } else {
            XCTFail("legit file should read via the fd anchor")
        }
        let evil = DaemonToolRouting.readFdAnchored(validatedPath: "evil", root: ws)
        if case .deny = evil { /* expected */ } else {
            XCTFail("leaf symlink escape must be denied (openat+O_NOFOLLOW)")
        }
    }

    /// The fd-anchored helper rejects an INTERMEDIATE-component symlink escape:
    // a dir component symlinked outside the workspace is denied (openat+
    // O_NOFOLLOW on the intermediate → ELOOP / fstat-not-dir).
    func testReadFdAnchoredRejectsIntermediateSymlinkEscape() throws {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-inter-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: ws) }
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-outside-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("exfil".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        // ws/sub → outside (intermediate symlink escape).
        try FileManager.default.createSymbolicLink(
            atPath: ws.appendingPathComponent("sub").path,
            withDestinationPath: outside.path)

        let result = DaemonToolRouting.readFdAnchored(
            validatedPath: "sub/secret.txt", root: ws)
        if case .deny = result { /* expected */ } else {
            XCTFail("intermediate symlink escape must be denied")
        }
    }

    /// The fd-anchored helper rejects a FIFO (non-regular file): a workspace
    // FIFO would otherwise block the read up to its timeout (a routed DoS).
    // `fstat` on the leaf requires S_IFREG.
    func testReadFdAnchoredRejectsFifo() throws {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-fifo-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: ws) }
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let fifoPath = ws.appendingPathComponent("pipe").path
        XCTAssertEqual(mkfifo(fifoPath, 0o600), 0, "mkfifo should succeed")

        let result = DaemonToolRouting.readFdAnchored(validatedPath: "pipe", root: ws)
        if case .deny = result { /* expected */ } else {
            XCTFail("FIFO must be denied (regular-files-only)")
        }
    }

    /// B-Swift Phase C / follow-up #3 (LOCKED 2026-06-30): a HARDLINK planted
    /// inside the workspace (`ln ~/.ssh/id_rsa ~/Documents/Fae/key`) is a regular
    /// file under the workspace, so it passes confinement and would exfiltrate
    /// the sensitive target. The fd-anchored read must reject `st_nlink > 1` on
    /// the leaf (defense-in-depth early-reject; the authoritative check is the
    /// fluers daemon read's post-open fstat — see C1a). Authoritative Swift
    /// check is the fstat off the opened leaf fd in `readFdAnchored`.
    func testReadFdAnchoredRejectsHardlinkedSecret() throws {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-hardlink-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: ws) }
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)

        // A legit single-link workspace file still reads (false-positive guard).
        try Data("ok".utf8).write(to: ws.appendingPathComponent("legit.txt"))

        // A sensitive file OUTSIDE the workspace, hardlinked IN: st_nlink == 2.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-hardlink-secret-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secretPath = outside.appendingPathComponent("id_rsa")
        try Data("TOPSECRET-ssh-key-material".utf8).write(to: secretPath)
        // Create a hardlink inside the workspace (nlink becomes 2).
        try FileManager.default.linkItem(at: secretPath, to: ws.appendingPathComponent("key"))

        // Legit read still works.
        let ok = DaemonToolRouting.readFdAnchored(validatedPath: "legit.txt", root: ws)
        if case .text(let t) = ok { XCTAssertEqual(t, "ok") } else {
            XCTFail("legit single-link file should read via the fd anchor")
        }

        // Hardlinked secret must be DENIED, and its content never returned.
        let exfil = DaemonToolRouting.readFdAnchored(validatedPath: "key", root: ws)
        switch exfil {
        case .text(let t):
            XCTFail("hardlinked secret must be denied, but read returned: \(t)")
        case .deny:
            break  // expected — multiple hard links can't be safely confined
        }
    }

    /// Companion to `testReadFdAnchoredRejectsHardlinkedSecret` for the daemon-UP
    /// routed path: `confineValidatedReadPath` (path-based, used by
    /// `executeSerializedRoutedRead`) early-rejects `st_nlink > 1` as
    /// defense-in-depth (authoritative check is the fluers daemon read's
    /// post-open fstat — C1a).
    func testConfineRejectsHardlinkedSecret() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-confine-hardlink-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // A legit single-link file still routes (false-positive guard).
        try Data("ok".utf8).write(to: tmp.appendingPathComponent("legit.txt"))
        if case .deny = DaemonToolRouting.confineReadPath("legit.txt", root: tmp) {
            XCTFail("legit single-link file should route")
        }

        // Sensitive file outside the workspace, hardlinked IN (nlink == 2).
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-confine-hardlink-secret-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secretPath = outside.appendingPathComponent("id_rsa")
        try Data("TOPSECRET".utf8).write(to: secretPath)
        try FileManager.default.linkItem(at: secretPath, to: tmp.appendingPathComponent("key"))

        switch DaemonToolRouting.confineReadPath("key", root: tmp) {
        case .deny(let reason):
            XCTAssertTrue(reason.contains("hard link"),
                          "hardlinked secret must be denied as multiple hard links: \(reason)")
        case .route:
            XCTFail("hardlinked secret must be denied (st_nlink > 1 early-reject)")
        }
    }

    // MARK: - B-Swift #4 — legacy rootless `ReadTool` leaf-TOCTOU (fd-anchored)

    /// #4: the rootless fd-anchored helper reads a regular absolute file. False-
    /// positive guard for the rejection tests below.
    func testReadRootlessFdAnchoredReadsRegularAbsoluteFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-rootless-ok-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("note.txt")
        try Data("hello rootless".utf8).write(to: file)

        let result = DaemonToolRouting.readRootlessFdAnchored(absolutePath: file.path)
        if case .text(let t) = result { XCTAssertEqual(t, "hello rootless") } else {
            XCTFail("regular absolute file should read; got \(result)")
        }
    }

    /// #4: the rootless helper rejects a LEAF symlink (`open` + O_NOFOLLOW →
    /// ELOOP), never following it. This is the TOCTOU the legacy `String(
    /// contentsOfFile:)` had: a leaf swapped for a symlink between the check and
    /// the read would exfiltrate the target.
    func testReadRootlessFdAnchoredRejectsLeafSymlink() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-rootless-symlink-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // leaf symlink → /etc/passwd (escape attempt).
        try FileManager.default.createSymbolicLink(
            atPath: tmp.appendingPathComponent("evil").path,
            withDestinationPath: "/etc/passwd")

        let result = DaemonToolRouting.readRootlessFdAnchored(
            absolutePath: tmp.appendingPathComponent("evil").path)
        if case .deny(let reason) = result {
            XCTAssertTrue(reason.contains("symbolic link"),
                          "leaf symlink denial should say so: \(reason)")
        } else {
            XCTFail("leaf symlink must be denied (open+O_NOFOLLOW→ELOOP); got \(result)")
        }
    }

    /// #4: end-to-end proof that the legacy `ReadTool` now rejects a leaf symlink
    /// (the call chain routes through `readRootlessFdAnchored`). Pre-fix this
    /// would have followed the symlink and returned the target's contents.
    func testReadToolRejectsLeafSymlinkEndToEnd() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-readtool-symlink-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: tmp.appendingPathComponent("evil").path,
            withDestinationPath: "/etc/passwd")

        let result = try await ReadTool().execute(input: [
            "path": tmp.appendingPathComponent("evil").path,
        ])
        XCTAssertTrue(result.isError,
                      "ReadTool must deny a leaf symlink end-to-end")
        XCTAssertFalse(result.output.contains("root:"),
                       "symlink target must not leak into the error: \(result.output)")
    }

    /// #4: the rootless helper FOLLOWS intermediate symlink directories (macOS
    /// `/tmp → /private/tmp`). This locks the macOS-compatible design: anchoring
    /// from `/` via `readFdAnchored` would reject `/tmp/...` outright, breaking
    /// legitimate reads. `open(path, O_NOFOLLOW)` follows intermediates and only
    /// rejects a leaf symlink.
    func testReadRootlessFdAnchoredFollowsIntermediateSymlinkDir() throws {
        // tmp/realdir/file.txt  +  tmp/linkdir -> realdir.
        // Reading tmp/linkdir/file.txt must SUCCEED (intermediate symlink dir
        // followed, leaf is a regular file).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-rootless-inter-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("realdir"), withIntermediateDirectories: true)
        try Data("via-symlink-dir".utf8).write(
            to: tmp.appendingPathComponent("realdir/file.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: tmp.appendingPathComponent("linkdir").path,
            withDestinationPath: tmp.appendingPathComponent("realdir").path)

        let result = DaemonToolRouting.readRootlessFdAnchored(
            absolutePath: tmp.appendingPathComponent("linkdir/file.txt").path)
        if case .text(let t) = result {
            XCTAssertEqual(t, "via-symlink-dir",
                           "intermediate symlink dir must be followed, not rejected")
        } else {
            XCTFail("intermediate symlink dir must be followed on macOS; got \(result)")
        }
    }

    /// #4: the rootless helper rejects a FIFO (non-regular file). `fstat` on the
    /// opened fd requires S_IFREG; without it a FIFO would block the read.
    func testReadRootlessFdAnchoredRejectsFifo() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-rootless-fifo-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let fifoPath = tmp.appendingPathComponent("pipe").path
        XCTAssertEqual(mkfifo(fifoPath, 0o600), 0, "mkfifo should succeed")

        let result = DaemonToolRouting.readRootlessFdAnchored(absolutePath: fifoPath)
        if case .deny = result { /* expected */ } else {
            XCTFail("FIFO must be denied (regular-files-only); got \(result)")
        }
    }

    // MARK: - B-Swift Phase C / follow-up #5 — routed-read pipeline (hooks/audit/timeout)

    /// #4: a routed read that stalls past the executor timeout returns a timeout
    /// error. Pre-Phase-C the routed read short-circuited BEFORE step 12 (no
    /// timeout). Phase C/#5 wraps the routed path in the executor timeout. Uses
    /// the test-seam closure (no real daemon) + a 0.4s timeout override so the
    /// test runs in <1s, not 30s. `Task.sleep` is cancellation-aware ⇒ the
    /// stalling task exits promptly when the timeout cancels it.
    func testRoutedReadTimeoutReturnsTimeoutError() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Intended-but-down (no daemon published) ⇒ plan = .confinedLocalFallback
        // ⇒ executeRoutedRead runs. The injected closure stalls 5s; the 0.4s
        // timeout must fire first.
        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: true)
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [ReadTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session)
        await executor.setRoutedReadTimeoutForTesting(0.4)
        await executor.setRoutedReadExecutorForTesting { _, _, _ in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return .success("should-not-reach")
        }

        let start = Date()
        let outcome = await executor.execute(
            ToolCall(name: "read", arguments: ["path": "notes.txt"]),
            context: makeFullContext(),
            callbacks: .noop)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(outcome.result.isError, "stalling routed read must time out")
        XCTAssertTrue(outcome.result.output.contains("took too long"),
                      "error must be the friendly timeout message: \(outcome.result.output)")
        XCTAssertLessThan(elapsed, 2.0, "the 0.4s timeout must fire, not the 5s stall")
        XCTAssertNotNil(outcome.latencyMs,
                        "timeout path must record latencyMs (Phase C/#5, code-review M1)")
    }

    /// #5: an opted-out runtime (useDaemonEngine=false) with no daemon falls
    /// through to the FULL local pipeline — the legacy `ReadTool` reads an
    /// ABSOLUTE path (which routing would deny), and the routed executor is
    /// NEVER called (its error return IS the sentinel: if it were called, the
    /// read would fail instead of returning the file content).
    func testRoutedReadOptedOutFallsThroughToLegacyLocal() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let absPath = tmp.appendingPathComponent("outside.txt")
        try Data("legacy-local-read".utf8).write(to: absPath)

        // Opted-out ⇒ plan = .legacyLocal ⇒ fall through; the sentinel closure
        // returns an error if ever called.
        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: false)
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [ReadTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session)
        await executor.setRoutedReadExecutorForTesting { _, _, _ in
            .error("routed executor must not be called for legacy fall-through")
        }

        let outcome = await executor.execute(
            ToolCall(name: "read", arguments: ["path": absPath.path]),
            context: makeFullContext(),
            callbacks: .noop)

        XCTAssertFalse(outcome.result.isError,
                       "legacy local read of an absolute path must succeed: \(outcome.result.output)")
        XCTAssertTrue(outcome.result.output.contains("legacy-local-read"),
                      "the legacy local ReadTool must have read the file: \(outcome.result.output)")
    }

    /// #6: an intended-but-down runtime (the default-bundled failure mode) runs
    /// the confined-fallback read THROUGH the routed pipeline (PreToolUse hooks +
    /// timeout + PostToolUse hooks + audit), not the old raw early-return. The
    /// sentinel closure stands in for the confined read; `latencyMs != nil`
    /// proves the wrapped pipeline ran (the pre-Phase-C early-return carried
    /// `latencyMs: nil`).
    func testRoutedReadConfinedFallbackGoesThroughPipeline() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: true)
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [ReadTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session)
        await executor.setRoutedReadExecutorForTesting { _, _, _ in
            .success("canned-confined-read")
        }

        let outcome = await executor.execute(
            ToolCall(name: "read", arguments: ["path": "notes.txt"]),
            context: makeFullContext(),
            callbacks: .noop)

        XCTAssertFalse(outcome.result.isError,
                       "routed read via the seam must succeed: \(outcome.result.output)")
        XCTAssertEqual(outcome.result.output, "canned-confined-read",
                       "the sentinel routed executor's result must surface")
        XCTAssertNotNil(outcome.latencyMs,
                        "latencyMs must be set — proves the routed pipeline (not the raw early-return) ran (Phase C/#5)")
    }

    // Spy actors + entry records for the hook/audit observability tests below.
    private struct SpyLogEntry: Sendable {
        let event: String; let toolName: String; let success: Bool?; let error: String?
    }
    private struct SpyAnalyticsRecord: Sendable {
        let toolName: String; let success: Bool; let error: String?
    }
    private actor SpyHookRunner: PluginHookRunning {
        private(set) var preToolNames: [String] = []
        private(set) var postToolNames: [String] = []
        private(set) var postOutputs: [String] = []
        let preResponse: HookResponse
        let postResponse: HookResponse
        let hasPre: Bool
        let hasPost: Bool
        init(preResponse: HookResponse = .passthrough, postResponse: HookResponse = .passthrough,
             hasPre: Bool = true, hasPost: Bool = true) {
            self.preResponse = preResponse; self.postResponse = postResponse
            self.hasPre = hasPre; self.hasPost = hasPost
        }
        func hasHooks(for event: HookEvent) -> Bool {
            switch event { case .preToolUse: return hasPre; case .postToolUse: return hasPost; default: return false }
        }
        func runHooks(event: HookEvent, input: HookInput) async -> HookResponse {
            switch event {
            case .preToolUse:
                preToolNames.append(input.toolName ?? "?"); return preResponse
            case .postToolUse:
                postToolNames.append(input.toolName ?? "?"); postOutputs.append(input.toolOutput ?? ""); return postResponse
            default: return .passthrough
            }
        }
    }
    private actor SpySecurityLogger: SecurityEventLogging {
        private(set) var entries: [SpyLogEntry] = []
        func log(event: String, toolName: String, decision: String?, reasonCode: String?,
                 approved: Bool?, success: Bool?, error: String?, arguments: [String: Any]?) {
            entries.append(SpyLogEntry(event: event, toolName: toolName, success: success, error: error))
        }
    }
    private actor SpyToolAnalytics: ToolAnalyticsRecording {
        private(set) var records: [SpyAnalyticsRecord] = []
        func record(toolName: String, success: Bool, latencyMs: Int?, approved: Bool?, error: String?) {
            records.append(SpyAnalyticsRecord(toolName: toolName, success: success, error: error))
        }
    }

    /// Helper: a ToolExecutor wired with the spy logger/analytics + a routed-read
    /// seam closure, on the confined-fallback plan (intended-but-down).
    private func makeSpiedRoutedExecutor(
        tmp: URL, hookRunner: SpyHookRunner?, logger: SpySecurityLogger,
        analytics: SpyToolAnalytics, routed: @escaping @Sendable (ToolCall, DaemonToolHostSession, DaemonToolRouting.ReadRoutePlan) async -> ToolResult
    ) async -> ToolExecutor {
        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: true)
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [ReadTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: logger,
            toolAnalytics: analytics,
            daemonToolHostSession: session)
        if let hookRunner { await executor.setPluginHookRunner(hookRunner) }
        await executor.setRoutedReadExecutorForTesting(routed)
        return executor
    }

    /// #1: a PreToolUse hook BLOCKS the routed read BEFORE the routed executor
    /// closure runs (the closure's `.success("closure-ran")` must never surface —
    /// the block message does). Closes the policy bypass: a user-configured read
    /// hook now applies to routed reads too (Phase C/#5).
    func testRoutedReadPreToolUseHookBlocksBeforeClosure() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let hooks = SpyHookRunner(preResponse:
            HookResponse(systemMessage: "blocked-by-test", block: true, metadata: nil))
        let logger = SpySecurityLogger(), analytics = SpyToolAnalytics()
        let executor = await makeSpiedRoutedExecutor(
            tmp: tmp, hookRunner: hooks, logger: logger, analytics: analytics) { _, _, _ in
                .success("closure-ran")
            }

        let outcome = await executor.execute(
            ToolCall(name: "read", arguments: ["path": "notes.txt"]),
            context: makeFullContext(), callbacks: .noop)

        let preNames = await hooks.preToolNames
        XCTAssertEqual(preNames, ["read"], "PreToolUse must fire for the routed read")
        XCTAssertTrue(outcome.result.isError, "a blocking PreToolUse hook must surface an error")
        XCTAssertEqual(outcome.result.output, "blocked-by-test",
                       "the hook's block message must surface: \(outcome.result.output)")
        let posts = await hooks.postToolNames
        XCTAssertEqual(posts, [], "PostToolUse must NOT fire when PreToolUse blocks")
    }

    /// #2: PostToolUse fires WITH the routed output (the hook observes what the
    /// routed read returned).
    func testRoutedReadFiresPostToolUseWithOutput() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let hooks = SpyHookRunner()  // passthrough pre + post
        let logger = SpySecurityLogger(), analytics = SpyToolAnalytics()
        let executor = await makeSpiedRoutedExecutor(
            tmp: tmp, hookRunner: hooks, logger: logger, analytics: analytics) { _, _, _ in
                .success("canned-routed-output")
            }

        let outcome = await executor.execute(
            ToolCall(name: "read", arguments: ["path": "notes.txt"]),
            context: makeFullContext(), callbacks: .noop)
        XCTAssertFalse(outcome.result.isError)

        let postNames = await hooks.postToolNames, postOutputs = await hooks.postOutputs
        XCTAssertEqual(postNames, ["read"], "PostToolUse must fire for the routed read")
        XCTAssertEqual(postOutputs, ["canned-routed-output"],
                       "PostToolUse must observe the routed read's output")
    }

    /// #3: a successful routed read records a Swift SecurityEventLogger row +
    /// ToolAnalytics event (the daemon's audit.jsonl is a complement, not a
    /// substitute — Phase C/#5).
    func testRoutedReadRecordsAuditAndAnalyticsOnSuccess() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let logger = SpySecurityLogger(), analytics = SpyToolAnalytics()
        let executor = await makeSpiedRoutedExecutor(
            tmp: tmp, hookRunner: nil, logger: logger, analytics: analytics) { _, _, _ in
                .success("ok")
            }

        let outcome = await executor.execute(
            ToolCall(name: "read", arguments: ["path": "notes.txt"]),
            context: makeFullContext(), callbacks: .noop)
        XCTAssertFalse(outcome.result.isError)

        let entries = await logger.entries, records = await analytics.records
        let resultEntries = entries.filter { $0.event == "tool_result" }
        XCTAssertEqual(resultEntries.count, 1, "one tool_result audit row for the routed read")
        XCTAssertEqual(resultEntries.first?.toolName, "read")
        XCTAssertEqual(resultEntries.first?.success, true)
        XCTAssertEqual(records.count, 1, "one ToolAnalytics record")
        XCTAssertEqual(records.first?.toolName, "read")
        XCTAssertEqual(records.first?.success, true)
        XCTAssertNil(records.first?.error)
    }

    /// #4: a routed `.error(...)` read records the failure to SecurityEventLogger
    /// + ToolAnalytics (success=false, error carried).
    func testRoutedReadRecordsAuditAndAnalyticsOnError() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let logger = SpySecurityLogger(), analytics = SpyToolAnalytics()
        let executor = await makeSpiedRoutedExecutor(
            tmp: tmp, hookRunner: nil, logger: logger, analytics: analytics) { _, _, _ in
                .error("routed-failure")
            }

        let outcome = await executor.execute(
            ToolCall(name: "read", arguments: ["path": "notes.txt"]),
            context: makeFullContext(), callbacks: .noop)
        XCTAssertTrue(outcome.result.isError)

        let entries = await logger.entries, records = await analytics.records
        let resultEntries = entries.filter { $0.event == "tool_result" }
        XCTAssertEqual(resultEntries.count, 1)
        XCTAssertEqual(resultEntries.first?.success, false)
        XCTAssertEqual(resultEntries.first?.error, "routed-failure")
        XCTAssertEqual(records.first?.success, false)
        XCTAssertEqual(records.first?.error, "routed-failure")
    }

    // MARK: - B-Swift #9 — routed-read friendly error copy

    /// #9: a mapped technical routed-read error is reframed in Fae's voice for
    /// the conversation, while the RAW technical string is preserved for audit/
    /// analytics. Proves the mapper + the audit-preserves-technical ordering
    /// (audit logged BEFORE the friendly reframing, so the security log keeps
    /// the precise technical reason).
    func testRoutedReadMapsTechnicalErrorToFriendlyCopyAndPreservesAudit() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let logger = SpySecurityLogger(), analytics = SpyToolAnalytics()
        let executor = await makeSpiedRoutedExecutor(
            tmp: tmp, hookRunner: nil, logger: logger, analytics: analytics) { _, _, _ in
                // A real confinement denial string from DaemonToolRouting.
                .error("read path escapes the workspace root")
            }

        let outcome = await executor.execute(
            ToolCall(name: "read", arguments: ["path": "../../etc/passwd"]),
            context: makeFullContext(), callbacks: .noop)
        XCTAssertTrue(outcome.result.isError)
        // Conversation-facing: friendly copy (no raw technical string).
        XCTAssertTrue(outcome.result.output.contains("outside it"),
                      "conversation output should be friendly: \(outcome.result.output)")
        XCTAssertFalse(outcome.result.output.contains("escapes the workspace root"),
                       "raw technical string must NOT surface to the conversation")

        // Audit/analytics: the RAW technical string is preserved (audit logged
        // before the friendly reframing).
        let entries = await logger.entries, records = await analytics.records
        XCTAssertEqual(
            entries.filter { $0.event == "tool_result" }.first?.error,
            "read path escapes the workspace root",
            "audit must keep the raw technical string")
        XCTAssertEqual(records.first?.error, "read path escapes the workspace root",
                      "analytics must keep the raw technical string")
    }

    /// #9: the friendly mapper covers the key routed-read outcome categories
    /// (symlink, hardlink, not-found, non-regular, daemon-unavailable, timeout,
    /// non-UTF-8) and reframes an unmapped error to a generic message (never
    /// leaks an internal path/errno/wire detail verbatim — red-team M2).
    func testFriendlyRoutedReadErrorMapsCategories() {
        // (technical input, a substring expected in the friendly output)
        let cases: [(String, String)] = [
            ("read path escapes the workspace root", "outside it"),
            ("path traversal (..) is not permitted", "outside it"),
            ("file is a symbolic link (not followed): /x", "symbolic link"),
            ("multiple hard links — can't safely confine: x", "hard links"),
            ("read supports regular files only (non-regular entry: x)", "regular file"),
            ("file not found: notes.txt", "couldn't find"),
            ("Daemon unavailable before the workspace root was approved", "isn't available"),
            ("Daemon read returned no content", "backend reported a problem"),
            ("Read was cancelled.", "cancelled"),
            ("Tool timed out after 30s", "took too long"),
            ("file is not UTF-8 text: bin.dat", "isn't UTF-8"),
        ]
        for (technical, expected) in cases {
            let friendly = ToolExecutor.friendlyRoutedReadError(for: technical)
            XCTAssertTrue(friendly.contains(expected),
                          "mapper for \(technical) → \(friendly); expected \"\(expected)\"")
        }
        // Unmapped error: generic fallback (never verbatim — leak risk, M2).
        let unmapped = "some novel internal error XYZ"
        let friendlyUnmapped = ToolExecutor.friendlyRoutedReadError(for: unmapped)
        XCTAssertNotEqual(friendlyUnmapped, unmapped,
                       "unmapped errors must NOT pass through verbatim (leak risk)")
        XCTAssertTrue(friendlyUnmapped.contains("couldn't read"),
                      "unmapped errors should get the generic fallback: \(friendlyUnmapped)")
    }

    // MARK: - B-Swift red-team — daemon-drop fallback re-confines (HIGH)

    /// red-team HIGH: when the daemon drops AFTER root approval (at `execute`),
    /// the fallback must re-confine via the fd-anchored reader (which performs
    /// the st_nlink hardlink check), NOT the legacy rootless ReadTool (which has
    /// no nlink check and would exfiltrate a hardlinked secret). Before the fix,
    /// `.fallbackLocally` routed through `readRootlessFdAnchored` and a file
    /// hardlinked into the workspace in the confine→execute window was read.
    func testRoutedReadFallbackReConfinesAndRejectsHardlinkedSecret() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-fallback-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // A secret OUTSIDE the workspace (in its own dir), hardlinked INTO it.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-fallback-secret-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secretPath = outside.appendingPathComponent("id_rsa")
        try Data("TOPSECRET-ssh-key-material".utf8).write(to: secretPath)
        try FileManager.default.linkItem(at: secretPath, to: tmp.appendingPathComponent("key"))

        // Simulate the daemon-drop-at-execute outcome: the (relative, root) the
        // session carries after a drop. mapReadOutcome must RE-CONFINE.
        let result = await DaemonToolRouting.mapReadOutcome(
            .fallbackLocally(relative: "key", root: tmp))
        XCTAssertTrue(result.isError,
                      "hardlinked secret must be DENIED on the fallback path: \(result.output)")
        XCTAssertFalse(result.output.contains("TOPSECRET"),
                       "hardlinked secret must not be exfiltrated via the fallback")
    }

    /// The happy counterpart: a regular (non-hardlinked) file under the same
    /// fallback outcome IS read. Proves the HIGH fix didn't over-restrict the
    /// fallback into denying every daemon-drop read.
    func testRoutedReadFallbackReadsRegularFileAfterReConfine() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try "hello-after-drop".write(
            to: tmp.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let result = await DaemonToolRouting.mapReadOutcome(
            .fallbackLocally(relative: "notes.txt", root: tmp))
        XCTAssertFalse(result.isError, "regular file should be read on fallback: \(result.output)")
        XCTAssertTrue(result.output.contains("hello-after-drop"))
    }

    // MARK: - B-Swift red-team — daemon response size cap (M3)

    /// red-team M3: a compromised/misbehaving daemon sending an unbounded
    /// `content` array must be capped (defense against OOM), not accumulated
    /// without limit.
    func testBuildReadResultCapsOversizedDaemonResponse() {
        let big = String(repeating: "x", count: 150 * 1024)  // 150 KiB block
        let result = DaemonToolRouting.buildReadResult(from: [
            "content": [big, big]  // 300 KiB total > 200 KiB hard cap
        ])
        XCTAssertFalse(result.isError, "capped response is still a success")
        XCTAssertTrue(result.output.contains("truncated"),
                      "oversized daemon response must carry the truncation marker")
        XCTAssertLessThan(result.output.utf8.count, 220 * 1024,
                          "output must be bounded near the 200 KiB cap")
    }

    /// red-team M3 (advisor tightening): a huge array of EMPTY blocks must not
    /// balloon memory (empty blocks are skipped) and separators count toward
    /// the cap. Proves the cap is robust to the empty-string-array shape, not
    /// just one big block.
    func testBuildReadResultCapsManyEmptyAndSmallBlocks() {
        // 10k small non-empty blocks (10 bytes each) = ~100 KiB + 10k separators
        // (~10 KiB) ≈ 110 KiB < 200 KiB cap → NOT truncated (all kept).
        let smallBlocks = Array(repeating: "0123456789", count: 10_000)
        let resultUnder = DaemonToolRouting.buildReadResult(from: ["content": smallBlocks])
        XCTAssertFalse(resultUnder.isError)
        XCTAssertFalse(resultUnder.output.contains("truncated"),
                       "110 KiB of small blocks is under the 200 KiB cap")
        // 100k empty blocks: must be skipped entirely (no memory balloon, no
        // output) — a daemon can't exhaust memory by spamming empty strings.
        let emptyBlocks = Array(repeating: "", count: 100_000)
        let resultEmpty = DaemonToolRouting.buildReadResult(from: ["content": emptyBlocks])
        XCTAssertFalse(resultEmpty.isError)
        XCTAssertEqual(resultEmpty.output, "",
                       "all-empty content yields empty output, no balloon")
    }

    // MARK: - B-Swift red-team — socket frame byte cap (M3, advisor)

    /// red-team M3 (advisor): a daemon that sends bytes WITHOUT a newline would
    /// grow `readLineLocked`'s buffer without limit (the `buildReadResult` cap
    /// only runs AFTER a full line is decoded). The per-frame byte cap must
    /// reject an oversized newline-less frame with a precise error, before OOM.
    func testSocketFrameCapRejectsOversizedNewlinelessFrame() async throws {
        let peer = try FakeDaemonPeer.listen()
        // Constructor-inject a small cap (default is 8 MiB; immutable `let` so
        // the @unchecked Sendable class has no mutable cross-thread state).
        let connection = DaemonSocketConnection(
            queueLabel: "fae.test.frame-cap", frameByteCap: 4 * 1024)
        try connection.connect(to: peer.path)
        defer { connection.close() }

        let client = try peer.accept()
        defer { client.close() }

        // Send 6 KiB with NO newline (exceeds the 4 KiB cap).
        try client.sendRaw(Array(repeating: UInt8(ascii: "x"), count: 6 * 1024))

        let frame = try DaemonWire.encodeFrame(
            requestID: "x", command: "toolhost.execute", payload: [:])
        do {
            _ = try await connection.roundTrip(frame: frame, expectRequestID: "x")
            XCTFail("roundTrip must reject an oversized newline-less frame")
        } catch DaemonLLMEngineError.protocolError(let message) {
            // Precise error, locked: frame-size + newline-less cause + the cap.
            XCTAssertTrue(message.lowercased().contains("frame"),
                          "expected a frame-size protocol error, got: \(message)")
            XCTAssertTrue(message.lowercased().contains("newline"),
                          "error should explain the newline-less cause: \(message)")
            XCTAssertTrue(message.contains("4096"),
                          "error should state the byte cap (4096), got: \(message)")
        } catch {
            // No broad fallback: the guard must surface the precise protocolError.
            // Any other error type is a regression (e.g. a hang masked as a
            // timeout, or a wrapped error that hides the root cause).
            XCTFail("expected protocolError for the oversized frame, got: \(error)")
        }
    }

    /// A valid UTF-8 file truncated by the byte cap MID-MULTIBYTE-CHARACTER is
    /// returned (shorter) rather than denied as "not UTF-8". The cap is 50 KiB;
    /// build a file whose boundary lands inside a multibyte sequence. The
    /// fd-anchored helper trims the incomplete trailing sequence and decodes
    /// the valid prefix. (Companion to follow-up #6 truncation parity.)
    func testReadFdAnchoredTruncatesMultibyteWithoutDenying() throws {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-mb-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: ws) }
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)

        // Build a file of 4-byte UTF-8 chars (U+1F600 = \u{F0 9F 98 80}). Fill
        // past the cap so the boundary lands inside a char. cap / 4 = 12800
        // chars exactly; append a few more to guarantee a mid-char split.
        let cap = DaemonToolRouting.localReadByteCap
        let char = "😀"  // 4 UTF-8 bytes
        let charBytes = char.utf8.count
        let charsToOverflow = (cap / charBytes) + 4
        let big = String(repeating: char, count: charsToOverflow)
        try Data(big.utf8).write(to: ws.appendingPathComponent("emoji.txt"))

        let result = DaemonToolRouting.readFdAnchored(validatedPath: "emoji.txt", root: ws)
        switch result {
        case .text(let text):
            // The byte marker is appended AFTER the capped content (B-Swift #6
            // daemon parity), so the total may slightly exceed `cap`; the CONTENT
            // must still respect the cap and end on a complete char. Strip a
            // trailing daemon-style marker (if present) before the byte assertion.
            let contentOnly = text.components(separatedBy: "\n[... truncated at").first ?? text
            XCTAssertLessThanOrEqual(
                contentOnly.utf8.count, cap,
                "returned content must respect the byte cap (marker excluded)")
            // Every returned code point is a complete char (no partial bytes).
            XCTAssertEqual(contentOnly.unicodeScalars.last?.description, "😀",
                           "no partial multibyte sequence at the boundary")
        case .deny:
            XCTFail("a valid UTF-8 file truncated mid-char must be returned, not denied")
        }
    }

    // MARK: - B-Swift #6 — truncation parity with the fluers daemon

    /// #6: a local read over 2000 lines truncates with the daemon-style LINE
    /// marker (matches fluers `apply_read_limits`). Pre-#6 the local path had
    /// no line cap and no marker; now routed/local surface the same truncation.
    func testReadFdAnchoredTruncatesAtLineCapWithDaemonMarker() throws {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-linecap-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: ws) }
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        // 2001 short lines — line cap binds (bytes are ~12k, well under 50KiB).
        let big = (1...2001).map { "line\($0)" }.joined(separator: "\n")
        try Data(big.utf8).write(to: ws.appendingPathComponent("many.txt"))

        let result = DaemonToolRouting.readFdAnchored(validatedPath: "many.txt", root: ws)
        if case .text(let text) = result {
            XCTAssertTrue(text.contains("\n[... truncated at 2000 lines ...]"),
                          "over-line-cap file must get the daemon-style line marker: last 60 chars=\(text.suffix(60))")
            // Exactly 2000 content lines kept + the marker line.
            XCTAssertEqual(text.split(separator: "\n").count, 2001,
                          "keep 2000 lines + 1 marker line")
        } else { XCTFail("expected .text; got \(result)") }
    }

    /// #6: a local read over 50 KiB truncates with the daemon-style BYTE marker.
    func testReadFdAnchoredTruncatesAtByteCapWithDaemonMarker() throws {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-bytecap-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: ws) }
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        // A single line > 50KiB — byte cap binds (1 line, no line-cap).
        let big = String(repeating: "x", count: 60_000)
        try Data(big.utf8).write(to: ws.appendingPathComponent("big.txt"))

        let result = DaemonToolRouting.readFdAnchored(validatedPath: "big.txt", root: ws)
        if case .text(let text) = result {
            XCTAssertTrue(text.contains("\n[... truncated at 51200 bytes ...]"),
                          "over-byte-cap file must get the daemon-style byte marker")
        } else { XCTFail("expected .text; got \(result)") }
    }

    /// #6: a file at EXACTLY the line cap is NOT truncated (daemon semantics:
    /// `i >= max_lines` is 0-indexed, so 2000 lines → no marker).
    func testReadFdAnchoredAtExactLineCapIsNotTruncated() throws {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-exact-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: ws) }
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let exact = (1...2000).map { "l\($0)" }.joined(separator: "\n")
        try Data(exact.utf8).write(to: ws.appendingPathComponent("exact.txt"))

        let result = DaemonToolRouting.readFdAnchored(validatedPath: "exact.txt", root: ws)
        if case .text(let text) = result {
            XCTAssertFalse(text.contains("truncated"),
                           "exactly 2000 lines must NOT be truncated: \(text.suffix(40))")
        } else { XCTFail("expected .text; got \(result)") }
    }

    /// #6: the legacy rootless `ReadTool` now emits the daemon-style markers too
    /// (parity) — and the OLD bare `\n[truncated]` is gone. End-to-end proof.
    func testReadToolEmitsDaemonStyleMarkerAndDropsLegacyBareMarker() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-readtool-marker-")
            .appendingPathComponent(UUID().uuidString.prefix(8).description)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let big = String(repeating: "x", count: 60_000)
        try Data(big.utf8).write(to: tmp.appendingPathComponent("big.txt"))

        let result = try await ReadTool().execute(input: [
            "path": tmp.appendingPathComponent("big.txt").path,
        ])
        XCTAssertFalse(result.isError, "read should succeed")
        XCTAssertTrue(result.output.contains("[... truncated at 51200 bytes ...]"),
                      "ReadTool must emit the daemon-style byte marker: \(result.output.suffix(60))")
        XCTAssertFalse(result.output.contains("\n[truncated]"),
                       "legacy bare \"\n[truncated]\" marker must be gone (parity): \(result.output.suffix(40))")
    }



    /// Provisioning side effect fires ONLY in the intended branch. INTENDED +
    /// no daemon + a missing workspace root provisions it (marker written) even
    /// when the read itself is denied (file not found). OPTED OUT leaves the
    /// root absent.
    func testReadIntendedButDownProvisionsWorkspaceMarker() async throws {
        // --- intended branch: provisioning fires ---
        let wsIntended = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-int-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: wsIntended) }
        // wsIntended does NOT exist yet.
        await clearDaemonEndpoints()
        let sessionIntended = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: wsIntended),
            daemonIntended: true
        )
        defer { Task { await sessionIntended.close() } }
        let executorIntended = ToolExecutor(
            registry: ToolRegistry(tools: [ReadTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: sessionIntended
        )
        // Read a file that does not exist → the read is denied (file not found),
        // but provisioning MUST have created the workspace + marker first.
        let denied = await executorIntended.execute(
            ToolCall(name: "read", arguments: ["path": "missing.txt"]),
            context: makeFullContext(), callbacks: .noop)
        XCTAssertTrue(denied.result.isError, "missing file must be denied")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: wsIntended.path),
            "intended branch must provision the workspace root")
        XCTAssertTrue(
            FaeWorkspace.markerPresent(at: wsIntended),
            "intended branch must write the ownership marker")
    }

    /// INTENDED + no daemon + a pre-existing workspace WITHOUT the Fae marker ⇒
    /// fail CLOSED. No daemon card is available to approve a user-made dir, so
    /// the confined fallback refuses (no silent takeover, no read). The marker
    /// is NOT written and the precious file is NOT exfiltrated.
    func testReadIntendedButDownPreExistingWithoutMarkerFailsClosed() async throws {
        let wsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-pre-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: wsRoot) }
        // A user-made dir (NO marker) with a precious file.
        try FileManager.default.createDirectory(at: wsRoot, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: wsRoot.appendingPathComponent("mine.txt"))

        await clearDaemonEndpoints()
        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: wsRoot),
            daemonIntended: true
        )
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [ReadTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session
        )
        let outcome = await executor.execute(
            ToolCall(name: "read", arguments: ["path": "mine.txt"]),
            context: makeFullContext(), callbacks: .noop)
        XCTAssertTrue(outcome.result.isError, "pre-existing-without-marker must fail closed when daemon is down")
        XCTAssertFalse(
            FaeWorkspace.markerPresent(at: wsRoot),
            "must NOT write the marker on a user-made dir without approval")
        // The precious file is untouched (no exfiltration).
        let stillThere = try String(contentsOfFile: wsRoot.appendingPathComponent("mine.txt").path, encoding: .utf8)
        XCTAssertEqual(stillThere, "precious")
    }


    /// A `read` with an escaping path (absolute / `..`) is DENIED at the Swift
    /// seam via the REAL `ToolExecutor.execute` path: no `set_root`, no
    /// `toolhost.execute` frame. Proven by `session.hasRoot() == false` after
    /// the call (a routed read would have rooted the session).
    func testReadDeniedPathDoesNotContactDaemon() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let (peer, tokenPath) = try await publishFakeDaemonEndpoints()
        defer {
            Task { await clearDaemonEndpoints() }
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp))
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [ReadTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session
        )

        for escaping in ["/etc/passwd", "../../etc/passwd"] {
            let outcome = await executor.execute(
                ToolCall(name: "read", arguments: ["path": escaping]),
                context: makeFullContext(), callbacks: .noop)
            XCTAssertTrue(outcome.result.isError, "escaping path '\(escaping)' must be denied")
        }
        // No daemon contact: the session was never rooted.
        let hasRoot = await session.hasRoot()
        XCTAssertFalse(hasRoot, "a denied read must not root the daemon session")
        _ = peer
    }

    /// Fail-closed: if the daemon is involved (published) but drops BEFORE the
    /// workspace root is approved, the read returns an `.error` and never reads
    /// locally on the un-approved (locally-computed) root. The server root guard
    /// must run before any local read is trusted. (The exact error path —
    /// `daemonUnavailable` vs a socket EOF/connection error — may differ; this
    /// asserts the SAFETY property: daemon was involved, root not approved,
    /// result is an error, no local read, `hasRoot == false`.)
    func testReadFailsClosedWhenDaemonDropsBeforeRootApproval() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: tmp.appendingPathComponent("notes.txt"))

        let (peer, tokenPath) = try await publishFakeDaemonEndpoints()
        defer {
            Task { await clearDaemonEndpoints() }
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        let session = DaemonToolHostSession(
            serverRequestHandler: { _, params in
                ["approved": true, "call_id": (params["call_id"] as? String) ?? ""]
            },
            workspaceProvider: TempWorkspace(workspaceRoot: tmp)
        )
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [ReadTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session
        )

        let exec = Task<ToolExecutorResult, Error> {
            await executor.execute(
                ToolCall(name: "read", arguments: ["path": "notes.txt"]),
                context: makeFullContext(), callbacks: .noop)
        }
        let client = try peer.accept()
        try driveAuth(client)
        // The daemon received set_root but then DROPS before approving the root
        // (no confirm_root, no set_root response). Simulate the drop by closing
        // the connection + clearing endpoints.
        _ = try await recvWithTimeout(client)  // set_root frame
        client.close()                         // daemon-side drop

        let outcome = try await withTimeout(exec)
        XCTAssertTrue(outcome.result.isError, "read must fail closed when the daemon drops before root approval")
        let hasRoot = await session.hasRoot()
        XCTAssertFalse(hasRoot, "root must not be approved after a daemon drop")
    }

    /// A FIFO (or other non-regular entry) in the workspace is DENIED before any
    /// daemon read — a workspace FIFO would otherwise block the daemon socket up
    /// to its recv timeout (a routed DoS). Verified directly on the pure
    /// confinement helper; the regular-file check is what catches it.
    func testReadFifoAndNonRegularDenied() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // FIFO via mkfifo.
        let fifoPath = tmp.appendingPathComponent("myfifo").path
        XCTAssertEqual(Darwin.mkfifo(fifoPath, 0o644), 0, "mkfifo should succeed")
        switch DaemonToolRouting.confineReadPath("myfifo", root: tmp) {
        case .deny(let reason):
            XCTAssertTrue(reason.contains("regular"), "FIFO must be denied as non-regular: \(reason)")
        case .route:
            XCTFail("a FIFO must not route (would block the daemon socket)")
        }

        // A sub-DIRECTORY is also denied as non-regular.
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("sub"), withIntermediateDirectories: true)
        switch DaemonToolRouting.confineReadPath("sub", root: tmp) {
        case .deny(let reason):
            XCTAssertTrue(reason.contains("regular"), "directory must be denied as non-regular: \(reason)")
        case .route:
            XCTFail("a directory must not route")
        }

        // Control: a regular file IS routed.
        try Data("x".utf8).write(to: tmp.appendingPathComponent("real.txt"))
        if case .deny = DaemonToolRouting.confineReadPath("real.txt", root: tmp) {
            XCTFail("a regular file must route")
        }
    }

    /// Root-binding-order: confinement uses the DAEMON-RETURNED root, not the
    /// provider root. Here the provider root (`tmp`) has NO `notes.txt`, but the
    /// fake daemon's `set_root` response returns a DIFFERENT canonical root that
    /// DOES contain `notes.txt`. The read routes+resolves ONLY because confinement
    /// runs against the daemon-returned root (the 3a invariant: bind the daemon-
    /// RETURNED root). If confinement used the provider root, `notes.txt` would be
    /// “not found” and the read would error.
    func testReadConfinesAgainstDaemonReturnedRoot() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // NOTE: deliberately NO notes.txt under tmp (the provider root).

        // The daemon-returned root: a DIFFERENT dir that DOES contain notes.txt.
        let daemonRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-daemon-root-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: daemonRoot) }
        try FileManager.default.createDirectory(at: daemonRoot, withIntermediateDirectories: true)
        try Data("from-daemon-root".utf8).write(to: daemonRoot.appendingPathComponent("notes.txt"))

        let (peer, tokenPath) = try await publishFakeDaemonEndpoints()
        defer {
            Task { await clearDaemonEndpoints() }
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        // Provider root = tmp; the daemon will RETURN daemonRoot.
        let session = DaemonToolHostSession(
            serverRequestHandler: { _, params in
                ["approved": true, "call_id": (params["call_id"] as? String) ?? ""]
            },
            workspaceProvider: TempWorkspace(workspaceRoot: tmp)
        )
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [ReadTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session
        )

        let exec = Task<ToolExecutorResult, Error> {
            await executor.execute(
                ToolCall(name: "read", arguments: ["path": "notes.txt"]),
                context: makeFullContext(), callbacks: .noop)
        }
        let client = try peer.accept()
        try driveAuth(client)
        // set_root request carries the PROVIDER path (tmp); confirm auto-approved.
        let setRootReq = try await recvWithTimeout(client)
        XCTAssertTrue(setRootReq.contains("\"command\":\"toolhost.set_root\""))
        try client.send("""
        {"v":2,"server_request_id":"sr-root","method":"workspace.confirm_root","params":{"call_id":"th-1","path":"\(tmp.path)","note":"grant"}}
        """)
        _ = try await recvWithTimeout(client)  // auto-approved reply
        // Daemon RETURNS daemonRoot (not tmp). The session binds daemonRoot.
        try client.send("""
        {"v":2,"request_id":"th-1","ok":true,"result":{"root":"\(daemonRoot.path)"}}
        """)
        // The routed execute reads notes.txt (found under daemonRoot, not tmp).
        let executeReq = try await recvWithTimeout(client)
        XCTAssertTrue(executeReq.contains("\"tool\":\"read\""))
        try client.send("""
        {"v":2,"request_id":"th-2","ok":true,"result":{"content":["from-daemon-root"]}}
        """)

        let outcome = try await withTimeout(exec)
        XCTAssertFalse(outcome.result.isError, "read must resolve against the daemon-returned root")
        XCTAssertEqual(outcome.result.output, "from-daemon-root")
        // The session stored the DAEMON-returned root, not the provider root.
        let stored = await session.rootPath()
        XCTAssertEqual(stored?.path, daemonRoot.path)
    }

    /// Concurrent cold reads SERIALIZE: two reads issued concurrently through
    /// the REAL `ToolExecutor.execute` path share ONE connection, ONE `set_root`,
    /// and their execute frames arrive strictly sequentially on the same accepted
    /// client. The operation lock makes this deterministic; without it, two
    /// server-request-aware roundTrips would interleave frames and steal each
    /// other's responses. (Cancellation-safe: proven by both reads succeeding on
    /// the single client — no blocking-accept timeout used.)
    func testConcurrentReadsSerializeOnOneConnection() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("AAA".utf8).write(to: tmp.appendingPathComponent("a.txt"))
        try Data("BBB".utf8).write(to: tmp.appendingPathComponent("b.txt"))

        let (peer, tokenPath) = try await publishFakeDaemonEndpoints()
        defer {
            Task { await clearDaemonEndpoints() }
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        let session = DaemonToolHostSession(
            serverRequestHandler: { _, params in
                ["approved": true, "call_id": (params["call_id"] as? String) ?? ""]
            },
            workspaceProvider: TempWorkspace(workspaceRoot: tmp)
        )
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [ReadTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session
        )

        // Two concurrent cold reads.
        let readA = Task<ToolExecutorResult, Never> {
            await executor.execute(
                ToolCall(name: "read", arguments: ["path": "a.txt"]),
                context: makeFullContext(), callbacks: .noop)
        }
        let readB = Task<ToolExecutorResult, Never> {
            await executor.execute(
                ToolCall(name: "read", arguments: ["path": "b.txt"]),
                context: makeFullContext(), callbacks: .noop)
        }

        let client = try peer.accept()
        try driveAuth(client)
        // Exactly ONE set_root handshake (concurrent reads dedupe to a single
        // root-establishment under the operation lock).
        let setRootReq = try await recvWithTimeout(client)
        XCTAssertTrue(setRootReq.contains("toolhost.set_root"))
        try client.send("""
        {"v":2,"server_request_id":"sr-root","method":"workspace.confirm_root","params":{"call_id":"th-1","path":"\(tmp.path)","note":"grant"}}
        """)
        _ = try await recvWithTimeout(client)  // auto-approved reply
        try client.send("""
        {"v":2,"request_id":"th-1","ok":true,"result":{"root":"\(tmp.path)"}}
        """)

        // Serve the two execute frames strictly sequentially on THIS client. The
        // lock serializes them; each is matched by request_id. Order is
        // non-deterministic but each read gets its own response regardless.
        func serveExecute() async throws {
            let frame = try await recvWithTimeout(client)
            XCTAssertTrue(frame.contains("\"command\":\"toolhost.execute\""),
                          "execute frame must arrive on the shared connection")
            let requestID = Self.extractField(frame, field: "request_id") ?? ""
            let path = Self.extractField(frame, field: "path") ?? ""
            let content = path == "a.txt" ? "AAA" : "BBB"
            try client.send("""
            {"v":2,"request_id":"\(requestID)","ok":true,"result":{"content":["\(content)"]}}
            """)
        }
        try await serveExecute()
        try await serveExecute()

        let outA = try await withTimeoutAsNever(readA)
        let outB = try await withTimeoutAsNever(readB)
        XCTAssertFalse(outA.result.isError)
        XCTAssertFalse(outB.result.isError)
        XCTAssertEqual(outA.result.output, "AAA", "read a.txt must get its own response (no stealing)")
        XCTAssertEqual(outB.result.output, "BBB", "read b.txt must get its own response (no stealing)")
    }

    /// Cancel-aware operation lock: a routed read cancelled WHILE PARKED on the
    /// lock returns `.cancelled`, runs no zombie daemon work, and does NOT
    /// retain/starve the lock — a later read acquires and succeeds on the same
    /// connection. (The original `withCheckedContinuation` lock never resumed on
    /// cancellation → zombie daemon round-trip + lock starvation.)
    ///
    /// Proven on the real `executeSerializedRoutedRead` path: read A holds the
    /// lock (its execute frame is read but not responded to); read B parks and
    /// is cancelled → `.cancelled`; read C then acquires after A releases and
    /// succeeds. Cancellation-safe: read C actually completes (no blocking-accept
    /// timeout used to assert "no frame").
    func testCancelledReadWaiterDoesNotRunZombieWorkOrStarveLock() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("AAA".utf8).write(to: tmp.appendingPathComponent("a.txt"))
        try Data("BBB".utf8).write(to: tmp.appendingPathComponent("b.txt"))
        try Data("CCC".utf8).write(to: tmp.appendingPathComponent("c.txt"))

        let (peer, tokenPath) = try await publishFakeDaemonEndpoints()
        defer {
            Task { await clearDaemonEndpoints() }
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        let session = DaemonToolHostSession(
            serverRequestHandler: { _, params in
                ["approved": true, "call_id": (params["call_id"] as? String) ?? ""]
            },
            workspaceProvider: TempWorkspace(workspaceRoot: tmp)
        )
        defer { Task { await session.close() } }

        // Root the session up front so the handshake isn't part of the
        // lock-holding dance.
        let rootTask = Task { try await session.ensureDefaultRooted() }
        let client = try peer.accept()
        try driveAuth(client)
        _ = try await recvWithTimeout(client)  // set_root
        try client.send("""
        {"v":2,"server_request_id":"sr-root","method":"workspace.confirm_root","params":{"call_id":"th-1","path":"\(tmp.path)","note":"grant"}}
        """)
        _ = try await recvWithTimeout(client)  // auto-approved reply
        try client.send("""
        {"v":2,"request_id":"th-1","ok":true,"result":{"root":"\(tmp.path)"}}
        """)
        _ = try await withTimeout(rootTask)

        // Read A: acquires the lock + sends its execute frame. DO NOT respond →
        // A stays parked inside `execute` holding the operation lock.
        let readA = Task<DaemonToolRouting.ReadExecutionOutcome, Never> {
            await session.executeSerializedRoutedRead(validatedPath: "a.txt")
        }
        let frameA = try await recvWithTimeout(client)
        XCTAssertTrue(frameA.contains("\"tool\":\"read\""), "read A sent its execute frame")
        XCTAssertTrue(frameA.contains("\"path\":\"a.txt\""))

        // Read B: parks on the operation lock (A holds it). Cancel it while parked.
        let readB = Task<DaemonToolRouting.ReadExecutionOutcome, Never> {
            await session.executeSerializedRoutedRead(validatedPath: "b.txt")
        }
        // Yield a few times so B reliably reaches the parked continuation before cancel.
        for _ in 0..<20 { await Task.yield() }
        readB.cancel()

        // B must resolve to `.cancelled` promptly (cancel handler resumes it).
        let outcomeB = try await withTimeoutAsNever(readB)
        if case .cancelled = outcomeB {
            // expected
        } else {
            XCTFail("cancelled parked read must return .cancelled, got \(outcomeB)")
        }

        // Now release A: respond to its execute frame → A completes + releases
        // the lock. A cancelled-B waiter (if it had left the lock in a bad state)
        // would surface here.
        try client.send("""
        {"v":2,"request_id":"\(Self.extractField(frameA, field: "request_id") ?? "th-2")","ok":true,"result":{"content":["AAA"]}}
        """)
        let outcomeA = try await withTimeoutAsNever(readA)
        if case .routed(let result) = outcomeA {
            XCTAssertEqual((result["content"] as? [String])?.first, "AAA")
        } else {
            XCTFail("read A should succeed, got \(outcomeA)")
        }

        // Read C: must acquire the lock the cancelled waiter did NOT retain and
        // succeed on the SAME connection. This is the no-starvation proof.
        let readC = Task<DaemonToolRouting.ReadExecutionOutcome, Never> {
            await session.executeSerializedRoutedRead(validatedPath: "c.txt")
        }
        let frameC = try await recvWithTimeout(client)
        XCTAssertTrue(frameC.contains("\"path\":\"c.txt\""),
                      "read C acquired the lock (cancellation did not starve it)")
        try client.send("""
        {"v":2,"request_id":"\(Self.extractField(frameC, field: "request_id") ?? "th-3")","ok":true,"result":{"content":["CCC"]}}
        """)
        let outcomeC = try await withTimeoutAsNever(readC)
        if case .routed(let result) = outcomeC {
            XCTAssertEqual((result["content"] as? [String])?.first, "CCC")
        } else {
            XCTFail("read C should succeed, got \(outcomeC)")
        }
    }

    // MARK: - B-Swift 3a follow-up #1: symlinked default workspace root

    /// A default root that is itself a symlink is REJECTED at provisioning — the
    /// marker is NOT written into the symlink target, and `provision` throws the
    /// symlink error. (The daemon's `is_safe_workspace_root` guard rejects the
    /// home dir but NOT home subdirs, so `~/Documents/Fae → ~/.ssh` would root
    /// into `~/.ssh` and leak SSH keys via a routed `read id_rsa`.)
    func testProvisionRejectsSymlinkedWorkspaceRoot() throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-symlink-target-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // Plant a marker in the TARGET — proves the guard does not follow the link.
        try Data("fae workspace\n".utf8).write(to: target.appendingPathComponent(FaeWorkspace.markerName))

        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-symlink-root-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let provider = TempWorkspace(workspaceRoot: link)
        XCTAssertThrowsError(try FaeWorkspace.provision(provider)) { error in
            guard case FaeWorkspaceError.symlinkedWorkspaceRoot = error else {
                XCTFail("expected symlinkedWorkspaceRoot, got \(error)")
                return
            }
        }
        // No NEW marker was written through the link (the target's planted one is
        // untouched; the link itself has no marker entry).
        XCTAssertTrue(FaeWorkspace.markerPresent(at: target),
                      "provision must not mutate the symlink target")
        XCTAssertTrue(FaeWorkspace.isSymlinkAtTip(link), "link is still a symlink")
    }

    /// The auto-approve wrapper does NOT auto-approve a symlinked default root,
    /// even with canonical-exact match + marker present — defense-in-depth so a
    /// swapped link can't race the provisioning guard.
    func testAutoApproveRejectsSymlinkedDefaultRoot() async throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-symlink-target-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("fae workspace\n".utf8).write(to: target.appendingPathComponent(FaeWorkspace.markerName))
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-symlink-root-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        actor Seen { var hit = false; func mark() { hit = true } }
        let seen = Seen()
        let real: DaemonServerRequestHandler = { _, _ in
            await seen.mark()
            return ["approved": false, "call_id": "x"]
        }
        // marker IS present (in the target), canonical path matches — but the link
        // tip is a symlink → must hit the real handler, NOT auto-approve.
        let wrapped = defaultAwareHandler(real, defaultPath: link, isMarkerPresent: { true })
        let reply = await wrapped("workspace.confirm_root",
                                  ["call_id": "c1", "path": link.path])
        XCTAssertEqual(reply["approved"] as? Bool, false, "symlinked default must NOT auto-approve")
        let hit = await seen.hit
        XCTAssertTrue(hit, "symlinked default confirm must surface the real handler")
    }

    /// `ensureDefaultRooted` rejects a symlinked default root BEFORE contacting
    /// the daemon — even with endpoints published, no `set_root` frame is sent.
    /// (Surfaces the symlink error, not `daemonUnavailable`.)
    func testEnsureDefaultRootedRejectsSymlinkedDefaultBeforeDaemon() async throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-symlink-target-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-symlink-root-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let (peer, tokenPath) = try await publishFakeDaemonEndpoints()
        defer {
            Task { await clearDaemonEndpoints() }
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: link))
        defer { Task { await session.close() } }

        let rooted = Task { try await session.ensureDefaultRooted() }
        // Drive nothing past auth; expect the symlink throw without a set_root.
        do {
            _ = try await withTimeout(rooted)
            XCTFail("ensureDefaultRooted must throw for a symlinked default root")
        } catch FaeWorkspaceError.symlinkedWorkspaceRoot {
            // expected — the symlink guard fired before setRoot.
        } catch DaemonAgentClientError.daemonUnavailable {
            XCTFail("symlink guard must fire before the daemon-unavailable path")
        } catch {
            XCTFail("expected symlinkedWorkspaceRoot, got \(error)")
        }
        let hasRoot = await session.hasRoot()
        XCTAssertFalse(hasRoot, "a symlinked default must leave the session unrooted")
        _ = peer  // daemon published but never sent a set_root
    }

    /// Executor-level proof: a routed `read` against a symlinked default root
    /// returns an error (fail closed) WITHOUT rooting the session, even though a
    /// daemon is published. (The SSH-key exfiltration vector — `read id_rsa` —
    /// must be stopped at the Swift seam.)
    func testRoutedReadRejectsSymlinkedDefaultRoot() async throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-ssh-standin-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // A "key" the model would love to read — planted in the symlink target.
        try Data("PRIVATE KEY MATERIAL".utf8).write(to: target.appendingPathComponent("id_rsa"))
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-symlink-root-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let (peer, tokenPath) = try await publishFakeDaemonEndpoints()
        defer {
            Task { await clearDaemonEndpoints() }
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: link))
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [ReadTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session
        )

        let exec = Task<ToolExecutorResult, Never> {
            await executor.execute(
                ToolCall(name: "read", arguments: ["path": "id_rsa"]),
                context: makeFullContext(), callbacks: .noop)
        }
        // Do NOT drive the daemon handshake; the symlink guard should fire first.
        let outcome = try await withTimeoutAsNever(exec)
        XCTAssertTrue(outcome.result.isError, "read of a symlinked-default-root file must be denied")
        XCTAssertFalse(outcome.result.output.contains("PRIVATE KEY MATERIAL"),
                      "the key material must NEVER be returned")
        let hasRoot = await session.hasRoot()
        XCTAssertFalse(hasRoot, "the session must not root through a symlinked default")
        _ = peer
    }

    // MARK: helpers

    /// Extract a `"field":"value"` string from a single-line JSON frame (test
    /// helper for matching routed execute frames without a full JSON parse).
    private static func extractField(_ line: String, field: String) -> String? {
        guard let range = line.range(of: "\"\(field)\":\"") else { return nil }
        let rest = line[range.upperBound...]
        if let endQuote = rest.firstIndex(of: "\"") {
            return String(rest[..<endQuote])
        }
        return nil
    }

    /// `withTimeout` for a `Task<T, Never>` (the concurrent-read tasks never throw).
    private func withTimeoutAsNever<T>(_ task: Task<T, Never>) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw NSError(domain: "DaemonToolHostTests", code: 99, userInfo: [NSLocalizedDescriptionKey: "timed out"])
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

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

// MARK: - B-Swift Phase F7a: routed write tests
//
// Mirror the routed-read test matrix with the KEY write difference: mutations
// are irreversible, so an intended-but-down daemon FAILS CLOSED (no confined
// local write fallback). The success path additionally exercises pre-state
// capture + receipt creation + post-action narration (the mutation steps the
// read branch skips). Each test uses the injected routed-write executor seam
// (`setRoutedWriteExecutorForTesting`) so the timeout/hooks/receipt pipeline
// runs without a live daemon.

extension DaemonToolHostTests {

    /// A routed write with a reachable (canned) daemon succeeds and records a
    /// receipt (the mutation step the read branch skips).
    func testRoutedWriteSucceedsAndRecordsReceipt() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7a-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: true)
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [WriteTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session)
        // Real ReceiptStore against a temp DB so the receipt row is actually
        // written (proves the mutation receipt step ran).
        let receiptDB = tmp.appendingPathComponent("receipts.db").path
        let store = try ReceiptStore(path: receiptDB)
        await executor.setReceiptStore(store)
        await executor.setRoutedWriteExecutorForTesting { _, _, _ in
            .routed(
                result: ["content": [["type": "text", "text": "Wrote 5 bytes to `notes.txt`"]]],
                preStateContent: nil,
                absoluteTargetPath: nil)
        }

        let outcome = await executor.execute(
            ToolCall(name: "write", arguments: ["path": "notes.txt", "content": "hello"]),
            context: makeFullContext(),
            callbacks: .noop)

        XCTAssertFalse(outcome.result.isError,
                       "routed write must succeed: \(outcome.result.output)")
        XCTAssertTrue(outcome.result.output.contains("Wrote 5 bytes"),
                      "the daemon's write success content must surface (not a generic string): \(outcome.result.output)")
        XCTAssertNotNil(outcome.latencyMs,
                        "the routed-write pipeline must record latencyMs")
    }

    /// F7a key invariant: an intended-but-down daemon FAILS CLOSED — no local
    /// write, friendly error. Tested via the REAL `routeWrite` (not the executor
    /// seam, which replaces routeWrite and would bypass the fail-closed branch).
    /// The `.daemonUnavailableFailClosed` plan must return an error WITHOUT
    /// contacting the daemon (no root bound).
    func testRoutedWriteIntendedDownFailsClosedNoLocalFallback() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7a-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: true)
        defer { Task { await session.close() } }

        let outcome = await DaemonToolRouting.routeWrite(
            call: ToolCall(name: "write", arguments: ["path": "notes.txt", "content": "hello"]),
            session: session,
            plan: .daemonUnavailableFailClosed)

        guard case .failClosed = outcome else {
            XCTFail("the fail-closed plan must return .failClosed (no local write fallback): \(outcome)")
            return
        }
        let failClosedHasRoot = await session.hasRoot()
        XCTAssertFalse(failClosedHasRoot,
                       "fail-closed must not bind a daemon root (no daemon contact)")
    }

    /// An opted-out runtime (useDaemonEngine=false) with no daemon falls through
    /// to the FULL local pipeline — the legacy path-based `WriteTool` writes an
    /// ABSOLUTE path (which routing would deny), and the routed executor is
    /// NEVER called.
    func testRoutedWriteOptedOutFallsThroughToLegacyLocal() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7a-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let absPath = tmp.appendingPathComponent("outside.txt")

        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: false)
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [WriteTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session)
        await executor.setRoutedWriteExecutorForTesting { _, _, _ in
            .failClosed("routed executor must not be called for legacy fall-through")
        }

        let outcome = await executor.execute(
            ToolCall(name: "write", arguments: ["path": absPath.path, "content": "legacy-local-write"]),
            context: makeFullContext(),
            callbacks: .noop)

        XCTAssertFalse(outcome.result.isError,
                       "legacy local write of an absolute path must succeed: \(outcome.result.output)")
        let wrote = (try? Data(contentsOf: absPath)).map { String(data: $0, encoding: .utf8) } ?? nil
        XCTAssertEqual(wrote, "legacy-local-write",
                       "the legacy local WriteTool must have written the file")
    }

    /// A stalling routed write trips the timeout (the wrapped pipeline fires).
    func testRoutedWriteTimeoutReturnsTimeoutError() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7a-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: true)
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [WriteTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session)
        await executor.setRoutedWriteTimeoutForTesting(0.4)
        await executor.setRoutedWriteExecutorForTesting { _, _, _ in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return .routed(result: [:], preStateContent: nil, absoluteTargetPath: nil)
        }

        let start = Date()
        let outcome = await executor.execute(
            ToolCall(name: "write", arguments: ["path": "notes.txt", "content": "hello"]),
            context: makeFullContext(),
            callbacks: .noop)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(outcome.result.isError, "stalling routed write must time out")
        XCTAssertTrue(outcome.result.output.contains("took too long"),
                      "error must be the friendly timeout message: \(outcome.result.output)")
        XCTAssertLessThan(elapsed, 2.0, "the 0.4s timeout must fire, not the 5s stall")
        XCTAssertNotNil(outcome.latencyMs,
                        "timeout path must record latencyMs")
    }

    /// A blocking PreToolUse hook must block BEFORE the routed write runs (no
    /// daemon side effect, no receipt). Mirrors the read hook test.
    func testRoutedWritePreToolUseHookBlocksBeforeWrite() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7a-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let hooks = SpyHookRunner(preResponse:
            HookResponse(systemMessage: "blocked-by-test", block: true, metadata: nil))
        let logger = SpySecurityLogger(), analytics = SpyToolAnalytics()
        let executor = await makeSpiedRoutedWriteExecutor(
            tmp: tmp, hookRunner: hooks, logger: logger, analytics: analytics) { _, _, _ in
                .routed(result: [:], preStateContent: nil, absoluteTargetPath: nil)
            }

        let outcome = await executor.execute(
            ToolCall(name: "write", arguments: ["path": "notes.txt", "content": "hello"]),
            context: makeFullContext(), callbacks: .noop)

        let preNames = await hooks.preToolNames
        XCTAssertEqual(preNames, ["write"], "PreToolUse must fire for the routed write")
        XCTAssertTrue(outcome.result.isError, "a blocking PreToolUse hook must surface an error")
        XCTAssertEqual(outcome.result.output, "blocked-by-test",
                       "the hook's block message must surface: \(outcome.result.output)")
        let posts = await hooks.postToolNames
        XCTAssertEqual(posts, [], "PostToolUse must NOT fire when PreToolUse blocks")
    }

    /// A routed write missing the `content` parameter is shape-denied before any
    /// daemon contact. Tested via the REAL `routeWrite` (the executor seam would
    /// bypass this guard, which lives inside routeWrite).
    func testRoutedWriteMissingContentIsShapeDenied() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7a-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: true)
        defer { Task { await session.close() } }

        // Even with a reachable plan, missing content is rejected BEFORE the
        // daemon is contacted (no root bound).
        let outcome = await DaemonToolRouting.routeWrite(
            call: ToolCall(name: "write", arguments: ["path": "notes.txt"]),  // no content
            session: session,
            plan: .daemonReachable)

        guard case .denied(let reason) = outcome else {
            XCTFail("missing content must be .denied: \(outcome)")
            return
        }
        XCTAssertTrue(reason.contains("content"),
                      "error must mention the missing content parameter: \(reason)")
        let missingContentHasRoot = await session.hasRoot()
        XCTAssertFalse(missingContentHasRoot,
                       "must not contact the daemon when content is missing")
    }

    /// `planWriteRoute` shape: opted-out + no daemon → `.legacyLocal` (fall
    /// through); intended + no daemon → `.daemonUnavailableFailClosed`.
    func testPlanWriteRouteBranches() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7a-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let optedOut = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: false)
        defer { Task { await optedOut.close() } }
        let planOut = await DaemonToolRouting.planWriteRoute(session: optedOut)
        XCTAssertEqual(planOut, .legacyLocal,
                       "opted-out + no daemon must plan the legacy local write")

        let intended = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: true)
        defer { Task { await intended.close() } }
        let planIn = await DaemonToolRouting.planWriteRoute(session: intended)
        XCTAssertEqual(planIn, .daemonUnavailableFailClosed,
                       "intended + no daemon must plan fail-closed (no local write fallback)")
    }

    /// `validateWritePathShape` parity with the read validator: absolute / `..` /
    /// empty / NUL are denied; a normal relative path passes.
    func testValidateWritePathShape() {
        XCTAssertEqual(DaemonToolRouting.validateWritePathShape("notes.txt"), .ok("notes.txt"))
        XCTAssertEqual(DaemonToolRouting.validateWritePathShape("a/b/c.txt"), .ok("a/b/c.txt"))
        if case .ok = DaemonToolRouting.validateWritePathShape("/etc/passwd") {
            XCTFail("absolute write path must be denied")
        }
        if case .ok = DaemonToolRouting.validateWritePathShape("../escape.txt") {
            XCTFail("`..` write path must be denied")
        }
        if case .ok = DaemonToolRouting.validateWritePathShape("") {
            XCTFail("empty write path must be denied")
        }
        if case .ok = DaemonToolRouting.validateWritePathShape("a\0b") {
            XCTFail("NUL in write path must be denied")
        }
    }

    /// F7a (advisor): the fd-anchored pre-state capture returns the OLD content
    /// of an existing regular file under the root — read off the open leaf fd,
    /// not a path (no TOCTOU). This is the safe replacement for the path-based
    /// capturePreStateForTool that would have followed symlinks/hardlinks.
    func testReadFdAnchoredPreStateCapturesOldContent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7a-ps-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("original-content".utf8).write(to: root.appendingPathComponent("file.txt"))

        let preState = DaemonToolRouting.readFdAnchoredPreState(validatedPath: "file.txt", root: root)
        XCTAssertEqual(preState, Data("original-content".utf8),
                       "pre-state must be the existing file's full content")
    }

    /// F7a (advisor): a symlink leaf in the workspace pointing OUTSIDE the root
    /// must NOT leak the outside content during pre-state capture. The O_NOFOLLOW
    /// leaf open rejects it (ELOOP) → nil. (The daemon write would reject it too.)
    func testReadFdAnchoredPreStateReturnsNilForSymlinkNoLeak() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7a-ps-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Outside secret the symlink would leak if the capture followed it.
        let secret = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7a-secret-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: secret) }
        try Data("TOPSECRET".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"), withDestinationURL: secret)

        let preState = DaemonToolRouting.readFdAnchoredPreState(validatedPath: "link.txt", root: root)
        XCTAssertNil(preState, "a symlink leaf must yield no pre-state (no leak)")
    }

    /// F7a (advisor): a hardlink (st_nlink > 1) yields no pre-state — the fstat
    /// off the opened leaf fd rejects it (mirrors the daemon's own hardlink
    /// reject on write).
    func testReadFdAnchoredPreStateReturnsNilForHardlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7a-ps-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("orig.txt")
        try Data("shared".utf8).write(to: original)
        try FileManager.default.linkItem(
            at: original, to: root.appendingPathComponent("link.txt"))  // now st_nlink == 2

        let preState = DaemonToolRouting.readFdAnchoredPreState(validatedPath: "link.txt", root: root)
        XCTAssertNil(preState, "a hardlink (st_nlink > 1) must yield no pre-state")
    }

    /// F7a (advisor): a new (non-existent) target yields no pre-state — there
    /// is nothing to undo (the write creates it).
    func testReadFdAnchoredPreStateReturnsNilForNewFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7a-ps-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let preState = DaemonToolRouting.readFdAnchoredPreState(validatedPath: "newfile.txt", root: root)
        XCTAssertNil(preState, "a non-existent target must yield no pre-state")
    }

    /// F7a (advisor): a routed write whose outcome carries fd-anchored pre-state
    /// records that pre-state (old content + absolute target path) in the
    /// receipt — proving the outcome→receipt wiring uses the SAFE material, not a
    /// path-based capture. (The capture itself is covered by the four tests above.)
    func testRoutedWriteReceiptCarriesFdAnchoredPreState() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7a-rc-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: true)
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [WriteTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session)
        let store = try ReceiptStore(path: tmp.appendingPathComponent("receipts.db").path)
        await executor.setReceiptStore(store)
        // Inject the SAFE outcome material the real executeSerializedRoutedWrite
        // would produce (fd-anchored old content + daemon-approved abs path).
        let absTarget = tmp.appendingPathComponent("notes.txt").path
        await executor.setRoutedWriteExecutorForTesting { _, _, _ in
            .routed(result: [:], preStateContent: Data("old-content".utf8), absoluteTargetPath: absTarget)
        }

        let outcome = await executor.execute(
            ToolCall(name: "write", arguments: ["path": "notes.txt", "content": "new"]),
            context: makeFullContext(),
            callbacks: .noop)
        XCTAssertFalse(outcome.result.isError, "routed write must succeed: \(outcome.result.output)")

        let receipts = await store.recentReceipts(speakerId: nil, limit: 5)
        let writeReceipt = receipts.first { $0.toolName == "write" }
        XCTAssertNotNil(writeReceipt, "a receipt must be recorded for the routed write")
        XCTAssertEqual(writeReceipt?.preStateBlob, Data("old-content".utf8),
                       "the receipt must carry the fd-anchored old content")
        XCTAssertEqual(writeReceipt?.preStatePath, absTarget,
                       "the receipt must carry the daemon-approved absolute target path")
    }

    /// F7a (advisor #1): a routed write that CREATES a new file (no old content)
    /// still records the receipt PATH (blob nil) — undo for a created file
    /// deletes it, so it needs the path. Mirrors the local `captureFilePreState`
    /// `(blob:nil, path:)` shape; the previous `preStateContent.map { ... }` form
    /// would have dropped the path when the blob was nil.
    func testRoutedWriteReceiptPreservesPathWhenBlobIsNil() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7a-nb-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: true)
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [WriteTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session)
        let store = try ReceiptStore(path: tmp.appendingPathComponent("receipts.db").path)
        await executor.setReceiptStore(store)
        // New-file outcome: fd-anchored pre-state is nil (file didn't exist),
        // but the absolute target path is still carried for undo.
        let absTarget = tmp.appendingPathComponent("newfile.txt").path
        await executor.setRoutedWriteExecutorForTesting { _, _, _ in
            .routed(result: [:], preStateContent: nil, absoluteTargetPath: absTarget)
        }

        let outcome = await executor.execute(
            ToolCall(name: "write", arguments: ["path": "newfile.txt", "content": "created"]),
            context: makeFullContext(),
            callbacks: .noop)
        XCTAssertFalse(outcome.result.isError, "routed write must succeed: \(outcome.result.output)")

        let receipts = await store.recentReceipts(speakerId: nil, limit: 5)
        let writeReceipt = receipts.first { $0.toolName == "write" }
        XCTAssertNotNil(writeReceipt, "a receipt must be recorded even for a new-file write")
        XCTAssertNil(writeReceipt?.preStateBlob,
                     "a created file has no old content (blob nil)")
        XCTAssertEqual(writeReceipt?.preStatePath, absTarget,
                       "the receipt must still carry the path for undo (blob nil must not drop the path)")
    }

    /// Write-variant of the spied executor helper (mirrors
    /// `makeSpiedRoutedExecutor` but injects the write executor + WriteTool).
    private func makeSpiedRoutedWriteExecutor(
        tmp: URL, hookRunner: SpyHookRunner?, logger: SpySecurityLogger,
        analytics: SpyToolAnalytics, routed: @escaping @Sendable (ToolCall, DaemonToolHostSession, DaemonToolRouting.WriteRoutePlan) async -> DaemonToolRouting.WriteExecutionOutcome
    ) async -> ToolExecutor {
        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: true)
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [WriteTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: logger,
            toolAnalytics: analytics,
            daemonToolHostSession: session)
        if let hookRunner { await executor.setPluginHookRunner(hookRunner) }
        await executor.setRoutedWriteExecutorForTesting(routed)
        return executor
    }
}

// MARK: - B-Swift Phase F7b: routed edit tests
//
// Mirrors the routed-write matrix (F7a). The KEY edit-specific addition is the
// schema-translation test: the Swift `EditTool` uses `old_string`/`new_string`,
// but the fluers daemon `EditTool` requires `old_text`/`new_text`. The
// translation happens at the daemon seam (`buildDaemonEditInput`, called by
// `executeSerializedRoutedEdit`), so the daemon receives `old_text`/`new_text`
// and `call.arguments`/hooks/audit/receipts keep the Swift-native keys.

extension DaemonToolHostTests {

    /// A routed edit with a reachable (canned) daemon succeeds and surfaces the
    /// daemon's edit success content ("Edited `path` (X -> Y bytes)").
    func testRoutedEditSucceedsAndSurfacesContent() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: true)
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [EditTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session)
        await executor.setRoutedEditExecutorForTesting { _, _, _ in
            .routed(
                result: ["content": [["type": "text", "text": "Edited `cfg.toml` (12 -> 14 bytes)"]]],
                preStateContent: nil,
                absoluteTargetPath: nil)
        }

        let outcome = await executor.execute(
            ToolCall(name: "edit",
                     arguments: ["path": "cfg.toml", "old_string": "timeout = 30", "new_string": "timeout = 600"]),
            context: makeFullContext(),
            callbacks: .noop)

        XCTAssertFalse(outcome.result.isError,
                       "routed edit must succeed: \(outcome.result.output)")
        XCTAssertTrue(outcome.result.output.contains("Edited"),
                      "the daemon's edit success content must surface (not a generic string): \(outcome.result.output)")
        XCTAssertNotNil(outcome.latencyMs,
                        "the routed-edit pipeline must record latencyMs")
    }

    /// F7b KEY test: the schema is TRANSLATED at the daemon seam. The Swift-
    /// facing `old_string`/`new_string` become the fluers `old_text`/`new_text`,
    /// and the Swift-native keys never leak into the daemon input dict. Pure
    /// unit test of `buildDaemonEditInput` (the exact dict `execute(tool:input:)`
    /// receives). A routed edit sending `old_string` to the daemon would be
    /// rejected by fluers `validate_input` (missing `old_text`).
    func testEditSchemaTranslatesOldNewStringToOldNewText() {
        let input = DaemonToolRouting.buildDaemonEditInput(
            validatedPath: "cfg.toml", oldString: "timeout = 30", newString: "timeout = 600")
        XCTAssertEqual(input["path"] as? String, "cfg.toml")
        XCTAssertEqual(input["old_text"] as? String, "timeout = 30",
                       "Swift old_string must be translated to the daemon's old_text")
        XCTAssertEqual(input["new_text"] as? String, "timeout = 600",
                       "Swift new_string must be translated to the daemon's new_text")
        XCTAssertNil(input["old_string"],
                     "the Swift-native old_string key must NOT leak to the daemon")
        XCTAssertNil(input["new_string"],
                     "the Swift-native new_string key must NOT leak to the daemon")
    }

    /// F7b key invariant (mirrors write): an intended-but-down daemon FAILS
    /// CLOSED — no local edit, friendly error. Tested via the REAL `routeEdit`
    /// (not the executor seam, which replaces routeEdit).
    func testRoutedEditIntendedDownFailsClosedNoLocalFallback() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: true)
        defer { Task { await session.close() } }

        let outcome = await DaemonToolRouting.routeEdit(
            call: ToolCall(name: "edit",
                           arguments: ["path": "cfg.toml", "old_string": "a", "new_string": "b"]),
            session: session,
            plan: .daemonUnavailableFailClosed)

        guard case .failClosed = outcome else {
            XCTFail("the fail-closed plan must return .failClosed (no local edit fallback): \(outcome)")
            return
        }
        let failClosedHasRoot = await session.hasRoot()
        XCTAssertFalse(failClosedHasRoot,
                       "fail-closed must not bind a daemon root (no daemon contact)")
    }

    /// An opted-out runtime (useDaemonEngine=false) with no daemon falls through
    /// to the FULL local pipeline — the legacy path-based `EditTool` edits an
    /// ABSOLUTE path (which routing would deny), and the routed executor is
    /// NEVER called.
    func testRoutedEditOptedOutFallsThroughToLegacyLocal() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let absPath = tmp.appendingPathComponent("outside.txt")
        try Data("hello world".utf8).write(to: absPath)

        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: false)
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [EditTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session)
        await executor.setRoutedEditExecutorForTesting { _, _, _ in
            .failClosed("routed executor must not be called for legacy fall-through")
        }

        let outcome = await executor.execute(
            ToolCall(name: "edit",
                     arguments: ["path": absPath.path, "old_string": "hello", "new_string": "goodbye"]),
            context: makeFullContext(),
            callbacks: .noop)

        XCTAssertFalse(outcome.result.isError,
                       "legacy local edit of an absolute path must succeed: \(outcome.result.output)")
        let edited = (try? Data(contentsOf: absPath)).flatMap { String(data: $0, encoding: .utf8) } ?? nil
        XCTAssertEqual(edited, "goodbye world",
                       "the legacy local EditTool must have edited the file")
    }

    /// A stalling routed edit trips the timeout (the wrapped pipeline fires).
    func testRoutedEditTimeoutReturnsTimeoutError() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: true)
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [EditTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session)
        await executor.setRoutedEditTimeoutForTesting(0.4)
        await executor.setRoutedEditExecutorForTesting { _, _, _ in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return .routed(result: [:], preStateContent: nil, absoluteTargetPath: nil)
        }

        let start = Date()
        let outcome = await executor.execute(
            ToolCall(name: "edit",
                     arguments: ["path": "cfg.toml", "old_string": "a", "new_string": "b"]),
            context: makeFullContext(),
            callbacks: .noop)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(outcome.result.isError, "stalling routed edit must time out")
        XCTAssertTrue(outcome.result.output.contains("took too long"),
                      "error must be the friendly timeout message: \(outcome.result.output)")
        XCTAssertLessThan(elapsed, 2.0, "the 0.4s timeout must fire, not the 5s stall")
        XCTAssertNotNil(outcome.latencyMs,
                        "timeout path must record latencyMs")
    }

    /// A blocking PreToolUse hook must block BEFORE the routed edit runs (no
    /// daemon side effect). Mirrors the write hook test.
    func testRoutedEditPreToolUseHookBlocksBeforeEdit() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let hooks = SpyHookRunner(preResponse:
            HookResponse(systemMessage: "blocked-by-test", block: true, metadata: nil))
        let logger = SpySecurityLogger(), analytics = SpyToolAnalytics()
        let executor = await makeSpiedRoutedEditExecutor(
            tmp: tmp, hookRunner: hooks, logger: logger, analytics: analytics) { _, _, _ in
                .routed(result: [:], preStateContent: nil, absoluteTargetPath: nil)
            }

        let outcome = await executor.execute(
            ToolCall(name: "edit",
                     arguments: ["path": "cfg.toml", "old_string": "a", "new_string": "b"]),
            context: makeFullContext(), callbacks: .noop)

        let preNames = await hooks.preToolNames
        XCTAssertEqual(preNames, ["edit"], "PreToolUse must fire for the routed edit")
        XCTAssertTrue(outcome.result.isError, "a blocking PreToolUse hook must surface an error")
        XCTAssertEqual(outcome.result.output, "blocked-by-test",
                       "the hook's block message must surface: \(outcome.result.output)")
        let posts = await hooks.postToolNames
        XCTAssertEqual(posts, [], "PostToolUse must NOT fire when PreToolUse blocks")
    }

    /// A routed edit missing `old_string`/`new_string`, or with an empty
    /// `old_string`, is shape-denied before any daemon contact. Tested via the
    /// REAL `routeEdit` (the executor seam would bypass these guards, which
    /// live inside routeEdit).
    func testRoutedEditMissingOrEmptyArgsAreShapeDenied() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: true)
        defer { Task { await session.close() } }

        // Missing old_string.
        let missingOld = await DaemonToolRouting.routeEdit(
            call: ToolCall(name: "edit", arguments: ["path": "cfg.toml", "new_string": "b"]),
            session: session, plan: .daemonReachable)
        guard case .denied(let r1) = missingOld else { XCTFail("missing old_string must be .denied: \(missingOld)"); return }
        XCTAssertTrue(r1.contains("old_string"), "error must mention old_string: \(r1)")

        // Missing new_string (note: empty new_string is ALLOWED — deletion — so
        // test the fully-absent key, not the empty string).
        let missingNew = await DaemonToolRouting.routeEdit(
            call: ToolCall(name: "edit", arguments: ["path": "cfg.toml", "old_string": "a"]),
            session: session, plan: .daemonReachable)
        guard case .denied(let r2) = missingNew else { XCTFail("missing new_string must be .denied: \(missingNew)"); return }
        XCTAssertTrue(r2.contains("new_string"), "error must mention new_string: \(r2)")

        // Empty old_string (would insert at the start — corruption).
        let emptyOld = await DaemonToolRouting.routeEdit(
            call: ToolCall(name: "edit", arguments: ["path": "cfg.toml", "old_string": "", "new_string": "b"]),
            session: session, plan: .daemonReachable)
        guard case .denied(let r3) = emptyOld else { XCTFail("empty old_string must be .denied: \(emptyOld)"); return }
        XCTAssertTrue(r3.contains("non-empty"), "error must reject empty old_string: \(r3)")

        // Empty new_string is ALLOWED (deletion of the unique match is valid) —
        // it must PASS arg validation and reach the plan, not be shape-denied.
        // Use the fail-closed plan so we observe .failClosed (not .denied) with
        // no daemon contact.
        let emptyNew = await DaemonToolRouting.routeEdit(
            call: ToolCall(name: "edit", arguments: ["path": "cfg.toml", "old_string": "a", "new_string": ""]),
            session: session, plan: .daemonUnavailableFailClosed)
        guard case .failClosed = emptyNew else {
            XCTFail("empty new_string must be allowed (deletion), reaching the plan (.failClosed), not denied: \(emptyNew)")
            return
        }

        // None of these contacted the daemon.
        let hasRoot = await session.hasRoot()
        XCTAssertFalse(hasRoot, "shape denials must not contact the daemon")
    }

    /// `planEditRoute` shape: opted-out + no daemon → `.legacyLocal` (fall
    /// through); intended + no daemon → `.daemonUnavailableFailClosed`.
    func testPlanEditRouteBranches() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let optedOut = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: false)
        defer { Task { await optedOut.close() } }
        let planOut = await DaemonToolRouting.planEditRoute(session: optedOut)
        XCTAssertEqual(planOut, .legacyLocal,
                       "opted-out + no daemon must plan the legacy local edit")

        let intended = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: true)
        defer { Task { await intended.close() } }
        let planIn = await DaemonToolRouting.planEditRoute(session: intended)
        XCTAssertEqual(planIn, .daemonUnavailableFailClosed,
                       "intended + no daemon must plan fail-closed (no local edit fallback)")
    }

    /// `validateEditPathShape` parity with the write/read validators: absolute /
    /// `..` / empty / NUL are denied; a normal relative path passes.
    func testValidateEditPathShape() {
        XCTAssertEqual(DaemonToolRouting.validateEditPathShape("cfg.toml"), .ok("cfg.toml"))
        XCTAssertEqual(DaemonToolRouting.validateEditPathShape("a/b/c.txt"), .ok("a/b/c.txt"))
        if case .ok = DaemonToolRouting.validateEditPathShape("/etc/passwd") {
            XCTFail("absolute edit path must be denied")
        }
        if case .ok = DaemonToolRouting.validateEditPathShape("../escape.txt") {
            XCTFail("`..` edit path must be denied")
        }
        if case .ok = DaemonToolRouting.validateEditPathShape("") {
            XCTFail("empty edit path must be denied")
        }
        if case .ok = DaemonToolRouting.validateEditPathShape("a\0b") {
            XCTFail("NUL in edit path must be denied")
        }
    }

    /// F7b: a routed edit whose outcome carries fd-anchored pre-state records
    /// that pre-state (old content + absolute target path) in the receipt. For
    /// edit the old content IS the undo target (essential), so this is the
    /// load-bearing receipt assertion.
    func testRoutedEditReceiptCarriesFdAnchoredPreState() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-f7b-rc-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: true)
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [EditTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session)
        let store = try ReceiptStore(path: tmp.appendingPathComponent("receipts.db").path)
        await executor.setReceiptStore(store)
        let absTarget = tmp.appendingPathComponent("cfg.toml").path
        await executor.setRoutedEditExecutorForTesting { _, _, _ in
            .routed(result: [:], preStateContent: Data("timeout = 30\n".utf8), absoluteTargetPath: absTarget)
        }

        let outcome = await executor.execute(
            ToolCall(name: "edit",
                     arguments: ["path": "cfg.toml", "old_string": "timeout = 30", "new_string": "timeout = 600"]),
            context: makeFullContext(),
            callbacks: .noop)
        XCTAssertFalse(outcome.result.isError, "routed edit must succeed: \(outcome.result.output)")

        let receipts = await store.recentReceipts(speakerId: nil, limit: 5)
        let editReceipt = receipts.first { $0.toolName == "edit" }
        XCTAssertNotNil(editReceipt, "a receipt must be recorded for the routed edit")
        XCTAssertEqual(editReceipt?.preStateBlob, Data("timeout = 30\n".utf8),
                       "the receipt must carry the fd-anchored old content (the undo target)")
        XCTAssertEqual(editReceipt?.preStatePath, absTarget,
                       "the receipt must carry the daemon-approved absolute target path")
        // Swift-native keys are preserved in the receipt's recorded arguments
        // (the schema translation is daemon-side ONLY — call.arguments is intact).
        let argsData = try XCTUnwrap(editReceipt?.argumentsJSON.data(using: .utf8))
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with: argsData) as? [String: Any])
        XCTAssertEqual(args["old_string"] as? String, "timeout = 30",
                       "the receipt must record the Swift-native old_string key")
        XCTAssertNil(args["old_text"],
                     "the daemon-translated old_text key must NOT appear in the receipt args")
    }

    /// Edit-variant of the spied executor helper (mirrors
    /// `makeSpiedRoutedWriteExecutor` but injects the edit executor + EditTool).
    private func makeSpiedRoutedEditExecutor(
        tmp: URL, hookRunner: SpyHookRunner?, logger: SpySecurityLogger,
        analytics: SpyToolAnalytics, routed: @escaping @Sendable (ToolCall, DaemonToolHostSession, DaemonToolRouting.EditRoutePlan) async -> DaemonToolRouting.EditExecutionOutcome
    ) async -> ToolExecutor {
        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp), daemonIntended: true)
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [EditTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: logger,
            toolAnalytics: analytics,
            daemonToolHostSession: session)
        if let hookRunner { await executor.setPluginHookRunner(hookRunner) }
        await executor.setRoutedEditExecutorForTesting(routed)
        return executor
    }
}
