import Foundation

/// File-backed live peer allowlist — the consent → allowlist bridge.
///
/// `<daemon data dir>/peer_allowlist.json` is the owner-granted peer store the
/// daemon merges (union) with the `FAE_X0X_ALLOW` / `FAE_X0X_OWNER_FLEET` env
/// lists and re-reads live (mtime/length fingerprint checked per inbound
/// envelope in `crates/fae-daemon/src/peer/allowlist.rs`) — a grant goes live
/// in seconds without a daemon respawn.
///
/// SECURITY: mutation is owner-gated. `SelfConfigTool` raises the
/// hardware-click governance card BEFORE calling `grant(agentID:label:tier:)`;
/// this type never shows UI itself. The file is Fae-integrity protected on the
/// daemon side (`toolhost/isolation.rs`) so jailed tools cannot forge grants.
/// Writes are atomic (temp file + rename via `.atomic`), and every consent
/// decision is also appended to the daemon's `peer_envelope_audit.jsonl` in
/// the same `peer_consent_decision` row shape `PeerOutbound::record_consent`
/// writes, so one JSONL file stays the complete consent record.
enum PeerAllowlistStore {
    /// Chat/presence tier — the peer may direct-message the user through Fae.
    static let chatTier = "chat"
    /// Owner-fleet tier — the user's OWN devices; additionally permitted
    /// `session_handoff`. Never grant this to someone else's agent.
    static let ownerFleetTier = "owner_fleet"
    /// The tiers the daemon understands; anything else is dropped there.
    static let supportedTiers: Set<String> = [chatTier, ownerFleetTier]
    /// Schema version written to (and required from) `peer_allowlist.json`.
    static let supportedVersion = 1

    /// One grant row. Field names mirror the daemon's wire shape.
    struct Entry: Codable, Equatable {
        let agentID: String
        let label: String
        let grantedAt: String
        let tier: String

        enum CodingKeys: String, CodingKey {
            case agentID = "agent_id"
            case label
            case grantedAt = "granted_at"
            case tier
        }
    }

    private struct FilePayload: Codable {
        let version: Int
        let allow: [Entry]
    }

    enum StoreError: LocalizedError {
        case invalidAgentID
        case invalidTier

        var errorDescription: String? {
            switch self {
            case .invalidAgentID:
                return "agent_id must be exactly 64 hexadecimal characters"
            case .invalidTier:
                return "tier must be \"chat\" or \"owner_fleet\""
            }
        }
    }

    /// Test seam: when set, reads/writes target this directory instead of the
    /// daemon data dir. Production never sets it.
    nonisolated(unsafe) static var directoryOverride: URL?

    /// The DAEMON's data dir — NOT `FaeDirectories.support`. The daemon has a
    /// single data dir with no dev-profile split (mirrors the daemon's
    /// `data_directory()` and `DaemonLLMEngine.defaultDataDirectory`), and the
    /// allowlist must live where the daemon reads it.
    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("fae", isDirectory: true)
        #else
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("fae", isDirectory: true)
        #endif
    }

    /// `<daemon data dir>/peer_allowlist.json`.
    static var fileURL: URL {
        directory.appendingPathComponent("peer_allowlist.json")
    }

    /// `<daemon data dir>/peer_envelope_audit.jsonl` — the daemon's peer audit
    /// trail, which consent decisions are appended to.
    static var auditURL: URL {
        directory.appendingPathComponent("peer_envelope_audit.jsonl")
    }

    /// Current grant rows. A missing or corrupt/wrong-version file reads as
    /// empty — corrupt grants are already dead (the daemon fails closed on
    /// them identically), so the next grant rebuilds a clean file.
    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let payload = try? JSONDecoder().decode(FilePayload.self, from: data),
              payload.version == supportedVersion
        else {
            NSLog(
                "PeerAllowlistStore: peer_allowlist.json malformed or wrong version — treating as empty"
            )
            return []
        }
        return payload.allow
    }

    /// Idempotent grant — replaces any existing row for the same agent id.
    /// SECURITY: callers MUST have obtained the owner's hardware-click
    /// approval BEFORE calling this (SelfConfigTool raises the governance
    /// card); this function only validates and writes.
    static func grant(agentID: String, label: String, tier: String) throws {
        let id = agentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard SelfConfigTool.isHex64(id) else { throw StoreError.invalidAgentID }
        guard supportedTiers.contains(tier) else { throw StoreError.invalidTier }
        var entries = load().filter { $0.agentID != id }
        entries.append(
            Entry(
                agentID: id,
                label: label,
                grantedAt: ISO8601DateFormatter().string(from: Date()),
                tier: tier))
        try write(entries: entries)
    }

    /// Remove a grant. Returns whether a row was removed. No approval card is
    /// required — removing access is always safe.
    @discardableResult
    static func revoke(agentID: String) throws -> Bool {
        let id = agentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let entries = load()
        let kept = entries.filter { $0.agentID != id }
        guard kept.count != entries.count else { return false }
        try write(entries: kept)
        return true
    }

    private static func write(entries: [Entry]) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(FilePayload(version: supportedVersion, allow: entries))
        // `.atomic` = write-to-temp + rename, so the daemon's per-frame reader
        // never observes a half-written file.
        try data.write(to: fileURL, options: .atomic)
    }

    /// Append the owner's consent decision to the daemon's peer audit log.
    /// Best-effort: a failed audit write is logged, never thrown — audit must
    /// not block a grant/revoke (the daemon's own audit appends are
    /// best-effort in exactly the same way).
    static func appendConsentAudit(agentID: String, granted: Bool, reason: String) {
        let record: [String: Any] = [
            "event_type": "peer_consent_decision",
            "envelope_id": "consent-\(Int(Date().timeIntervalSince1970 * 1000))",
            "sender_id": agentID,
            "kind": NSNull(),
            "decision": granted ? "accepted" : "rejected",
            "reason": reason,
        ]
        do {
            var line = try JSONSerialization.data(
                withJSONObject: record, options: [.sortedKeys])
            line.append(0x0A)
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: auditURL.path) {
                fm.createFile(atPath: auditURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: auditURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            NSLog(
                "PeerAllowlistStore: consent audit append failed: %@",
                error.localizedDescription)
        }
    }
}
