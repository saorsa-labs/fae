import CryptoKit
import XCTest
@testable import Fae

/// P9/C4 (W2) — gate receipt machinery: artifact digest, mint/verify (HMAC + allowlist),
/// and persistence. Uses a fixed key via the `using:` overloads to avoid Keychain access.
final class GateReceiptTests: XCTestCase {

    private let testKey = SymmetricKey(data: Data(repeating: 0x42, count: 32))

    // MARK: - Helpers

    private func tempFile(_ contents: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-gr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("adapter.gguf").path
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Create a directory of files (keys are relative paths, possibly nested).
    private func tempDir(files: [(String, String)]) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-grdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (rel, contents) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root.path
    }

    private func mint(
        cycleId: String = "cycle-1",
        path: String,
        kind: AdapterKind = .gguf,
        evaluatorId: String = "DaemonABEvaluator"
    ) throws -> GateReceipt {
        try GateMinter.mint(
            cycleId: cycleId, candidatePath: path, kind: kind,
            measured: [.toolCalling: 3.0, .faeCapability: 1.0, .assistantFit: 2.0, .serialization: 0.0],
            evaluatorId: evaluatorId, baseModelId: "gemma-4-e4b",
            evalSuiteVersion: "suite-v1", mintedAt: "2026-06-21T00:00:00Z",
            using: testKey
        )
    }

    // MARK: - Artifact digest

    func testFileDigestIsStableAndContentSensitive() throws {
        let path = try tempFile("hello gguf bytes")
        let d1 = try GateArtifactDigest.digest(forPath: path, kind: .gguf)
        let d2 = try GateArtifactDigest.digest(forPath: path, kind: .gguf)
        XCTAssertEqual(d1, d2, "digest is deterministic")
        try "hello gguf bytes!".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(d1, try GateArtifactDigest.digest(forPath: path, kind: .gguf),
                          "digest changes when bytes change")
    }

    func testDirManifestIsOrderIndependentAndContentSensitive() throws {
        // Same content, different file-creation order → same manifest.
        let dirA = try tempDir(files: [("a.bin", "1"), ("nested/c.bin", "2")])
        let dirB = try tempDir(files: [("nested/c.bin", "2"), ("a.bin", "1")])
        XCTAssertEqual(
            try GateArtifactDigest.digest(forPath: dirA, kind: .mlxDir),
            try GateArtifactDigest.digest(forPath: dirB, kind: .mlxDir),
            "manifest is independent of directory-walk order"
        )
        // One file's content changes → different manifest.
        let dirC = try tempDir(files: [("a.bin", "1"), ("nested/c.bin", "CHANGED")])
        XCTAssertNotEqual(
            try GateArtifactDigest.digest(forPath: dirA, kind: .mlxDir),
            try GateArtifactDigest.digest(forPath: dirC, kind: .mlxDir)
        )
    }

