import Foundation

// MARK: - FaeWorkspaceProvider

/// The default workspace Fae owns for portable tool operations (B-Swift Layer 3a,
/// owner decision C′: non-technical users never pick a folder).
///
/// A **provider** abstraction (not a concrete path) so:
/// - Tests inject a temp-dir provider and NEVER touch real `~/Documents` (avoids
///   macOS TCC sandbox prompts in CI; oracle MAJOR-1 DI precedent).
/// - If `.documentDirectory` triggers a disruptive Files permission prompt at
///   runtime, the provider can swap to App Support with NO routing changes —
///   the provider is the only seam that knows the path.
protocol FaeWorkspaceProvider {
    /// The workspace root this provider resolves (e.g. `~/Documents/Fae`).
    var workspaceRoot: URL { get }
}

/// Production provider: `~/Documents/Fae` — visible to the user (non-technical
/// users can browse "what Fae made for me"). Guard-safe: 3 Normal components,
/// not home, not a system dir.
struct DefaultDocumentsWorkspace: FaeWorkspaceProvider {
    var workspaceRoot: URL {
        // `.documentDirectory` resolves to `~/Documents` on macOS. Fall back to
        // `~/Documents` constructed from home if the lookup fails.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return docs.appendingPathComponent("Fae")
    }
}

// MARK: - Provisioning

/// Errors from workspace provisioning/root checks.
///
/// `symlinkedWorkspaceRoot` is a **security fail-closed** (B-Swift 3a follow-up
/// #1): the daemon's `is_safe_workspace_root` server guard rejects the home dir
/// itself but NOT its subdirs (it must allow `~/Documents/Fae`, also a home
/// subdir). So a symlink `~/Documents/Fae → ~/.ssh` defeats the guard — the
/// daemon roots into `~/.ssh` and a routed `read id_rsa` exfiltrates SSH keys.
/// Fae therefore refuses to use a default root that is itself a symbolic link.
enum FaeWorkspaceError: Error, LocalizedError {
    /// `provider.workspaceRoot` (at its tip path) is a symbolic link. Fae will
    /// not root through it. The path is the requested default root.
    case symlinkedWorkspaceRoot(URL)

    var errorDescription: String? {
        switch self {
        case .symlinkedWorkspaceRoot(let url):
            return "Fae's default workspace (\(url.path)) is a symbolic link. "
                + "Remove it so Fae can create a real workspace directory."
        }
    }
}

/// Pure workspace provisioning (no shared mutable state). Idempotent.
enum FaeWorkspace {

    /// Ownership sentinel — proves Fae created this dir (not a pre-existing user
    /// dir Fae would silently take over). **UX/collision guard, NOT a security
    /// boundary** (advisor #3): symlink-to-home attacks are defeated by the
    /// daemon's `is_safe_workspace_root` server guard (`root_confirm.rs:224-278`),
    /// which canonicalizes and rejects home/system regardless of client approval.
    static let markerName = ".fae-workspace"

    /// The result of provisioning the default workspace.
    enum ProvisionOutcome: Equatable {
        /// Fae created the dir + marker this call (fresh → auto-approve is sound).
        case provisioned(URL)
        /// The marker was already present (sticky across launches → auto-approve).
        case alreadyOwned(URL)
        /// The dir exists but has NO marker — a user (not Fae) likely made it.
        /// Surface the REAL confirm card once; on approval write the marker.
        case preExistingWithoutMarker(URL)
    }

    /// Provision the workspace root for `provider`. Idempotent, pure.
    ///
    /// - Returns `.provisioned` if Fae created it fresh; `.alreadyOwned` if the
    ///   marker was already present; `.preExistingWithoutMarker` if the dir
    ///   exists without a marker (caller must NOT auto-approve).
    static func provision(_ provider: FaeWorkspaceProvider) throws -> ProvisionOutcome {
        let root = provider.workspaceRoot
        // SECURITY (B-Swift 3a follow-up #1): refuse a default root that is itself
        // a symbolic link. `fileExists`/`attributesOfItem` FOLLOW symlinks, so a
        // `~/Documents/Fae → ~/.ssh` link would otherwise look like an ordinary
        // dir and Fae would root into `~/.ssh` (the daemon's `is_safe_workspace_
        // root` guard rejects the home dir but NOT home subdirs, so it accepts
        // `~/.ssh` reached this way). `lstat` reports the link entry itself; a
        // symlink at the tip is fail-closed here, before any marker/provisioning/
        // set_root. Ancestors that are symlinks (e.g. macOS `/tmp → /private/tmp`)
        // are fine — only the tip is checked.
        try requireNotSymlinkAtTip(root)

        let marker = root.appendingPathComponent(markerName)
        let fm = FileManager.default
        let markerExists = fm.fileExists(atPath: marker.path)
        let rootExists = fm.fileExists(atPath: root.path)
        if markerExists {
            return .alreadyOwned(root)
        }
        if rootExists {
            // Dir exists but Fae didn't create it → don't silently take over.
            return .preExistingWithoutMarker(root)
        }
        // Neither exists → Fae creates the dir + writes the marker.
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fae workspace\n".utf8).write(to: marker)
        return .provisioned(root)
    }

