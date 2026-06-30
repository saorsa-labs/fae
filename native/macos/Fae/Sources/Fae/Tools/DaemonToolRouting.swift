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
//   4. No daemon reachable ⇒ mode-dependent (B-Swift follow-up #2, gated on
//      `session.daemonIntended` = `FaeConfig.llm.useDaemonEngine`):
//        - INTENDED-but-down (default-bundled runtime): the read is CONFINED
//          LOCALLY to the provisioned default workspace (`read` capability is
//          preserved, the universal "reads are confined to ~/Documents/Fae"
//          invariant holds during outages). Provisioning fires only here.
//        - OPTED OUT (`useDaemonEngine == false`, CI / pure-MLX): the read
//          falls through to the existing local `ReadTool` with the ORIGINAL
//          args — the legacy, UNCONFINED pre-routing path (no provisioning
//          side effect in non-injecting test suites).
//      Either branch is logged (never silent). The invariant that NEVER
//      changes: when the daemon is involved but drops before root approval,
//      the read FAILS CLOSED — it never reads locally on a locally-computed
//      root that bypasses the server root guard.

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

    /// `O_CLOEXEC` flag value, resolved once at load. Present on all supported
    /// macOS SDKs; this indirection keeps the fd-anchored read portable and
    /// avoids a bare magic number in the open flag sets.
    private static let openCloexec: Int32 = Darwin.O_CLOEXEC

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
        // B-Swift Phase C / follow-up #3 (LOCKED 2026-06-30): reject multiple
        // hard links as defense-in-depth early-reject (a hardlinked secret under
        // the workspace would exfiltrate). Path-based here (lstat); the
        // authoritative check is the fluers daemon read's post-open fstat (C1a),
        // with `readFdAnchored`'s fd-anchored fstat the stronger Swift check.
        guard st.st_nlink <= 1 else {
            return .deny("multiple hard links — can't safely confine: \(validated)")
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

    // MARK: - FD-anchored confined local read (red-team fix for follow-up #2)

    /// Hard byte cap for an fd-anchored local read. Matches the order of the
    /// daemon's 50 KiB truncation (parity tracked in follow-up #6; exact line /
    /// char parity is settled there).
    static let localReadByteCap = 50 * 1024

    /// Open flags common to every fd-anchored open. `O_NOFOLLOW` rejects a
    /// symlink leaf at the kernel level (ELOOP — no path re-resolution, the
    /// TOCTOU fix). `O_CLOEXEC` avoids the fd leaking across an exec.
    /// `O_NONBLOCK` is **mandatory** to defeat an open-time DoS: opening a FIFO
    /// (or some character devices) for reading WITHOUT `O_NONBLOCK` **blocks
    /// until a writer opens it** — a workspace FIFO would hang the read
    /// indefinitely before the `fstat` regular-file check ever runs. With
    /// `O_NONBLOCK` the open returns immediately and `fstat` then rejects the
    /// non-regular entry. Harmless on regular files and directories.
    private static let openFlags: Int32 =
        Darwin.O_RDONLY | Darwin.O_NOFOLLOW | openCloexec | Darwin.O_NONBLOCK

    /// The result of an fd-anchored confined local read.
    enum FdAnchoredRead: Equatable {
        /// The file was opened, confirmed regular, and read (truncated to
        /// `localReadByteCap` bytes, decoded as UTF-8).
        case text(String)
        /// The path could not be opened / confirmed regular / decoded. The
        /// reason is surfaced to the caller as a denial.
        case deny(String)
    }

    /// FD-ANCHORED confined local read (closes the root-symlink TOCTOU the
    /// red-team flagged on the path-based fallback).
    ///
    /// The open IS the atomic check-and-use: `root` is opened with `O_NOFOLLOW`,
    /// so even if a symlink swap races `FaeWorkspace.provision`'s `lstat`, the
    /// open fails with `ELOOP` (the leaf of `root.path` being a symlink is
    /// rejected by the kernel). Once `rootFd` is obtained it anchors everything
    /// that follows — the path on disk can be swapped freely; navigation uses
    /// `openat(rootFd, ...)` from the stable descriptor. Each component is
    /// likewise opened with `O_NOFOLLOW` + `fstat`, so an intermediate or leaf
    /// symlink (a workspace file symlinked to `/etc/passwd`) is rejected at the
    /// kernel level (no re-resolution of a path string → no TOCTOU).
    ///
    /// `validatedPath` MUST already be shape-validated (no leading `/`, no `..`,
    /// no NUL, non-empty). `.` components are filtered defensively. The leaf is
    /// `fstat`-required to be `S_IFREG` (rejects FIFOs/dirs/sockets/devices — a
    /// FIFO would otherwise block). Does NOT use `ReadTool(path:)` (that would
    /// re-resolve the path from cwd and re-open the TOCTOU window).
    static func readFdAnchored(
        validatedPath: String,
        root: URL
    ) -> FdAnchoredRead {
        // Split into components; the shape validator already rejected `..`, so
        // every component is a real name (filter `.` and empties defensively).
        let rawParts = validatedPath.split(separator: "/", omittingEmptySubsequences: true)
        let parts = rawParts.map(String.init).filter { $0 != "." && $0 != ".." }
        guard !parts.isEmpty else {
            return .deny("read path must name a file")
        }

        // Anchor: open the ROOT with O_NOFOLLOW. If `root.path`'s tip is (or has
        // become) a symlink, the kernel returns ELOOP — this is the TOCTOU fix.
        let rootFd = root.path.withCString { cstr -> Int32 in
            Darwin.open(cstr, openFlags, 0)
        }
        guard rootFd >= 0 else {
            return .deny("workspace root is not a readable directory")
        }
        defer { Darwin.close(rootFd) }

        // Confirm the anchored root is a directory (fstat off the open fd, NOT a
        // path — no re-resolution).
        var rootSt = stat()
        guard Darwin.fstat(rootFd, &rootSt) == 0 else {
            return .deny("workspace root is not readable")
        }
        guard (rootSt.st_mode & S_IFMT) == S_IFDIR else {
            return .deny("workspace root is not a directory")
        }

        // Walk every intermediate component as a directory (openat + O_NOFOLLOW
        // + fstat). Hold each fd only long enough to descend; close on swap.
        var parentFd = rootFd
        // Keep the fds we open for intermediate dirs so we can close them all at
        // the end (the root is closed by the outer `defer`).
        var openedIntermediates: [Int32] = []
        defer {
            for fd in openedIntermediates where fd >= 0 { Darwin.close(fd) }
        }
        let lastIdx = parts.count - 1
        for (idx, name) in parts.enumerated() {
            let isLeaf = idx == lastIdx
            let requireDir = !isLeaf
            guard let opened = openComponent(
                parent: parentFd, name: name, requireDir: requireDir)
            else {
                if isLeaf {
                    return .deny("file not found or not a regular file: \(validatedPath)")
                }
                return .deny("read path component is not a directory: \(name)")
            }
            if isLeaf {
                // B-Swift Phase C / follow-up #3 (LOCKED 2026-06-30): reject multiple
                // hard links — a hardlinked secret under the workspace (`ln
                // ~/.ssh/id_rsa ~/Documents/Fae/key`) is a regular file that passes
                // confinement and would exfiltrate the target. `fstat` off the
                // OPENED leaf fd (no path re-resolution). This is the Swift
                // authoritative check for the fd-anchored path; the fluers daemon
                // read's post-open fstat (C1a) is the server-side authority, and
                // `confineValidatedReadPath`'s lstat-site check is path-based
                // early-reject defense-in-depth.
                var leafSt = stat()
                if Darwin.fstat(opened, &leafSt) == 0, leafSt.st_nlink > 1 {
                    Darwin.close(opened)
                    return .deny(
                        "multiple hard links — can't safely confine: \(validatedPath)")
                }
                // Leaf: read from this open fd, then close it. Never re-resolve.
                defer { Darwin.close(opened) }
                return readLeaf(fd: opened, validatedPath: validatedPath)
            }
            // Intermediate dir: keep it open for the next iteration.
            openedIntermediates.append(opened)
            parentFd = opened
        }
        // Unreachable: parts is non-empty and the loop returns on the leaf.
        return .deny("read path could not be resolved")
    }

    /// Open one component relative to `parent` with `O_RDONLY | O_NOFOLLOW`, then
    /// `fstat` to confirm it is a directory (intermediate) or a regular file
    /// (leaf). `O_NOFOLLOW` makes a symlink leaf fail with `ELOOP` at the kernel
    /// level — no path re-resolution, no TOCTOU. Returns the fd or nil on any
    /// failure (closes the fd before returning nil so it never leaks).
    private static func openComponent(
        parent: Int32, name: String, requireDir: Bool
    ) -> Int32? {
        name.withCString { cstr -> Int32? in
            let fd = Darwin.openat(parent, cstr, openFlags, 0)
            guard fd >= 0 else { return nil }
            var st = stat()
            guard Darwin.fstat(fd, &st) == 0 else {
                Darwin.close(fd)
                return nil
            }
            let kind = st.st_mode & S_IFMT
            if requireDir {
                guard kind == S_IFDIR else {
                    Darwin.close(fd)
                    return nil
                }
            } else {
                guard kind == S_IFREG else {
                    Darwin.close(fd)
                    return nil
                }
            }
            return fd
        }
    }

    /// Read up to `localReadByteCap` bytes from an already-open regular-file fd,
    /// decode as UTF-8, and return `.text`. A non-UTF-8 file is denied (the
    /// workspace is a text surface; binary files are out of scope for the
    /// fallback read). Never re-resolves a path.
    ///
    /// Two robustness details (red-team §4 + multibyte-UTF-8):
    /// - `EINTR` on `read()` retries (bounded) instead of denying — a signal
    ///   during the read must not turn into a spurious failure.
    /// - The byte cap may split a multibyte UTF-8 sequence. Decode is attempted
    ///   first; on failure, trim trailing incomplete-sequence bytes and retry,
    ///   so a valid UTF-8 file truncated mid-character is returned (shorter)
    ///   rather than denied as "not UTF-8". Only genuinely non-UTF-8 content is
    ///   denied. (Truncation parity with the daemon is tracked in follow-up #6.)
    private static func readLeaf(fd: Int32, validatedPath: String) -> FdAnchoredRead {
        var collected = Data()
        collected.reserveCapacity(Swift.min(localReadByteCap, 8192))
        var buffer = [UInt8](repeating: 0, count: 8192)
        while collected.count < localReadByteCap {
            let n = buffer.withUnsafeMutableBufferPointer { ptr -> ssize_t in
                Darwin.read(fd, ptr.baseAddress, ptr.count)
            }
            if n < 0 {
                // Retry on EINTR (a signal interrupted the syscall); any other
                // errno is a real read failure → deny.
                if errno == EINTR { continue }
                return .deny("read failed: \(validatedPath)")
            }
            if n == 0 { break }
            collected.append(contentsOf: buffer.prefix(Int(n)))
        }
        // Prefer a whole-buffer decode (fast path for files under the cap).
        if let text = String(data: collected, encoding: .utf8) {
            return .text(trimmedToByteCap(text))
        }
        // The cap may have split a multibyte sequence. Trim trailing bytes until
        // the remainder decodes as UTF-8 (drop at most 3 continuation bytes), so
        // a valid UTF-8 file truncated mid-character is returned, not denied.
        var bytes = collected
        for _ in 0..<3 where !bytes.isEmpty {
            bytes.removeLast()
            if let text = String(data: bytes, encoding: .utf8) {
                return .text(trimmedToByteCap(text))
            }
        }
        return .deny("file is not UTF-8 text: \(validatedPath)")
    }

    /// Cap a decoded `String` to `localReadByteCap` UTF-8 bytes without splitting
    /// a multibyte character (`String.prefix(_:)` is Character-based, so it can
    /// land mid-sequence in bytes). Iteratively drop trailing characters until
    /// the UTF-8 byte length fits. No-op when already within the cap.
    private static func trimmedToByteCap(_ text: String) -> String {
        guard text.utf8.count > localReadByteCap else { return text }
        var trimmed = text
        while trimmed.utf8.count > localReadByteCap, !trimmed.isEmpty {
            trimmed.removeLast()
        }
        return trimmed
    }


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
        /// The confined LOCAL read already happened (fd-anchored, no daemon):
        /// the workspace was provisioned, the validated path was walked from an
        /// `O_NOFOLLOW`-opened root fd via `openat`, and the file was read from
        /// an open leaf fd (truncated to `~50 KiB`). Carries the text directly so
        /// the caller never re-resolves a path from cwd (closes the root-symlink
        /// TOCTOU the red-team flagged on the path-based fallback).
        case localText(String)
    }

    // MARK: - Route a read through the daemon session

    /// Route a `read` tool call to the daemon, confined to the default workspace.
    ///
    /// Three distinct no-daemon / daemon-loss policies (do not conflate them):
    /// - **No daemon published + opted OUT** (`isDaemonReachable() == false` AND
    ///   `session.daemonIntended == false`, e.g. CI / pure-MLX): returns `nil`
    ///   so the caller falls through to the existing local `ReadTool` pipeline
    ///   with the ORIGINAL arguments. This is **legacy pre-routing local read**
    ///   (`read` is `.low` risk and was always local) — it is NOT workspace-
    ///   confined, and it avoids provisioning `~/Documents/Fae` as a side effect
    ///   in non-injecting test suites. Logged (never silent).
    /// - **No daemon published + INTENDED** (`isDaemonReachable() == false` AND
    ///   `session.daemonIntended == true`, the default-bundled runtime): the
    ///   read is **confined LOCALLY** to the workspace via
    ///   `confinedLocalReadFallback`. The universal "reads are confined to
    ///   `~/Documents/Fae`" invariant holds whether or not the daemon is up, and
    ///   the `read` capability is preserved during daemon outages (no
    ///   regression). The provisioning side effect fires ONLY in this branch.
    ///   Logged (never silent). (B-Swift follow-up #2, 2026-06-30.)
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
        let reachable = await session.isDaemonReachable()

        // Opted-out + no daemon (useDaemonEngine == false, e.g. CI / pure-MLX):
        // preserve the legacy UNCONFINED local read. Return nil BEFORE shape
        // validation so a legacy absolute path (legitimate when the daemon is
        // not the runtime and there is no workspace root) is not rejected at
        // the routing seam — the local `ReadTool` reads the original args as-is.
        // No provisioning side effect. Logged (never silent).
        if !reachable, !session.daemonIntended {
            NSLog(
                "DaemonToolRouting: daemon unreachable and useDaemonEngine=false "
                + "(opted out) → legacy local read (unconfined, pre-routing behavior)")
            return nil
        }

        // Either the daemon is reachable, or it is intended-but-down (confined
        // local fallback). Both paths CONFINEMENT, so require + shape-validate
        // the path now. Shape validation needs no daemon contact: absolute / `..`
        // / NUL / empty are denied without rooting the session or sending a frame.
        guard let requested = call.arguments["path"] as? String else {
            return .error("Missing required parameter: path")
        }
        let validated: String
        switch validateReadPathShape(requested) {
        case .deny(let reason): return .error(reason)
        case .ok(let trimmed): validated = trimmed
        }

        if reachable {
            // Serialized daemon interaction: root FIRST (binds the daemon-
            // approved root), then confine against THAT root (root-binding-
            // order), then execute. One operation lock prevents concurrent
            // routed reads from interleaving frames on the shared connection.
            let outcome = await session.executeSerializedRoutedRead(validatedPath: validated)
            return await mapReadOutcome(outcome)
        }

        // Intended-but-down (the default-bundled runtime's live failure mode).
        // Confine LOCALLY so the "reads are confined to ~/Documents/Fae"
        // invariant survives the outage and the `read` capability is preserved.
        // Provisioning fires only here. `daemonIntended` is a `nonisolated let
        // Bool` ⇒ readable off-actor without `await`.
        NSLog(
            "DaemonToolRouting: daemon unreachable and useDaemonEngine=true "
            + "(intended) → confined local read (universal invariant preserved)")
        let fallback = await session.confinedLocalReadFallback(validatedPath: validated)
        return await mapReadOutcome(fallback)
    }

    /// Map a `ReadExecutionOutcome` (from either the serialized daemon path or
    /// the confined-local fallback) to a Swift `ToolResult`. Shared so the two
    /// paths surface identical result shapes.
    private static func mapReadOutcome(
        _ outcome: ReadExecutionOutcome
    ) async -> ToolResult {
        switch outcome {
        case .routed(let result):
            return buildReadResult(from: result)
        case .denied(let reason):
            return .error(reason)
        case .failClosed(let reason):
            return .error(reason)
        case .fallbackLocally(let canonical):
            return await readLocally(path: canonical.path)
        case .localText(let text):
            return .success(text)
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
