//! M6-Intel: shared intelligence as signed candidate priors — EXPORT slice.
//!
//! v1 is **export-only + import-rejects-all** (spec §1/§2.3). This module's
//! M6-B surface is the sanitizer + unsigned-preview writer:
//! - [`sanitize_receipt`] reads a [`RouteReceipt`], projects it onto the closed
//!   §3.1 allowlist, bounds + token-validates every exported `String` so it
//!   cannot carry free text (fix #5), and buckets raw latency. It is
//!   **structural**: it reads ONLY the allowlist fields from `RouteReceipt`, so
//!   no denylisted field (fingerprint / worker_id / roles / fallback_reason /
//!   payload_hash / cost / raw latency / timestamp / user_signal) can be carried
//!   through — total projection, every source field accounted for.
//! - [`export_preview`] emits a [`fae_envelope_gate::PeerEnvelope`]-shaped JSON
//!   (exact field set + snake_case `kind`, derived from the enum) that the gate
//!   can re-parse on import (M6-C).
//!
//! Dormant: nothing constructs this in production yet (no caller until M6-C/D).
//! No network egress — the export is a local file write to the conductor store
//! dir (spec §4). The authority is the sanitizer, not the egress membrane: the
//! output is a local redacted aggregate, not a remote-bound prompt.

use std::path::Path;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

use fae_envelope_gate::EnvelopeKind;

use crate::conductor::recipe::{ConductorTopology, PrivacyLane};
use crate::conductor::telemetry::{RouteReceipt, TargetKind};

// ── bounds + token validation (fix #5: shape-bound the exported strings) ────

/// Max length of an exported `recipe_id`. Bounded so it cannot carry free text.
pub const MAX_RECIPE_ID_LEN: usize = 64;
/// Max length of an exported `eval_delta`.
pub const MAX_EVAL_DELTA_LEN: usize = 32;

/// `recipe_id` alphabet: `^[a-zA-Z0-9_.:-]+$`.
fn is_recipe_id_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | ':' | '-')
}

/// `eval_delta` shape: `^[a-z_]+:[+-]?[0-9.]+$` (e.g. `routing_acc:+0.08`).
/// Hand-rolled (no `regex` dep in fae-daemon).
fn is_valid_eval_delta(s: &str) -> bool {
    let Some((name, value)) = s.split_once(':') else {
        return false;
    };
    !name.is_empty()
        && name.chars().all(|c| c.is_ascii_lowercase() || c == '_')
        && is_valid_eval_delta_value(value)
}

fn is_valid_eval_delta_value(v: &str) -> bool {
    let rest = v.strip_prefix(['+', '-']).unwrap_or(v);
    !rest.is_empty() && rest.chars().all(|c| c.is_ascii_digit() || c == '.')
}

// ── latency bucket (closed enum, never raw ms) ──────────────────────────────

/// Bucketed latency. Raw ms is too fine-grained for cross-node correlation, so
/// it is projected to a closed enum (spec §3.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LatencyBucket {
    Under100,
    Under1000,
    Over1000,
    Unknown,
}

/// Deterministic, total over `Option<u64>` (spec §3.1).
pub fn bucket_latency(latency_ms: Option<u64>) -> LatencyBucket {
    match latency_ms {
        None => LatencyBucket::Unknown,
        Some(ms) if ms < 100 => LatencyBucket::Under100,
        Some(ms) if ms < 1000 => LatencyBucket::Under1000,
        Some(_) => LatencyBucket::Over1000,
    }
}

// ── the §3.1 allowlist payload ──────────────────────────────────────────────

/// Tier-2 shared-intelligence prior payload. Total projection over
/// [`RouteReceipt`] — every source field is accounted for (allow OR deny), so
/// no denylisted field can be carried through. `deny_unknown_fields` so the
/// M6-C import deserialization fails closed on an unknown key.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GateReceiptPriorPayload {
    topology: ConductorTopology,
    privacy_lane: PrivacyLane,
    target_kind: TargetKind,
    recipe_id: String,
    success: bool,
    fallback: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    eval_delta: Option<String>,
    latency_bucket_ms: LatencyBucket,
}

