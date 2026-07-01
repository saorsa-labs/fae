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
    /// The owner-approved durable root bound to THIS connection (advisor #2: store
    /// the PATH, not just a bool — routing confines tool args to it). `nil` until
    /// `setRoot`/`ensureDefaultRooted` succeeds; reset on reconnect.
    private var approvedRootPath: URL?
    private var requestCounter = 0
    /// The server-request handler (workspace.confirm_root during setRoot,
    /// tool.confirm during a dangerous execute). Injectable for tests.
    private let serverRequestHandler: DaemonServerRequestHandler
    /// The default workspace provider this session roots against. Layer 3b
    /// routing uses the SAME provider for path confinement (so the confinement
    /// root == the daemon-approved root). Defaults to the real
    /// `~/Documents/Fae`; tests inject a temp-dir provider.
    private let workspaceProvider: FaeWorkspaceProvider

    /// Whether the daemon is the intended runtime for this session
    /// (`FaeConfig.llm.useDaemonEngine`). Gates the no-daemon fallback policy
    /// (B-Swift follow-up #2): when the daemon is intended but momentarily
    /// unreachable, routed `read`s confine LOCALLY to the workspace (the
    /// "reads are confined to `~/Documents/Fae`" invariant holds whether or
    /// not the daemon is up, and the `read` capability is preserved during
    /// outages); when the daemon is explicitly opted out (`useDaemonEngine ==
    /// false`, e.g. CI / pure-MLX), reads fall through to legacy UNCONFINED
    /// local behavior (pre-3b), which avoids provisioning `~/Documents/Fae`
    /// as a side effect in non-injecting test suites. `nonisolated` + Sendable
    /// `Bool` ⇒ readable off-actor without `await`.
    nonisolated let daemonIntended: Bool

    /// - Parameters:
    ///   - serverRequestHandler: defaults to the real governance handler
    ///     (`DaemonAgentClient.handleServerRequest`). Tests inject a fake that
    ///     returns the strict reply without the UI card (so the round-trip
    ///     completes without a human responder).
    ///   - workspaceProvider: the default workspace to root against AND confine
    ///     routed-tool paths to. Defaults to `~/Documents/Fae`; tests inject a
    ///     temp-dir provider.
    ///   - daemonIntended: mirrors `FaeConfig.llm.useDaemonEngine`. The
    ///     production construction site (`PipelineCoordinator`) passes the
    ///     config-derived value; tests pass `false` to exercise the opted-out
    ///     legacy fallback. Defaults to `true` to match the config default.
    init(
        serverRequestHandler: @escaping DaemonServerRequestHandler =
            DaemonAgentClient.handleServerRequest,
        workspaceProvider: FaeWorkspaceProvider = DefaultDocumentsWorkspace(),
        daemonIntended: Bool = true
    ) {
        self.serverRequestHandler = serverRequestHandler
        self.workspaceProvider = workspaceProvider
        self.daemonIntended = daemonIntended
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
        approvedRootPath = nil
    }

    // MARK: - Public API

    /// Bind an owner-approved durable workspace root (B-Rust `toolhost.set_root`).
    /// Surfaces the DISTINCT `workspace.confirm_root` card via the server-request-
    /// aware round-trip; the root is bound to THIS connection for the session.
    /// On owner denial, the root is NOT set and `execute` will fail-closed.
    ///
    /// - Returns: the daemon's `result` object (e.g. `{"root": "<canonical>"}`).
    /// Bind an owner-approved durable workspace root (B-Rust `toolhost.set_root`)
    /// using the session's default server-request handler. See `setRoot(_:handler:)`
    /// for the handler-injectable form used by `ensureDefaultRooted`.
    @discardableResult
    func setRoot(path: String) async throws -> [String: Any] {
        try await setRoot(path: path, handler: serverRequestHandler)
    }

    /// Handler-injectable `setRoot` (private — an internal helper for
    /// `ensureDefaultRooted`; the public API stays `setRoot(path:)`). Passes a
    /// `defaultAwareHandler`-wrapped handler so the Fae-owned default root is
    /// auto-approved (no card) while every other confirm surfaces the real card.
    @discardableResult
    private func setRoot(path: String, handler: @escaping DaemonServerRequestHandler) async throws -> [String: Any] {
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
                await handler(method, params)
            })
        let validated = try DaemonAgentClient.validate(raw)
        let result = (validated["result"] as? [String: Any]) ?? [:]
        // B-Rust returns ok=true with {root} on approval; a denial comes back as
        // ok=false (root_denied / unsafe_root / root_already_initialized). Bind
        // ONLY a clean, absolute, daemon-RETURNED root — not the requested path —
        // so raw/symlink drift, whitespace, or a relative root can't make the
        // session believe a different root (advisor #2). Whitespace-only or
        // relative roots leave approvedRootPath nil → ensureDefaultRooted throws.
        if (validated["ok"] as? Bool) == true,
           let rootStr = result["root"] as? String, isCleanAbsolutePath(rootStr)
        {
            approvedRootPath = URL(fileURLWithPath: rootStr)
        }
        return result
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
        guard approvedRootPath != nil else {
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

    /// The approved workspace root bound to this connection, if any. Layer 3
    /// routing confines tool args to this path (advisor #2).
    func rootPath() -> URL? { approvedRootPath }

    /// Whether an approved root is bound. Layer 3 routing consults this before
    /// routing a file tool.
    func hasRoot() -> Bool { approvedRootPath != nil }

    /// Whether a daemon is currently published and thus routing is possible.
    /// Layer 3b consults this BEFORE any confinement/provisioning so an absent
    /// daemon (tests / CI / before bundling) yields pre-3b local behavior with
    /// no `~/Documents/Fae` side effect.
    func isDaemonReachable() async -> Bool {
        await DaemonEndpointStore.shared.current() != nil
    }

    // MARK: - Serialized routed execution (B-Swift Layer 3b)

    /// Mutual-exclusion state for daemon-interacting routed operations. Actor
    /// isolation alone does NOT serialize across `await`s (reentrancy), and the
    /// server-request-aware `DaemonSocketConnection.roundTrip(... onServerRequest:)`
    /// issues its write + reads as SEPARATE dispatch-queue hops — so the
    /// connection's serial queue does not make two concurrent routed reads safe.
    /// Without this lock, concurrent reads would interleave frames on the one
    /// shared socket and steal each other's responses (lost/mismatched
    /// `request_id`). One operation at a time, FIFO.
    private var toolHostOperationLocked = false
    private var toolHostOperationWaiters: [ToolHostOperationWaiter] = []

    /// Acquire the operation lock. The first caller proceeds immediately; later
    /// callers suspend (in FIFO order) until `releaseToolHostOperationLock()`.
    ///
    /// Cancellation-aware: if the calling Task is cancelled while parked (or
    /// before it acquires), the waiter is resumed with `CancellationError` and
    /// the lock is NOT taken — the cancelled caller runs no zombie daemon work
    /// and holds no lock. `withCheckedContinuation` alone can't do this (it never
    /// resumes on cancellation); the per-waiter `ToolHostOperationWaiter` makes
    /// the cancel path win exclusively against the release path (one-shot).
    private func acquireToolHostOperationLock() async throws {
        // Fast cooperative-cancellation check up front.
        try Task.checkCancellation()
        if !toolHostOperationLocked {
            toolHostOperationLocked = true
            return
        }
        let waiter = ToolHostOperationWaiter()
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    // Runs synchronously on this actor; arm then enqueue.
                    waiter.arm(continuation)
                    self.toolHostOperationWaiters.append(waiter)
                }
            },
            onCancel: {
                // SYNC — must not touch actor-isolated state. Only the Sendable
                // waiter. If release already resumed it, this is a no-op.
                waiter.cancel()
            }
        )
    }

    /// Release the operation lock, handing it to the next LIVE waiter (if any) or
    /// marking it free. Sync (non-async) so it is safe to call from `defer`.
    /// Cancelled waiters return `false` from `resumeLock()` and are skipped;
    /// they never held the lock, so skipping is correct and cleans them up.
    private func releaseToolHostOperationLock() {
        while let next = toolHostOperationWaiters.first {
            toolHostOperationWaiters.removeFirst()
            if next.resumeLock() {
                // Handed the lock to this live waiter; stay locked.
                return
            }
            // Cancelled — drop and try the next.
        }
        toolHostOperationLocked = false
    }

    /// The serialized daemon-interacting core of a routed `read` (B-Swift 3b).
    ///
    /// Under the operation lock (one routed op at a time):
    ///   1. `ensureDefaultRooted()` — bind the daemon-approved root FIRST;
    ///   2. confine the already-shape-validated path against the daemon-RETURNED
    ///      root (root-binding-order — never a locally-computed root), rejecting
    ///      non-existent / non-regular / escaping targets;
    ///   3. `execute` the read on the persistent connection.
    ///
    /// Daemon-loss semantics:
    /// - lost BEFORE root approval ⇒ `.failClosed` (never read locally on an
    ///   un-approved root that bypasses the server root guard);
    /// - lost AFTER root approval, at `execute` ⇒ `.fallbackLocally(relative,
    ///   root)` (the path was already confined; re-confine it locally via the
    ///   fd-anchored reader, never cwd).
    func executeSerializedRoutedRead(
        validatedPath: String
    ) async -> DaemonToolRouting.ReadExecutionOutcome {
        // Acquire (parks if contended; throws CancellationError if the caller's
        // Task is cancelled while parked). The deferred release is registered
        // ONLY after a successful acquire so a cancelled-acquire never releases a
        // lock it never took.
        do {
            try await acquireToolHostOperationLock()
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failClosed("Could not acquire the read lock: \(error.localizedDescription)")
        }
        defer { releaseToolHostOperationLock() }
        // Re-check after acquire: if the holder released and resumed us a hair
        // before cancellation fired, we hold the lock but our Task is cancelled.
        // Bail (the defer releases) instead of running zombie daemon work.
        if Task.isCancelled { return .cancelled }

        do {
            // Root FIRST. Returns the daemon-approved (daemon-RETURNED) root and
            // binds `approvedRootPath`. Uses the session's stored provider.
            let daemonRoot = try await ensureDefaultRooted()
            switch DaemonToolRouting.confineValidatedReadPath(validatedPath, root: daemonRoot) {
            case .deny(let reason):
                return .denied(reason)
            case .route(let relative, _):
                do {
                    let result = try await execute(tool: "read", input: ["path": relative])
                    return .routed(result)
                } catch DaemonAgentClientError.daemonUnavailable {
                    // Root was approved (we are past ensureDefaultRooted); the
                    // daemon dropped at execute. Carry the relative path + the
                    // daemon-approved root so mapReadOutcome re-confines via the
                    // fd-anchored reader (with st_nlink check), NOT the legacy
                    // rootless ReadTool (red-team HIGH: hardlink exfil bypass).
                    return .fallbackLocally(relative: relative, root: daemonRoot)
                }
            }
        } catch DaemonAgentClientError.daemonUnavailable {
            // Daemon dropped before/during root approval. Fail closed.
            return .failClosed(
                "Daemon unavailable before the workspace root was approved; " +
                "refusing to read locally without a daemon-approved root.")
        } catch is CancellationError {
            // Task cancelled during the daemon round-trip (root approval or
            // execute). Surface a clean cancelled result (maps to friendly copy)
            // rather than the raw "Daemon read failed: CancellationError"
            // (red-team M5).
            return .cancelled
        } catch {
            // Daemon up but errored (root denial, path escape caught
            // server-side, etc.) — do NOT fall back; surface the error.
            return .failClosed("Daemon read failed: \(error.localizedDescription)")
        }
    }

    /// Confined LOCAL read fallback for the no-daemon-but-intended branch
    /// (B-Swift follow-up #2: daemon intended but momentarily unreachable).
    ///
    /// Provisions the default workspace LOCALLY (idempotent,
    /// #1-symlink-guarded via `FaeWorkspace.provision`), then performs an
    /// **fd-anchored** confined read (`DaemonToolRouting.readFdAnchored`): the
    /// root is opened with `O_NOFOLLOW` (the open IS the atomic check-and-use,
    /// closing the root-symlink TOCTOU a path-based confine would re-open), the
    /// validated path is walked from that fd with `openat`+`O_NOFOLLOW`, each
    /// component is `fstat`-checked, and the leaf is read from its open fd. No
    /// path string is ever re-resolved, so swapping the workspace dir for a
    /// symlink after provisioning cannot redirect the read.
    ///
    /// Does **NOT** mutate `approvedRootPath` — the daemon root guard never
    /// ran, so this is a local confinement against the provisioned default
    /// (the universal "reads are confined to `~/Documents/Fae`" invariant), NOT
    /// a daemon-approved root.
    ///
    /// `.preExistingWithoutMarker` fails closed: no daemon card is available to
    /// approve a user-made dir, so we never silently read through (or take over)
    /// a dir Fae did not create. A symlinked default root is hard-denied by the
    /// `O_NOFOLLOW` open (and, defense-in-depth, inside `FaeWorkspace.provision`).
    func confinedLocalReadFallback(
        validatedPath: String
    ) -> DaemonToolRouting.ReadExecutionOutcome {
        let provisioned: FaeWorkspace.ProvisionOutcome
        do {
            provisioned = try FaeWorkspace.provision(workspaceProvider)
        } catch {
            // Includes `symlinkedWorkspaceRoot` (fail-closed) + any lstat/IO
            // error during provisioning.
            return .failClosed(
                "Could not provision the local workspace for a confined read: "
                + "\(error.localizedDescription)")
        }
        switch provisioned {
        case .provisioned(let url), .alreadyOwned(let url):
            // Fae owns the dir → fd-anchored confined read. `O_NOFOLLOW` on the
            // root open + per-component `openat` defeats both a root-symlink
            // swap (TOCTOU) and intermediate/leaf symlink escapes, at the kernel
            // level — no path re-resolution. The daemon root guard is absent
            // here, so do NOT bind `approvedRootPath`; the fd anchor is the guard.
            switch DaemonToolRouting.readFdAnchored(validatedPath: validatedPath, root: url) {
            case .text(let text):
                return .localText(text)
            case .deny(let reason):
                return .denied(reason)
            }
        case .preExistingWithoutMarker:
            // A user-made dir with no Fae marker, and the daemon (the only
            // authority that can surface the confirm card) is down. Fail closed
            // rather than silently reading through or taking it over.
            return .failClosed(
                "Fae's default workspace exists but was not created by Fae, and "
                + "the daemon is unavailable to approve it; refusing to read locally.")
        }
    }

    // MARK: - Default workspace (Layer 3a, C′ root-source)

    /// Idempotently bind Fae's default workspace as the session root. Provisions
    /// the dir if absent, then `setRoot`s it. The `workspace.confirm_root` card
    /// is AUTO-APPROVED when Fae owns the dir (marker present); a pre-existing
    /// dir without a marker surfaces the REAL card once, and on approval the
    /// marker is written (sticky thereafter).
    ///
    /// Because B-Rust root is immutable per connection, this is called at most
    /// once per session; subsequent calls return the already-approved path.
    /// - Returns: the approved workspace root.
    @discardableResult
    func ensureDefaultRooted(
        provider override: FaeWorkspaceProvider? = nil
    ) async throws -> URL {
        // Use the explicit override when given (existing tests pass a temp-dir
        // provider per-call); otherwise the session's stored provider — the SAME
        // provider Layer 3b confinement uses — so routing + rooting agree.
        let provider = override ?? workspaceProvider
        if let existing = approvedRootPath { return existing }
        let outcome = try FaeWorkspace.provision(provider)
        let url: URL
        let handler: DaemonServerRequestHandler
        var writeMarkerAfterApproval = false
        switch outcome {
        case .provisioned(let u), .alreadyOwned(let u):
            // Fae owns it → auto-approve the root confirm (no card).
            url = u
            handler = defaultAwareHandler(
                serverRequestHandler,
                defaultPath: u,
                isMarkerPresent: { FaeWorkspace.markerPresent(at: u) })
        case .preExistingWithoutMarker(let u):
            // A user-made dir → surface the real card; mark sticky on approval.
            url = u
            handler = serverRequestHandler
            writeMarkerAfterApproval = true
        }
        // The daemon is authoritative: an unsafe root (e.g. a symlink that
        // canonicalizes to home) is rejected server-side regardless of approval.
        // setRoot binds approvedRootPath only on ok==true with a non-empty
        // daemon-RETURNED root. Require it and return THAT, not the requested
        // provider URL — avoids raw/symlink drift (advisor #2). Also handles
        // ok:true arriving with a missing/blank root.
        _ = try await setRoot(path: url.path, handler: handler)
        guard let approved = approvedRootPath else {
            throw DaemonAgentClientError.agentFailed("workspace root not approved by daemon")
        }
        if writeMarkerAfterApproval {
            try? FaeWorkspace.writeMarker(at: approved)
        }
        return approved
    }

    /// Execute a portable tool confined to the default workspace. Ensures the
    /// root is bound first (idempotent), then delegates to `execute`.
    ///
    /// NOTE: this is NOT the 3b live-routing call site. Production `read` routing
    /// goes through `executeSerializedRoutedRead`, which serializes root + confine
    /// + execute under one operation lock (this method, like `execute`, runs the
    /// server-request-aware roundTrip that is NOT safe under concurrent calls —
    /// actor isolation does not serialize across awaits). `executeInDefaultWorkspace`
    /// is retained for the 3a test surface and direct/sequential callers; do not
    /// add concurrent live callers here. Fails closed without a root.
    @discardableResult
    func executeInDefaultWorkspace(
        tool: String,
        input: [String: Any]
    ) async throws -> [String: Any] {
        _ = try await ensureDefaultRooted()
        return try await execute(tool: tool, input: input)
    }

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

