//! Phase E — real ML-DSA-65 peer-envelope signing + verification.
//!
//! ## Key model (who holds what)
//!
//! The daemon's peer identity IS its local x0xd agent identity: x0xd owns the
//! ML-DSA-65 keypair and never releases the secret key. Outbound envelopes are
//! therefore signed **through x0xd** (`POST /agent/sign`, the same mechanism
//! `x0x-symphony-signing::X0xdClient` uses), while inbound envelopes are
//! verified **locally** with `saorsa-pqc` — verification needs only public
//! material, must be synchronous (the gate's [`SignatureVerifier`] trait is
//! sync), and must not depend on x0xd being reachable. saorsa-pqc is the exact
//! crate x0xd signs with (via ant-quic), so sign/verify are bit-compatible by
//! construction.
//!
//! ## What is signed (canonical bytes + DST)
//!
//! The signature covers x0xd's *external* domain-separated string:
//!
//! ```text
//! [0xF0] || b"x0x.external-agent-sign.v1" || len(context):u32 BE || context || payload
//! ```
//!
//! mirrored byte-for-byte from x0x `src/api/agent_signing.rs::assemble_buffer`
//! (v0.32.0) in [`assemble_external_dst`] — x0xd assembles it server-side on
//! sign, the daemon assembles it locally on verify. `context` is
//! [`PEER_ENVELOPE_SIGN_CONTEXT`]; `payload` is the canonical envelope bytes
//! from [`fae_envelope_gate::envelope_signing_bytes`] (every envelope field
//! except `signature`, compact JSON, recursively sorted keys). Signer and
//! verifier share those two functions — there is no second canonicalization.
//!
//! ## Sender ↔ public-key binding
//!
//! The envelope's `signature.public_key_id` carries the sender's RAW
//! ML-DSA-65 public key (1952 bytes; org key canon — base64 is transport
//! only). That embedded key is trustworthy because the x0x agent id is
//! *derived from it*: `agent_id = SHA-256("AUTONOMI_PEER_ID_V2:" || pk)`
//! (x0x `src/identity.rs::AgentId::from_public_key` → ant-quic
//! `derive_peer_id_from_public_key`). Verification enforces
//! `derive_agent_id_hex(pk) == envelope.sender_id`, and the ingress
//! additionally cross-checks `envelope.sender_id` against the
//! transport-attested SSE `sender` — so a forged key cannot claim an
//! allowlisted identity, and a real signature cannot be replayed under a
//! different sender.
//!
//! ## Layering (defense in depth)
//!
//! x0xd already verifies the sender's transport signature on delivery
//! (`verified: true` + `trust_decision` on the SSE frame; dropped pre-gate
//! otherwise). This module adds the END-TO-END layer on top: the envelope
//! *content* is bound to the sender identity even if x0xd, the SSE channel,
//! or a relaying node were compromised. No trust-upgrade behavior lives here —
//! allowlists (`FAE_X0X_ALLOW`/`FAE_X0X_OWNER_FLEET`) remain config-owned.

use base64::Engine as _;
use fae_envelope_gate::SignatureProof;
use saorsa_pqc::{MlDsa65, MlDsaOperations, MlDsaPublicKey, MlDsaSignature};
use sha2::{Digest, Sha256};

/// Domain-separation context for Fae peer envelopes, passed to x0xd's
/// `/agent/sign` and reproduced locally on verify. Distinct from every other
/// x0x/symphony context, so a peer-envelope signature can never double as a
/// symphony claim/handoff (and vice versa).
pub const PEER_ENVELOPE_SIGN_CONTEXT: &str = "fae-peer-envelope-v1";

/// The wire `algorithm` string inside peer envelopes (schema v1 — unchanged
/// for interop with pre-signing peers, whose verifiers check this exact
/// value).
pub const ENVELOPE_SIGN_ALGORITHM: &str = "ml-dsa-65";

/// x0xd's external-signing scheme id, echoed in every `/agent/sign` response.
/// A response advertising anything else is rejected fail-closed.
pub const X0X_SIGN_SCHEME: &str = "x0x.agent-sign.v2.ml-dsa-65";

