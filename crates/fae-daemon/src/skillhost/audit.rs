//! Fail-closed audit for the governed SkillHost (ADR-013 Vision A, A2.5).
//!
//! Sibling of [`crate::toolhost::audit`]: every skill lifecycle event
//! (`skill_loaded` / `skill_quarantined` / `skill_executed`) produces exactly
//! one row with its checksum-verification status. Production wires a
//! [`ConductorStoreSkillAudit`] (JSONL sibling `skillhost_audit.jsonl`, in the
//! conductor store dir — NEVER `fae.db`/`MemoryOrchestrator`); tests inject a
//! [`CapturingSkillAudit`]. Storage-isolation invariant matches the ToolHost.

use std::sync::Arc;

use serde::Serialize;

use crate::conductor::ConductorStore;

/// The kind of skill lifecycle event.
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SkillEvent {
    /// A skill parsed + verified cleanly and is available.
    Loaded,
    /// A skill failed a load-time gate (integrity, manifest, parse) and is
    /// unavailable.
    Quarantined,
    /// A skill script was re-verified and dispatched for execution.
    Executed,
}

/// One skill lifecycle decision. Serialized to `skillhost_audit.jsonl`.
#[derive(Debug, Clone, Serialize)]
pub struct SkillHostAuditRecord {
    /// Always the literal `"skill_event"` (fast grep/filter).
    pub event_type: &'static str,
    /// Decision time, ms since UNIX epoch.
    pub ts_ms: u64,
    /// The skill name (frontmatter `name`).
    pub skill: String,
    /// The lifecycle event.
    pub event: SkillEvent,
    /// `"verified"`, `"instruction_only"`, or a quarantine reason
    /// (`"modified:scripts/x.py"`, `"missing_manifest"`, …).
    pub checksum_status: String,
    /// Correlation id (present for `Executed`; empty for load-time events).
    pub call_id: String,
}

/// A fail-closed skill-audit sink.
pub trait SkillHostAudit: Send + Sync {
    /// Persist one skill event row. Errors are surfaced so callers can fail
    /// closed (an unauditable execution must not proceed).
    fn record(&self, record: SkillHostAuditRecord) -> Result<(), SkillHostAuditError>;
}

/// A skill-audit sink error.
#[derive(Debug, thiserror::Error)]
pub enum SkillHostAuditError {
    /// The underlying store rejected the write.
    #[error("skillhost audit write failed: {0}")]
    Write(String),
}

/// Production sink: appends to `skillhost_audit.jsonl` in the conductor store.
#[derive(Clone)]
pub struct ConductorStoreSkillAudit {
    store: Arc<ConductorStore>,
}

impl ConductorStoreSkillAudit {
    /// Wrap the shared conductor store (one-way boundary: skillhost → conductor).
    #[must_use]
    pub fn new(store: Arc<ConductorStore>) -> Self {
        Self { store }
    }
}

impl SkillHostAudit for ConductorStoreSkillAudit {
    fn record(&self, record: SkillHostAuditRecord) -> Result<(), SkillHostAuditError> {
        self.store
            .append_skillhost_audit(&record)
            .map_err(|e| SkillHostAuditError::Write(e.to_string()))
    }
}

// ---------------------------------------------------------------------------
// test support
// ---------------------------------------------------------------------------

/// In-memory sink for tests: captures every record.
#[cfg(test)]
#[derive(Default, Clone)]
pub struct CapturingSkillAudit {
    records: std::sync::Arc<std::sync::Mutex<Vec<SkillHostAuditRecord>>>,
    fail: std::sync::Arc<std::sync::Mutex<bool>>,
}

#[cfg(test)]
impl CapturingSkillAudit {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Force `record()` to fail — proves fail-closed execution behavior.
    pub fn set_failing(&self) {
        *self.fail.lock().expect("audit mutex poisoned") = true;
    }

    #[must_use]
    pub fn snapshot(&self) -> Vec<SkillHostAuditRecord> {
        self.records.lock().expect("audit mutex poisoned").clone()
    }
}

#[cfg(test)]
impl SkillHostAudit for CapturingSkillAudit {
    fn record(&self, record: SkillHostAuditRecord) -> Result<(), SkillHostAuditError> {
        if *self.fail.lock().expect("audit mutex poisoned") {
            return Err(SkillHostAuditError::Write("injected failure".into()));
        }
        self.records
            .lock()
            .expect("audit mutex poisoned")
            .push(record);
        Ok(())
    }
}