impl GateReceiptPriorPayload {
    /// Read-only field accessors (used by tests; future M6-C/D may consume).
    pub fn topology(&self) -> ConductorTopology {
        self.topology
    }
    pub fn privacy_lane(&self) -> PrivacyLane {
        self.privacy_lane
    }
    pub fn target_kind(&self) -> TargetKind {
        self.target_kind
    }
    pub fn recipe_id(&self) -> &str {
        &self.recipe_id
    }
    pub fn success(&self) -> bool {
        self.success
    }
    pub fn fallback(&self) -> bool {
        self.fallback
    }
    pub fn eval_delta(&self) -> Option<&str> {
        self.eval_delta.as_deref()
    }
    pub fn latency_bucket_ms(&self) -> LatencyBucket {
        self.latency_bucket_ms
    }

    /// Validate the bounded + token fields (§3.1, fix #5). A payload is valid
    /// iff `recipe_id` matches `^[a-zA-Z0-9_.:-]+$` (≤64) and `eval_delta`, if
    /// present, matches `^[a-z_]+:[+-]?[0-9.]+$` (≤32).
    ///
    /// Called at TWO seams so the bound is a TYPE/SEAM invariant, not a caller
    /// convention (oracle review of M6-B, MAJOR): [`sanitize_receipt`] calls it
    /// as it builds (the construct path), and [`export_preview`] re-validates
    /// at the export seam — because `GateReceiptPriorPayload` derives
    /// `Deserialize`, a payload materialized via serde (e.g. M6-C's import path)
    /// bypassed the sanitizer. M6-C's import path reuses this same method after
    /// its `from_value`, so the token-bound holds regardless of construction
    /// path.
    pub fn validate(&self) -> Result<(), SanitizeError> {
        validate_recipe_id(&self.recipe_id)?;
        if let Some(delta) = self.eval_delta.as_deref() {
            validate_eval_delta_field(delta)?;
        }
        Ok(())
    }
}

#[derive(Debug, Error)]
pub enum SanitizeError {
    #[error("recipe_id not token-valid or too long (max {max}): {value:?}")]
    InvalidRecipeId { value: String, max: usize },
    #[error("eval_delta not token-valid or too long (max {max}): {value:?}")]
    InvalidEvalDelta { value: String, max: usize },
}

/// Validate + bound a `recipe_id` against `^[a-zA-Z0-9_.:-]+$`, ≤64 chars.
fn validate_recipe_id(s: &str) -> Result<(), SanitizeError> {
    let valid = !s.is_empty() && s.len() <= MAX_RECIPE_ID_LEN && s.chars().all(is_recipe_id_char);
    if valid {
        Ok(())
    } else {
        Err(SanitizeError::InvalidRecipeId {
            value: s.to_owned(),
            max: MAX_RECIPE_ID_LEN,
        })
    }
}

/// Validate + bound an `eval_delta` against `^[a-z_]+:[+-]?[0-9.]+$`, ≤32 chars.
fn validate_eval_delta_field(s: &str) -> Result<(), SanitizeError> {
    let valid = s.len() <= MAX_EVAL_DELTA_LEN && is_valid_eval_delta(s);
    if valid {
        Ok(())
    } else {
        Err(SanitizeError::InvalidEvalDelta {
            value: s.to_owned(),
            max: MAX_EVAL_DELTA_LEN,
        })
    }
}

/// Project a [`RouteReceipt`] onto the §3.1 allowlist. Structural: reads ONLY
/// the allowlist fields, bounds + token-validates the `String` fields, and
/// buckets latency. Returns `Err` (rather than emitting over-long / non-token
/// content) so the export can never carry free text in a bounded field (fix #5).
///
/// Validation routes through [`GateReceiptPriorPayload::validate`] (the single
/// source of truth shared with the export seam) AFTER construction — so the
/// bound holds whether the payload is built here or materialized via
/// `Deserialize` and re-validated elsewhere.
pub fn sanitize_receipt(receipt: &RouteReceipt) -> Result<GateReceiptPriorPayload, SanitizeError> {
    let payload = GateReceiptPriorPayload {
        topology: receipt.topology,
        privacy_lane: receipt.privacy_lane,
        target_kind: receipt.target_kind,
        recipe_id: receipt.recipe_id.clone(),
        success: receipt.success,
        fallback: receipt.fallback,
        eval_delta: receipt.eval_delta.clone(),
        latency_bucket_ms: bucket_latency(receipt.latency_ms),
    };
    payload.validate()?;
    Ok(payload)
}

