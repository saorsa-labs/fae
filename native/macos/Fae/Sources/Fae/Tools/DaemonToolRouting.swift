import Foundation

// MARK: - B-Swift Layer 3b: daemon routing classifier + path confinement
//
// The minimal `read`-only routing slice. `ToolExecutor.executeInner` consults
// this between tool lookup (step 6) and DamageControl (step 7): a `read` of a
// file inside Fae's default workspace is routed to the governed daemon ToolHost
// (audited, path/damage/egress-governed), while every other tool stays on its
// existing local path. A routed read returns BEFORE DamageControl — the daemon's
// governance (including its own `tool.confirm`) is authoritative, so there is no
// double approval in Swift.
//
// Safety invariants (must not break — see
// `docs/plans/vision-a-bswift-layer3-routing-scope-2026-06-29.md` §5.4):
//   1. Paths are ROOT-RELATIVE. Absolute paths (even under the workspace) and any
//      path escaping the root (`..`, symlink escape) are DENIED at the Swift
//      seam — they never reach the daemon.
//   2. The root is the DAEMON-APPROVED default workspace — NEVER inferred from a
//      requested file path, and NEVER a locally-computed root. A "read
//      /etc/passwd" must never become "approve /etc as root." The daemon roots
//      first; Swift confines against the daemon-RETURNED root (root-binding-order
//      — closes a TOCTOU where a root-symlink swap between a local confinement
//      and `set_root` would let Swift confine against a different path than the
//      daemon approved).
//   3. `tool.confirm` is never auto-approved by routing (routing does not touch
//      approval at all for `read`; `read` is safe-scope and needs no confirm).
//   4. No daemon reachable ⇒ the read is NOT routed. It falls through to the
//      existing local `ReadTool` (`read` is `.low` risk and was always local) —
//      the legacy, UNCONFINED pre-routing path (deliberate; see follow-ups).

/// The Layer 3b routing classifier + `read`-path confinement helper.
///
/// Pure where it matters: the confinement helpers and `routedTools` have no
/// daemon dependency and are unit-tested directly. `routeRead` is the single
/// call site `ToolExecutor` uses; it delegates the daemon-interacting core to
/// `DaemonToolHostSession.executeSerializedRoutedRead`, which serializes the
/// whole operation (root + confine + execute) under one lock so concurrent
/// routed reads cannot interleave frames on the shared connection (actor
/// isolation alone does not serialize across `await`s, and the server-request-
/// aware `roundTrip` releases the connection's dispatch queue between reads).
enum DaemonToolRouting {

    /// The ONLY tools Layer 3b routes to the daemon. `write`/`edit` stay
    /// dangerous-classed and are NOT enabled until Layer 4 provisions the
    /// server-side `ToolExecuteDangerous` scope; `bash` stays local (highest
    /// blast radius — the substring damage-denylist is not complete shell
    /// safety). Unknown/Apple/scheduler tools stay local unless deliberately
    /// classified here.
    static let routedTools: Set<String> = ["read"]

    /// Canonicalize a URL: standardize (resolve `.`/`..` lexically) then resolve
    /// symlinks. Used so both the confinement root and the resolved target are
    /// compared on their real on-disk paths (a symlink that escapes
    /// canonicalizes outside the root → denied).
    static func canonicalPath(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    // MARK: - Read confinement

    /// The result of confining a `read` path argument to the workspace root.
    enum ReadConfinement: Equatable {
        /// The path is inside the workspace.
        /// - `relativePath`: the root-relative path to send to the daemon
        ///   (`"."` if the target is the root itself).
        /// - `canonicalTarget`: the canonical on-disk target URL (used for the
        ///   daemon-down local fallback so the read never resolves from cwd).
        case route(relativePath: String, canonicalTarget: URL)
        /// The path escapes the workspace (absolute, `..`, symlink escape), is
        /// non-regular (FIFO/dir/socket/device), or is malformed / non-existent.
        /// The caller returns a `.error` and does NOT contact the daemon.
        case deny(String)
    }

    /// Phase 1 — shape validation (NO daemon contact, NO root needed).
    ///
    /// Trims; rejects empty, absolute (leading `/`), NUL-containing, and any path
    /// component exactly equal to `..`. Run BEFORE the daemon is contacted so a
    /// shape-denied read roots nothing and sends no frame.
    enum ShapeValidation: Equatable {
        case ok(String)
        case deny(String)
    }

    static func validateReadPathShape(_ requested: String) -> ShapeValidation {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .deny("read path is empty") }
        // Layer 3b routes ONLY root-relative paths. Absolute paths are denied
        // even when they happen to sit under the workspace — the model must name
        // workspace-relative paths (stricter 3b scope; relaxable later).
        guard !trimmed.hasPrefix("/") else {
            return .deny(
                "Absolute paths are not supported for workspace reads; use a path relative to the workspace root")
        }
        guard !trimmed.contains("\0") else { return .deny("read path contains a NUL byte") }
        // Reject dot-only and trailing-slash shapes (directory-ish) up front, so
        // they never root the session or contact the daemon.
        guard trimmed != "." else {
            return .deny("read path must name a file, not the workspace root")
        }
        guard !trimmed.hasSuffix("/") else {
            return .deny("read path must not end with a path separator")
        }
        // Reject any `..` component (defense-in-depth — the daemon canonicalizes
        // too). A literal directory named like `..hidden` is NOT `..` and passes.
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.contains("..") {
            return .deny("path traversal (..) is not permitted in a workspace read")
        }
        return .ok(trimmed)
    }

