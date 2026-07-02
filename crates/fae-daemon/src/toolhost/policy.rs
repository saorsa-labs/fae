//! The governed tool-policy pipeline (ADR-013 Vision A, A2).
//!
//! [`FaeToolPolicy`] implements [`fluers_core::ToolPolicy`]. Its [`check`]
//! runs the §5.2 pipeline and returns [`PolicyVerdict::Allow`] or
//! [`PolicyVerdict::Deny`] — **never `Confirm`** (the fluers loop treats
//! `Confirm` as allow-with-log, so emitting it would silently allow dangerous
//! tools; see the §4.1 trap below).
//!
//! ## Pipeline (§5.2)
//! 1. **Classify** by name → [`RiskClass`]. Unknown → deny (deny-until-classified).
//! 2. **Control-plane `authorize`** with the risk's scope command.
//!    - `Allow` → continue.
//!    - `Deny(reason)` → deny + audit (`missing_scope`/etc.).
//!    - `ConfirmRequired` → **deny + audit** (§4.1 trap: no confirmation channel
//!      until A3).
//! 3. **PathPolicy** — per-tool path extractor; reject escapes (absolute, `..`,
//!    backslash, Windows drive). Absent optional field (grep `paths`) = allow.
//! 4. **DamageControl** — `bash` catastrophic-pattern denylist.
//! 5. **Egress gate** — `Networked` tools only (the 3-gate wrapper seam).
//! 6. **Allow + audit** (fail-closed: an audit write failure denies).
//!
//! ## The §4.1 `Confirm` trap
//! `fae_control_plane::authorize` returns [`AuthzDecision::ConfirmRequired`]
//! whenever a command needs `Scope::ToolExecuteDangerous` and the client holds
//! that scope. There is no confirmation channel until A3, so we map
//! `ConfirmRequired` → `Deny`. Returning `PolicyVerdict::Confirm` instead would
//! be a silent-allow bypass (the fluers loop treats `Confirm` as `Allow`).
//!
//! ## Networked → `safe` scope (documented deviation from scope rev 3 §5.2)
//! The scope table listed networked tools as `tool.execute_dangerous`. That
//! makes the egress gate (step 5) **unreachable**: `dangerous` ⇒ step 2 returns
//! `ConfirmRequired` ⇒ we deny before step 5. A networked tool's risk is
//! *egress* (data leaving the device), gated by the egress membrane — not local
//! destruction (gated by the confirm flow). So networked tools map to
//! `tool.execute_safe` and the egress gate IS their authorization. With the A2
//! [`DisabledGate`](crate::toolhost::egress::DisabledGate) they still deny
//! (fail-closed); the gate is now load-bearing and testable. Flagged for
//! oracle/review.

use std::sync::Arc;

use async_trait::async_trait;
use fae_control_plane::{
    authorize, AuthzDecision, ClientRecord, Command, DenyReason, PROTOCOL_VERSION,
};
use fluers_core::tool::InvokeContext;
use fluers_core::{PolicyVerdict, ToolPolicy};
use serde_json::Value;

use crate::toolhost::audit::{AuditDecision, ToolHostAudit, ToolHostAuditRecord};
use crate::toolhost::damage::{classify_bash, classify_path_arg, is_workspace_wipe, DamageVerdict};
use crate::toolhost::egress::{EgressDecision, ToolEgressGate};

/// (A3→B) Whether the ToolHost root is the ephemeral temp sandbox or an
/// owner-approved durable workspace directory. Drives the workspace-wipe
/// damage control: `is_workspace_wipe` patterns are catastrophic ONLY under a
/// durable root (a temp-sandbox wipe is harmless — deleted on close anyway).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RootMode {
    TempSandbox,
    DurableWorkspace,
}

/// The risk profile assigned to a tool name. Each variant fixes its scope
/// command, path-extraction behavior, and which downstream gates apply.
///
/// Adding a new path-bearing tool REQUIRES adding it here with its field —
/// otherwise it stays [`Option::None`] from [`classify`] and is denied
/// (deny-until-classified / deny-until-extractor, structurally enforced).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RiskClass {
    /// `read` — safe, path field `path`.
    Read,
    /// `glob` — safe, path field `pattern`.
    Glob,
    /// `grep` — safe, path field `paths` (OPTIONAL: absent ⇒ path-less search).
    Grep,
    /// `write` — dangerous, path field `path`.
    Write,
    /// `edit` — dangerous, path field `path`.
    Edit,
    /// `bash` — dangerous, no path, damage-control applies.
    Shell,
    /// `web_search`/`fetch_url` — safe scope, egress gate applies.
    Networked,
}

