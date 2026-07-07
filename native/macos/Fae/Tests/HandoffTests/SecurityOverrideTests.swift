import XCTest
@testable import Fae

/// Security-override Wave 2 (the Swift half that DRIVES the daemon override).
/// Hermetic unit coverage for every load-bearing L-rule surface: truthful origin
/// threading (L1), Part A denial messaging, the hardware-only one-shot card
/// (L2/L6/L12), the re-submit `security_override` construction (the wire contract),
/// grant-store integrity (L8), and interactive-only auto-apply (L9).
final class SecurityOverrideTests: XCTestCase {

    // Build fake secret material by CONCATENATION so nothing here trips secret
    // scanners (owner rule: never write a literal credential fixture).
    private func fakeSecretsPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/" + "." + "secrets"
    }

    // MARK: - L1: truthful origin threading (interactive vs autonomous)

    private func context(
        actionSource: ActionSource,
        proactive: PipelineCoordinator.ProactiveRequestContext?,
        isScriptBlock: Bool
    ) -> ToolExecutorContext {
        ToolExecutorContext(
            toolMode: "full",
            privacyMode: "local_preferred",
            modelLocality: .local,
            explicitUserAuthorization: false,
            isOwner: true,
            livenessScore: nil,
            speakerId: nil,
            actionSource: actionSource,
            proactiveContext: proactive,
            isScriptBlock: isScriptBlock,
            visionEnabled: false,
            firstOwnerEnrollmentActive: false,
            workflowTurnID: nil,
            traceToolCallID: nil,
            workflowRunID: nil)
    }

    func testInteractiveOwnerTurnMapsToOwnerInteractive() {
        let ctx = context(actionSource: .voice, proactive: nil, isScriptBlock: false)
        XCTAssertEqual(ToolExecutor.daemonToolOrigin(for: ctx), .ownerInteractive)
        XCTAssertTrue(ToolExecutor.daemonToolOrigin(for: ctx).isInteractive)
    }

    func testProactiveTurnMapsToNonInteractiveOrigin() {
        let pc = PipelineCoordinator.ProactiveRequestContext(
            source: .voice, taskId: "overnight", allowedTools: [],
            consentGranted: true, conversationTag: "t")
        let ctx = context(actionSource: .voice, proactive: pc, isScriptBlock: false)
        let origin = ToolExecutor.daemonToolOrigin(for: ctx)
        XCTAssertEqual(origin, .proactive)
        XCTAssertFalse(origin.isInteractive, "a proactive turn must NOT send owner_interactive")
    }

    func testScriptBlockMapsToScriptBlockOrigin() {
        let ctx = context(actionSource: .voice, proactive: nil, isScriptBlock: true)
        let origin = ToolExecutor.daemonToolOrigin(for: ctx)
        XCTAssertEqual(origin, .scriptBlock)
        XCTAssertFalse(origin.isInteractive, "a tool_program turn must NOT send owner_interactive")
    }

    func testSchedulerTurnMapsToSchedulerOrigin() {
        let ctx = context(actionSource: .scheduler, proactive: nil, isScriptBlock: false)
        XCTAssertEqual(ToolExecutor.daemonToolOrigin(for: ctx), .scheduler)
    }

    func testOriginRawValuesMatchDaemonWireStrings() {
        // Lockstep with `parse_tool_origin` in crates/fae-daemon/src/session.rs.
        XCTAssertEqual(DaemonToolOrigin.ownerInteractive.rawValue, "owner_interactive")
        XCTAssertEqual(DaemonToolOrigin.proactive.rawValue, "proactive")
        XCTAssertEqual(DaemonToolOrigin.scheduler.rawValue, "scheduler")
        XCTAssertEqual(DaemonToolOrigin.autoSkill.rawValue, "auto_skill")
        XCTAssertEqual(DaemonToolOrigin.scriptBlock.rawValue, "script_block")
        XCTAssertEqual(DaemonToolOrigin.delegated.rawValue, "delegated")
    }

    func testPayloadStampsTruthfulOrigin() {
        let interactive = DaemonToolHostSession.buildExecutePayload(
            tool: "bash", input: ["command": "ls"], origin: .ownerInteractive,
            securityOverride: nil, requestID: "th-1")
        XCTAssertEqual(interactive["origin"] as? String, "owner_interactive")
        XCTAssertNil(interactive["security_override"], "no override ⇒ byte-identical to today (Invariant F)")

        let proactive = DaemonToolHostSession.buildExecutePayload(
            tool: "bash", input: ["command": "ls"], origin: .proactive,
            securityOverride: nil, requestID: "th-2")
        XCTAssertEqual(proactive["origin"] as? String, "proactive")
    }

    // MARK: - Part A: security-denial messaging + tier classification

    func testSecretsTierClassificationAndMessage() {
        let target = fakeSecretsPath()
        XCTAssertEqual(SecurityTier.classify(absolutePath: target), .secrets)
        let denial = SecurityDenial(reason: "blocked", target: target, tier: .secrets)
        XCTAssertTrue(denial.overridable)
        XCTAssertTrue(denial.spokenMessage.contains("~/.secrets"),
                      "the message must name the protected path in ~ form: \(denial.spokenMessage)")
        XCTAssertTrue(denial.spokenMessage.lowercased().contains("security"))
        XCTAssertFalse(denial.spokenMessage.contains("✗"), "no opaque failure glyph")
    }

    func testFaeIntegrityTierNotOverridable() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let vault = home + "/" + ".fae-vault"
        XCTAssertEqual(SecurityTier.classify(absolutePath: vault), .faeIntegrity)
        let denial = SecurityDenial(reason: "blocked", target: vault, tier: .faeIntegrity)
        XCTAssertFalse(denial.overridable, "Fae-integrity is never overridable")
    }

    func testGrantStoreFileIsClassifiedFaeIntegrity() {
        // The grant store must be a never-path (L8) so no override can unlock it.
        XCTAssertEqual(
            SecurityTier.classify(absolutePath: FaeDirectories.grantStoreFile.path),
            .faeIntegrity)
    }

    // MARK: - L2 / L6 / L12: hardware-only one-shot card

    func testNeverTierShowsNoAllowButton() {
        XCTAssertEqual(SecurityOverridePrompt.allowedGrantKinds(for: .faeIntegrity), [])
        XCTAssertEqual(SecurityOverridePrompt.allowedGrantKinds(for: .secrets), [.once, .expiring])
        XCTAssertEqual(SecurityOverridePrompt.allowedGrantKinds(for: .general), [.once, .persistent])
        XCTAssertFalse(SecurityOverridePrompt.allowedGrantKinds(for: .secrets).contains(.persistent),
                       "Secrets tier must never offer a persistent 'always allow'")
    }

    func testConsentTextNamesSandboxExitAndFullCommand() {
        let denial = SecurityDenial(reason: "blocked", target: fakeSecretsPath(), tier: .secrets)
        let prompt = SecurityOverridePrompt(
            denial: denial, command: "cat ~/.secrets | grep TOKEN", timeoutSeconds: 5)
        let text = prompt.consentText
        XCTAssertTrue(text.lowercased().contains("outside") && text.lowercased().contains("sandbox"))
        XCTAssertTrue(text.contains("cat ~/.secrets | grep TOKEN"), "the FULL command must be shown verbatim")
        XCTAssertTrue(text.contains("Secrets"), "the tier must be named")
    }

    func testCardTimeoutResolvesDenyAndLateClickIsNoOp() async {
        let denial = SecurityDenial(reason: "blocked", target: fakeSecretsPath(), tier: .secrets)
        let prompt = SecurityOverridePrompt(denial: denial, command: "cat ~/.secrets", timeoutSeconds: 0.05)
        let decision = await prompt.result()
        XCTAssertEqual(decision, .deny, "the 10s (here 50ms) timeout resolves Deny")
        // A late click after the timeout must do nothing (one-shot, L6).
        XCTAssertFalse(prompt.approve(.once), "a late click after expiry is a no-op")
        XCTAssertFalse(prompt.deny(), "already resolved")
    }

    func testCardResolvesExactlyOnceOnApprove() async {
        let denial = SecurityDenial(reason: "blocked", target: fakeSecretsPath(), tier: .secrets)
        let prompt = SecurityOverridePrompt(denial: denial, command: "cat ~/.secrets", timeoutSeconds: 5)
        // Approve BEFORE awaiting (exercises the resolve-before-arm race path).
        XCTAssertTrue(prompt.approve(.once))
        XCTAssertFalse(prompt.approve(.expiring), "second click is a no-op")
        let decision = await prompt.result()
        XCTAssertEqual(decision, .allow(.once))
    }

    func testSecretsCardRejectsPersistentApproval() {
        let denial = SecurityDenial(reason: "blocked", target: fakeSecretsPath(), tier: .secrets)
        let prompt = SecurityOverridePrompt(denial: denial, command: "cat ~/.secrets", timeoutSeconds: 5)
        // A UI wiring bug offering "always" for Secrets must be refused at the model.
        XCTAssertFalse(prompt.approve(.persistent), "Secrets tier never grants a persistent override")
    }

    // MARK: - The re-submit security_override construction (wire contract)

    func testResubmitOverrideMatchesDaemonFieldsAndBindsCallId() {
        let target = fakeSecretsPath()
        let nowMs: UInt64 = 1_700_000_000_000
        let override = DaemonSecurityOverride.mint(
            target: target, tier: .secrets, kind: .expiring, nowMs: nowMs)
        // A Secrets 5-min grant mints the "expiring" wire kind with the right window.
        XCTAssertEqual(override.grantKindWire, "expiring")
        XCTAssertEqual(override.tierWire, "secrets")
        XCTAssertEqual(override.expiryMs, nowMs + DaemonSecurityOverride.expiringWindowMs)

        let payload = DaemonToolHostSession.buildExecutePayload(
            tool: "bash", input: ["command": "cat ~/.secrets"], origin: .ownerInteractive,
            securityOverride: override, requestID: "th-42")
        guard let so = payload["security_override"] as? [String: Any] else {
            return XCTFail("security_override sibling must be present on re-submit")
        }
        XCTAssertEqual(so["call_id"] as? String, "th-42", "call_id MUST equal the request id (L7)")
        XCTAssertEqual(so["target_path"] as? String, target, "target = the denied path (L4)")
        XCTAssertEqual(so["tier"] as? String, "secrets")
        XCTAssertEqual(so["grant_kind"] as? String, "expiring")
        XCTAssertEqual(so["expiry_ms"] as? UInt64, nowMs + DaemonSecurityOverride.expiringWindowMs)
        // The override rides a TOP-LEVEL sibling, never inside model-authored input.
        let input = payload["input"] as? [String: Any]
        XCTAssertNil(input?["security_override"], "override must never live inside `input`")
    }

    func testPersistentGrantMintsSingleUseOnceWireKind() {
        let nowMs: UInt64 = 1_700_000_000_000
        let override = DaemonSecurityOverride.mint(
            target: "/tmp/x", tier: .general, kind: .persistent, nowMs: nowMs)
        // Persistence lives in the GrantStore; the per-call directive is single-use.
        XCTAssertEqual(override.grantKindWire, "once")
        XCTAssertEqual(override.expiryMs, nowMs + DaemonSecurityOverride.onceWindowMs)
    }

    // MARK: - L8: grant-store integrity

    private func tempStorePath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-grant-test-\(UUID().uuidString)")
            .appendingPathComponent("grant-store.json")
    }

    func testGrantStoreWritesChmod0600AndKeysNarrowly() async throws {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let store = GrantStore(path: path)
        let target = "/Users/x/project/notes.txt"
        try await store.record(canonicalTarget: target, tier: .general, kind: .persistent, nowMs: 1)

        // chmod 0600.
        let perms = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600, "the grant store must be chmod 0600")

        // Narrow keying: only the exact canonical target matches; a sibling does not.
        let hit = await store.lookup(canonicalTarget: target, nowMs: 2)
        XCTAssertEqual(hit?.canonicalTarget, target)
        let miss = await store.lookup(canonicalTarget: "/Users/x/project/other.txt", nowMs: 2)
        XCTAssertNil(miss, "a grant authorizes ONE narrow path, never a sibling")
    }

    func testGrantStoreRejectsSymlinkedStore() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-grant-symlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A real store the attacker points the expected path at via a symlink.
        let real = dir.appendingPathComponent("real.json")
        try Data("[]".utf8).write(to: real)
        let link = dir.appendingPathComponent("grant-store.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let store = GrantStore(path: link)
        do {
            _ = try await store.loadStrict()
            XCTFail("a symlinked grant store must be rejected")
        } catch let e as GrantStore.GrantStoreError {
            XCTAssertEqual(e, .rejectedSymlink)
        }
        // The best-effort load fails closed to EMPTY (grants nothing).
        let grants = await store.load()
        XCTAssertTrue(grants.isEmpty, "a rejected store grants nothing (fail closed)")
    }

    func testGrantStoreRejectsMalformedAndTamperedRows() async throws {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A tampered row: a Secrets-tier PERSISTENT grant (forbidden — L8 guard).
        let tampered = #"[{"canonicalTarget":"/Users/x/.secrets","tier":"secrets","grantKind":"persistent","expiryMs":null}]"#
        try Data(tampered.utf8).write(to: path)
        let store = GrantStore(path: path)
        do {
            _ = try await store.loadStrict()
            XCTFail("a Secrets-tier persistent grant is malformed and must reject")
        } catch let e as GrantStore.GrantStoreError {
            XCTAssertEqual(e, .malformed)
        }
    }

    // MARK: - L9: interactive-only auto-apply

    func testAutoApplyOnlyOnInteractiveTurn() {
        let target = fakeSecretsPath()
        let denial = SecurityDenial(reason: "blocked", target: target, tier: .secrets)
        let grant = GrantStore.Grant(
            canonicalTarget: target, tier: "secrets", grantKind: "expiring",
            expiryMs: 2_000)
        // Interactive + unexpired ⇒ auto-mints an override.
        let ok = GrantStore.autoApplyOverride(
            grant: grant, denial: denial, origin: .ownerInteractive, nowMs: 1_000)
        XCTAssertNotNil(ok)
        XCTAssertEqual(ok?.targetPath, target)

        // A proactive turn NEVER auto-applies even with a live grant (L9/L1).
        XCTAssertNil(GrantStore.autoApplyOverride(
            grant: grant, denial: denial, origin: .proactive, nowMs: 1_000))
        XCTAssertNil(GrantStore.autoApplyOverride(
            grant: grant, denial: denial, origin: .scriptBlock, nowMs: 1_000))

        // An expired grant does not auto-apply even on an interactive turn.
        XCTAssertNil(GrantStore.autoApplyOverride(
            grant: grant, denial: denial, origin: .ownerInteractive, nowMs: 3_000))
    }

    func testAutoApplyRejectsTierMismatchAndFaeIntegrity() {
        let target = fakeSecretsPath()
        let secretsDenial = SecurityDenial(reason: "b", target: target, tier: .secrets)
        // A grant claiming "general" must not auto-apply against a Secrets denial.
        let mismatched = GrantStore.Grant(
            canonicalTarget: target, tier: "general", grantKind: "persistent", expiryMs: nil)
        XCTAssertNil(GrantStore.autoApplyOverride(
            grant: mismatched, denial: secretsDenial, origin: .ownerInteractive, nowMs: 1))

        // Fae-integrity denial is never overridable regardless of any grant.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let vaultDenial = SecurityDenial(
            reason: "b", target: home + "/.fae-vault", tier: .faeIntegrity)
        let anyGrant = GrantStore.Grant(
            canonicalTarget: home + "/.fae-vault", tier: "general", grantKind: "persistent", expiryMs: nil)
        XCTAssertNil(GrantStore.autoApplyOverride(
            grant: anyGrant, denial: vaultDenial, origin: .ownerInteractive, nowMs: 1))
    }
}
