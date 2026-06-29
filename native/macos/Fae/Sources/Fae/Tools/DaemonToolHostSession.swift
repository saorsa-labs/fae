import Foundation

/// A persistent, authenticated connection to the daemon ToolHost that binds an
/// owner-approved durable workspace root (B-Swift Layer 2, Option B).
///
/// **Why this actor exists (the persistent-connection invariant):** B-Rust's
/// `root_state` is **per transport connection** — a local inside the daemon's
/// `handle_connection`. The A3-Swift one-shot pattern (`toolhostExecute` opens /
/// authenticates / closes per call) would LOSE the approved root: `set_root` on
/// connection A, then `execute` on connection B, leaves B at `Unset` (temp
/// sandbox or denied). This actor owns ONE `DaemonSocketConnection` for the
/// session: authenticate once → `set_root` once → reuse the SAME socket for every
/// `execute`. Actor isolation serializes calls (no concurrent roundTrips on one
/// socket, which the single-read-loop wire protocol cannot multiplex).
///
/// The server-request handler is shared with `DaemonAgentClient`, so a
/// `workspace.confirm_root` (during `setRoot`) and a `tool.confirm` (during a
/// dangerous `execute`) both work on this live connection.
///
/// Inert until Layer 3 (routing) calls it. No production caller wires it into
/// the pipeline yet — the root-source decision (scope §8) gates routing.
/// The type of the server-request handler used by the session. Defaulting to
/// the real `DaemonAgentClient.handleServerRequest` in production; tests inject a
/// fake that returns the strict reply without surfacing the UI card (oracle
/// MAJOR-1 precedent: the test seam is a function, NOT a mutable global actor).
typealias DaemonServerRequestHandler =
    (_ method: String, _ params: [String: Any]) async -> [String: Any]

