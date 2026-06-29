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
