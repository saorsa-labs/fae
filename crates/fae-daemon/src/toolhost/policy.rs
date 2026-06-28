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
use crate::toolhost::damage::is_catastrophic_command;
use crate::toolhost::egress::{EgressDecision, ToolEgressGate};

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

    /// Record an allow decision; fail-closed (an audit write failure denies).
    fn decide_allowed(&self, tool: &str, risk_label: &'static str) -> PolicyVerdict {
        let rec = ToolHostAuditRecord {
            event_type: "tool_policy",
            ts_ms: self.gov.now_ms,
            tool: tool.to_string(),
            call_id: self.gov.call_id.clone(),
            decision: AuditDecision::Allowed,
            reason: "allowed".into(),
            risk_class: risk_label,
        };
        match self.gov.audit.record(rec) {
            Ok(()) => PolicyVerdict::Allow,
            Err(e) => PolicyVerdict::Deny(format!("audit_write_failed: {e}")),
        }
    }

    /// Record a deny decision (best-effort audit: the decision is already Deny).
    fn decide_denied(&self, tool: &str, risk_label: &'static str, reason: &str) -> PolicyVerdict {
        let rec = ToolHostAuditRecord {
            event_type: "tool_policy",
            ts_ms: self.gov.now_ms,
            tool: tool.to_string(),
            call_id: self.gov.call_id.clone(),
            decision: AuditDecision::Denied,
            reason: reason.into(),
            risk_class: risk_label,
        };
        if let Err(e) = self.gov.audit.record(rec) {
            tracing::warn!(
                tool = %tool,
                call_id = %self.gov.call_id,
                error = %e,
                "toolhost deny-path audit write failed"
            );
        }
        PolicyVerdict::Deny(reason.into())
    }
}

#[async_trait]
impl ToolPolicy for FaeToolPolicy {
    async fn check(&self, tool: &str, input: &Value, _ctx: &InvokeContext) -> PolicyVerdict {
        // 1. Classify (deny-until-classified).
        let Some(rc) = classify(tool) else {
            return self.decide_denied(tool, "Unknown", "unknown_tool");
        };
        let risk_label = rc.label();

        // 2. Control-plane authorize.
        let cmd = Command {
            v: PROTOCOL_VERSION,
            request_id: self.gov.call_id.clone(),
            command: rc.scope_command().into(),
            payload: Value::Null,
        };
        match authorize(&self.gov.client, &cmd, self.gov.now_ms) {
            AuthzDecision::Allow => {}
            AuthzDecision::ConfirmRequired => {
                // §4.1 trap: no confirmation channel until A3.
                return self.decide_denied(tool, risk_label, "confirm_required_mapped_to_deny");
            }
            AuthzDecision::Deny(reason) => {
                return self.decide_denied(tool, risk_label, deny_reason_label(reason));
            }
        }

        // 3. PathPolicy (per-tool extractor; absent optional field ⇒ allow).
        if let PathProbe::Paths(paths) = path_probe(rc, input) {
            for p in &paths {
                if path_is_escape(p) {
                    return self.decide_denied(tool, risk_label, "path_escape");
                }
            }
        }

        // 4. DamageControl (Shell only).
        if matches!(rc, RiskClass::Shell) {
            if let Some(cmd_str) = input.get("command").and_then(Value::as_str) {
                if is_catastrophic_command(cmd_str) {
                    return self.decide_denied(tool, risk_label, "damage_control");
                }
            }
        }

        // 5. Egress gate (Networked only — the 3-gate wrapper seam).
        if matches!(rc, RiskClass::Networked) {
            match self.gov.egress.check_network_tool(tool, input).await {
                EgressDecision::Allow => {}
                EgressDecision::Deny(reason) => {
                    return self.decide_denied(tool, risk_label, reason.as_label());
                }
            }
        }

        // 6. Allow + audit (fail-closed).
        self.decide_allowed(tool, risk_label)
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