    /// Phase 2 — resolution + containment against the (daemon-approved) root.
    ///
    /// Resolves the validated path under `root`, requires the target to EXIST and
    /// be a REGULAR file (rejects FIFOs, directories, sockets, devices — a FIFO
    /// in the workspace would otherwise block the daemon socket up to its recv
    /// timeout), canonicalizes, and asserts the canonical target IS the root or
    /// lives under it. Symlink escapes are denied by the canonicalize step.
    static func confineValidatedReadPath(_ validated: String, root: URL) -> ReadConfinement {
        let rootCanon = canonicalPath(root)
        // Resolve under the root; `standardizedFileURL` collapses `./` lexically.
        let resolved = rootCanon.appendingPathComponent(validated).standardizedFileURL

        // Canonicalize (resolves symlinks on disk). On a non-existent path this
        // returns the path as-is; the lstat below then catches non-existence.
        let targetCanon = resolved.resolvingSymlinksInPath()

        // Containment FIRST: the canonical target must BE the root or live under
        // it. This is what defeats symlink escapes (canonicalization reveals
        // them) — and it means we never lstat/stat a path outside the workspace.
        if targetCanon != rootCanon,
           !targetCanon.path.hasPrefix(rootCanon.path + "/")
        {
            return .deny("read path escapes the workspace root")
        }

        // Existence + regular-file check via lstat on the in-workspace canonical
        // target (its tip has no symlink once canonicalized, so lstat reflects the
        // real entry). Rejects FIFOs/dirs/sockets/devices — a workspace FIFO would
        // otherwise block the daemon recv up to its timeout (a routed DoS).
        var st = stat()
        let statOK = targetCanon.path.withCString { Darwin.lstat($0, &st) } == 0
        guard statOK else {
            return .deny("file not found: \(validated)")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            return .deny("read supports regular files only (non-regular entry: \(validated))")
        }

        let relative: String
        if targetCanon == rootCanon {
            relative = "."
        } else {
            let prefix = rootCanon.path + "/"
            relative = String(targetCanon.path.dropFirst(prefix.count))
        }
        return .route(relativePath: relative, canonicalTarget: targetCanon)
    }

    /// Full confinement (phase 1 + phase 2) for direct/unit testing.
    static func confineReadPath(_ requested: String, root: URL) -> ReadConfinement {
        switch validateReadPathShape(requested) {
        case .deny(let reason): return .deny(reason)
        case .ok(let trimmed): return confineValidatedReadPath(trimmed, root: root)
        }
    }

    // MARK: - Serialized daemon execution outcome

    /// The outcome of the serialized daemon-interacting core of a routed read
    /// (produced by `DaemonToolHostSession.executeSerializedRoutedRead`).
    enum ReadExecutionOutcome {
        /// The daemon executed the read; carry its result dict.
        case routed([String: Any])
        /// Containment/regular-file denial (decided before the `execute` frame).
        case denied(String)
        /// The daemon dropped AFTER the root was approved; read this confined
        /// canonical path locally (never cwd).
        case fallbackLocally(URL)
        /// Daemon dropped/errored BEFORE the root was approved, or the daemon
        /// execute itself errored. Fail closed — surface an error, no local read.
        case failClosed(String)
        /// The caller's Task was cancelled (e.g. while parked on the operation
        /// lock). No daemon round-trip ran; surface a clean cancelled result. The
        /// cancellation must NOT fall through to a local `ReadTool` (that would
        /// be extra work the caller already abandoned).
        case cancelled
    }