/// Org key canon: raw ML-DSA-65 public key / signature sizes in bytes.
pub const ML_DSA_65_PUBLIC_KEY_LEN: usize = 1952;
pub const ML_DSA_65_SIGNATURE_LEN: usize = 3309;

/// Reserved namespace tag + layout magic of x0xd's external signing DST.
/// Provenance: x0x `src/api/agent_signing.rs` (`NAMESPACE_TAG`, `MAGIC`),
/// v0.32.0. Any layout change upstream bumps the magic's `.v1`, which makes
/// verification here fail CLOSED rather than silently accept.
const X0X_EXTERNAL_NAMESPACE_TAG: u8 = 0xF0;
const X0X_EXTERNAL_MAGIC: &[u8] = b"x0x.external-agent-sign.v1";

/// Domain prefix of the x0x agent-id derivation (ant-quic
/// `derive_peer_id_from_public_key`).
const AGENT_ID_DOMAIN_PREFIX: &[u8] = b"AUTONOMI_PEER_ID_V2:";

/// Assemble x0xd's external signing buffer
/// `[0xF0] || magic || len(context):u32 BE || context || payload` —
/// byte-for-byte mirror of x0x `agent_signing::assemble_buffer` (see module
/// docs for why the mirror is safe).
pub fn assemble_external_dst(context: &str, payload: &[u8]) -> Vec<u8> {
    let mut buf =
        Vec::with_capacity(1 + X0X_EXTERNAL_MAGIC.len() + 4 + context.len() + payload.len());
    buf.push(X0X_EXTERNAL_NAMESPACE_TAG);
    buf.extend_from_slice(X0X_EXTERNAL_MAGIC);
    let len = u32::try_from(context.len()).unwrap_or(u32::MAX);
    buf.extend_from_slice(&len.to_be_bytes());
    buf.extend_from_slice(context.as_bytes());
    buf.extend_from_slice(payload);
    buf
}

/// Derive the x0x agent id (lowercase 64-hex) from raw ML-DSA-65 public-key
/// bytes: `hex(SHA-256("AUTONOMI_PEER_ID_V2:" || pk))`.
pub fn derive_agent_id_hex(public_key: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(AGENT_ID_DOMAIN_PREFIX);
    hasher.update(public_key);
    hex::encode(hasher.finalize())
}

/// Verify a peer envelope's ML-DSA-65 signature against its canonical signing
/// bytes and its claimed sender. FAIL CLOSED: every malformed, missing,
/// placeholder, wrong-length, unbound, or cryptographically invalid input
/// returns `false` — there is no error channel to fail open through.
///
/// The full chain:
/// 1. `algorithm == "ml-dsa-65"`;
/// 2. `public_key_id` base64-decodes to exactly 1952 raw key bytes;
/// 3. binding — `derive_agent_id_hex(pk) == sender_id` (case-insensitive hex);
/// 4. `signature_b64` base64-decodes to exactly 3309 signature bytes;
/// 5. ML-DSA-65 verify over `assemble_external_dst(context, signing_bytes)`.
pub fn verify_envelope_signature(
    signature: &SignatureProof,
    signing_bytes: &[u8],
    sender_id: &str,
) -> bool {
    if signature.algorithm() != ENVELOPE_SIGN_ALGORITHM {
        return false;
    }
    let Ok(pk_bytes) =
        base64::engine::general_purpose::STANDARD.decode(signature.public_key_id().as_bytes())
    else {
        return false;
    };
    if pk_bytes.len() != ML_DSA_65_PUBLIC_KEY_LEN {
        return false;
    }
    if !derive_agent_id_hex(&pk_bytes).eq_ignore_ascii_case(sender_id) {
        return false;
    }
    let Ok(sig_bytes) =
        base64::engine::general_purpose::STANDARD.decode(signature.signature_b64().as_bytes())
    else {
        return false;
    };
    if sig_bytes.len() != ML_DSA_65_SIGNATURE_LEN {
        return false;
    }
    let Ok(public_key) = MlDsaPublicKey::from_bytes(&pk_bytes) else {
        return false;
    };
    let Ok(ml_dsa_signature) = MlDsaSignature::from_bytes(&sig_bytes) else {
        return false;
    };
    let message = assemble_external_dst(PEER_ENVELOPE_SIGN_CONTEXT, signing_bytes);
    matches!(
        MlDsa65::new().verify(&public_key, &message, &ml_dsa_signature),
        Ok(true)
    )
}