    func testDirManifestRejectsSymlink() throws {
        let dir = try tempDir(files: [("a.bin", "1")])
        let link = URL(fileURLWithPath: dir).appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: "/etc/passwd")
        )
        XCTAssertThrowsError(try GateArtifactDigest.digest(forPath: dir, kind: .mlxDir)) { error in
            guard case GateReceiptError.symlinkInArtifact = error else {
                return XCTFail("expected symlinkInArtifact, got \(error)")
            }
        }
    }

    // MARK: - Mint + verify

    func testMintVerifyRoundtrip() throws {
        let path = try tempFile("adapter weights")
        let receipt = try mint(path: path)
        XCTAssertEqual(receipt.decision, "pass")
        XCTAssertNoThrow(try GateReceiptVerifier.verify(receipt, expectedCandidatePath: path, using: testKey))
    }

    func testMintRejectsNonAllowlistedEvaluator() throws {
        let path = try tempFile("adapter")
        XCTAssertThrowsError(try mint(path: path, evaluatorId: "loss_proxy")) { error in
            guard case GateReceiptError.evaluatorNotAllowed = error else {
                return XCTFail("expected evaluatorNotAllowed, got \(error)")
            }
        }
    }

    func testForgedHmacRejected() throws {
        let path = try tempFile("adapter")
        let receipt = try mint(path: path)
        let forged = GateReceipt(
            cycleId: receipt.cycleId, candidatePath: receipt.candidatePath, kind: receipt.kind,
            artifactDigest: receipt.artifactDigest, measured: receipt.measured, decision: receipt.decision,
            evaluatorId: receipt.evaluatorId, baseModelId: receipt.baseModelId,
            evalSuiteVersion: receipt.evalSuiteVersion, gatePolicyVersion: receipt.gatePolicyVersion,
            receiptVersion: receipt.receiptVersion, mintedAt: receipt.mintedAt,
            hmac: "00000000000000000000000000000000"
        )
        XCTAssertThrowsError(try GateReceiptVerifier.verify(forged, expectedCandidatePath: path, using: testKey)) { error in
            guard case GateReceiptError.hmacMismatch = error else {
                return XCTFail("expected hmacMismatch, got \(error)")
            }
        }
    }

    func testWrongKeyRejected() throws {
        let path = try tempFile("adapter")
        let receipt = try mint(path: path)
        let otherKey = SymmetricKey(data: Data(repeating: 0x99, count: 32))
        XCTAssertThrowsError(try GateReceiptVerifier.verify(receipt, expectedCandidatePath: path, using: otherKey)) { error in
            guard case GateReceiptError.hmacMismatch = error else {
                return XCTFail("expected hmacMismatch, got \(error)")
            }
        }
    }

    func testCandidateMismatchRejected() throws {
        let path = try tempFile("adapter")
        let receipt = try mint(path: path)
        XCTAssertThrowsError(try GateReceiptVerifier.verify(receipt, expectedCandidatePath: "/some/other/path", using: testKey)) { error in
            guard case GateReceiptError.candidateMismatch = error else {
                return XCTFail("expected candidateMismatch, got \(error)")
            }
        }
    }

    func testDigestMismatchAfterTamper() throws {
        let path = try tempFile("adapter")
        let receipt = try mint(path: path)
        // Mutate the artifact AFTER minting — the re-pointed/edited file must fail verify.
        try "tampered weights".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try GateReceiptVerifier.verify(receipt, expectedCandidatePath: path, using: testKey)) { error in
            guard case GateReceiptError.digestMismatch = error else {
                return XCTFail("expected digestMismatch, got \(error)")
            }
        }
    }

    func testStalePolicyVersionRejected() throws {
        let path = try tempFile("adapter")
        let receipt = try mint(path: path)
        // A receipt minted under a future policy version is invalid now (policy bump
        // invalidates old receipts). Checked before HMAC, so the hmac value is irrelevant.
        let stale = GateReceipt(
            cycleId: receipt.cycleId, candidatePath: receipt.candidatePath, kind: receipt.kind,
            artifactDigest: receipt.artifactDigest, measured: receipt.measured, decision: receipt.decision,
            evaluatorId: receipt.evaluatorId, baseModelId: receipt.baseModelId,
            evalSuiteVersion: receipt.evalSuiteVersion,
            gatePolicyVersion: receipt.gatePolicyVersion + 1,
            receiptVersion: receipt.receiptVersion, mintedAt: receipt.mintedAt, hmac: receipt.hmac
        )
        XCTAssertThrowsError(try GateReceiptVerifier.verify(stale, expectedCandidatePath: path, using: testKey)) { error in
            guard case GateReceiptError.stalePolicyVersion = error else {
                return XCTFail("expected stalePolicyVersion, got \(error)")
            }
        }
    }

    func testMintRecordsRealDecisionForRegression() throws {
        let path = try tempFile("adapter")
        // A candidate with a > 5% regression must mint a receipt that records the REAL
        // decision ("fail"), never a hardcoded "pass" — so the deploy-time verifier's
        // decision guard rejects it.
        let receipt = try GateMinter.mint(
            cycleId: "cycle-1", candidatePath: path, kind: .gguf,
            measured: [.toolCalling: -10.0, .faeCapability: 1.0, .assistantFit: 2.0, .serialization: 0.0],
            evaluatorId: "DaemonABEvaluator", baseModelId: "gemma-4-e4b",
            evalSuiteVersion: "suite-v1", mintedAt: "2026-06-21T00:00:00Z", using: testKey
        )
        XCTAssertEqual(receipt.decision, "fail", "minter records the true gate decision, not a hardcoded pass")
        XCTAssertThrowsError(try GateReceiptVerifier.verify(receipt, expectedCandidatePath: path, using: testKey)) { error in
            guard case GateReceiptError.wrongDecision = error else {
                return XCTFail("expected wrongDecision, got \(error)")
            }
        }
    }

    func testReceiptWithRegressedMeasuredDeltasFailsVerification() throws {
        let path = try tempFile("adapter")
        let digest = try GateArtifactDigest.digest(forPath: path, kind: .gguf)
        // Model a (hypothetical future) minting bug: a receipt that CLAIMS decision "pass"
        // while its measured deltas carry a > 5% regression. The verifier re-runs
        // AdapterGate over the receipt's own measured deltas and rejects it BEFORE the HMAC
        // check — so it can never verify, even though the decision field lies. The HMAC is
        // deliberately garbage to prove the recompute guard fires first.
        let regressed = GateReceipt(
            cycleId: "cycle-1", candidatePath: path, kind: .gguf,
            artifactDigest: digest,
            measured: ["toolCalling": -10.0, "faeCapability": 1.0, "assistantFit": 2.0, "serialization": 0.0],
            decision: "pass",
            evaluatorId: "DaemonABEvaluator", baseModelId: "gemma-4-e4b",
            evalSuiteVersion: "suite-v1", gatePolicyVersion: GatePolicy.policyVersion,
            receiptVersion: GatePolicy.receiptVersion, mintedAt: "2026-06-21T00:00:00Z",
            hmac: "00000000000000000000000000000000"
        )
        XCTAssertThrowsError(try GateReceiptVerifier.verify(regressed, expectedCandidatePath: path, using: testKey)) { error in
            guard case GateReceiptError.measuredDeltasRejected = error else {
                return XCTFail("expected measuredDeltasRejected, got \(error)")
            }
        }
    }

    // MARK: - Persistence

    private func makeTempStore() async throws -> ImprovementStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ImprovementStore()
        try await store.open(at: dir.appendingPathComponent("improvement.db"))
        try await store.ensureStateRow()
        return store
    }

    func testReceiptPersistenceRoundtripAndSingleUseConsume() async throws {
        let store = try await makeTempStore()
        let path = try tempFile("adapter")
        let receipt = try mint(cycleId: "cycle-42", path: path)

        try await store.insertGateReceipt(receipt)
        let fetched = try await store.gateReceipt(forCycleId: "cycle-42")
        XCTAssertEqual(fetched, receipt, "receipt round-trips through the store unchanged")

        let consumedBefore = try await store.isGateReceiptConsumed(cycleId: "cycle-42")
        XCTAssertFalse(consumedBefore)
        try await store.consumeGateReceipt(cycleId: "cycle-42", at: "2026-06-21T01:00:00Z")
        let consumedAfter = try await store.isGateReceiptConsumed(cycleId: "cycle-42")
        XCTAssertTrue(consumedAfter, "consume marks the receipt single-use")

        // A fetched, consumed receipt still verifies cryptographically — single-use is
        // enforced by the store flag, which the deploy gate (W4) checks separately.
        XCTAssertNoThrow(try GateReceiptVerifier.verify(fetched!, expectedCandidatePath: path, using: testKey))
    }

    func testMissingReceiptReturnsNil() async throws {
        let store = try await makeTempStore()
        let absent = try await store.gateReceipt(forCycleId: "nope")
        XCTAssertNil(absent)
        let consumed = try await store.isGateReceiptConsumed(cycleId: "nope")
        XCTAssertFalse(consumed)
    }
}