    // MARK: - Route a read through the daemon session

    /// Route a `read` tool call to the daemon, confined to the default workspace.
    ///
    /// Two distinct no-daemon policies (do not conflate them):
    /// - **No daemon published** (`isDaemonReachable() == false`): returns `nil`
    ///   so the caller falls through to the existing local `ReadTool` pipeline
    ///   with the ORIGINAL arguments. This is **legacy pre-routing local read**
    ///   (`read` is `.low` risk and was always local) — it is NOT workspace-
    ///   confined, and it avoids provisioning `~/Documents/Fae` as a side effect
    ///   in non-injecting test suites. **DECISION (follow-up #2, 2026-06-30):**
    ///   once a routing gate lands, this branch becomes mode-dependent —
    ///   confined-local when the daemon is intended-but-down, legacy when opted
    ///   out. Not yet implemented; see `docs/plans/bswift-3b-followups-2026-06-30.md`.
    /// - **Daemon involved but the root was never approved** (daemon dropped
    ///   during `ensureDefaultRooted`): fail CLOSED — `.failClosed`. Never read
    ///   locally on a locally-computed root that bypasses the server root guard.
    ///
    /// When the root WAS approved and the daemon then drops at `execute`, fall
    /// back to a LOCAL read of the already-confined canonical path (never cwd).
    static func routeRead(
        call: ToolCall,
        session: DaemonToolHostSession
    ) async -> ToolResult? {
        // No daemon published ⇒ NOT routed. Return nil so the caller falls through
        // to the local pipeline (legacy pre-routing local read — see above).
        guard await session.isDaemonReachable() else { return nil }

        guard let requested = call.arguments["path"] as? String else {
            return .error("Missing required parameter: path")
        }

        // Shape validation FIRST — no daemon contact. Absolute / `..` / NUL /
        // empty are denied without rooting the session or sending any frame.
        let validated: String
        switch validateReadPathShape(requested) {
        case .deny(let reason): return .error(reason)
        case .ok(let trimmed): validated = trimmed
        }

        // Serialized daemon interaction: root FIRST (binds the daemon-approved
        // root), then confine against THAT root (root-binding-order), then
        // execute. One operation lock prevents concurrent routed reads from
        // interleaving frames on the shared connection.
        let outcome = await session.executeSerializedRoutedRead(validatedPath: validated)
        switch outcome {
        case .routed(let result):
            return buildReadResult(from: result)
        case .denied(let reason):
            return .error(reason)
        case .failClosed(let reason):
            return .error(reason)
        case .fallbackLocally(let canonical):
            return await readLocally(path: canonical.path)
        case .cancelled:
            return .error("Read was cancelled.")
        }
    }

    // MARK: - Helpers

    /// Build the Swift `ToolResult` from the daemon's `read` reply.
    ///
    /// The daemon's `read` returns content blocks in `result["content"]`
    /// (Layer 2/3a used `["hello"]`). String blocks — and `{text: …}` dict
    /// blocks — are joined with a newline into the prose `output`.
    private static func buildReadResult(from result: [String: Any]) -> ToolResult {
        guard let content = result["content"] as? [Any] else {
            return .error("Daemon read returned no content")
        }
        let text = content.compactMap { block -> String? in
            if let s = block as? String { return s }
            if let d = block as? [String: Any], let t = d["text"] as? String { return t }
            return nil
        }.joined(separator: "\n")
        return .success(text)
    }

    /// Read a file locally, reusing `ReadTool`'s read + 50k-char truncation.
    /// Used for the daemon-down fallback (the confined canonical path is passed,
    /// so the read never resolves a root-relative path from process cwd).
    private static func readLocally(path: String) async -> ToolResult {
        do {
            return try await ReadTool().execute(input: ["path": path])
        } catch {
            return .error("Local read failed: \(error.localizedDescription)")
        }
    }
}