/// The signature material an x0xd `/agent/sign` call yields for one envelope.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvelopeSignature {
    /// Base64 of the RAW 1952-byte ML-DSA-65 public key — goes into the
    /// envelope's `public_key_id` field (the binding carrier, see module docs).
    pub public_key_b64: String,
    /// Base64 detached ML-DSA-65 signature — goes into `signature_b64`.
    pub signature_b64: String,
}

/// Validate an x0xd `/agent/sign` response against OUR identity before its
/// signature is ever embedded in an outbound envelope. FAIL CLOSED on any
/// mismatch: a signature x0xd produced under an unexpected scheme, context, or
/// identity must never leave this node inside a Fae envelope.
pub fn validate_sign_response(
    response: &super::x0x_client::AgentSignResponse,
    own_agent_id: &str,
) -> Result<EnvelopeSignature, String> {
    if response.algorithm != X0X_SIGN_SCHEME {
        return Err(format!(
            "x0xd signed with unexpected scheme {:?} (expected {X0X_SIGN_SCHEME:?})",
            response.algorithm
        ));
    }
    if response.context != PEER_ENVELOPE_SIGN_CONTEXT {
        return Err(format!(
            "x0xd echoed unexpected signing context {:?}",
            response.context
        ));
    }
    if !response.agent_id.eq_ignore_ascii_case(own_agent_id) {
        return Err(format!(
            "x0xd signed as agent {} but this node is {own_agent_id}",
            response.agent_id
        ));
    }
    let pk_bytes = base64::engine::general_purpose::STANDARD
        .decode(response.public_key_b64.as_bytes())
        .map_err(|error| format!("x0xd public key is not valid base64: {error}"))?;
    if pk_bytes.len() != ML_DSA_65_PUBLIC_KEY_LEN {
        return Err(format!(
            "x0xd public key is {} bytes (expected {ML_DSA_65_PUBLIC_KEY_LEN})",
            pk_bytes.len()
        ));
    }
    if !derive_agent_id_hex(&pk_bytes).eq_ignore_ascii_case(own_agent_id) {
        return Err("x0xd public key does not derive our own agent id".to_owned());
    }
    Ok(EnvelopeSignature {
        public_key_b64: response.public_key_b64.clone(),
        signature_b64: response.signature_b64.clone(),
    })
}

/// Base64 (standard, padded) length for `n` raw bytes — used to size the
/// exact-length placeholders the handoff fit-loop uses before the real
/// signature exists.
pub const fn base64_len(raw_len: usize) -> usize {
    raw_len.div_ceil(3) * 4
}

#[cfg(test)]
pub(crate) mod test_support {
    //! Real-crypto fixtures for peer tests: a generated ML-DSA-65 identity
    //! whose agent id is honestly derived from the public key, plus a signer
    //! that mirrors x0xd's `/agent/sign` (DST assembly + ML-DSA-65 sign) so
    //! strict-mode tests exercise the exact verify path with NO mocks.

    use super::*;
    use saorsa_pqc::MlDsaSecretKey;

    pub struct TestIdentity {
        pub agent_id: String,
        pub public_key_b64: String,
        secret_key: MlDsaSecretKey,
    }

    impl TestIdentity {
        pub fn generate() -> TestIdentity {
            let (public_key, secret_key) =
                MlDsa65::new().generate_keypair().expect("ML-DSA-65 keygen");
            let pk_bytes = public_key.as_bytes().to_vec();
            TestIdentity {
                agent_id: derive_agent_id_hex(&pk_bytes),
                public_key_b64: base64::engine::general_purpose::STANDARD.encode(&pk_bytes),
                secret_key,
            }
        }

