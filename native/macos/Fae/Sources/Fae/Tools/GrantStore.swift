import Foundation

/// Persistent, integrity-checked store of the owner's standing sandbox-override
/// grants (security-override Wave 2, L8 / L9).
///
/// Lives at the HARD-CODED `~/Library/Application Support/fae/grant-store.json`
/// (`FaeDirectories.grantStoreFile`) — a path DamageControl zero-accesses and the
/// daemon's Fae-integrity/never set covers, so no tool can read or rewrite it.
///
/// Integrity rules (fail-closed, Invariant F):
/// - written `chmod 0600`;
/// - on load, the store file is REJECTED if it is a symlink or its `realpath`
///   differs from the expected path (defeats a swap to a tool-writable location);
/// - a malformed / tampered payload rejects the WHOLE store (returns empty) rather
///   than trusting partial data.
///
/// Grants are keyed NARROWLY by canonical target path — never "always allow bash"
/// wholesale. Secrets-tier grants are `expiring` only (never persistent); the
/// daemon + `SecurityTier` both refuse a persistent Secrets grant regardless.
actor GrantStore {
    /// A single standing grant, keyed by its canonical target path.
    struct Grant: Codable, Sendable, Equatable {
        /// The canonical (symlink-resolved, absolute) file the grant authorizes.
        let canonicalTarget: String
        /// Advisory tier (`"general"` | `"secrets"`).
        let tier: String
        /// `"persistent"` (General "always") or `"expiring"` (Secrets 5-min).
        let grantKind: String
        /// Absolute UNIX-epoch ms expiry for `expiring`; `nil` for `persistent`.
        let expiryMs: UInt64?
    }

    enum GrantStoreError: Error, Equatable {
        case rejectedSymlink
        case realpathMismatch
        case malformed
    }

    private let path: URL

    /// - Parameter path: the store location. Defaults to the hard-coded
    ///   `FaeDirectories.grantStoreFile`; tests inject a temp path.
    init(path: URL = FaeDirectories.grantStoreFile) {
        self.path = path
    }

    // MARK: - Load (integrity-checked)

    /// Load + integrity-check the store. Throws on a symlink / realpath mismatch /
    /// malformed payload (the caller treats any throw as "no grants" — fail closed).
    func loadStrict() throws -> [Grant] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else { return [] }
        // lstat-based type check (does NOT follow the link): reject a symlinked
        // store outright — a tool could otherwise point it at a writable target.
        let attrs = try fm.attributesOfItem(atPath: path.path)
        if let type = attrs[.type] as? FileAttributeType, type == .typeSymbolicLink {
            throw GrantStoreError.rejectedSymlink
        }
        // realpath must equal the expected path (defeats a parent-dir symlink swap).
        let expected = (path.path as NSString).standardizingPath
        let real = (path.resolvingSymlinksInPath().path as NSString).standardizingPath
        guard real == expected else { throw GrantStoreError.realpathMismatch }

        let data = try Data(contentsOf: path)
        let grants: [Grant]
        do {
            grants = try JSONDecoder().decode([Grant].self, from: data)
        } catch {
            throw GrantStoreError.malformed
        }
        // Integrity: every entry must be well-formed. A single bad row rejects the
        // whole store (fail closed) rather than silently honouring the rest.
        for g in grants {
            guard g.canonicalTarget.hasPrefix("/"), !g.canonicalTarget.isEmpty else {
                throw GrantStoreError.malformed
            }
            guard g.tier == "general" || g.tier == "secrets" else {
                throw GrantStoreError.malformed
            }
            switch g.grantKind {
            case "persistent":
                // Secrets tier can NEVER be persistent (tier misclassification guard).
                if g.tier == "secrets" { throw GrantStoreError.malformed }
            case "expiring":
                if g.expiryMs == nil { throw GrantStoreError.malformed }
            default:
                throw GrantStoreError.malformed
            }
        }
        return grants
    }

    /// Best-effort load: any integrity failure yields an EMPTY store (fail closed),
    /// so a tampered/symlinked store grants nothing rather than throwing into the
    /// hot path.
    func load() -> [Grant] {
        (try? loadStrict()) ?? []
    }

    // MARK: - Lookup

    /// The live (non-expired) grant for a canonical target, if any. Expired
    /// `expiring` grants are ignored (and lazily pruned on the next write).
    func lookup(canonicalTarget: String, nowMs: UInt64) -> Grant? {
        load().first { g in
            guard g.canonicalTarget == canonicalTarget else { return false }
            if let exp = g.expiryMs { return nowMs <= exp }
            return true
        }
    }

    // MARK: - Record

    /// Upsert a grant (keyed by canonical target), pruning expired rows, then write
    /// `chmod 0600`. A `once` grant is never stored (single-use); callers pass only
    /// `persistent` / `expiring`. Throws on an unwritable store.
    func record(
        canonicalTarget: String,
        tier: SecurityTier,
        kind: SecurityGrantKind,
        nowMs: UInt64
    ) throws {
        guard kind != .once else { return }
        // Secrets tier is expiring-only; refuse to persist it (defence-in-depth).
        if tier == .secrets && kind == .persistent { return }
        let grantKind: String
        let expiryMs: UInt64?
        switch kind {
        case .persistent:
            grantKind = "persistent"
            expiryMs = nil
        case .expiring:
            grantKind = "expiring"
            expiryMs = nowMs &+ DaemonSecurityOverride.expiringWindowMs
        case .once:
            return
        }
        var grants = load().filter { g in
            // Drop any existing row for this target + any expired expiring rows.
            if g.canonicalTarget == canonicalTarget { return false }
            if let exp = g.expiryMs { return nowMs <= exp }
            return true
        }
        grants.append(Grant(
            canonicalTarget: canonicalTarget,
            tier: tier.wireValue,
            grantKind: grantKind,
            expiryMs: expiryMs))
        try write(grants)
    }

    /// Atomically write the store then tighten perms to `0600`.
    private func write(_ grants: [Grant]) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(grants)
        try data.write(to: path, options: [.atomic])
        try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))],
                             ofItemAtPath: path.path)
    }

    // MARK: - Interactive-only auto-apply (L9, pure decision)

    /// Decide whether a stored grant auto-mints a per-call override for a fresh
    /// denial — WITHOUT prompting. Pure + testable.
    ///
    /// L9 rules enforced here:
    /// - ONLY on a genuine interactive owner turn (never proactive/script/scheduler);
    /// - the denial must be overridable (never Fae-integrity);
    /// - the grant's canonical target + tier must still match the (re-derived) denial;
    /// - a Secrets `expiring` grant must not be past its absolute expiry.
    static func autoApplyOverride(
        grant: Grant?,
        denial: SecurityDenial,
        origin: DaemonToolOrigin,
        nowMs: UInt64
    ) -> DaemonSecurityOverride? {
        guard origin.isInteractive else { return nil }
        guard denial.overridable else { return nil }
        guard let grant else { return nil }
        // Re-derive: the grant must name THIS denial's target + tier.
        guard grant.canonicalTarget == denial.target else { return nil }
        guard grant.tier == denial.tier.wireValue else { return nil }
        let kind: SecurityGrantKind
        switch grant.grantKind {
        case "persistent":
            // Secrets can never be persistent — reject on mismatch.
            if denial.tier == .secrets { return nil }
            kind = .persistent
        case "expiring":
            guard let exp = grant.expiryMs, nowMs <= exp else { return nil }
            kind = .expiring
        default:
            return nil
        }
        return DaemonSecurityOverride.mint(
            target: denial.target, tier: denial.tier, kind: kind, nowMs: nowMs)
    }
}