impl RiskClass {
    /// The control-plane command used to authorize this class.
    fn scope_command(self) -> &'static str {
        match self {
            // Local read-only + networked (egress is the gate, not the scope).
            Self::Read | Self::Glob | Self::Grep | Self::Networked => "tool.execute_safe",
            // Local destructive — confirm flow (denies until A3).
            Self::Write | Self::Edit | Self::Shell => "tool.execute_dangerous",
        }
    }

    /// Short static label for the audit row.
    fn label(self) -> &'static str {
        match self {
            Self::Read => "Read",
            Self::Glob => "Glob",
            Self::Grep => "Grep",
            Self::Write => "Write",
            Self::Edit => "Edit",
            Self::Shell => "Shell",
            Self::Networked => "Networked",
        }
    }
}

/// Classify a tool name. `None` ⇒ unknown ⇒ the policy denies (fail-closed).
///
/// The known set mirrors the fluers `mvp_tools` registry (`read`/`write`/`edit`/
/// `bash`/`glob`/`grep`) plus the roadmap networked tools (`web_search`/
/// `fetch_url`, classified now so the egress wiring is structural even though
/// the tools themselves land on A2.5/P7).
fn classify(name: &str) -> Option<RiskClass> {
    match name {
        "read" => Some(RiskClass::Read),
        "glob" => Some(RiskClass::Glob),
        "grep" => Some(RiskClass::Grep),
        "write" => Some(RiskClass::Write),
        "edit" => Some(RiskClass::Edit),
        "bash" => Some(RiskClass::Shell),
        "web_search" | "fetch_url" => Some(RiskClass::Networked),
        _ => None,
    }
}

/// The set of path strings to inspect for a call. `NotPathBearing` skips the
/// path check; `Paths([])` is a path-bearing call with no paths to inspect
/// (missing required field — fluers' `validate_input` rejects it — OR a
/// legitimate path-less grep) and is allowed.
enum PathProbe<'a> {
    NotPathBearing,
    Paths(Vec<&'a str>),
}

/// Extract the path strings to inspect for `rc` from `input`.
fn path_probe<'a>(rc: RiskClass, input: &'a Value) -> PathProbe<'a> {
    match rc {
        RiskClass::Shell | RiskClass::Networked => PathProbe::NotPathBearing,
        RiskClass::Read | RiskClass::Write | RiskClass::Edit => {
            PathProbe::Paths(field_strs(input, "path"))
        }
        RiskClass::Glob => PathProbe::Paths(field_strs(input, "pattern")),
        RiskClass::Grep => {
            // `paths` is OPTIONAL: absent ⇒ path-less search of the contained
            // root (owner watch-item, scope rev 3). Allow.
            match input.get("paths") {
                None | Some(Value::Null) => PathProbe::Paths(Vec::new()),
                Some(Value::Array(arr)) => {
                    PathProbe::Paths(arr.iter().filter_map(Value::as_str).collect())
                }
                // Wrong type: let fluers' validate_input reject it; nothing to
                // escape-check.
                Some(_) => PathProbe::Paths(Vec::new()),
            }
        }
    }
}

/// Read a single string field into a 0/1-element vec (missing/wrong-type ⇒ empty).
fn field_strs<'a>(input: &'a Value, field: &str) -> Vec<&'a str> {
    input
        .get(field)
        .and_then(Value::as_str)
        .into_iter()
        .collect()
}

/// True if a path string looks like an escape attempt.
///
/// Defense-in-depth ahead of `LocalSessionEnv`'s own containment (which is
/// accidental-escape-only). Rejects: leading `/`, any `..`, any `\` (Windows
/// separator/escape), and Windows drive prefixes (`C:`).
fn path_is_escape(p: &str) -> bool {
    if p.is_empty() {
        return false;
    }
    p.starts_with('/') || p.contains("..") || p.contains('\\') || windows_drive_prefix(p)
}