        /// Sign canonical envelope bytes exactly as x0xd does: assemble the
        /// external DST for [`PEER_ENVELOPE_SIGN_CONTEXT`], then ML-DSA-65.
        pub fn sign_signing_bytes(&self, signing_bytes: &[u8]) -> String {
            let message = assemble_external_dst(PEER_ENVELOPE_SIGN_CONTEXT, signing_bytes);
            let signature = MlDsa65::new()
                .sign(&self.secret_key, &message)
                .expect("ML-DSA-65 sign");
            base64::engine::general_purpose::STANDARD.encode(signature.as_bytes())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::TestIdentity;
    use super::*;
    use fae_envelope_gate::{envelope_signing_bytes, EnvelopeKind, SUPPORTED_SCHEMA_VERSION};

    fn signing_bytes_for(sender_id: &str, text: &str) -> Vec<u8> {
        envelope_signing_bytes(
            SUPPORTED_SCHEMA_VERSION,
            &EnvelopeKind::DirectMessage,
            "env-1",
            sender_id,
            1_700_000_000_000,
            &serde_json::json!({ "text": text }),
        )
    }

    fn proof(public_key_id: &str, signature_b64: &str) -> SignatureProof {
        proof_with_algorithm(ENVELOPE_SIGN_ALGORITHM, public_key_id, signature_b64)
    }

    /// The gate never exposes a SignatureProof constructor; round-trip one
    /// through serde the way the wire does.
    fn proof_with_algorithm(
        algorithm: &str,
        public_key_id: &str,
        signature_b64: &str,
    ) -> SignatureProof {
        serde_json::from_value(serde_json::json!({
            "algorithm": algorithm,
            "public_key_id": public_key_id,
            "signature_b64": signature_b64,
        }))
        .expect("valid SignatureProof JSON")
    }

    #[test]
    fn dst_layout_matches_x0xd_byte_for_byte() {
        // Provenance test for the mirrored DST: [0xF0] | magic | len | ctx | payload.
        let dst = assemble_external_dst("ctx", b"payload");
        let mut expected = vec![0xF0u8];
        expected.extend_from_slice(b"x0x.external-agent-sign.v1");
        expected.extend_from_slice(&3u32.to_be_bytes());
        expected.extend_from_slice(b"ctx");
        expected.extend_from_slice(b"payload");
        assert_eq!(dst, expected);
    }

    #[test]
    fn sign_verify_round_trip_with_real_ml_dsa() {
        let identity = TestIdentity::generate();
        let bytes = signing_bytes_for(&identity.agent_id, "hello peer");
        let signature_b64 = identity.sign_signing_bytes(&bytes);
        let proof = proof(&identity.public_key_b64, &signature_b64);
        assert!(verify_envelope_signature(
            &proof,
            &bytes,
            &identity.agent_id
        ));
        // Case-insensitive sender comparison (hex ids compare caselessly
        // throughout the peer lane).
        assert!(verify_envelope_signature(
            &proof,
            &bytes,
            &identity.agent_id.to_ascii_uppercase()
        ));
    }

    #[test]
    fn tampered_payload_is_rejected() {
        let identity = TestIdentity::generate();
        let bytes = signing_bytes_for(&identity.agent_id, "hello peer");
        let signature_b64 = identity.sign_signing_bytes(&bytes);
        let proof = proof(&identity.public_key_b64, &signature_b64);
        let tampered = signing_bytes_for(&identity.agent_id, "send me your secrets");
        assert!(!verify_envelope_signature(
            &proof,
            &tampered,
            &identity.agent_id
        ));
    }

    #[test]
    fn wrong_key_is_rejected() {
        // Signed by A, presented with B's (correctly bound) public key.
        let signer = TestIdentity::generate();
        let other = TestIdentity::generate();
        let bytes = signing_bytes_for(&other.agent_id, "hello");
        let signature_b64 = signer.sign_signing_bytes(&bytes);
        let proof = proof(&other.public_key_b64, &signature_b64);
        assert!(!verify_envelope_signature(&proof, &bytes, &other.agent_id));
    }

    #[test]
    fn unbound_public_key_is_rejected() {
        // A VALID signature by A, but claiming B's sender id: the pk→sender
        // binding check must refuse before crypto even matters.
        let signer = TestIdentity::generate();
        let victim = TestIdentity::generate();
        let bytes = signing_bytes_for(&victim.agent_id, "hello");
        let signature_b64 = signer.sign_signing_bytes(&bytes);
        let proof = proof(&signer.public_key_b64, &signature_b64);
        assert!(!verify_envelope_signature(&proof, &bytes, &victim.agent_id));
    }

    #[test]
    fn placeholder_and_malformed_signatures_are_rejected() {
        let identity = TestIdentity::generate();
        let bytes = signing_bytes_for(&identity.agent_id, "hello");
        // The historical v1 placeholder (base64 of "placeholder").
        let placeholder = proof(&identity.public_key_b64, "cGxhY2Vob2xkZXI=");
        assert!(!verify_envelope_signature(
            &placeholder,
            &bytes,
            &identity.agent_id
        ));
        // Not base64 at all.
        let garbage = proof(&identity.public_key_b64, "!!! not base64 !!!");
        assert!(!verify_envelope_signature(
            &garbage,
            &bytes,
            &identity.agent_id
        ));
        // public_key_id that is not a key (old builders put the agent id here).
        let real_sig = identity.sign_signing_bytes(&bytes);
        let id_as_key = proof(&identity.agent_id, &real_sig);
        assert!(!verify_envelope_signature(
            &id_as_key,
            &bytes,
            &identity.agent_id
        ));
        // Wrong algorithm string.
        let wrong_algorithm = proof_with_algorithm("ed25519", &identity.public_key_b64, &real_sig);
        assert!(!verify_envelope_signature(
            &wrong_algorithm,
            &bytes,
            &identity.agent_id
        ));
    }

    #[test]
    fn agent_id_derivation_matches_org_canon() {
        // The derivation is SHA-256 over the domain prefix + raw pk bytes,
        // lowercase hex — pinned so a silent change breaks loudly.
        let identity = TestIdentity::generate();
        assert_eq!(identity.agent_id.len(), 64);
        assert!(identity
            .agent_id
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()));
        let pk = base64::engine::general_purpose::STANDARD
            .decode(&identity.public_key_b64)
            .expect("test pk is valid base64");
        assert_eq!(pk.len(), ML_DSA_65_PUBLIC_KEY_LEN);
        assert_eq!(derive_agent_id_hex(&pk), identity.agent_id);
    }