// MARK: - Operation-lock waiter (cancellation-aware one-shot)

/// A parked `acquireToolHostOperationLock()` caller, made cancellation-aware.
///
/// `withCheckedContinuation` alone never resumes on cooperative cancellation, so
/// a cancelled waiter would stay parked until the holder released it — then run
/// the full daemon round-trip (zombie work) and starve the lock. This class is a
/// **one-shot** continuation holder: whichever of {release, cancel} fires first
/// wins exclusively and takes the continuation; the other no-ops. The `cancelled`
/// flag closes the ordering hazard where `cancel()` runs before `arm(_:)`.
///
/// All access is `NSLock`-guarded so the sync `onCancel` handler can safely touch
/// it without actor isolation (it must not reach actor state).
private final class ToolHostOperationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false

    /// Bind the continuation. If `cancel()` already fired, resume it immediately
    /// with `CancellationError` (closes the cancel-before-arm race).
    func arm(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Cancel handler: mark cancelled and, if armed, resume with
    /// `CancellationError`. Idempotent and safe against a concurrent `resumeLock`.
    func cancel() {
        lock.lock()
        cancelled = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: CancellationError())
    }

    /// Release path: resume the waiter successfully (hand it the lock). Returns
    /// `true` if THIS call resumed (the waiter was live and armed), `false` if it
    /// was already cancelled/resumed. Exactly-once.
    @discardableResult
    func resumeLock() -> Bool {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        guard let cont else { return false }
        cont.resume()
        return true
    }
}