/// Detect a `X:` Windows drive prefix.
fn windows_drive_prefix(p: &str) -> bool {
    let mut chars = p.chars();
    let Some(drive) = chars.next() else {
        return false;
    };
    drive.is_ascii_alphabetic() && chars.next() == Some(':')
}

fn deny_reason_label(r: DenyReason) -> &'static str {
    match r {
        DenyReason::ClientRevoked => "client_revoked",
        DenyReason::TokenExpired => "token_expired",
        DenyReason::UnknownCommand => "unknown_command",
        DenyReason::MissingScope => "missing_scope",
        DenyReason::WrongProtocolVersion => "wrong_protocol_version",
    }
}

/// Run-scoped governance state. The fields fluers' `InvokeContext` does NOT
/// carry (it has only `tool_call_id` + a cancel token), held in an `Arc` so the
/// `&self` policy impl can read them per-call.
pub struct ToolHostGovernance {
    /// Control-plane identity for `authorize`.
    pub(crate) client: ClientRecord,
    /// Fail-closed policy audit sink.
    pub(crate) audit: Arc<dyn ToolHostAudit>,
    /// The networked-tool egress gate.
    pub(crate) egress: Arc<dyn ToolEgressGate>,
    /// Decision time, ms since UNIX epoch (also the authorize `now_ms`).
    pub(crate) now_ms: u64,
    /// The tool-call id (audit correlation).
    pub(crate) call_id: String,
    /// (A3→B) Temp sandbox vs durable workspace — drives the workspace-wipe
    /// damage control.
    pub(crate) root_mode: RootMode,
    /// (B3) The resolved home directory, for the absolute-path spelling of the
    /// protected/credential-path damage control (`~`/`$HOME` symbolic spellings
    /// are caught without it). `None` ⇒ only the symbolic spellings are scanned.
    pub(crate) home: Option<String>,
}

/// The internal (non-fluers) evaluation outcome — richer than
/// [`PolicyVerdict`], which cannot carry "needs confirmation" safely (fluers'
/// loop treats `Confirm` as allow-with-log, the §4.1 trap). The governed
/// ToolHost path consumes this; the fluers-loop [`check`](FaeToolPolicy::check)
/// maps `NeedsConfirmation` → `Deny`.
pub(crate) enum EvalDecision {
    Allow,
    Deny(String),
    /// A dangerous tool that passed path/damage/egress and now needs the
    /// owner's confirmation (via `tool.confirm`) before it may execute.
    NeedsConfirmation(String),
}

/// A pure pipeline decision (no audit). `risk_label` is the [`RiskClass`] label
/// for the audit row the caller records.
pub(crate) struct Evaluated {
    pub(crate) risk_label: &'static str,
    pub(crate) decision: EvalDecision,
}

impl Evaluated {
    fn deny(risk_label: &'static str, reason: &str) -> Self {
        Self {
            risk_label,
            decision: EvalDecision::Deny(reason.into()),
        }
    }
}

/// The Fae tool policy: composes control-plane scope + path/damage/egress gates
/// into one `check` that never emits `Confirm`.
pub struct FaeToolPolicy {
    gov: Arc<ToolHostGovernance>,
}
impl FaeToolPolicy {
    /// Bind a fresh policy to one call's governance state.
    #[must_use]
    pub fn new(gov: Arc<ToolHostGovernance>) -> Self {
        Self { gov }
    }

