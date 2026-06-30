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
            guard fd >= 0 else {
                throw NSError(domain: "FakeDaemonPeer", code: 6, userInfo: [NSLocalizedDescriptionKey: "send() on closed client"])
            }
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
        // Classifier assertion: only `read` routes in 3b.
        XCTAssertEqual(DaemonToolRouting.routedTools, ["read"])
        for nonRouted in ["write", "edit", "bash", "calendar", "web_search", "self_config"] {
            XCTAssertFalse(DaemonToolRouting.routedTools.contains(nonRouted),
                           "\(nonRouted) must not route in 3b")
        }

        // Smoke: a `write` with a daemon published runs locally + never roots.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let outFile = tmp.appendingPathComponent("out.txt")

        let (peer, tokenPath) = try await publishFakeDaemonEndpoints()
        defer {
            Task { await clearDaemonEndpoints() }
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
        let session = DaemonToolHostSession(
            workspaceProvider: TempWorkspace(workspaceRoot: tmp))
        defer { Task { await session.close() } }
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [WriteTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared,
            daemonToolHostSession: session
        )

        let outcome = await executor.execute(
            ToolCall(name: "write", arguments: ["path": outFile.path, "content": "hi"]),
            context: makeFullContext(), callbacks: .noop)
        XCTAssertFalse(outcome.result.isError, "local write should succeed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outFile.path), "write ran locally")
        // Routing never fired → the session was never rooted / never connected.
        let hasRoot = await session.hasRoot()
        XCTAssertFalse(hasRoot, "write must not root the daemon session")
        _ = peer  // daemon published but never contacted by the write
    }

    /// No daemon reachable ⇒ `read` falls back to the LOCAL ReadTool (legacy
    /// pre-routing behavior). `read` is `.low` risk and was always local. This
    /// uses the ORIGINAL path (not workspace-confined) — distinct from the
    /// daemon-involved fail-closed path in `testReadFailsClosedWhenDaemon…`.
    func testReadFallsBackToLocalWhenDaemonDown() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-3b-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("local content".utf8).write(to: tmp.appendingPathComponent("fallback.txt"))

        // No daemon published.
        await clearDaemonEndpoints()
        let executor = ToolExecutor(
            registry: ToolRegistry(tools: [ReadTool()]),
            damageControlPolicy: DamageControlPolicy(),
            securityLogger: SecurityEventLogger.shared
        )
        let outcome = await executor.execute(
            ToolCall(name: "read", arguments: ["path": tmp.appendingPathComponent("fallback.txt").path]),
            context: makeFullContext(), callbacks: .noop)
        XCTAssertFalse(outcome.result.isError, "local fallback read should succeed")
        XCTAssertEqual(outcome.result.output, "local content")
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