actor DaemonToolHostSession {

    /// The single persistent connection, held across calls.
    private var connection: DaemonSocketConnection?
    /// The endpoints the current connection is bound to. If the daemon restarts
    /// (endpoints change), the session resets and re-binds on the next call.
    private var boundEndpoints: (socketPath: String, tokenPath: String)?
    private var authenticated = false
    /// `true` once `setRoot` succeeded on this connection. A fresh connection
    /// (after reset/reconnect) loses the root and must re-`setRoot`.
    private var rootSet = false
    private var requestCounter = 0
    /// The server-request handler (workspace.confirm_root during setRoot,
    /// tool.confirm during a dangerous execute). Injectable for tests.
    private let serverRequestHandler: DaemonServerRequestHandler

    /// - Parameter serverRequestHandler: defaults to the real governance handler
    ///   (`DaemonAgentClient.handleServerRequest`). Tests inject a fake that
    ///   returns the strict reply without the UI card (so the round-trip
    ///   completes without a human responder).
    init(serverRequestHandler: @escaping DaemonServerRequestHandler =
        DaemonAgentClient.handleServerRequest)
    {
        self.serverRequestHandler = serverRequestHandler
    }

    // MARK: - Lifecycle

    /// Ensure a live, authenticated connection to the current daemon endpoints.
    /// Reconnects (and resets root state) if endpoints changed or the
    /// connection is gone. Throws `daemonUnavailable` when no daemon is published.
    private func ensureConnected() async throws -> DaemonSocketConnection {
        guard let live = await DaemonEndpointStore.shared.current() else {
            // Daemon down — drop any stale connection so a later revival rebinds.
            resetLocked()
            throw DaemonAgentClientError.daemonUnavailable
        }
        // Reuse the live connection if the endpoints haven't moved.
        if let conn = connection,
           authenticated,
           boundEndpoints?.socketPath == live.socketPath
        {
            return conn
        }
        // (Re)connect + authenticate on a fresh socket.
        resetLocked()
        let conn = DaemonSocketConnection(queueLabel: "fae.daemon-toolhost.socket")
        try conn.connect(to: live.socketPath)
        do {
            try await DaemonAgentClient.authenticate(
                connection: conn, tokenPath: live.tokenPath)
        } catch {
            conn.close()
            throw error
        }
        connection = conn
        boundEndpoints = live
        authenticated = true
        // rootSet stays false — a brand-new connection has no approved root.
        return conn
    }

    /// Tear everything down (no root, no connection). Safe to call repeatedly.
    private func resetLocked() {
        connection?.close()
        connection = nil
        boundEndpoints = nil
        authenticated = false
        rootSet = false
    }

    // MARK: - Public API

    /// Bind an owner-approved durable workspace root (B-Rust `toolhost.set_root`).
    /// Surfaces the DISTINCT `workspace.confirm_root` card via the server-request-
    /// aware round-trip; the root is bound to THIS connection for the session.
    /// On owner denial, the root is NOT set and `execute` will fail-closed.
    ///
    /// - Returns: the daemon's `result` object (e.g. `{"root": "<canonical>"}`).
    @discardableResult
    func setRoot(path: String) async throws -> [String: Any] {
        let conn = try await ensureConnected()
        let requestID = nextRequestID()
        let frame = try DaemonWire.encodeFrame(
            requestID: requestID,
            command: "toolhost.set_root",
            payload: ["path": path])
        let raw = try await conn.roundTrip(
            frame: frame,
            expectRequestID: requestID,
            onServerRequest: { _, method, params in
                await self.serverRequestHandler(method, params)
            })
        let validated = try DaemonAgentClient.validate(raw)
        // B-Rust returns ok=true with {root} on approval; a denial comes back as
        // ok=false (root_denied / unsafe_root / root_already_initialized). Only
        // flip rootSet on a genuine approval.
        if (validated["ok"] as? Bool) == true {
            rootSet = true
        }
        return (validated["result"] as? [String: Any]) ?? [:]
    }

    /// Execute a portable tool on the durable-rooted ToolHost. REQUIRES a root
    /// set first (`setRoot`) — without one the daemon would bind a temp sandbox,
    /// which is the wrong root for routed owner-facing file tools (Layer 3
    /// routing must never call this without a root). Fails closed otherwise.
    ///
    /// A dangerous tool (write/edit/bash) additionally emits a `tool.confirm`
    /// server-request, answered on this same connection. The caller must also
    /// hold the server-side `ToolExecuteDangerous` scope (Q7b) or the daemon's
    /// inner gate denies without prompting (proven `ec15a4bd`).
    ///
    /// - Returns: the daemon's `result` object for the tool invocation.
    @discardableResult
    func execute(tool: String, input: [String: Any]) async throws -> [String: Any] {
        let conn = try await ensureConnected()
        guard rootSet else {
            // No approved root → do NOT silently run against the temp sandbox.
            // Layer 3 routing must not reach here without a root.
            throw DaemonAgentClientError.agentFailed(
                "no workspace root set — refusing to execute against a temp sandbox")
        }
        let requestID = nextRequestID()
        let frame = try DaemonWire.encodeFrame(
            requestID: requestID,
            command: "toolhost.execute",
            payload: ["tool": tool, "input": input])
        let raw = try await conn.roundTrip(
            frame: frame,
            expectRequestID: requestID,
            onServerRequest: { _, method, params in
                await self.serverRequestHandler(method, params)
            })
        let validated = try DaemonAgentClient.validate(raw)
        return (validated["result"] as? [String: Any]) ?? [:]
    }

    /// Whether `setRoot` has succeeded on the current connection (a durable root
    /// is bound). Layer 3 routing consults this before routing a file tool.
    func hasRoot() -> Bool { rootSet }

    /// Tear down the session (daemon shutdown, root denial, app session close).
    /// Resets connection + root state; the next call reconnects + re-roots.
    func close() {
        resetLocked()
    }

    /// Monotonic per-call request id (the daemon matches request_id per-frame;
    /// uniqueness avoids any stale-frame collision on the persistent socket).
    private func nextRequestID() -> String {
        requestCounter += 1
        return "th-\(requestCounter)"
    }
}