    /// The real pipeline (steps 1–5), returning a pure decision WITHOUT
    /// auditing. Two callers: [`check`](FaeToolPolicy::check) (the fluers-loop
    /// path — denies on `NeedsConfirmation`) and the governed ToolHost path
    /// (`execute_governed`, which performs the `tool.confirm` round-trip).
    ///
    /// Ordering (scope §6.2): `ConfirmRequired` from authorize is **deferred**
    /// — path/damage/egress run first, so a path-escaping or catastrophic
    /// dangerous call denies before ever prompting the owner.
    pub(crate) async fn evaluate(&self, tool: &str, input: &Value) -> Evaluated {
        // 1. Classify (deny-until-classified).
        let Some(rc) = classify(tool) else {
            return Evaluated::deny("Unknown", "unknown_tool");
        };
        let risk_label = rc.label();

        // 2. Control-plane authorize. ConfirmRequired is DEFERRED (not returned
        //    yet) so steps 3–5 run first (scope §6.2).
        let cmd = Command {
            v: PROTOCOL_VERSION,
            request_id: self.gov.call_id.clone(),
            command: rc.scope_command().into(),
            payload: Value::Null,
        };
        let mut needs_confirm = false;
        match authorize(&self.gov.client, &cmd, self.gov.now_ms) {
            AuthzDecision::Allow => {}
            AuthzDecision::ConfirmRequired => needs_confirm = true,
            AuthzDecision::Deny(reason) => {
                return Evaluated::deny(risk_label, deny_reason_label(reason));
            }
        }

        // 3. PathPolicy (per-tool extractor; absent optional field ⇒ allow) +
        //    (B3) protected/credential-path damage control for read/write/edit.
        if let PathProbe::Paths(paths) = path_probe(rc, input) {
            for p in &paths {
                if path_is_escape(p) {
                    return Evaluated::deny(risk_label, "path_escape");
                }
            }
            // Block reads/writes/edits of home-anchored credential/identity
            // material (parity with Swift DamageControlPolicy's zero-access set).
            // glob/grep patterns are searches, not file targets — Swift gates
            // read/write/edit/bash, so we mirror that scope.
            if matches!(rc, RiskClass::Read | RiskClass::Write | RiskClass::Edit) {
                for p in &paths {
                    if let DamageVerdict::Block(reason) = classify_path_arg(p) {
                        return Evaluated::deny(risk_label, reason);
                    }
                }
            }
        }

        // 4. DamageControl (Shell only) — three-tier verdict (B3).
        if matches!(rc, RiskClass::Shell) {
            if let Some(cmd_str) = input.get("command").and_then(Value::as_str) {
                match classify_bash(cmd_str, self.gov.home.as_deref()) {
                    DamageVerdict::Allow => {}
                    // Hard deny (root delete, disk format, credential/identity access).
                    DamageVerdict::Block(reason) => return Evaluated::deny(risk_label, reason),
                    // Catastrophic: the daemon denies, but loudly (never a silent
                    // Disaster deny — the Swift tier's physical-click escape hatch
                    // has no daemon analogue).
                    DamageVerdict::Disaster(reason) => {
                        tracing::warn!(
                            tool = %tool,
                            call_id = %self.gov.call_id,
                            reason = %reason,
                            "damage-control DISASTER verdict — denied"
                        );
                        return Evaluated::deny(risk_label, reason);
                    }
                    // Dangerous-but-legitimate → surface the owner confirmation.
                    // (bash already carries `tool.execute_dangerous` scope, so
                    // `needs_confirm` is typically already set; this keeps the
                    // mapping explicit and covers any future safe-scoped shell.)
                    DamageVerdict::ConfirmRequired(_) => needs_confirm = true,
                }
                // A3→B: under a DURABLE root, workspace-wipe commands (rm -rf .,
                // git clean -fdx, ...) are catastrophic (real files) — deny BEFORE
                // the confirm (scope §6.2). Under the temp sandbox they're harmless.
                if self.gov.root_mode == RootMode::DurableWorkspace && is_workspace_wipe(cmd_str) {
                    return Evaluated::deny(risk_label, "workspace_wipe_blocked");
                }
            }
        }

        // 5. Egress gate (Networked only — the 3-gate wrapper seam).
        if matches!(rc, RiskClass::Networked) {
            match self.gov.egress.check_network_tool(tool, input).await {
                EgressDecision::Allow => {}
                EgressDecision::Deny(reason) => {
                    return Evaluated::deny(risk_label, reason.as_label());
                }
            }
        }

        // 6. Resolve: the deferred confirmation surfaces here (path/damage/
        //    egress all passed), or allow.
        if needs_confirm {
            Evaluated {
                risk_label,
                decision: EvalDecision::NeedsConfirmation(
                    "dangerous_tool_requires_confirmation".into(),
                ),
            }
        } else {
            Evaluated {
                risk_label,
                decision: EvalDecision::Allow,
            }
        }
    }