    #[test]
    fn validate_sign_response_fail_closed_matrix() {
        let identity = TestIdentity::generate();
        let good = super::super::x0x_client::AgentSignResponse {
            agent_id: identity.agent_id.clone(),
            public_key_b64: identity.public_key_b64.clone(),
            signature_b64: "c2ln".to_owned(),
            algorithm: X0X_SIGN_SCHEME.to_owned(),
            context: PEER_ENVELOPE_SIGN_CONTEXT.to_owned(),
        };
        let accepted =
            validate_sign_response(&good, &identity.agent_id).expect("valid response accepted");
        assert_eq!(accepted.public_key_b64, identity.public_key_b64);

        // Wrong scheme.
        let mut bad = good.clone();
        bad.algorithm = "ml-dsa-65".to_owned();
        assert!(validate_sign_response(&bad, &identity.agent_id).is_err());

        // Wrong context echo.
        let mut bad = good.clone();
        bad.context = "x0x-symphony-handoff-v1".to_owned();
        assert!(validate_sign_response(&bad, &identity.agent_id).is_err());

        // x0xd claims a different agent id than ours.
        assert!(validate_sign_response(&good, &TestIdentity::generate().agent_id).is_err());

        // Public key that does not derive our agent id.
        let mut bad = good.clone();
        bad.public_key_b64 = TestIdentity::generate().public_key_b64;
        assert!(validate_sign_response(&bad, &identity.agent_id).is_err());

        // Truncated key material.
        let mut bad = good;
        bad.public_key_b64 = base64::engine::general_purpose::STANDARD.encode([0u8; 32]);
        assert!(validate_sign_response(&bad, &identity.agent_id).is_err());
    }

    #[test]
    fn base64_len_matches_real_encoded_lengths() {
        assert_eq!(
            base64_len(ML_DSA_65_PUBLIC_KEY_LEN),
            base64::engine::general_purpose::STANDARD
                .encode(vec![0u8; ML_DSA_65_PUBLIC_KEY_LEN])
                .len()
        );
        assert_eq!(
            base64_len(ML_DSA_65_SIGNATURE_LEN),
            base64::engine::general_purpose::STANDARD
                .encode(vec![0u8; ML_DSA_65_SIGNATURE_LEN])
                .len()
        );
    }
}
