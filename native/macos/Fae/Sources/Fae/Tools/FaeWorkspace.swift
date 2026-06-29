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
    /// No-op if already present.
    static func writeMarker(at url: URL) throws {
        let marker = url.appendingPathComponent(markerName)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try Data("fae workspace\n".utf8).write(to: marker)
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
        if confirmCanon == defaultCanon && isMarkerPresent() {
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