    /// Record the final decision to the audit log. Returns `false` on write
    /// failure so the governed-execute caller can fail-closed (deny). The
    /// fluers-loop path embeds this in `decide_allowed`/`decide_denied`.
    pub(crate) fn record_audit(
        &self,
        tool: &str,
        risk_label: &'static str,
        decision: AuditDecision,
        reason: &str,
    ) -> bool {
        let rec = ToolHostAuditRecord {
            event_type: "tool_policy",
            ts_ms: self.gov.now_ms,
            tool: tool.to_string(),
            call_id: self.gov.call_id.clone(),
            decision,
            reason: reason.into(),
            risk_class: risk_label,
        };
        match self.gov.audit.record(rec) {
            Ok(()) => true,
            Err(e) => {
                tracing::warn!(
                    tool = %tool,
                    call_id = %self.gov.call_id,
                    error = %e,
                    "toolhost audit write failed"
                );
                false
            }
        }
    }

    /// Record an allow decision; fail-closed (an audit write failure denies).
    fn decide_allowed(&self, tool: &str, risk_label: &'static str, reason: &str) -> PolicyVerdict {
        if self.record_audit(tool, risk_label, AuditDecision::Allowed, reason) {
            PolicyVerdict::Allow
        } else {
            PolicyVerdict::Deny("audit_write_failed".into())
        }
    }

    /// Record a deny decision (best-effort audit: the decision is already Deny).
    fn decide_denied(&self, tool: &str, risk_label: &'static str, reason: &str) -> PolicyVerdict {
        // Best-effort: the decision is already Deny; an audit failure is logged
        // inside record_audit but does not change the outcome.
        let _ = self.record_audit(tool, risk_label, AuditDecision::Denied, reason);
        PolicyVerdict::Deny(reason.into())
    }
}

#[async_trait]
impl ToolPolicy for FaeToolPolicy {
    async fn check(&self, tool: &str, input: &Value, _ctx: &InvokeContext) -> PolicyVerdict {
        // The fluers-loop path: run the full pipeline, but a NeedsConfirmation
        // outcome (dangerous tool) is DENIED here — the §4.1 trap. The governed
        // ToolHost path (execute_governed) calls evaluate() directly and
        // performs the tool.confirm round-trip instead. This keeps FaeToolPolicy
        // safe to wire into fluers' run_agent: it never emits Confirm, so it can
        // never become a silent-allow.
        let ev = self.evaluate(tool, input).await;
        match ev.decision {
            EvalDecision::Allow => self.decide_allowed(tool, ev.risk_label, "allowed"),
            EvalDecision::Deny(reason) => self.decide_denied(tool, ev.risk_label, &reason),
            EvalDecision::NeedsConfirmation(_) => {
                self.decide_denied(tool, ev.risk_label, "confirm_required_via_loop_bypass")
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_escape_detects_common_vectors() {
        assert!(path_is_escape("../secret"));
        assert!(path_is_escape("a/../b"));
        assert!(path_is_escape("/etc/passwd"));
        assert!(path_is_escape("a\\b"));
        assert!(path_is_escape("C:/windows"));
        assert!(path_is_escape("d:/x"));
    }

    #[test]
    fn path_escape_allows_relative_clean() {
        assert!(!path_is_escape("src/main.rs"));
        assert!(!path_is_escape("a/b/c.txt"));
        assert!(!path_is_escape("file.txt"));
        assert!(!path_is_escape(""));
    }

    #[test]
    fn classify_known_and_unknown() {
        assert_eq!(classify("read"), Some(RiskClass::Read));
        assert_eq!(classify("grep"), Some(RiskClass::Grep));
        assert_eq!(classify("bash"), Some(RiskClass::Shell));
        assert_eq!(classify("web_search"), Some(RiskClass::Networked));
        assert_eq!(classify("rm-rf"), None);
        assert_eq!(classify("edit_tool"), None);
    }

    #[test]
    fn grep_probe_absent_paths_is_empty_allow() {
        // Only `pattern`, no `paths` ⇒ path-less search ⇒ nothing to inspect.
        let input = serde_json::json!({"pattern": "foo"});
        match path_probe(RiskClass::Grep, &input) {
            PathProbe::Paths(v) => assert!(v.is_empty()),
            _ => panic!("grep without paths must probe an empty path list"),
        }
    }

    #[test]
    fn grep_probe_with_paths_extracts_each() {
        let input = serde_json::json!({"pattern": "x", "paths": ["a.txt", "../b"]});
        match path_probe(RiskClass::Grep, &input) {
            PathProbe::Paths(v) => assert_eq!(v, vec!["a.txt", "../b"]),
            _ => panic!("must extract paths"),
        }
    }
}