    /// Is the ownership marker present at `url`? (Used by the auto-approve wrapper.)
    static func markerPresent(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(markerName).path)
    }

    /// Write the marker (after a one-time card approval of a pre-existing dir).
    /// No-op if already present. SECURITY: never writes through a symlinked tip —
    /// `requireNotSymlinkAtTip` guards against a swapped `~/Documents/Fae → …`
    /// link making the marker sticky on an attacker-chosen target.
    static func writeMarker(at url: URL) throws {
        try requireNotSymlinkAtTip(url)
        let marker = url.appendingPathComponent(markerName)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try Data("fae workspace\n".utf8).write(to: marker)
    }
}

// MARK: - Symlink-at-tip guard (B-Swift 3a follow-up #1)

extension FaeWorkspace {

    /// True iff `url`'s own path entry is a symbolic link (`lstat` `S_IFLNK`).
    /// Only the TIP is checked — ancestor symlinks (`/tmp → /private/tmp`) are
    /// fine; the daemon canonicalizes those and guards the canonical path. The
    /// hazard is specifically the default root ITSELF being a link.
    static func isSymlinkAtTip(_ url: URL) -> Bool {
        var st = stat()
        guard Darwin.lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// Fail-closed if `url` exists and its tip is a symlink; no-op if it does not
    /// exist (provisioning may create it). Any other `lstat` error is treated as
    /// unsafe (deny) rather than safe.
    static func requireNotSymlinkAtTip(_ url: URL) throws {
        var st = stat()
        let rc = Darwin.lstat(url.path, &st)
        if rc == 0 {
            if (st.st_mode & S_IFMT) == S_IFLNK {
                throw FaeWorkspaceError.symlinkedWorkspaceRoot(url)
            }
            return
        }
        // rc != 0: ENOENT (does not exist) is fine — provisioning will create it.
        // Anything else (EACCES/EIO/…) → fail closed.
        if errno != ENOENT {
            throw FaeWorkspaceError.symlinkedWorkspaceRoot(url)
        }
    }
}

// MARK: - Auto-approve wrapper (advisor #3)

/// Wraps a real governance handler so the Fae-owned default root is
/// auto-approved WITHOUT surfacing the UI card, while every other confirmation
/// (including ALL `tool.confirm`) still goes to the real handler.
///
/// **Auto-approve fires IFF ALL hold:**
/// 1. `method == "workspace.confirm_root"` (NEVER `tool.confirm`), AND
/// 2. the confirm's canonical path == the default's canonical path (EXACT, never
///    prefix — a prefix match would wrongly auto-approve `~/Documents/Fae-evil`),
///    AND
/// 3. the marker is present (Fae owns the dir).
///
/// The daemon STILL asks (`set_root` always sends the confirm round-trip); the
/// client STILL decides — only UI friction is removed for the one Fae-owned path.
/// Authority is intact; the marker is an ownership/collision guard, NOT a
/// security boundary (the daemon's server guard is the authority).
func defaultAwareHandler(
    _ real: @escaping DaemonServerRequestHandler,
    defaultPath: URL,
    isMarkerPresent: @escaping () -> Bool
) -> DaemonServerRequestHandler {
    let defaultCanon = canonical(defaultPath)
    return { method, params in
        // Only the ROOT grant is ever auto-approved. Per-call dangerous-op
        // confirmations (`tool.confirm`) ALWAYS surface the real card.
        guard method == "workspace.confirm_root" else {
            return await real(method, params)
        }
        // Layer 1 fail-closed invariant: a missing/blank, PADDED, or non-absolute
        // `path` and any missing/blank/padded `call_id` must NOT be auto-approved.
        // Require raw == trimmed + non-empty (call_id) and clean-absolute (path);
        // else delegate to the real handler (which also denies on a malformed
        // confirm) — preserving the invariant rather than bypassing it (advisor #1).
        guard let callID = params["call_id"] as? String, isCleanNonBlank(callID),
              let confirmPath = params["path"] as? String, isCleanAbsolutePath(confirmPath)
        else {
            return await real(method, params)
        }
        let confirmCanon = canonical(URL(fileURLWithPath: confirmPath))
        // Defense-in-depth (B-Swift 3a follow-up #1): never auto-approve when the
        // default root itself is a symlink. `ensureDefaultRooted` already
        // hard-denies a symlinked default before `setRoot`, but this keeps the
        // handler safe against future reuse and a swapped link racing the guard.
        if confirmCanon == defaultCanon && isMarkerPresent() && !FaeWorkspace.isSymlinkAtTip(defaultPath) {
            return ["approved": true, "call_id": callID]
        }
        return await real(method, params)
    }
}

/// Canonicalize a URL for exact comparison: standardize + resolve symlinks.
/// Both sides of an auto-approve comparison pass through this so a symlinked
/// default is compared fairly (the daemon's server guard is the real defense).
private func canonical(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
}

/// True iff `s` is non-blank with NO leading/trailing whitespace (raw == trimmed).
/// Rejects padding anomalies the daemon should never emit (defense-in-depth on
/// the Layer 1 fail-closed invariant — "  th-1  " is not a valid call_id).
func isCleanNonBlank(_ s: String) -> Bool {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && s == trimmed
}

/// True iff `s` is a clean (non-blank, no padding) ABSOLUTE path. A relative root
/// is ambiguous (binds to the daemon's cwd); the daemon's server guard also
/// requires absolute.
func isCleanAbsolutePath(_ s: String) -> Bool {
    isCleanNonBlank(s) && s.hasPrefix("/")
}
