import Foundation

/// The three sandbox tiers a blocked path can fall into (security-override Wave 2,
/// L3). This Swift table is ADVISORY UX ONLY — it drives which authorize buttons
/// the card shows. The daemon RE-DERIVES the authoritative tier from the canonical
/// path (`classify_canonical_tier`) and enforces it; Swift's job is to never
/// OFFER an override the daemon would refuse (a Fae-integrity path shows no Allow
/// button at all). The member lists mirror the daemon's exactly
/// (`crates/fae-daemon/src/toolhost/isolation.rs`) so the UX never contradicts the
/// backstop.
enum SecurityTier: String, Sendable, Equatable {
    /// Fae's own trust anchors — vault, speaker profiles, directive, models.lock,
    /// grant-store. NEVER overridable (Deny only). Precedence: strictest wins.
    case faeIntegrity
    /// Owner-owned credential files/dirs (`~/.secrets`, `~/.ssh`, …). Overridable
    /// only `once` / `expiring` — never persistently.
    case secrets
    /// Any other path. Overridable `once` or `always` (persistent scoped grant).
    case general

    /// Home-relative Fae-integrity members (mirror of the daemon's
    /// `fae_integrity_relative()`). Both `fae` and `fae-dev` data dirs are covered.
    private static let faeIntegrityRelative: [String] = [
        ".fae-vault",
        ".fae-vault-dev",
        "Library/Application Support/fae/speakers.json",
        "Library/Application Support/fae/directive.md",
        "Library/Application Support/fae/models.lock",
        "Library/Application Support/fae/grant-store.json",
        "Library/Application Support/fae/peer_allowlist.json",
        "Library/Application Support/fae-dev/speakers.json",
        "Library/Application Support/fae-dev/directive.md",
        "Library/Application Support/fae-dev/models.lock",
        "Library/Application Support/fae-dev/grant-store.json",
        "Library/Application Support/fae-dev/peer_allowlist.json",
    ]

    /// Home-relative Secrets members (mirror of the daemon's `secrets_relative()`).
    private static let secretsRelative: [String] = [
        ".secrets", ".env", ".envrc", ".saorsa-keys",
        ".ssh", ".gnupg", ".aws", ".azure", ".kube",
        ".docker/config.json", ".netrc", ".npmrc", ".pypirc",
    ]

    /// Classify an absolute (home-expanded) path into its advisory tier. Strictest
    /// match wins: Fae-integrity > Secrets > General. A path that equals OR sits
    /// under a member is that member's tier (so a file under `~/.ssh` classifies
    /// Secrets; a file under `~/.fae-vault` classifies Fae-integrity).
    static func classify(absolutePath: String) -> SecurityTier {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let homePrefixed = "/" + home
        let target = (absolutePath as NSString).standardizingPath
        func matches(_ members: [String]) -> Bool {
            for rel in members {
                let member = (homePrefixed + "/" + rel as NSString).standardizingPath
                if target == member || target.hasPrefix(member + "/") { return true }
            }
            return false
        }
        if matches(Self.faeIntegrityRelative) { return .faeIntegrity }
        if matches(Self.secretsRelative) { return .secrets }
        return .general
    }

    /// Whether the daemon would ever honor an override for this tier. Fae-integrity
    /// is hard-refused on both sides (Swift offers no Allow button; the daemon
    /// hard-rejects any directive naming a never-path).
    var isOverridable: Bool { self != .faeIntegrity }

    /// Human-readable tier label for the authorize card.
    var displayName: String {
        switch self {
        case .faeIntegrity: return "Fae integrity (protected)"
        case .secrets: return "Secrets"
        case .general: return "General"
        }
    }

    /// The advisory wire `tier` string (`"general"` | `"secrets"`). Fae-integrity
    /// never rides the wire (it is never overridable), so it maps to `"secrets"`
    /// defensively — the daemon re-classifies regardless and would reject it.
    var wireValue: String {
        switch self {
        case .general: return "general"
        case .secrets, .faeIntegrity: return "secrets"
        }
    }
}

