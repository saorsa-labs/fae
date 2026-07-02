import CryptoKit
import Foundation

// MARK: - GateReceipt (P9/C4 W2)

/// A tamper-evident proof that a specific adapter artifact passed a real evaluation
/// gate. Bound to the exact artifact (content digest) and signed with a per-install
/// HMAC key held in the Keychain.
///
/// ## Threat model (local, single-user)
/// The owner already controls the machine, so the threat is NOT a motivated attacker
/// forging a row — it is **accidental re-opening** of the deploy gate (a future code
/// path, a stale row, a test helper leaking into prod). The controls are therefore:
/// - **single minting path** (`GateMinter.mint`) + an **evaluator allowlist** — only an
///   allowlisted evaluator can mint a receipt whose HMAC verifies;
/// - **HMAC tamper-evidence** with a key stored in the Keychain (NOT in `fae.db`), so a
///   copied/edited `.db` row cannot carry a valid signature;
/// - **content digest** bound at mint and re-checked at verify, closing the re-point gap;
/// - **gatePolicyVersion** so a change to the gate rule invalidates old receipts.
///
/// W4 makes `performDeploy` REQUIRE a verifying, unconsumed receipt; W7's evaluators are
/// the only callers of `GateMinter.mint`. This file is the machinery; it is not yet
/// wired into the live deploy path (that is W4).
struct GateReceipt: Codable, Sendable, Equatable {
    /// The cycle that produced the candidate (ties receipt → candidate).
    let cycleId: String
    /// The exact artifact this receipt certifies.
    let candidatePath: String
    /// The artifact kind — drives the digest algorithm and the deploy/engine routing.
    let kind: AdapterKind
    /// Content digest of the artifact at mint time (see `GateArtifactDigest`).
    let artifactDigest: String
    /// The measured correctness deltas that produced the pass (dimension → delta).
    let measured: [String: Double]
    /// The gate decision the receipt certifies, computed by `AdapterGate.decide` over
    /// `measured` at mint time. Only a `"pass"` receipt can verify; a receipt minted for a
    /// regressed candidate records its true (`"fail"`/`"concern"`) decision and is rejected.
    let decision: String
    /// The evaluator that produced the measurement — must be on the allowlist.
    let evaluatorId: String
    /// The baseline the candidate was evaluated AGAINST (the deployed adapter, or the
    /// base model if none) — guards against passing vs the wrong baseline.
    let baseModelId: String
    /// Version of the held-out eval set (drift guard).
    let evalSuiteVersion: String
    /// The gate-policy version in force at mint. A bump invalidates older receipts.
    let gatePolicyVersion: Int
    /// Receipt schema version (forward-compat).
    let receiptVersion: Int
    /// ISO-8601 mint timestamp.
    let mintedAt: String
    /// HMAC-SHA256 over the canonical encoding of every field above, hex-encoded.
    let hmac: String
}

// MARK: - Errors

enum GateReceiptError: Error, Equatable, CustomStringConvertible {
    case evaluatorNotAllowed(String)
    case artifactMissing(String)
    case symlinkInArtifact(String)
    case digestFailed(String)
    case keychainUnavailable
    case hmacMismatch
    case digestMismatch
    case candidateMismatch
    case stalePolicyVersion(found: Int, expected: Int)
    case wrongDecision(String)
    case measuredDeltasRejected
    case alreadyConsumed(String)

    var description: String {
        switch self {
        case .evaluatorNotAllowed(let id): return "evaluator not on allowlist: \(id)"
        case .artifactMissing(let p): return "artifact missing: \(p)"
        case .symlinkInArtifact(let p): return "symlink not allowed in adapter artifact: \(p)"
        case .digestFailed(let p): return "could not digest artifact: \(p)"
        case .keychainUnavailable: return "gate receipt HMAC key unavailable in Keychain"
        case .hmacMismatch: return "receipt HMAC does not verify (forged or tampered)"
        case .digestMismatch: return "artifact digest changed since mint (tampered or re-pointed)"
        case .candidateMismatch: return "receipt is for a different candidate path"
        case .stalePolicyVersion(let f, let e): return "receipt gatePolicyVersion \(f) != \(e)"
        case .wrongDecision(let d): return "receipt decision is not pass: \(d)"
        case .measuredDeltasRejected: return "receipt measured deltas do not pass the gate rule"
        case .alreadyConsumed(let c): return "gate receipt already consumed for cycle \(c)"
        }
    }
}

