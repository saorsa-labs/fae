import XCTest

@testable import Fae

/// Consent→allowlist bridge tests: the file-backed grant store
/// (`PeerAllowlistStore`) and the owner-gated `self_config` actions
/// (`peer_grant` / `peer_revoke`).
///
/// WHY these tests matter: the allowlist file is a live network-trust surface
/// the daemon reloads per inbound envelope. A grant that skips the owner's
/// approval card, accepts a malformed agent id, or writes an unreadable file
/// would either open the peer lane to someone the owner never chose or
/// silently kill existing grants.
final class PeerAllowlistBridgeTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peer-allowlist-tests-\(UUID().uuidString)")
        PeerAllowlistStore.directoryOverride = tempDir
    }

    override func tearDown() {
        PeerAllowlistStore.directoryOverride = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    private let hexA = String(repeating: "a", count: 64)
    private let hexB = String(repeating: "b", count: 64)

    private func fileJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: PeerAllowlistStore.fileURL)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - Store

    func testGrantWritesVersionedFileTheDaemonCanParse() throws {
        try PeerAllowlistStore.grant(agentID: hexA, label: "Alice", tier: "chat")
        let json = try fileJSON()
        XCTAssertEqual(json["version"] as? Int, 1, "daemon requires version 1")
        let allow = try XCTUnwrap(json["allow"] as? [[String: Any]])
        XCTAssertEqual(allow.count, 1)
        XCTAssertEqual(allow[0]["agent_id"] as? String, hexA)
        XCTAssertEqual(allow[0]["tier"] as? String, "chat")
        XCTAssertEqual(allow[0]["label"] as? String, "Alice")
        XCTAssertNotNil(allow[0]["granted_at"] as? String)
    }

    func testGrantIsIdempotentPerAgentAndNormalisesCase() throws {
        // WHY: the daemon matches ids case-insensitively on lowercase; two
        // rows for one agent would make revocation ambiguous.
        try PeerAllowlistStore.grant(agentID: hexA.uppercased(), label: "Alice", tier: "chat")
        try PeerAllowlistStore.grant(agentID: hexA, label: "Alice B", tier: "owner_fleet")
        let entries = PeerAllowlistStore.load()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].agentID, hexA)
        XCTAssertEqual(entries[0].tier, "owner_fleet")
    }

    func testGrantRejectsInvalidAgentIDAndUnknownTier() {
        XCTAssertThrowsError(
            try PeerAllowlistStore.grant(agentID: "not-hex", label: "x", tier: "chat"))
        XCTAssertThrowsError(
            try PeerAllowlistStore.grant(agentID: hexA, label: "x", tier: "superuser"),
            "an unknown tier must never be written — the daemon would drop it, "
                + "but the file must not pretend a grant exists")
        XCTAssertFalse(FileManager.default.fileExists(atPath: PeerAllowlistStore.fileURL.path))
    }

    func testRevokeRemovesGrantAndReportsWhetherItExisted() throws {
        try PeerAllowlistStore.grant(agentID: hexA, label: "Alice", tier: "chat")
        try PeerAllowlistStore.grant(agentID: hexB, label: "laptop", tier: "owner_fleet")
        XCTAssertTrue(try PeerAllowlistStore.revoke(agentID: hexA))
        XCTAssertFalse(try PeerAllowlistStore.revoke(agentID: hexA), "second revoke is a no-op")
        let entries = PeerAllowlistStore.load()
        XCTAssertEqual(entries.map(\.agentID), [hexB], "other grants must survive a revoke")
    }

    func testCorruptExistingFileIsTreatedAsEmptyAndRebuilt() throws {
        // WHY: the daemon fails closed on a corrupt file (its grants are
        // already dead), so the next grant must rebuild a clean file rather
        // than crash or append to garbage.
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: PeerAllowlistStore.fileURL)
        XCTAssertEqual(PeerAllowlistStore.load(), [])
        try PeerAllowlistStore.grant(agentID: hexA, label: "Alice", tier: "chat")
        XCTAssertEqual(PeerAllowlistStore.load().map(\.agentID), [hexA])
    }

    func testConsentAuditAppendsDaemonShapedRows() throws {
        // WHY: grants/revokes must land in the SAME audit trail the daemon's
        // gate writes (`peer_envelope_audit.jsonl`), in the same row shape as
        // `PeerOutbound::record_consent`, so one file is the complete record.
        PeerAllowlistStore.appendConsentAudit(
            agentID: hexA, granted: true, reason: "owner_consent_granted")
        PeerAllowlistStore.appendConsentAudit(
            agentID: hexA, granted: false, reason: "owner_consent_revoked")
        let content = try String(contentsOf: PeerAllowlistStore.auditURL, encoding: .utf8)
        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let first = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(first["event_type"] as? String, "peer_consent_decision")
        XCTAssertEqual(first["decision"] as? String, "accepted")
        XCTAssertEqual(first["sender_id"] as? String, hexA)
        XCTAssertEqual(first["reason"] as? String, "owner_consent_granted")
        let second = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(second["decision"] as? String, "rejected")
    }

    // MARK: - self_config peer_grant / peer_revoke

    /// Auto-answers the next governance approval card, recording whether one
    /// was ever requested. Deliberately drives the REAL notification
    /// round-trip (`.faeGovernanceConfirmationRequested` → `…Respond`) — the
    /// same seam the AppKit card uses — so the test proves the grant path
    /// cannot complete without a card decision.
    private final class CardResponder {
        private var observer: NSObjectProtocol?
        private(set) var requested = false

        init(approve: Bool) {
            observer = NotificationCenter.default.addObserver(
                forName: .faeGovernanceConfirmationRequested,
                object: nil,
                queue: .main
            ) { [weak self] note in
                self?.requested = true
                guard let requestID = note.userInfo?["request_id"] as? String else { return }
                NotificationCenter.default.post(
                    name: .faeGovernanceConfirmationRespond,
                    object: nil,
                    userInfo: ["request_id": requestID, "approved": approve])
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func testPeerGrantRejectsBadAgentIDWithoutRaisingACard() async throws {
        let responder = CardResponder(approve: true)
        let result = try await SelfConfigTool().execute(
            input: ["action": "peer_grant", "agent_id": "definitely-not-hex"])
        XCTAssertTrue(result.isError)
        XCTAssertFalse(
            responder.requested,
            "validation must fail BEFORE the owner is ever asked to approve")
        XCTAssertFalse(FileManager.default.fileExists(atPath: PeerAllowlistStore.fileURL.path))
    }

    func testPeerGrantDeniedOnCardWritesNothingButAuditsTheDecision() async throws {
        // WHY: a declined card is the trust boundary working — the file must
        // stay untouched and the denial must still be auditable.
        let responder = CardResponder(approve: false)
        let result = try await SelfConfigTool().execute(
            input: ["action": "peer_grant", "agent_id": hexA, "label": "Alice"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(responder.requested, "the approval card must be raised")
        XCTAssertFalse(FileManager.default.fileExists(atPath: PeerAllowlistStore.fileURL.path))
        let audit = try String(contentsOf: PeerAllowlistStore.auditURL, encoding: .utf8)
        XCTAssertTrue(audit.contains("owner_consent_denied"))
    }

    func testPeerGrantApprovedOnCardWritesLiveGrantAndAudit() async throws {
        let responder = CardResponder(approve: true)
        let result = try await SelfConfigTool().execute(
            input: ["action": "peer_grant", "agent_id": hexA, "label": "Alice", "tier": "chat"])
        XCTAssertFalse(result.isError, "grant should succeed: \(result.output)")
        XCTAssertTrue(responder.requested)
        let entries = PeerAllowlistStore.load()
        XCTAssertEqual(entries.map(\.agentID), [hexA])
        XCTAssertEqual(entries[0].tier, "chat")
        let audit = try String(contentsOf: PeerAllowlistStore.auditURL, encoding: .utf8)
        XCTAssertTrue(audit.contains("owner_consent_granted"))
    }

    func testPeerGrantRejectsUnknownTierBeforeTheCard() async throws {
        let responder = CardResponder(approve: true)
        let result = try await SelfConfigTool().execute(
            input: ["action": "peer_grant", "agent_id": hexA, "tier": "superuser"])
        XCTAssertTrue(result.isError)
        XCTAssertFalse(responder.requested)
    }

    func testPeerRevokeRemovesGrantWithoutACard() async throws {
        try PeerAllowlistStore.grant(agentID: hexA, label: "Alice", tier: "chat")
        let responder = CardResponder(approve: false)
        let result = try await SelfConfigTool().execute(
            input: ["action": "peer_revoke", "agent_id": hexA])
        XCTAssertFalse(result.isError, "revoke should succeed: \(result.output)")
        XCTAssertFalse(responder.requested, "removing access never needs approval")
        XCTAssertEqual(PeerAllowlistStore.load(), [])
        let audit = try String(contentsOf: PeerAllowlistStore.auditURL, encoding: .utf8)
        XCTAssertTrue(audit.contains("owner_consent_revoked"))
    }
}
