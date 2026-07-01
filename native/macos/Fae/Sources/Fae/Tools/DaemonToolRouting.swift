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
    static let routedTools: Set<String> = ["read", "write", "edit", "bash"]

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
    /// Line cap for local reads (B-Swift #6 parity with the fluers daemon's
    /// `apply_read_limits`: 2000 lines OR 50 KiB, whichever binds first).
    static let localReadLineCap = 2_000

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

    /// Rootless fd-anchored read for the legacy `ReadTool` (B-Swift #4).
    ///
    /// Unlike `readFdAnchored`, this takes an ABSOLUTE path with NO workspace
    /// root: the legacy `read` tool is intentionally unconfined (it predates
    /// daemon routing and stays as the opted-out / no-daemon fallback). This
    /// does NOT add confinement — it only closes the LEAF TOCTOU: `open` with
    /// `O_NOFOLLOW` follows intermediate symlinks (so macOS `/tmp → /private/tmp`
    /// and home-dir symlinks still resolve) but rejects a LEAF symlink with
    /// `ELOOP`, and the read happens off the OPENED fd (no check-then-reopen
    /// race, no path re-resolution). `fstat` rejects non-regular entries
    /// (FIFOs/dirs/sockets/devices) — a FIFO would otherwise block; `O_NONBLOCK`
    /// in `openFlags` made the open return immediately for that case.
    ///
    /// Deliberately NO `st_nlink > 1` (hardlink) check here. Owner LOCKED #3
    /// hardlink rejection to the routed/confined path + fluers daemon only —
    /// hardlink rejection is a CONFINEMENT measure, and this read is unconfined
    /// by design. Rejecting hardlinks here would be inconsistent and would break
    /// legitimate hardlinked files (git objects, system files, etc.).
    ///
    /// Anchoring from `/` via `readFdAnchored` is intentionally NOT used: it
    /// would reject every intermediate symlink (breaking `/tmp`, `/var`, `/etc`
    /// on macOS) and mishandle `..` components. `open(path, O_NOFOLLOW)` is the
    /// correct primitive for a rootless read: atomic for the leaf, normal path
    /// resolution for the intermediates.
    static func readRootlessFdAnchored(absolutePath: String) -> FdAnchoredRead {
        let fd = absolutePath.withCString { cstr -> Int32 in
            Darwin.open(cstr, openFlags, 0)
        }
        guard fd >= 0 else {
            // Capture errno before anything else can clobber it.
            let err = errno
            switch err {
            case ELOOP:
                return .deny("file is a symbolic link (not followed): \(absolutePath)")
            case ENOENT, ENOTDIR:
                return .deny("File not found: \(absolutePath)")
            default:
                return .deny("Could not open file: \(absolutePath)")
            }
        }
        defer { Darwin.close(fd) }

        // Confirm the opened fd is a regular file (fstat off the fd, NOT a path
        // — no re-resolution). Rejects FIFOs/dirs/sockets/devices. NO st_nlink
        // check (see doc comment — confinement belongs to the routed path).
        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else {
            return .deny("Could not read file metadata: \(absolutePath)")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            return .deny("Not a regular file: \(absolutePath)")
        }

        // Read off the open fd. Reuses the hardened leaf reader (EINTR retry,
        // multibyte-UTF-8-safe truncation to `localReadByteCap`).
        return readLeaf(fd: fd, validatedPath: absolutePath)
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
        // fstat the open fd to detect whether we will truncate by BYTES (the
        // read loop stops at `localReadByteCap`). Using the fd (not a path)
        // avoids re-resolution; st_size on the open leaf is authoritative for
        // the byte-truncation marker (B-Swift #6 daemon-parity).
        var leafSt = stat()
        let byteTruncated = (Darwin.fstat(fd, &leafSt) == 0)
            && UInt64(leafSt.st_size) > UInt64(localReadByteCap)

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
            return .text(applyPresentationLimits(
                trimmedToByteCap(text), byteTruncated: byteTruncated))
        }
        // The cap may have split a multibyte sequence. Trim trailing bytes until
        // the remainder decodes as UTF-8 (drop at most 3 continuation bytes), so
        // a valid UTF-8 file truncated mid-character is returned, not denied.
        var bytes = collected
        for _ in 0..<3 where !bytes.isEmpty {
            bytes.removeLast()
            if let text = String(data: bytes, encoding: .utf8) {
                return .text(applyPresentationLimits(
                    trimmedToByteCap(text), byteTruncated: byteTruncated))
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

    /// Apply daemon-parity presentation limits to a byte-capped read (B-Swift
    /// #6). Mirrors fluers `apply_read_limits` EXACTLY (same semantics so a
    /// routed read and a local read surface the SAME truncation):
    /// `split_inclusive('\n')` (each line keeps its trailing newline; a
    /// trailing newline-less line is still one element), 0-indexed line counter,
    /// `i >= max_lines` truncates (so exactly `max_lines` lines → NO marker,
    /// `max_lines+1` → marker), and bytes-bind checked per-line.
    ///
    /// `byteTruncated` is decided by `fstat.st_size` (the source file is larger
    /// than the byte cap). The line check runs first ("whichever binds first").
    /// Swift's `String.enumeratedSubstrings` is awkward for `split_inclusive`;
    /// we walk newline offsets manually to keep the trailing-newline semantics.
    private static func applyPresentationLimits(
        _ text: String, byteTruncated: Bool
    ) -> String {
        // Split keeping trailing newlines: "a\nb\n" → ["a\n", "b\n"],
        // "a\nb" (no trailing nl) → ["a\n", "b"]. Matches Rust split_inclusive.
        var lines: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            if let nl = text[start...].firstIndex(of: "\n") {
                let after = text.index(after: nl) // include the newline
                lines.append(String(text[start..<after]))
                start = after
            } else {
                lines.append(String(text[start..<text.endIndex]))
                break
            }
        }
        // Edge case: empty text → no lines (daemon: split_inclusive on "" → []).
        if lines.isEmpty { return text }

        var bytesLeft = localReadByteCap
        var out = ""
        for (i, line) in lines.enumerated() {
            if i >= localReadLineCap {
                out += "\n[... truncated at \(localReadLineCap) lines ...]"
                return out
            }
            let lineBytes = line.utf8.count
            if lineBytes > bytesLeft {
                // Byte cap binds mid/after this line. Take whole bytes that fit
                // on a UTF-8 boundary (don't split a multibyte char).
                var taken = ""
                var bytesUsed = 0
                for ch in line {
                    let chBytes = ch.utf8.count
                    if bytesUsed + chBytes > bytesLeft { break }
                    taken.append(ch)
                    bytesUsed += chBytes
                }
                out += taken
                out += "\n[... truncated at \(localReadByteCap) bytes ...]"
                return out
            }
            out += line
            bytesLeft -= lineBytes
        }
        // No truncation bound by lines or bytes within the (already byte-capped)
        // window. But if the SOURCE file exceeded the byte cap, the read loop
        // stopped early — surface the byte marker (fstat-detected, authoritative).
        if byteTruncated {
            return text + "\n[... truncated at \(localReadByteCap) bytes ...]"
        }
        return text
    }


    /// The outcome of the serialized daemon-interacting core of a routed read
    /// (produced by `DaemonToolHostSession.executeSerializedRoutedRead`).
    enum ReadExecutionOutcome {
        /// The daemon executed the read; carry its result dict.
        case routed([String: Any])
        /// Containment/regular-file denial (decided before the `execute` frame,
        /// or re-decided by the fd-anchored re-confine after a daemon drop).
        case denied(String)
        /// The daemon dropped AFTER the root was approved (at `execute`). Carries
        /// the relative path + daemon-approved root so `mapReadOutcome` can
        /// re-confine via the fd-anchored reader (with the st_nlink check) — NOT
        /// the legacy rootless ReadTool (red-team HIGH: hardlink exfil bypass).
        case fallbackLocally(relative: String, root: URL)
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

    /// The outcome of the serialized daemon-interacting core of a routed write
    /// (F7a). Mirrors `ReadExecutionOutcome` but has NO local-fallback case —
    /// mutations are irreversible, so any daemon drop/error fails closed. The
    /// confined local write path is intentionally absent (a Swift-side
    /// fd-anchored write would duplicate the fluers hard-gate work and widen
    /// risk; the legacy path-based `WriteTool` is reachable only via the
    /// explicit opt-out `.legacyLocal` plan, never as a fallback).
    enum WriteExecutionOutcome {
        /// The daemon executed the write (after its `tool.confirm` card, if it
        /// needed one). Carries: `result` — the daemon's reply dict (whose
        /// `content` blocks are surfaced to the user, e.g. "Wrote N bytes to
        /// `path`"); `preStateContent` — the fd-anchored old content for undo
        /// (nil for a new file or a target the daemon rejects); `absoluteTargetPath`
        /// — the daemon-approved root + relative path, the canonical undo target.
        case routed(result: [String: Any], preStateContent: Data?, absoluteTargetPath: String?)
        /// Containment/path denial (decided before the `execute` frame).
        case denied(String)
        /// Daemon dropped/errored before OR during `execute` (including before
        /// the root was approved), or the routed write timed out. Fail closed —
        /// never write locally.
        case failClosed(String)
        /// The caller's Task was cancelled (e.g. while parked on the operation
        /// lock). No daemon round-trip ran.
        case cancelled
    }

    // MARK: - Read route planning (B-Swift Phase C / follow-up #5)

    /// The decided route for a `read` tool call, computed BEFORE any side effect
    /// (no path validation, no daemon frame, no provisioning). Splitting the
    /// DECISION from the EXECUTION lets `ToolExecutor` run plugin hooks + audit
    /// + timeout around the routed path deterministically — the route is fixed
    /// before any daemon/root/provision side effect, so there is no policy race
    /// from daemon availability shifting between computing the route and acting
    /// on it.
    enum ReadRoutePlan {
        /// Opted-out + no daemon → the legacy UNCONFINED local `ReadTool`, via
        /// the FULL local pipeline (DamageControl, hooks, audit, receipts).
        /// `ToolExecutor` falls through; `routeRead(_:plan:)` is NOT called.
        case legacyLocal
        /// Daemon reachable → route to the governed daemon ToolHost (serialized:
        /// root → confine → execute, one operation lock).
        case daemonReachable
        /// Daemon intended but unreachable → confined fd-anchored LOCAL read
        /// (the universal "reads are confined to ~/Documents/Fae" invariant
        /// survives the outage; provisioning fires here).
        case confinedLocalFallback
    }

    /// Decide the read route from daemon reachability + intent (the DECISION).
    /// No path validation, no side effect, no daemon frame. `ToolExecutor` runs
    /// this after tool lookup and BEFORE DamageControl so it can run hooks +
    /// timeout around the routed execution. See `routeRead(_:plan:)` for
    /// execution. Logged (never silent) on each branch.
    static func planReadRoute(
        session: DaemonToolHostSession
    ) async -> ReadRoutePlan {
        let reachable = await session.isDaemonReachable()
        if !reachable, !session.daemonIntended {
            NSLog(
                "DaemonToolRouting: daemon unreachable and useDaemonEngine=false "
                + "(opted out) → legacy local read (unconfined, pre-routing behavior)")
            return .legacyLocal
        }
        if reachable {
            return .daemonReachable
        }
        NSLog(
            "DaemonToolRouting: daemon unreachable and useDaemonEngine=true "
            + "(intended) → confined local read (universal invariant preserved)")
        return .confinedLocalFallback
    }

    /// EXECUTE a routed `read` for a pre-computed `plan`. Never returns nil —
    /// the plan already decided the route, so the optionality is removed.
    ///
    /// Handles the two routed cases (`.daemonReachable`,
    /// `.confinedLocalFallback`). `.legacyLocal` is `ToolExecutor`'s
    /// fall-through (it runs the full local pipeline) and is NOT routed here;
    /// reaching this method with `.legacyLocal` is defended as a misconfig
    /// error (the caller must check `plan == .legacyLocal` and fall through).
    ///
    /// Race rule (advisor C3): if the plan was routed/confined, NEVER fall
    /// through to the local `ReadTool` after the caller has skipped
    /// DamageControl. A daemon that drops mid-route uses the existing routed
    /// semantics — fail CLOSED before root approval; fall back to a confined
    /// local read only AFTER the daemon-approved root is bound (never cwd).
    static func routeRead(
        call: ToolCall,
        session: DaemonToolHostSession,
        plan: ReadRoutePlan
    ) async -> ToolResult {
        guard plan != .legacyLocal else {
            return .error("read routing misconfigured: legacy route reached the routed executor")
        }

        // Both routed paths CONFINEMENT ⇒ require + shape-validate the path.
        // Shape validation needs no daemon contact: absolute / `..` / NUL /
        // empty are denied without rooting the session or sending a frame.
        guard let requested = call.arguments["path"] as? String else {
            return .error("Missing required parameter: path")
        }
        let validated: String
        switch validateReadPathShape(requested) {
        case .deny(let reason): return .error(reason)
        case .ok(let trimmed): validated = trimmed
        }

        switch plan {
        case .daemonReachable:
            // Serialized daemon interaction: root FIRST (binds the daemon-
            // approved root), then confine against THAT root (root-binding-
            // order), then execute. One operation lock prevents concurrent
            // routed reads from interleaving frames on the shared connection.
            let outcome = await session.executeSerializedRoutedRead(validatedPath: validated)
            return await mapReadOutcome(outcome)
        case .confinedLocalFallback:
            // Intended-but-down (the default-bundled runtime's live failure
            // mode). Confine LOCALLY so the "reads are confined to
            // ~/Documents/Fae" invariant survives the outage; provisioning
            // fires only here.
            let fallback = await session.confinedLocalReadFallback(validatedPath: validated)
            return await mapReadOutcome(fallback)
        case .legacyLocal:
            return .error("read routing misconfigured: legacy route reached the routed executor")
        }
    }

    // Legacy 2-arg `routeRead(call:session:) -> ToolResult?` wrapper REMOVED
    // (Phase C/#5, red-team F5): it ran NONE of the Pre/Post hooks, audit, or
    // timeout — so a future caller could resurrect the pre-#5 policy bypass.
    // Zero callers at removal time. Use `planReadRoute` + `routeRead(_:plan:)`.

    /// Map a `ReadExecutionOutcome` (from either the serialized daemon path or
    /// the confined-local fallback) to a Swift `ToolResult`. Shared so the two
    /// paths surface identical result shapes.
    static func mapReadOutcome(
        _ outcome: ReadExecutionOutcome
    ) async -> ToolResult {
        switch outcome {
        case .routed(let result):
            return buildReadResult(from: result)
        case .denied(let reason):
            return .error(reason)
        case .failClosed(let reason):
            return .error(reason)
        case .fallbackLocally(let relative, let root):
            // Re-confine via the fd-anchored confined reader, NOT the legacy
            // rootless ReadTool. A file hardlinked in the confine→execute window
            // would otherwise bypass the st_nlink policy (the rootless reader
            // has no nlink check — red-team HIGH). The fd-anchored fstat off the
            // OPENED leaf fd is stronger than the pre-drop lstat anyway (no path
            // re-resolution → no TOCTOU between the pre-drop lstat and the read).
            switch readFdAnchored(validatedPath: relative, root: root) {
            case .text(let text):
                return .success(text)
            case .deny(let reason):
                return .error(reason)
            }
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
    static func buildReadResult(from result: [String: Any]) -> ToolResult {
        guard let content = result["content"] as? [Any] else {
            return .error("Daemon read returned no content")
        }
        // Defense against a compromised/misbehaving daemon (red-team M3 +
        // advisor): cap total decoded bytes INCLUDING join separators, and skip
        // empty/nil blocks so a daemon can't balloon memory with a huge array
        // of empty strings. The daemon applies apply_read_limits (~50 KiB)
        // itself, so a well-behaved reply is small; 200 KiB is well above the
        // legitimate max.
        let hardCap = 4 * localReadByteCap  // 200 KiB
        var blocks: [String] = []
        var bytes = 0
        for block in content {
            let next: String?
            if let s = block as? String { next = s }
            else if let d = block as? [String: Any], let t = d["text"] as? String { next = t }
            else { next = nil }
            guard let text = next, !text.isEmpty else { continue }
            let sep = blocks.isEmpty ? 0 : 1  // "\n" between blocks, counted
            if bytes + sep + text.utf8.count > hardCap {
                let remaining = max(0, hardCap - bytes - sep)
                if remaining > 0 {
                    blocks.append(String(decoding: text.utf8.prefix(remaining), as: UTF8.self))
                }
                blocks.append("\n[... daemon response exceeded \(hardCap / 1024) KiB; truncated ...]")
                return .success(blocks.joined(separator: "\n"))
            }
            blocks.append(text)
            bytes += sep + text.utf8.count
        }
        return .success(blocks.joined(separator: "\n"))
    }

    // MARK: - B-Swift Phase F7a: route `write` through the daemon

    /// The decided route for a `write` tool call, computed BEFORE any side
    /// effect (mirrors `ReadRoutePlan`). Mutations are irreversible, so the
    /// outage branches are STRICTER than read:
    /// - `.legacyLocal` — explicit daemon opt-out (`!reachable && !intended`):
    ///   the legacy path-based `WriteTool` via the full local pipeline
    ///   (DamageControl, hooks, audit, receipts). Pre-routing behavior.
    /// - `.daemonReachable` — route to the governed daemon ToolHost.
    /// - `.daemonUnavailableFailClosed` — daemon INTENDED but unreachable: FAIL
    ///   CLOSED. No confined local write fallback (a Swift-side fd-anchored
    ///   write would duplicate the fluers hard-gate work and widen risk).
    enum WriteRoutePlan {
        case legacyLocal
        case daemonReachable
        case daemonUnavailableFailClosed
    }

    /// Decide the write route from daemon reachability + intent (the DECISION).
    /// No path validation, no side effect. `ToolExecutor` runs this after tool
    /// lookup and BEFORE DamageControl so it can run hooks + timeout around the
    /// routed execution. See `routeWrite(_:plan:)` for execution.
    static func planWriteRoute(
        session: DaemonToolHostSession
    ) async -> WriteRoutePlan {
        let reachable = await session.isDaemonReachable()
        if !reachable, !session.daemonIntended {
            NSLog(
                "DaemonToolRouting: write — daemon unreachable and useDaemonEngine=false "
                + "(opted out) → legacy local write (pre-routing behavior)")
            return .legacyLocal
        }
        if reachable {
            return .daemonReachable
        }
        NSLog(
            "DaemonToolRouting: write — daemon unreachable and useDaemonEngine=true "
            + "(intended) → FAIL CLOSED (mutations are irreversible; no local fallback)")
        return .daemonUnavailableFailClosed
    }

    /// EXECUTE a routed `write` for a pre-computed `plan`. Returns the
    /// `WriteExecutionOutcome` (NOT a pre-mapped `ToolResult`) so `ToolExecutor`
    /// can run hooks + timeout + audit around it AND build the receipt from the
    /// outcome's fd-anchored pre-state material (the receipt/undo capture
    /// happens INSIDE `executeSerializedRoutedWrite`, under the operation lock,
    /// after root approval — never path-based/outside the lock).
    ///
    /// `.legacyLocal` is `ToolExecutor`'s fall-through (full local pipeline) and
    /// is NOT routed here; reaching this method with `.legacyLocal` is a
    /// misconfig error (surfaced as `.failClosed`).
    static func routeWrite(
        call: ToolCall,
        session: DaemonToolHostSession,
        plan: WriteRoutePlan
    ) async -> WriteExecutionOutcome {
        guard plan != .legacyLocal else {
            return .failClosed("write routing misconfigured: legacy route reached the routed executor")
        }

        // Shape-validate path + content BEFORE any daemon contact.
        guard let requestedPath = call.arguments["path"] as? String else {
            return .denied("Missing required parameter: path")
        }
        guard let content = call.arguments["content"] as? String else {
            return .denied("Missing required parameter: content")
        }
        switch validateWritePathShape(requestedPath) {
        case .deny(let reason):
            return .denied(reason)
        case .ok(let trimmed):
            switch plan {
            case .daemonReachable:
                return await session.executeSerializedRoutedWrite(
                    validatedPath: trimmed, content: content)
            case .daemonUnavailableFailClosed:
                // Mutations are irreversible; never fall back to a local write.
                return .failClosed(
                    "Daemon unavailable and routing is intended; refusing to write locally")
            case .legacyLocal:
                return .failClosed("write routing misconfigured: legacy route reached the routed executor")
            }
        }
    }

    /// Map a `WriteExecutionOutcome` to a Swift `ToolResult`. Returns RAW
    /// technical error strings for the failure cases; `ToolExecutor.executeRoutedWrite`
    /// reframes them via `friendlyRoutedWriteError` for the conversation AFTER
    /// audit (mirrors the read split). The `.routed` pre-state material is for
    /// the receipt (read by `executeRoutedWrite`); the daemon's `content` blocks
    /// (e.g. "Wrote N bytes to `path`") are surfaced via `buildWriteResult`.
    static func mapWriteOutcome(
        _ outcome: WriteExecutionOutcome
    ) -> ToolResult {
        switch outcome {
        case .routed(let result, _, _):
            return buildWriteResult(from: result)
        case .denied(let reason):
            return .error(reason)
        case .failClosed(let reason):
            return .error(reason)
        case .cancelled:
            return .error("Write was cancelled.")
        }
    }

    /// Build the Swift `ToolResult` from the daemon's `write` reply. The fluers
    /// `WriteTool` returns a content block on success — `{type:"text", text:
    /// "Wrote N bytes to `path`"}` — (NOT contentless: `SessionEnv::write_file`
    /// returns `()`, but the tool wrapper builds this message from it; see
    /// fluers-runtime `tool.rs` `WriteTool::execute`). We surface that content
    /// rather than a generic string. The extraction mirrors `buildReadResult`'s
    /// M3 hardening: join string/`{text}` blocks, skip empty, cap total bytes
    /// (a compromised/misbehaving daemon could otherwise balloon memory with a
    /// huge array of blocks — the legitimate write message is tiny).
    static func buildWriteResult(from result: [String: Any]) -> ToolResult {
        // See `buildMutationToolResult` — write + edit share the same content
        // extraction (both fluers tools return a content block on success).
        buildMutationToolResult(from: result, genericSuccess: "Wrote file via the governed daemon.")
    }

    /// Build the Swift `ToolResult` from the daemon's `edit` reply. The fluers
    /// `EditTool::execute` returns a content block on success —
    /// `{type:"text", text:"Edited `path` (old -> new bytes)"}` — (see
    /// fluers-runtime `tool.rs` `EditTool::execute`). Surfaced the same way as a
    /// write reply; a missing content array is still a success.
    static func buildEditResult(from result: [String: Any]) -> ToolResult {
        buildMutationToolResult(from: result, genericSuccess: "Edited file via the governed daemon.")
    }

    /// Shared content extraction for routed MUTATING tools (write/edit). The
    /// fluers `WriteTool`/`EditTool` return a content block on success ("Wrote N
    /// bytes to `path`" / "Edited `path` (X -> Y bytes)"); surface it via the
    /// read-side M3-hardened extractor (cap total bytes, skip empty blocks — a
    /// compromised daemon could otherwise balloon a content array). If content
    /// is absent (defensive — a misbehaving daemon), the `.routed` outcome STILL
    /// means success, so return a generic success rather than an error (unlike
    /// read, where missing content IS an error).
    private static func buildMutationToolResult(
        from result: [String: Any],
        genericSuccess: String
    ) -> ToolResult {
        if let content = result["content"] as? [Any], !content.isEmpty {
            return buildReadResult(from: result)
        }
        return .success(genericSuccess)
    }

    // MARK: - Write helpers

    /// Shape-validate a write path (mirrors `validateReadPathShape`, minus the
    /// directory-ish rejects that don't apply to a write target). Absolute
    /// paths, NUL, empty, and any `..` component are denied up front — no root
    /// binding, no daemon frame. No existence/regular-file check here: a write
    /// target legitimately may not exist yet (creation), and existence is
    /// probed server-side for the confirm card (`probe_old_exists`).
    static func validateWritePathShape(_ requested: String) -> ShapeValidation {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .deny("write path is empty") }
        guard !trimmed.hasPrefix("/") else {
            return .deny(
                "Absolute paths are not supported for workspace writes; use a path relative to the workspace root")
        }
        guard !trimmed.contains("\0") else { return .deny("write path contains a NUL byte") }
        guard trimmed != "." else {
            return .deny("write path must name a file, not the workspace root")
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.contains("..") {
            return .deny("path traversal (..) is not permitted in a workspace write")
        }
        return .ok(trimmed)
    }

    /// F7a: fd-anchored pre-state capture for a routed write's receipt/undo.
    /// Returns the FULL old content (as `Data`, up to the receipt blob cap) of
    /// an existing REGULAR file with `st_nlink <= 1` under the daemon-approved
    /// `root`, read off the SAME open leaf fd that anchored the confinement —
    /// no path re-resolution, so a symlink/hardlink swap cannot leak outside
    /// content during capture (closes the TOCTOU the path-based
    /// `ReceiptStore.capturePreStateForTool` would reopen).
    ///
    /// Returns `nil` for: a new file (not-found), a symlink/hardlink, or a
    /// non-regular entry. In all those cases either the file is being created
    /// (no undo material) or the daemon write will fail closed (fluers 0.5.0
    /// rejects symlinks/hardlinks) — so no pre-state is needed. A file larger
    /// than the blob cap also returns `nil` (matches the local pipeline's
    /// `captureFilePreState` skip).
    ///
    /// MUST be called under the routed operation lock, after root approval, to
    /// avoid the concurrent-write stale-pre-state race (the lock serializes
    /// routed writes, so capture + execute are atomic w.r.t. other routed ops).
    static func readFdAnchoredPreState(
        validatedPath: String,
        root: URL
    ) -> Data? {
        let rawParts = validatedPath.split(separator: "/", omittingEmptySubsequences: true)
        let parts = rawParts.map(String.init).filter { $0 != "." && $0 != ".." }
        guard !parts.isEmpty else { return nil }

        // Anchor: open the ROOT with O_NOFOLLOW (mirrors readFdAnchored).
        let rootFd = root.path.withCString { cstr -> Int32 in
            Darwin.open(cstr, openFlags, 0)
        }
        guard rootFd >= 0 else { return nil }
        defer { Darwin.close(rootFd) }

        var rootSt = stat()
        guard Darwin.fstat(rootFd, &rootSt) == 0,
              (rootSt.st_mode & S_IFMT) == S_IFDIR
        else { return nil }

        // Walk intermediates as directories (openat + O_NOFOLLOW + fstat).
        var parentFd = rootFd
        var openedIntermediates: [Int32] = []
        defer {
            for fd in openedIntermediates where fd >= 0 { Darwin.close(fd) }
        }
        let lastIdx = parts.count - 1
        for (idx, name) in parts.enumerated() {
            let isLeaf = idx == lastIdx
            guard let opened = openComponent(
                parent: parentFd, name: name, requireDir: !isLeaf)
            else {
                // Leaf not-found (new file) or intermediate missing → no pre-state.
                return nil
            }
            if isLeaf {
                defer { Darwin.close(opened) }
                // Leaf checks off the OPENED fd (authoritative — no path).
                var leafSt = stat()
                guard Darwin.fstat(opened, &leafSt) == 0 else { return nil }
                // Only an existing regular file with a single link has undo
                // material. Symlinks (rejected by O_NOFOLLOW), hardlinks
                // (st_nlink>1 — the daemon write rejects these too), and
                // non-regular entries → nil.
                guard (leafSt.st_mode & S_IFMT) == S_IFREG,
                      leafSt.st_nlink <= 1
                else { return nil }
                let size = Int(leafSt.st_size)
                guard size >= 0,
                      size <= ReceiptStore.maxPreStateBlobBytes
                else { return nil }  // too large — skip the blob (matches local)
                // Read the FULL old content off the open fd (no display
                // truncation — undo needs the verbatim bytes).
                let fh = FileHandle(fileDescriptor: opened, closeOnDealloc: false)
                return fh.readData(ofLength: size)
            }
            openedIntermediates.append(opened)
            parentFd = opened
        }
        return nil
    }

    // MARK: - Edit routing (F7b)
    //
    // `edit` is a near-mechanical mirror of routed `write` (F7a): same
    // decision/execution split, same fd-anchored receipt pre-state, same
    // fail-closed-on-outage semantics, same DamageControl SKIP (edit's
    // DamageControl rules are confinement-only — `zeroAccessPaths`/
    // `readOnlyPaths`; the catastrophe/`.disaster` rules are bash-only and stay
    // deferred to F8). The ONE tool-specific difference is schema translation:
    // the Swift `EditTool` uses `old_string`/`new_string`, but the fluers daemon
    // `EditTool` requires `old_text`/`new_text` (enforced by `validate_input`).
    // The translation happens at the daemon seam (`executeSerializedRoutedEdit`),
    // so Swift-land (call.arguments, hooks, audit, receipts) keeps `old_string`/
    // `new_string` and the daemon gets the keys its schema requires.

    /// Mirrors `WriteRoutePlan`. `.legacyLocal` = explicit daemon opt-out (the
    /// legacy path-based `EditTool` via the full local pipeline);
    /// `.daemonReachable` = route to the governed daemon;
    /// `.daemonUnavailableFailClosed` = daemon INTENDED but unreachable → FAIL
    /// CLOSED (mutations are irreversible; no local edit fallback).
    enum EditRoutePlan {
        case legacyLocal
        case daemonReachable
        case daemonUnavailableFailClosed
    }

    /// Mirrors `WriteExecutionOutcome`. Carries the daemon's reply `result`
    /// (whose `content` is surfaced), the fd-anchored `preStateContent` (old
    /// file content for undo — the ESSENTIAL undo material for an in-place
    /// edit), and the `absoluteTargetPath` (canonical undo target).
    enum EditExecutionOutcome {
        case routed(result: [String: Any], preStateContent: Data?, absoluteTargetPath: String?)
        case denied(String)
        case failClosed(String)
        case cancelled
    }

    /// Decide the edit route from daemon reachability + intent (the DECISION).
    /// No path validation, no side effect. Mirrors `planWriteRoute`.
    static func planEditRoute(
        session: DaemonToolHostSession
    ) async -> EditRoutePlan {
        let reachable = await session.isDaemonReachable()
        if !reachable, !session.daemonIntended {
            NSLog(
                "DaemonToolRouting: edit — daemon unreachable and useDaemonEngine=false "
                + "(opted out) → legacy local edit (pre-routing behavior)")
            return .legacyLocal
        }
        if reachable {
            return .daemonReachable
        }
        NSLog(
            "DaemonToolRouting: edit — daemon unreachable and useDaemonEngine=true "
            + "(intended) → FAIL CLOSED (mutations are irreversible; no local fallback)")
        return .daemonUnavailableFailClosed
    }

    /// EXECUTE a routed `edit` for a pre-computed `plan`. Mirrors `routeWrite`
    /// but with edit's args (`path`/`old_string`/`new_string`). Only `path` needs
    /// containment validation; `old_string`/`new_string` are content payloads.
    /// Reject empty `old_string` (would insert at the start — corruption); allow
    /// empty `new_string` (deletion of the match is valid). Do NOT pre-count
    /// occurrences here — that would be a path-based read; the daemon/fluers
    /// does the fd-anchored read + unique-match check (advisor F7b rule).
    static func routeEdit(
        call: ToolCall,
        session: DaemonToolHostSession,
        plan: EditRoutePlan
    ) async -> EditExecutionOutcome {
        guard plan != .legacyLocal else {
            return .failClosed("edit routing misconfigured: legacy route reached the routed executor")
        }
        guard let requestedPath = call.arguments["path"] as? String else {
            return .denied("Missing required parameter: path")
        }
        guard let oldString = call.arguments["old_string"] as? String else {
            return .denied("Missing required parameter: old_string")
        }
        guard let newString = call.arguments["new_string"] as? String else {
            return .denied("Missing required parameter: new_string")
        }
        guard !oldString.isEmpty else {
            return .denied("old_string must be non-empty")
        }
        switch validateEditPathShape(requestedPath) {
        case .deny(let reason):
            return .denied(reason)
        case .ok(let trimmed):
            switch plan {
            case .daemonReachable:
                return await session.executeSerializedRoutedEdit(
                    validatedPath: trimmed, oldString: oldString, newString: newString)
            case .daemonUnavailableFailClosed:
                // Mutations are irreversible; never fall back to a local edit.
                return .failClosed(
                    "Daemon unavailable and routing is intended; refusing to edit locally")
            case .legacyLocal:
                return .failClosed("edit routing misconfigured: legacy route reached the routed executor")
            }
        }
    }

    /// Map an `EditExecutionOutcome` to a Swift `ToolResult`. Mirrors
    /// `mapWriteOutcome`: raw technical error strings here; `ToolExecutor
    /// .executeRoutedEdit` reframes them via `friendlyRoutedEditError` AFTER
    /// audit. The `.routed` pre-state material is for the receipt; the daemon's
    /// `content` (e.g. "Edited `path` (X -> Y bytes)") is surfaced via
    /// `buildEditResult`.
    static func mapEditOutcome(
        _ outcome: EditExecutionOutcome
    ) -> ToolResult {
        switch outcome {
        case .routed(let result, _, _):
            return buildEditResult(from: result)
        case .denied(let reason):
            return .error(reason)
        case .failClosed(let reason):
            return .error(reason)
        case .cancelled:
            return .error("Edit was cancelled.")
        }
    }

    /// Shape-validate an edit path. Mirrors `validateWritePathShape` (only the
    /// path matters for containment; `old_string`/`new_string` are content).
    static func validateEditPathShape(_ requested: String) -> ShapeValidation {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .deny("edit path is empty") }
        guard !trimmed.hasPrefix("/") else {
            return .deny(
                "Absolute paths are not supported for workspace edits; use a path relative to the workspace root")
        }
        guard !trimmed.contains("\0") else { return .deny("edit path contains a NUL byte") }
        guard trimmed != "." else {
            return .deny("edit path must name a file, not the workspace root")
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.contains("..") {
            return .deny("path traversal (..) is not permitted in a workspace edit")
        }
        return .ok(trimmed)
    }

    /// Build the daemon-bound input dict for a routed edit, TRANSLATING the
    /// Swift schema (`old_string`/`new_string`, what the model produces + what
    /// `call.arguments`/hooks/audit/receipts carry) to the fluers daemon schema
    /// (`old_text`/`new_text`, what `validate_input` requires — see fluers-runtime
    /// `tool.rs` `EditTool`). Pure + directly unit-testable. Called by
    /// `executeSerializedRoutedEdit` AT the daemon seam; the Swift-native keys
    /// never leak across it.
    static func buildDaemonEditInput(
        validatedPath: String, oldString: String, newString: String
    ) -> [String: Any] {
        ["path": validatedPath, "old_text": oldString, "new_text": newString]
    }

    // MARK: - Bash routing (F8)
    //
    // `bash` is the LAST Layer-4 mutation to route. It mirrors write/edit's
    // routing/timeout/receipt shape but has TWO decisive differences (both from
    // owner decisions + a sandbox-reach audit — see `ACTIVE_WORK.md` + the F7/F8
    // policy doc §F8):
    //
    // 1. DamageControl is NOT skipped (unlike write/edit). The audit (Decision 2
    //    = ii) found the fluers daemon bash is explicitly NOT an OS-level sandbox
    //    (`local_env.rs:1-13`): `exec` (`local_env.rs:458-497`) runs `sh -c` with
    //    an fd-anchored cwd ONLY — the child has full user-FS reach (can
    //    `cd /; rm -rf …`), as the user's UID. So Swift's full bash DamageControl
    //    (`zeroAccessPaths` + `noDeletePaths` + `bashRules`) is NON-REDUNDANT and
    //    runs Swift-side BEFORE routing (in `ToolExecutor.executeRoutedBash`, not
    //    here — DamageControl lives in the executor, the routing layer is pure
    //    decision/execution). The daemon's own `damage.rs` covers a different
    //    scope (system-wide + workspace-wipe) as defense-in-depth.
    // 2. Receipts are coarse (Decision 1 = a): pattern-match the redirect target,
    //    snapshot that file, else no pre-state. Undo for arbitrary `rm`/pipelines
    //    is infeasible — DamageControl is the real guard. The coarse capture is
    //    routed-aware (relative target → daemon root, not Swift cwd).
    //
    // This layer (`routeBash`) does NOT run DamageControl — it only validates the
    // `command` arg exists. DamageControl runs in the executor BEFORE this is
    // called, so a catastrophe command never reaches `routeBash`.

    /// Mirrors `WriteRoutePlan`/`EditRoutePlan`. `.legacyLocal` = explicit daemon
    /// opt-out (legacy local `BashTool` via the full local pipeline, INCLUDING
    /// DamageControl); `.daemonReachable` = route to the governed daemon;
    /// `.daemonUnavailableFailClosed` = daemon INTENDED but unreachable → FAIL
    /// CLOSED (bash mutations are irreversible; no local bash fallback).
    enum BashRoutePlan {
        case legacyLocal
        case daemonReachable
        case daemonUnavailableFailClosed
    }

    /// Mirrors `WriteExecutionOutcome`/`EditExecutionOutcome`. Carries the
    /// daemon's reply `result` (whose `content` — `[exit N] stdout/stderr` — is
    /// surfaced), the coarse `preStateContent` (redirect-target file snapshot,
    /// or nil), and the `absoluteTargetPath` (the resolved undo target, or nil).
    enum BashExecutionOutcome {
        case routed(result: [String: Any], preStateContent: Data?, absoluteTargetPath: String?)
        case denied(String)
        case failClosed(String)
        case cancelled
    }

    /// Decide the bash route from daemon reachability + intent (the DECISION).
    /// Mirrors `planWriteRoute`/`planEditRoute`.
    static func planBashRoute(
        session: DaemonToolHostSession
    ) async -> BashRoutePlan {
        let reachable = await session.isDaemonReachable()
        if !reachable, !session.daemonIntended {
            NSLog(
                "DaemonToolRouting: bash — daemon unreachable and useDaemonEngine=false "
                + "(opted out) → legacy local bash (pre-routing behavior)")
            return .legacyLocal
        }
        if reachable {
            return .daemonReachable
        }
        NSLog(
            "DaemonToolRouting: bash — daemon unreachable and useDaemonEngine=true "
            + "(intended) → FAIL CLOSED (mutations are irreversible; no local fallback)")
        return .daemonUnavailableFailClosed
    }

    /// EXECUTE a routed `bash` for a pre-computed `plan`. Mirrors `routeWrite`/
    /// `routeEdit` but bash has a single `command` arg (no path to shape-validate
    /// — DamageControl, which runs in the executor BEFORE this, governs the
    /// command's safety). Only validates `command` exists + is a string.
    static func routeBash(
        call: ToolCall,
        session: DaemonToolHostSession,
        plan: BashRoutePlan
    ) async -> BashExecutionOutcome {
        guard plan != .legacyLocal else {
            return .failClosed("bash routing misconfigured: legacy route reached the routed executor")
        }
        guard let command = call.arguments["command"] as? String else {
            return .denied("Missing required parameter: command")
        }
        switch plan {
        case .daemonReachable:
            return await session.executeSerializedRoutedBash(command: command)
        case .daemonUnavailableFailClosed:
            // Mutations are irreversible; never fall back to a local bash.
            return .failClosed(
                "Daemon unavailable and routing is intended; refusing to run bash locally")
        case .legacyLocal:
            return .failClosed("bash routing misconfigured: legacy route reached the routed executor")
        }
    }

    /// Map a `BashExecutionOutcome` to a Swift `ToolResult`. Mirrors
    /// `mapWriteOutcome`/`mapEditOutcome`: raw technical error strings here;
    /// `ToolExecutor.executeRoutedBash` reframes them via
    /// `friendlyRoutedBashError` AFTER audit. The `.routed` daemon content
    /// (`[exit N] --- stdout --- … --- stderr --- …`) is surfaced via
    /// `buildBashResult`; a nonzero exit is CONTENT (the command ran), not a
    /// transport error.
    static func mapBashOutcome(
        _ outcome: BashExecutionOutcome
    ) -> ToolResult {
        switch outcome {
        case .routed(let result, _, _):
            return buildBashResult(from: result)
        case .denied(let reason):
            return .error(reason)
        case .failClosed(let reason):
            return .error(reason)
        case .cancelled:
            return .error("Bash was cancelled.")
        }
    }

    /// Build the Swift `ToolResult` from the daemon's `bash` reply. The fluers
    /// `BashTool::execute` returns a content block on success — `{type:"text",
    /// text:"[exit N] --- stdout --- … --- stderr --- …"}` (see fluers-runtime
    /// `tool.rs` `BashTool::execute`). Surfaced the same way as write/edit
    /// (shared M3-hardened extractor); a missing content array is still a
    /// success (the command ran; the daemon just returned no content block).
    static func buildBashResult(from result: [String: Any]) -> ToolResult {
        buildMutationToolResult(from: result, genericSuccess: "Ran command via the governed daemon.")
    }

    /// F8 (Decision 1 = a): coarse bash pre-state capture for a routed receipt.
    /// Pattern-matches the command for a `>`/`>>` redirect target (shared
    /// `ReceiptStore.extractBashOutputPath` parser, so routed + local use the
    /// SAME parser). Resolution is PATH-BASED, not fd-anchored: bash is NOT
    /// filesystem-confined (the daemon runs `sh -c` with full user-FS reach),
    /// and shell-relative paths can legitimately include `..`/symlinks — fd-
    /// anchoring (which filters `..`/rejects symlinks) would CHANGE SHELL
    /// SEMANTICS. This is best-effort UNDO material, NOT a confinement boundary
    /// (DamageControl, run in the executor, is the real guard).
    ///
    /// RELATIVE targets resolve path-based against `root` and STANDARDIZE
    /// (`root/out.txt`; `../sibling.txt` → the real sibling path). ABSOLUTE
    /// targets stay absolute (the daemon bash can write anywhere). The blob is
    /// snapshotted path-based with the receipt cap (mirrors
    /// `ReceiptStore.captureFilePreState`). No detectable target → `(nil, nil)`.
    /// Pure + directly unit-testable.
    static func captureCoarseBashPreState(
        command: String, root: URL
    ) -> (preStateContent: Data?, absoluteTargetPath: String?) {
        guard let target = ReceiptStore.extractBashOutputPath(command: command) else {
            return (nil, nil)
        }
        let absPath = target.hasPrefix("/")
            ? target
            : root.appendingPathComponent(target).standardizedFileURL.path
        // Path-based snapshot with the receipt blob cap. Returns (nil, absPath)
        // if the target doesn't exist yet (new file) or exceeds the cap — the
        // PATH is still carried for undo (a created target can be deleted).
        let fm = FileManager.default
        guard fm.fileExists(atPath: absPath),
              let attrs = try? fm.attributesOfItem(atPath: absPath),
              let size = attrs[.size] as? Int,
              size >= 0, size <= ReceiptStore.maxPreStateBlobBytes
        else { return (nil, absPath) }
        return (try? Data(contentsOf: URL(fileURLWithPath: absPath)), absPath)
    }

}