// MARK: - Policy constants

enum GatePolicy {
    /// Bump when `AdapterGate.decide` semantics change — invalidates older receipts.
    static let policyVersion = 1
    /// Receipt schema version.
    static let receiptVersion = 1
    /// Only these evaluators can mint a verifying receipt (the loss-proxy is absent by
    /// design, so it can never gate a deploy).
    static let allowedEvaluators: Set<String> = ["DaemonABEvaluator", "FaeBenchmarkEvaluator"]
}

// MARK: - Artifact digest

/// Computes a content digest for an adapter artifact. The digest is bound into the
/// receipt and re-checked at deploy, so a swapped/edited artifact fails verification.
enum GateArtifactDigest {
    static func digest(forPath path: String, kind: AdapterKind) throws -> String {
        switch kind {
        case .gguf: return try fileSHA256(path)
        case .mlxDir: return try directoryManifestSHA256(path)
        }
    }

    /// SHA-256 of a file's bytes, hex-encoded.
    static func fileSHA256(_ path: String) throws -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw GateReceiptError.artifactMissing(path)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical content manifest for an MLX adapter directory: every regular file's
    /// relative POSIX path + SHA-256, sorted by path, hashed together. Stable under
    /// directory-walk order; changes when any file changes. Symlinks are rejected (an
    /// adapter directory is plain files; a symlink could point outside the tree).
    static func directoryManifestSHA256(_ dirPath: String) throws -> String {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: dirPath).standardizedFileURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw GateReceiptError.artifactMissing(dirPath)
        }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw GateReceiptError.digestFailed(dirPath)
        }

        var entries: [(rel: String, sha: String)] = []
        let prefixCount = root.path.count + 1
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw GateReceiptError.symlinkInArtifact(url.path)
            }
            guard values.isRegularFile == true else { continue }
            let standardized = url.standardizedFileURL.path
            guard standardized.count > prefixCount else { continue }
            let rel = String(standardized.dropFirst(prefixCount))
            entries.append((rel, try fileSHA256(standardized)))
        }
        entries.sort { $0.rel < $1.rel }

        // NUL is the field separator; POSIX filenames cannot contain NUL, so a relpath
        // can never inject a separator and forge a different manifest with the same bytes.
        var hasher = SHA256()
        for entry in entries {
            hasher.update(data: Data("\(entry.rel)\u{0}\(entry.sha)\u{0}".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Signing payload + crypto

/// Every field of `GateReceipt` EXCEPT the hmac, in a Codable form whose canonical
/// (sorted-keys) JSON is the signed message.
private struct GateReceiptPayload: Codable {
    let cycleId: String
    let candidatePath: String
    let kind: String
    let artifactDigest: String
    let measured: [String: Double]
    let decision: String
    let evaluatorId: String
    let baseModelId: String
    let evalSuiteVersion: String
    let gatePolicyVersion: Int
    let receiptVersion: Int
    let mintedAt: String

    init(from receipt: GateReceipt) {
        cycleId = receipt.cycleId
        candidatePath = receipt.candidatePath
        kind = receipt.kind.rawValue
        artifactDigest = receipt.artifactDigest
        measured = receipt.measured
        decision = receipt.decision
        evaluatorId = receipt.evaluatorId
        baseModelId = receipt.baseModelId
        evalSuiteVersion = receipt.evalSuiteVersion
        gatePolicyVersion = receipt.gatePolicyVersion
        receiptVersion = receipt.receiptVersion
        mintedAt = receipt.mintedAt
    }
}

enum GateReceiptCrypto {
    /// Keychain item name for the per-install HMAC key.
    private static let keychainItem = "p9.gate_receipt.hmac_key.v1"

    /// Fetch (or lazily create + store) the per-install HMAC key. The key lives in the
    /// Keychain, never in `fae.db`, so a copied/edited database row cannot carry a valid
    /// signature. Production callers (W4/W7) resolve the key once; unit tests pass a
    /// fixed key to the `using:` overloads to avoid Keychain access.
    static func keychainKey() throws -> SymmetricKey {
        if let b64 = CredentialManager.retrieve(key: keychainItem),
           let data = Data(base64Encoded: b64), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        do {
            try CredentialManager.store(key: keychainItem, value: raw.base64EncodedString())
        } catch {
            throw GateReceiptError.keychainUnavailable
        }
        return key
    }

    /// HMAC-SHA256 over the canonical (sorted-keys) encoding of a payload, hex-encoded.
    fileprivate static func sign(_ payload: GateReceiptPayload, using key: SymmetricKey) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let message = try encoder.encode(payload)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Minter (single privileged path)

/// The ONLY path that produces a verifying `GateReceipt`. Callers must be
/// `AdapterEvaluator` conformers (W7); the allowlist enforces that a receipt minted for
/// a non-allowlisted evaluator (e.g. the loss-proxy) can never verify.
///
/// > NOTE (threat model): the **allowlist is the privilege boundary, not a module
/// > boundary** — any in-process code that supplies an allowlisted `evaluatorId` can mint.
/// > This is acceptable for the stated threat model (accidental re-opening of the gate,
/// > NOT a motivated in-process attacker, who already controls the machine). W7 makes the
/// > real evaluators the only callers; W4 makes a verifying + unconsumed receipt mandatory
/// > at the deploy boundary. The HMAC (Keychain key) + content digest are the
/// > tamper-evidence layer against an edited `fae.db` row.
enum GateMinter {
    /// Mint a signed pass-receipt for an evaluated candidate, using the per-install
    /// Keychain key. Production convenience (W7).
    static func mint(
        cycleId: String,
        candidatePath: String,
        kind: AdapterKind,
        measured: [GateDimension: Double],
        evaluatorId: String,
        baseModelId: String,
        evalSuiteVersion: String,
        mintedAt: String
    ) throws -> GateReceipt {
        try mint(
            cycleId: cycleId, candidatePath: candidatePath, kind: kind, measured: measured,
            evaluatorId: evaluatorId, baseModelId: baseModelId,
            evalSuiteVersion: evalSuiteVersion, mintedAt: mintedAt,
            using: try GateReceiptCrypto.keychainKey()
        )
    }

    /// Mint with an explicit HMAC key (unit tests pass a fixed key; production uses the
    /// Keychain convenience above).
    static func mint(
        cycleId: String,
        candidatePath: String,
        kind: AdapterKind,
        measured: [GateDimension: Double],
        evaluatorId: String,
        baseModelId: String,
        evalSuiteVersion: String,
        mintedAt: String,
        using key: SymmetricKey
    ) throws -> GateReceipt {
        guard GatePolicy.allowedEvaluators.contains(evaluatorId) else {
            throw GateReceiptError.evaluatorNotAllowed(evaluatorId)
        }
        let digest = try GateArtifactDigest.digest(forPath: candidatePath, kind: kind)
        let measuredStrings = Dictionary(
            uniqueKeysWithValues: measured.map { ($0.key.rawValue, $0.value) }
        )
        // Record the REAL gate decision over the measured deltas — never a hardcoded
        // "pass". A receipt minted for a regressed candidate carries its true decision,
        // so the verifier's `decision == "pass"` guard rejects it even if a future bug
        // reaches this mint for a non-passing candidate.
        let decision = AdapterGate.decide(
            MeasuredDeltas(measured: measured, throughputDelta: nil)
        ).rawValue
        func receipt(hmac: String) -> GateReceipt {
            GateReceipt(
                cycleId: cycleId, candidatePath: candidatePath, kind: kind,
                artifactDigest: digest, measured: measuredStrings, decision: decision,
                evaluatorId: evaluatorId, baseModelId: baseModelId,
                evalSuiteVersion: evalSuiteVersion,
                gatePolicyVersion: GatePolicy.policyVersion,
                receiptVersion: GatePolicy.receiptVersion,
                mintedAt: mintedAt, hmac: hmac
            )
        }
        let hmac = try GateReceiptCrypto.sign(GateReceiptPayload(from: receipt(hmac: "")), using: key)
        return receipt(hmac: hmac)
    }
}

// MARK: - Verifier

/// Verifies a receipt at the deploy boundary (used by W4). All checks fail closed.
enum GateReceiptVerifier {
    /// Verify that `receipt` authorizes deploying the artifact at `expectedCandidatePath`.
    /// Checks (in order): decision is pass, the measured deltas independently PASS the gate
    /// rule, evaluator allowlist, gate-policy version, candidate-path match, HMAC signature,
    /// and the on-disk artifact digest. Re-deciding the gate over the receipt's own measured
    /// deltas means a receipt for a regressed candidate can NEVER verify — even if a future
    /// minting bug stamped `decision:"pass"` onto it.
    /// Single-use (consumed) enforcement is done against the store by the caller (W4).
    static func verify(_ receipt: GateReceipt, expectedCandidatePath: String) throws {
        try verify(receipt, expectedCandidatePath: expectedCandidatePath, using: try GateReceiptCrypto.keychainKey())
    }

    /// Verify with an explicit HMAC key (unit tests pass a fixed key).
    static func verify(_ receipt: GateReceipt, expectedCandidatePath: String, using key: SymmetricKey) throws {
        guard receipt.decision == "pass" else {
            throw GateReceiptError.wrongDecision(receipt.decision)
        }
        // Re-run the fail-closed gate rule over the receipt's OWN measured deltas. The
        // stored `decision` is not trusted on its own: a receipt whose measured deltas
        // carry a regression (or an incomplete measurement) is rejected here regardless
        // of what the `decision` field claims.
        guard recomputedGatePasses(receipt.measured) else {
            throw GateReceiptError.measuredDeltasRejected
        }
        guard GatePolicy.allowedEvaluators.contains(receipt.evaluatorId) else {
            throw GateReceiptError.evaluatorNotAllowed(receipt.evaluatorId)
        }
        guard receipt.gatePolicyVersion == GatePolicy.policyVersion else {
            throw GateReceiptError.stalePolicyVersion(
                found: receipt.gatePolicyVersion, expected: GatePolicy.policyVersion
            )
        }
        guard receipt.candidatePath == expectedCandidatePath else {
            throw GateReceiptError.candidateMismatch
        }
        let expectedHmac = try GateReceiptCrypto.sign(GateReceiptPayload(from: receipt), using: key)
        // Constant-time-ish compare over equal-length hex strings.
        guard constantTimeEquals(expectedHmac, receipt.hmac) else {
            throw GateReceiptError.hmacMismatch
        }
        let onDiskDigest = try GateArtifactDigest.digest(
            forPath: receipt.candidatePath, kind: receipt.kind
        )
        guard onDiskDigest == receipt.artifactDigest else {
            throw GateReceiptError.digestMismatch
        }
    }

    /// Re-decide the gate over a receipt's stored (string-keyed) measured deltas. Unknown
    /// dimension keys are dropped, which makes the measurement incomplete and fails closed.
    private static func recomputedGatePasses(_ measured: [String: Double]) -> Bool {
        var dims: [GateDimension: Double] = [:]
        for (key, value) in measured {
            guard let dim = GateDimension(rawValue: key) else { continue }
            dims[dim] = value
        }
        return AdapterGate.decide(MeasuredDeltas(measured: dims, throughputDelta: nil)) == .pass
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count { diff |= aBytes[i] ^ bBytes[i] }
        return diff == 0
    }
}
