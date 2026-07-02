//! Fail-closed mutation receipts for the governed ToolHost (B4).
//!
//! A lighter-weight daemon analogue of the Swift `ReceiptStore` +
//! `ReversibilityEngine`: for every ALLOWED mutating execution (`write`/`edit`/
//! `bash`) the host appends one receipt to `toolhost_receipts.jsonl` — a sibling
//! of `toolhost_audit.jsonl` in the same private conductor store, NEVER in
//! `fae.db` / `MemoryOrchestrator` (the storage-isolation invariant).
//!
//! The receipt records, PRE-execution: the tool, the resolved target path, the
//! SHA-256 of the target's pre-image (write/edit, when readable within a size
//! cap), a bounded + redacted input summary (the same `ConfirmDetail` the confirm
//! channel sends — never file content), and how the mutation was authorized.
//!
//! **Fail-closed like the audit log:** the receipt is written BEFORE the tool
//! runs, and a write failure DENIES the mutation. A full undo engine stays
//! Swift-side (ADR-013 caveat #2); this is the receipt lane only.

use std::sync::Arc;

use serde::Serialize;

use crate::conductor::ConductorStore;
use crate::toolhost::confirm::ConfirmDetail;

/// One mutation receipt. Serialized to `toolhost_receipts.jsonl`.
#[derive(Debug, Clone, Serialize)]
pub struct MutationReceipt {
    /// Always the literal `"tool_mutation"` (fast grep/filter).
    pub event_type: &'static str,
    /// Receipt time, ms since UNIX epoch (from the governance clock).
    pub ts_ms: u64,
    /// The mutating tool (`write`, `edit`, `bash`).
    pub tool: String,
    /// The tool-call id (correlates with the audit row + fluers `InvokeContext`).
    pub call_id: String,
    /// The risk class label (`Write`/`Edit`/`Shell`).
    pub risk_class: String,
    /// The resolved (sandbox-relative) target path for write/edit; `None` for bash.
    pub path: Option<String>,
    /// SHA-256 hex of the target's pre-mutation content (write/edit, when it
    /// exists and is readable within the size cap); `None` otherwise.
    pub pre_image_sha256: Option<String>,
    /// Why there is no pre-image hash: `"absent"` | `"too_large"` |
    /// `"unreadable"` | `"not_applicable"` (bash). `None` when a hash IS present.
    pub pre_image_note: Option<&'static str>,
    /// Bounded, redacted input summary (the confirm detail — never file content).
    pub detail: ConfirmDetail,
    /// How the mutation was authorized: `"allowed"` (safe/owner-full) or
    /// `"confirmed_by_owner"` (passed the `tool.confirm` round-trip).
    pub outcome: &'static str,
}

/// A fail-closed mutation-receipt sink.
///
/// Implementations MUST surface write failures — the ToolHost converts a receipt
/// write failure into a DENY before executing the mutation.
pub trait ToolHostReceipts: Send + Sync {
    /// Persist one mutation receipt. Errors are surfaced so the caller denies.
    fn record(&self, receipt: MutationReceipt) -> Result<(), ToolHostReceiptError>;
}

/// A sink error. The string is folded into the deny reason on fail-closed.
#[derive(Debug, thiserror::Error)]
pub enum ToolHostReceiptError {
    /// The underlying store rejected the write.
    #[error("toolhost receipt write failed: {0}")]
    Write(String),
}

/// Production sink: appends to `toolhost_receipts.jsonl` in the conductor store.
#[derive(Clone)]
pub struct ConductorStoreReceipts {
    store: Arc<ConductorStore>,
}

impl ConductorStoreReceipts {
    /// Wrap the shared conductor store (one-way boundary: toolhost → conductor).
    #[must_use]
    pub fn new(store: Arc<ConductorStore>) -> Self {
        Self { store }
    }
}

impl ToolHostReceipts for ConductorStoreReceipts {
    fn record(&self, receipt: MutationReceipt) -> Result<(), ToolHostReceiptError> {
        self.store
            .append_toolhost_receipt(&receipt)
            .map_err(|e| ToolHostReceiptError::Write(e.to_string()))
    }
}

// ---------------------------------------------------------------------------
// test support
// ---------------------------------------------------------------------------

/// In-memory sink for tests: captures every receipt, never fails (unless
/// configured). Mirrors the audit `CapturingAudit`.
#[cfg(test)]
#[derive(Default, Clone)]
pub struct CapturingReceipts {
    receipts: std::sync::Arc<std::sync::Mutex<Vec<MutationReceipt>>>,
    fail_next: std::sync::Arc<std::sync::Mutex<bool>>,
}

#[cfg(test)]
impl CapturingReceipts {
    /// A capturing sink that succeeds on every write.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Force `record()` to fail — proves the fail-closed (deny-before-mutation) path.
    pub fn set_failing(&self) {
        *self.fail_next.lock().expect("receipt mutex poisoned") = true;
    }

    /// Snapshot of the captured receipts, in insertion order.
    #[must_use]
    pub fn snapshot(&self) -> Vec<MutationReceipt> {
        self.receipts
            .lock()
            .expect("receipt mutex poisoned")
            .clone()
    }
}

#[cfg(test)]
impl ToolHostReceipts for CapturingReceipts {
    fn record(&self, receipt: MutationReceipt) -> Result<(), ToolHostReceiptError> {
        if *self.fail_next.lock().expect("receipt mutex poisoned") {
            return Err(ToolHostReceiptError::Write("injected failure".into()));
        }
        self.receipts
            .lock()
            .expect("receipt mutex poisoned")
            .push(receipt);
        Ok(())
    }
}

/// SHA-256 hex of `bytes` (matches the `models_lock` / `llamacpp_adapter`
/// convention: `hex::encode(Sha256::digest(..))`).
#[must_use]
pub fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    hex::encode(Sha256::digest(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_hex_matches_known_vector() {
        // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn capturing_receipts_fail_closed_switch() {
        let sink = CapturingReceipts::new();
        let r = MutationReceipt {
            event_type: "tool_mutation",
            ts_ms: 1,
            tool: "write".into(),
            call_id: "c1".into(),
            risk_class: "Write".into(),
            path: Some("a.txt".into()),
            pre_image_sha256: None,
            pre_image_note: Some("absent"),
            detail: ConfirmDetail::WriteEdit {
                path: "a.txt".into(),
                new_bytes: 3,
                old_exists: false,
            },
            outcome: "allowed",
        };
        assert!(sink.record(r.clone()).is_ok());
        assert_eq!(sink.snapshot().len(), 1);
        sink.set_failing();
        assert!(sink.record(r).is_err());
    }
}