/// A typed security denial carried on a tool result when a security layer blocks a
/// call (security-override Wave 2, Part A). The pipeline turns it into a clear
/// spoken/printed line instead of an opaque "✗ Failed: bash", and the routed-bash
/// executor uses it to decide whether to offer the human-gated authorize card.
struct SecurityDenial: Sendable, Equatable {
    /// The raw block reason from the security layer (audit / debugging).
    let reason: String
    /// The protected path (home-expanded, absolute) the call tried to touch. This
    /// is also the `target_path` a post-click override relaxes.
    let target: String
    /// The advisory tier of `target`.
    let tier: SecurityTier
    /// Whether an override could be offered (false for Fae-integrity).
    var overridable: Bool { tier.isOverridable }

    /// The plain-language line the user hears/sees instead of a generic failure
    /// (L12 tone — honest about WHY, not soft-pedalled).
    var spokenMessage: String {
        let display = SecurityDenial.tildeCollapsed(target)
        switch tier {
        case .faeIntegrity:
            return "I can't touch \(display) — that's one of my own protected trust "
                + "anchors, and I'm blocked from reading or changing it for your security."
        case .secrets:
            return "I can't read \(display) — it's a protected secret I'm blocked from "
                + "touching for your security. If you truly want me to, you can authorize "
                + "it on the card."
        case .general:
            return "I can't access \(display) — it's outside my safety sandbox. If you "
                + "truly want me to, you can authorize it on the card."
        }
    }

    /// Collapse a home-prefixed absolute path back to its `~` form for display.
    static func tildeCollapsed(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// How long a granted authorization holds (security-override Wave 2, Part B).
enum SecurityGrantKind: String, Sendable, Equatable {
    /// This one call only. Never stored.
    case once
    /// A bounded window (Secrets tier "allow 5 min"). Stored with an expiry.
    case expiring
    /// A persistent scoped grant (General tier "always allow"). Stored, no expiry.
    case persistent
}

/// The user's decision on the authorize card.
enum SecurityOverrideDecision: Sendable, Equatable {
    /// Denied (explicit deny OR the 10 s timeout).
    case deny
    /// Authorized with the chosen grant kind.
    case allow(SecurityGrantKind)
}

/// A per-call, human-gated sandbox override directive — the Swift-side model of
/// the wire contract's top-level `security_override` sibling of `toolhost.execute`.
///
/// It is minted ONLY after a hardware click on the authorize card (or from a
/// previously-authorized stored grant, auto-applied on a genuine interactive turn).
/// The model can neither see nor set it. `callID` is filled in by
/// `DaemonToolHostSession.buildExecutePayload` at send time so it always equals
/// the request's own `call_id` (L7 single-use binding); every OTHER field is
/// re-validated daemon-side.
struct DaemonSecurityOverride: Sendable, Equatable {
    /// The file the read-deny is relaxed for. The daemon re-canonicalizes this and
    /// removes exactly that one canonical leaf (L4).
    let targetPath: String
    /// Advisory tier (`"general"` | `"secrets"`). The daemon re-derives it (L3).
    let tierWire: String
    /// Advisory grant kind (`"once"` | `"expiring"`) — the daemon honors the
    /// single-call binding + absolute expiry regardless.
    let grantKindWire: String
    /// Absolute UNIX-epoch ms; the daemon honors only `now_ms() <= expiry_ms` (L6).
    let expiryMs: UInt64

    /// The per-call override window (ms) for a single-shot relaxation. The daemon
    /// only needs `now <= expiry`; the read happens immediately after mint, so a
    /// short window is correct and minimises exposure.
    static let onceWindowMs: UInt64 = 10_000
    /// The Secrets "allow 5 min" window (ms).
    static let expiringWindowMs: UInt64 = 5 * 60_000

    /// Mint a per-call override for a just-authorized denial. `nowMs` is the
    /// current UNIX-epoch ms (injectable for tests). The wire `grant_kind` is the
    /// closed daemon enum: a persistent grant still mints a SINGLE-call `once`
    /// directive here (persistence lives in the `GrantStore`, off the wire).
    static func mint(
        target: String,
        tier: SecurityTier,
        kind: SecurityGrantKind,
        nowMs: UInt64
    ) -> DaemonSecurityOverride {
        let (wireKind, windowMs): (String, UInt64)
        switch kind {
        case .once, .persistent:
            (wireKind, windowMs) = ("once", onceWindowMs)
        case .expiring:
            (wireKind, windowMs) = ("expiring", expiringWindowMs)
        }
        return DaemonSecurityOverride(
            targetPath: target,
            tierWire: tier.wireValue,
            grantKindWire: wireKind,
            expiryMs: nowMs &+ windowMs
        )
    }
}