// ── unsigned-preview envelope export ────────────────────────────────────────

/// v1 export signature marker (spec §3.2). The gate reads this on import
/// (M6-C); the production verifier rejects it (import-rejects-all, §2.3).
const SIGNATURE_ALGORITHM: &str = "ml-dsa-65";
const SIGNATURE_PUBLIC_KEY_ID: &str = "<none>";
const SIGNATURE_PREVIEW: &str = "export-preview-unsigned";
const SENDER_ID_SELF: &str = "<self>";

#[derive(Debug, Error)]
pub enum ExportError {
    #[error("payload serialization failed: {0}")]
    Serialize(#[from] serde_json::Error),
    #[error("envelope write failed: {0}")]
    Write(#[from] std::io::Error),
    #[error("payload failed validation at the export seam: {0}")]
    InvalidPayload(#[from] SanitizeError),
}

/// Derive a fresh, content+time-bound envelope id (`prior:<ms>-<hash8>`).
/// Deterministic for a given payload + timestamp, unique per export. Avoids a
/// new `uuid` dep (fae-daemon has none) while staying collision-resistant for a
/// dormant, low-frequency export.
pub fn envelope_id_for(payload: &GateReceiptPriorPayload, created_at_ms: u64) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"fae-conductor-prior-v1");
    let canonical = serde_json::to_string(payload).unwrap_or_default();
    hasher.update(canonical.as_bytes());
    let digest = hasher.finalize();
    let hash8 = hex::encode(&digest[..4]);
    format!("prior:{created_at_ms}-{hash8}")
}

/// Write a `PeerEnvelope`-shaped unsigned-preview JSON for one prior to
/// `out_path`. The shape matches [`fae_envelope_gate::PeerEnvelope`] exactly
/// (snake_case `kind` derived from the enum, the exact 7-field set, a
/// `deny_unknown_fields`-compatible signature block) so the gate can re-parse
/// it on import (M6-C). Returns the generated envelope id.
///
/// `created_at_ms` is a parameter (not read from the clock) so exports are
/// deterministic in tests; production passes a real wall-clock timestamp.
pub fn export_preview(
    payload: &GateReceiptPriorPayload,
    created_at_ms: u64,
    out_path: &Path,
) -> Result<String, ExportError> {
    // Defense-in-depth (oracle review of M6-B, MAJOR): re-validate at the export
    // seam. `sanitize_receipt` validates as it builds, but a payload
    // materialized via `Deserialize` (e.g. M6-C's import path) bypassed that. A
    // bound that depends on "only sanitize_receipt constructed this" rots the
    // moment a second construction path lands — so the export seam enforces it
    // too, making the token-bound a seam invariant rather than a caller
    // convention. Rejects BEFORE any file is written.
    payload.validate()?;
    let envelope_id = envelope_id_for(payload, created_at_ms);
    let kind = serde_json::to_value(EnvelopeKind::ConductorGateReceiptPrior)?;
    let payload_value = serde_json::to_value(payload)?;
    let envelope = serde_json::json!({
        "schema_version": fae_envelope_gate::SUPPORTED_SCHEMA_VERSION,
        "kind": kind,
        "envelope_id": envelope_id,
        "sender_id": SENDER_ID_SELF,
        "created_at_ms": created_at_ms,
        "payload": payload_value,
        "signature": {
            "algorithm": SIGNATURE_ALGORITHM,
            "public_key_id": SIGNATURE_PUBLIC_KEY_ID,
            "signature_b64": SIGNATURE_PREVIEW,
        },
    });
    if let Some(parent) = out_path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    std::fs::write(out_path, serde_json::to_vec_pretty(&envelope)?)?;
    Ok(envelope_id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conductor::fingerprint::RequestFingerprint;
    use crate::conductor::recipe::{ConductorTopology, PrivacyLane};
    use crate::conductor::telemetry::{RouteReceipt, TargetKind};

    /// A receipt with sentinels in EVERY denylisted field, so absence proofs
    /// are non-vacuous. Allowlisted fields carry clean token values.
    fn receipt_with_sentinels(latency_ms: Option<u64>, eval_delta: Option<&str>) -> RouteReceipt {
        RouteReceipt {
            request_fingerprint: RequestFingerprint("SENTINEL-FP".into()),
            recipe_id: "v1-direct".into(),
            topology: ConductorTopology::Direct,
            worker_id: "SENTINEL-WORKER".into(),
            target_kind: TargetKind::LocalModel,
            privacy_lane: PrivacyLane::LocalOnly,
            roles: None,
            latency_ms,
            cost_micros: Some(12_345),
            success: true,
            fallback: false,
            fallback_reason: Some("SENTINEL free-text fallback reason".into()),
            payload_hash: Some("SENTINELdeadbeefhash".into()),
            eval_delta: eval_delta.map(str::to_owned),
            user_signal: Some("accept".into()),
            timestamp_ms: 9_999_999_999,
        }
    }

    fn serialized(payload: &GateReceiptPriorPayload) -> serde_json::Value {
        serde_json::to_value(payload).expect("payload serializes")
    }

    #[test]
    fn sanitize_receipt_drops_all_denylisted_fields() {
        let receipt = receipt_with_sentinels(Some(500), Some("routing_acc:+0.08"));
        let payload = sanitize_receipt(&receipt).expect("valid receipt");
        let json = serialized(&payload).to_string();

        // F-4 token + every denylisted field + its sentinel must be absent.
        for needle in [
            "request_fingerprint",
            "SENTINEL-FP",
            "worker_id",
            "SENTINEL-WORKER",
            "roles",
            "fallback_reason",
            "free-text",
            "payload_hash",
            "deadbeef",
            "cost_micros",
            "latency_ms",
            "timestamp_ms",
            "9_999_999_999",
            "user_signal",
        ] {
            assert!(
                !json.contains(needle),
                "denylisted token `{needle}` leaked into prior payload: {json}"
            );
        }
    }

    #[test]
    fn sanitize_receipt_allowlist_is_correct() {
        let receipt = receipt_with_sentinels(Some(500), Some("routing_acc:+0.08"));
        let payload = sanitize_receipt(&receipt).expect("valid receipt");
        assert_eq!(payload.topology(), ConductorTopology::Direct);
        assert_eq!(payload.privacy_lane(), PrivacyLane::LocalOnly);
        assert_eq!(payload.target_kind(), TargetKind::LocalModel);
        assert_eq!(payload.recipe_id(), "v1-direct");
        assert!(payload.success());
        assert!(!payload.fallback());
        assert_eq!(payload.eval_delta(), Some("routing_acc:+0.08"));
        assert_eq!(payload.latency_bucket_ms(), LatencyBucket::Under1000);

        // The payload carries EXACTLY the 8 allowlist fields (no extras).
        let obj = serialized(&payload)
            .as_object()
            .expect("payload is an object")
            .keys()
            .cloned()
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(
            obj,
            [
                "eval_delta",
                "fallback",
                "latency_bucket_ms",
                "privacy_lane",
                "recipe_id",
                "success",
                "target_kind",
                "topology",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect()
        );
    }

    #[test]
    fn sanitize_receipt_buckets_latency() {
        assert_eq!(bucket_latency(None), LatencyBucket::Unknown);
        let mk = |ms| sanitize_receipt(&receipt_with_sentinels(Some(ms), None));
        assert_eq!(mk(0).unwrap().latency_bucket_ms(), LatencyBucket::Under100);
        assert_eq!(mk(99).unwrap().latency_bucket_ms(), LatencyBucket::Under100);
        assert_eq!(
            mk(100).unwrap().latency_bucket_ms(),
            LatencyBucket::Under1000
        );
        assert_eq!(
            mk(999).unwrap().latency_bucket_ms(),
            LatencyBucket::Under1000
        );
        assert_eq!(
            mk(1000).unwrap().latency_bucket_ms(),
            LatencyBucket::Over1000
        );
    }

    #[test]
    fn sanitize_receipt_drops_cost_and_raw_latency_even_when_present() {
        let receipt = receipt_with_sentinels(Some(4321), None);
        let payload = sanitize_receipt(&receipt).unwrap();
        // Cost is dropped entirely; latency is bucketed, never raw.
        let json = serialized(&payload).to_string();
        assert!(!json.contains("cost"));
        assert!(!json.contains("4321"));
        assert!(json.contains("over1000"));
    }

    #[test]
    fn sanitize_receipt_rejects_overlong_recipe_id() {
        let mut receipt = receipt_with_sentinels(Some(50), None);
        receipt.recipe_id = "a".repeat(MAX_RECIPE_ID_LEN + 1);
        assert!(matches!(
            sanitize_receipt(&receipt),
            Err(SanitizeError::InvalidRecipeId { .. })
        ));
    }

    #[test]
    fn sanitize_receipt_rejects_non_token_recipe_id() {
        let mut receipt = receipt_with_sentinels(Some(50), None);
        // A space breaks the token alphabet — the sanitizer must NOT emit it
        // (could otherwise smuggle free text in the recipe_id field).
        receipt.recipe_id = "recipe with spaces".into();
        assert!(matches!(
            sanitize_receipt(&receipt),
            Err(SanitizeError::InvalidRecipeId { .. })
        ));
    }

    #[test]
    fn sanitize_receipt_rejects_overlong_eval_delta() {
        let mut receipt = receipt_with_sentinels(Some(50), None);
        // >32 chars: a long name that is otherwise well-formed.
        receipt.eval_delta = Some(format!("{}:+0.1", "a".repeat(MAX_EVAL_DELTA_LEN)));
        assert!(matches!(
            sanitize_receipt(&receipt),
            Err(SanitizeError::InvalidEvalDelta { .. })
        ));
    }

    #[test]
    fn sanitize_receipt_rejects_non_token_eval_delta() {
        let mut receipt = receipt_with_sentinels(Some(50), None);
        // Uppercase name is not in `[a-z_]`; free text must be rejected.
        receipt.eval_delta = Some("RoutingAcc:+0.08".into());
        assert!(matches!(
            sanitize_receipt(&receipt),
            Err(SanitizeError::InvalidEvalDelta { .. })
        ));

        // No colon separator: malformed.
        receipt.eval_delta = Some("garbage".into());
        assert!(matches!(
            sanitize_receipt(&receipt),
            Err(SanitizeError::InvalidEvalDelta { .. })
        ));
    }

    #[test]
    fn sanitize_receipt_accepts_valid_eval_delta_shapes() {
        for ok in ["routing_acc:+0.08", "lat:-1.5", "cost:0", "x_:.0"] {
            let receipt = receipt_with_sentinels(Some(50), Some(ok));
            assert_eq!(
                sanitize_receipt(&receipt).unwrap().eval_delta(),
                Some(ok),
                "`{ok}` should be accepted"
            );
        }
    }

    #[test]
    fn envelope_id_is_deterministic_and_fresh() {
        let payload = sanitize_receipt(&receipt_with_sentinels(Some(50), None)).unwrap();
        let a = envelope_id_for(&payload, 1_700_000_000_000);
        let b = envelope_id_for(&payload, 1_700_000_000_000);
        let c = envelope_id_for(&payload, 1_700_000_000_001);
        assert_eq!(a, b, "same payload + time ⇒ same id");
        assert_ne!(a, c, "different time ⇒ different id");
        assert!(a.starts_with("prior:"));
    }

    #[test]
    fn export_preview_writes_unsigned_envelope_round_trippable_by_gate() {
        let payload = sanitize_receipt(&receipt_with_sentinels(
            Some(500),
            Some("routing_acc:+0.08"),
        ))
        .unwrap();
        let dir = tempfile::tempdir().expect("tempdir");
        let out = dir.path().join("prior-preview.json");

        let created_at = 1_700_000_000_123u64;
        let envelope_id = export_preview(&payload, created_at, &out).expect("export ok");
        assert!(envelope_id.starts_with(&format!("prior:{created_at}-")));
        assert!(out.exists());

        let json = std::fs::read_to_string(&out).unwrap();
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();

        // Shape: exact field set the gate's deny_unknown_fields expects.
        assert_eq!(
            value["schema_version"],
            fae_envelope_gate::SUPPORTED_SCHEMA_VERSION
        );
        assert_eq!(value["kind"], "conductor_gate_receipt_prior");
        assert_eq!(value["envelope_id"], envelope_id);
        assert_eq!(value["sender_id"], "<self>");
        assert_eq!(value["created_at_ms"], created_at);
        assert_eq!(value["signature"]["algorithm"], "ml-dsa-65");
        assert_eq!(value["signature"]["public_key_id"], "<none>");
        assert_eq!(
            value["signature"]["signature_b64"],
            "export-preview-unsigned"
        );
        // The allowlist payload is embedded verbatim (no denylisted fields).
        assert_eq!(value["payload"]["topology"], "direct");
        assert_eq!(value["payload"]["latency_bucket_ms"], "under1000");
        let payload_str = value["payload"].to_string();
        assert!(!payload_str.contains("SENTINEL"));

        // Hard contract: the gate can re-parse this exact JSON as a PeerEnvelope
        // (deny_unknown_fields-compatible field set + schema version). This is
        // the M6-B→M6-C boundary proof.
        assert!(
            serde_json::from_str::<fae_envelope_gate::PeerEnvelope>(&json).is_ok(),
            "exported JSON must be gate-parseable"
        );
    }

    #[test]
    fn export_preview_rejects_forged_invalid_payload() {
        // Oracle review of M6-B (MAJOR): a payload materialized via Deserialize
        // bypasses sanitize_receipt's validation (serde checks structure, not
        // value bounds). export_preview must re-validate at the seam — the
        // token-bound is a seam invariant, not a caller convention. (M6-C's
        // import path deserializes then calls the SAME validate(), so this seam
        // protects both.)
        let wire = serde_json::json!({
            "topology": "direct",
            "privacy_lane": "local_only",
            "target_kind": "local_model",
            "recipe_id": "a".repeat(MAX_RECIPE_ID_LEN + 1),
            "success": true,
            "fallback": false,
            "latency_bucket_ms": "under1000",
        });
        let forged: GateReceiptPriorPayload = serde_json::from_value(wire)
            .expect("Deserialize builds without value-bound validation (the bypass)");
        // Sanity: the forged payload is genuinely invalid.
        assert!(forged.validate().is_err());

        let dir = tempfile::tempdir().expect("tempdir");
        let out = dir.path().join("forged.json");
        let result = export_preview(&forged, 1_700_000_000_000, &out);
        assert!(
            matches!(result, Err(ExportError::InvalidPayload(_))),
            "export_preview must reject a forged invalid payload at the seam"
        );
        assert!(!out.exists(), "no file written for a rejected payload");
    }

    #[test]
    fn export_preview_rejects_forged_non_token_eval_delta() {
        // Second forge vector: an eval_delta carrying uppercase (free text) that
        // Deserialize accepts but the token-bound rejects.
        let wire = serde_json::json!({
            "topology": "direct",
            "privacy_lane": "local_only",
            "target_kind": "local_model",
            "recipe_id": "ok",
            "success": true,
            "fallback": false,
            "eval_delta": "RoutingAcc:+0.08",
            "latency_bucket_ms": "under1000",
        });
        let forged: GateReceiptPriorPayload = serde_json::from_value(wire)
            .expect("Deserialize builds the non-token eval_delta (the bypass)");
        assert!(forged.validate().is_err());
        let dir = tempfile::tempdir().expect("tempdir");
        let out = dir.path().join("forged2.json");
        assert!(matches!(
            export_preview(&forged, 1_700_000_000_000, &out),
            Err(ExportError::InvalidPayload(_))
        ));
        assert!(!out.exists());
    }
}
