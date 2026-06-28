//! Fail-closed audit for the governed ToolHost (ADR-013 Vision A, A2).
//!
//! Every policy decision (allow AND deny) produces exactly one row. The sink
//! is a trait so production wires a [`ConductorStoreAudit`] (JSONL sibling to
//! the conductor telemetry files) while tests inject a [`CapturingAudit`] (or a
//! failing sink to prove fail-closed behavior). Storage isolation invariant:
//! audit rows NEVER reach `fae.db` / `MemoryOrchestrator`.

use std::sync::Arc;

use serde::Serialize;

use crate::conductor::ConductorStore;

/// One policy decision. Serialized to `toolhost_audit.jsonl`.
#[derive(Debug, Clone, Serialize)]
pub struct ToolHostAuditRecord {
    /// Always the literal `"tool_policy"` (fast grep/filter).
    pub event_type: &'static str,
    /// Decision time, ms since UNIX epoch (from the governance clock).
    pub ts_ms: u64,
    /// The tool name as supplied to the call (`read`, `write`, `bash`, …).
    pub tool: String,
    /// The tool-call id (correlates with the fluers `InvokeContext`).
    pub call_id: String,
    /// The outcome. `Denied` covers every fail-closed path.
    pub decision: AuditDecision,
    /// Short static reason (`allowed`, `confirm_required_mapped_to_deny`,
    /// `missing_scope`, `path_escape`, `damage_control`, `egress_blocked`,
    /// `unknown_tool`, `audit_write_failed`, …).
    pub reason: String,
    /// The risk class assigned at classification (`Read`/`Write`/`Shell`/…).
    pub risk_class: &'static str,
}

/// The outcome of a single policy decision.
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AuditDecision {
    /// The tool call was cleared to execute.
    Allowed,
    /// The tool call was blocked before any side effect.
    Denied,
}

/// A fail-closed policy-audit sink.
///
/// Implementations MUST surface write failures (the policy converts an
/// allow-path write failure into a deny — see [`crate::toolhost::policy`]).
pub trait ToolHostAudit: Send + Sync {
    /// Persist one decision row. Errors are surfaced so the caller can deny.
    fn record(&self, record: ToolHostAuditRecord) -> Result<(), ToolHostAuditError>;
}

/// A sink error. The string is folded into the deny reason on fail-closed.
#[derive(Debug, thiserror::Error)]
pub enum ToolHostAuditError {
    /// The underlying store rejected the write.
    #[error("toolhost audit write failed: {0}")]
    Write(String),
}

/// Production sink: appends to `toolhost_audit.jsonl` in the conductor store.
///
/// Holds an `Arc<ConductorStore>` (one-way boundary: toolhost → conductor).
#[derive(Clone)]
pub struct ConductorStoreAudit {
    store: Arc<ConductorStore>,
}

impl ConductorStoreAudit {
    /// Wrap the shared conductor store. The store owns the private audit dir.
    #[must_use]
    pub fn new(store: Arc<ConductorStore>) -> Self {
        Self { store }
    }
}

impl ToolHostAudit for ConductorStoreAudit {
    fn record(&self, record: ToolHostAuditRecord) -> Result<(), ToolHostAuditError> {
        self.store
            .append_toolhost_audit(&record)
            .map_err(|e| ToolHostAuditError::Write(e.to_string()))
    }
}

// ---------------------------------------------------------------------------
// test support
// ---------------------------------------------------------------------------

/// In-memory sink for tests: captures every record, never fails (unless
/// configured). Not part of the production surface.
#[cfg(test)]
#[derive(Default, Clone)]
pub struct CapturingAudit {
    records: std::sync::Arc<std::sync::Mutex<Vec<ToolHostAuditRecord>>>,
    fail_next: std::sync::Arc<std::sync::Mutex<bool>>,
}

#[cfg(test)]
impl CapturingAudit {
    /// A capturing sink that succeeds on every write.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Force the next `record()` call (and all subsequent) to fail — used to
    /// prove the allow-path fail-closed behavior.
    pub fn set_failing(&self) {
        *self.fail_next.lock().expect("audit mutex poisoned") = true;
    }

    /// Snapshot of the captured records, in insertion order.
    #[must_use]
    pub fn snapshot(&self) -> Vec<ToolHostAuditRecord> {
        self.records.lock().expect("audit mutex poisoned").clone()
    }
}

#[cfg(test)]
impl ToolHostAudit for CapturingAudit {
    fn record(&self, record: ToolHostAuditRecord) -> Result<(), ToolHostAuditError> {
        let failing = self.fail_next.lock().expect("audit mutex poisoned");
        if *failing {
            return Err(ToolHostAuditError::Write("injected failure".into()));
        }
        self.records
            .lock()
            .expect("audit mutex poisoned")
            .push(record);
        Ok(())
    }
}
