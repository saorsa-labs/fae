//! ADR-013 Vision A — the daemon governed tool-execution host (A2-body).
//!
//! [`ToolHost`] runs fluers native tools (`read`/`write`/`edit`/`bash`/`glob`/
//! `grep`) over a [`LocalSessionEnv`], **behind** a [`FaeToolPolicy`] that
//! composes the control-plane scope check + a Fae-owned path/damage/egress
//! stack, with every decision producing a fail-closed audit row. This is the
//! governed entry point A3 (the protocol surface) will wrap in `toolhost.execute`;
//! raw [`fluers_core::Tool::execute`] is NOT exposed outside this module.
//!
//! **Vision-B boundary (unchanged):** no loop relocation, no
//! conductor-as-`ModelProvider`, no `RemoteSwiftTool`. The Swift multi-turn loop
//! still drives; it calls INTO this host for portable/native tool execution.
//!
//! This module is a sibling of `conductor/` (tool *execution* is a separate
//! daemon subsystem from *routing*) and is outside the mesh/metaopt boundary
//! guards (those protect the conductor core from x0x/metaopt deps; fluers is the
//! sanctioned substrate, and toolhost depends one-way on conductor governance).
//!
//! See `docs/plans/vision-a-a2-toolhost-scope-2026-06-29.md` (reviewer-approved;
//! owner accepted the networked→`safe` scope deviation 2026-06-29) for the full
//! design, the §4.1/§4.2 traps, and the open questions.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use fluers_core::tool::{InvokeContext, Tool, ToolResult};
use fluers_core::ToolPolicy;
use fluers_runtime::{Limits, LocalSessionEnv, SessionEnv};
use serde_json::Value;
use tokio_util::sync::CancellationToken;

use crate::conductor::ConductorStore;
use crate::toolhost::audit::{AuditDecision, ConductorStoreAudit, ToolHostAudit};
use crate::toolhost::confirm::{build_detail, ConfirmReply, ConfirmRequest, ToolConfirmation};
use crate::toolhost::egress::{DisabledGate, ToolEgressGate};
use crate::toolhost::policy::{EvalDecision, FaeToolPolicy, ToolHostGovernance};
use fae_control_plane::ClientRecord;

pub mod audit;
pub mod confirm;
pub mod damage;
pub mod egress;
pub mod isolation;
pub mod policy;
pub mod root_confirm;

use crate::toolhost::isolation::{IsolationMode, JailedSessionEnv, ToolOrigin};

/// A request to execute one tool call under governance.
#[derive(Debug, Clone)]
pub struct ToolHostRequest {
    /// The control-plane identity (scopes drive `authorize`).
    pub client: ClientRecord,
    /// Tool name (`read`, `write`, `bash`, …).
    pub tool: String,
    /// The tool's JSON input.
    pub input: Value,
    /// Correlation id (audit + fluers `InvokeContext`).
    pub call_id: String,
    /// Cooperative cancellation.
    pub cancel: CancellationToken,
    /// (B2) Where the call originated. Drives the required [`IsolationMode`]:
    /// non-interactive origins require the OS jail; an owner's interactive turn
    /// may run on the host. No `Default` — every construction states it.
    pub origin: ToolOrigin,
}

/// The governed outcome of one tool call.
#[derive(Debug, Clone)]
pub struct ToolHostResult {
    /// The tool's output (only present when the policy allowed + the tool ran).
    pub output: ToolResult,
}

/// A tool-host error. Every non-`Ok` path is a deny (fail-closed).
#[derive(Debug, thiserror::Error)]
pub enum ToolHostError {
    /// The policy denied the call (scope, path, damage, egress, confirm, …).
    #[error("tool call denied: {0}")]
    Denied(String),
    /// The tool name was classified but is not in the registry (defense-in-depth;
    /// the policy should have denied it as unknown first).
    #[error("tool not registered: {0}")]
    UnknownTool(String),
    /// The underlying tool execution failed.
    #[error("tool execution failed: {0}")]
    Tool(String),
    /// The sandbox root could not be created.
    #[error("sandbox root error: {0}")]
    Sandbox(String),
}

/// The clock the host consults for `authorize`'s `now_ms` + audit timestamps.
pub trait ToolHostClock: Send + Sync {
    /// Milliseconds since the UNIX epoch.
    fn now_ms(&self) -> u64;
}

/// Production clock: reads `SystemTime::now()`.
#[derive(Default, Clone, Copy)]
pub struct SystemToolHostClock;

impl ToolHostClock for SystemToolHostClock {
    fn now_ms(&self) -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }
}

/// The governed tool-execution host.
///
/// Owns the sandbox ([`LocalSessionEnv`]) + the tool registry, and runs every
/// call through [`FaeToolPolicy`] before dispatch. Construct via [`ToolHost::new`]
/// (A3 wires the real instance in `main.rs`; A2 proves the surface in tests).
pub struct ToolHost {
    #[allow(dead_code)] // exercised by execute(); kept for future A3 introspection.
    env: Arc<LocalSessionEnv>,
    /// Host-tier tools (bare fluers env — path-confined only).
    registry: HashMap<String, Arc<dyn Tool>>,
    /// (B2) Jailed-tier tools: identical set built over a [`JailedSessionEnv`]
    /// whose `exec` runs inside an OS sandbox. Selected per-call by isolation.
    jailed_registry: HashMap<String, Arc<dyn Tool>>,
    /// (B2) Whether the OS sandbox backend is present. When `false`, a call that
    /// *requires* the jail fails closed (deny) rather than degrading to host.
    jail_available: bool,
    audit: Arc<dyn ToolHostAudit>,
    egress: Arc<dyn ToolEgressGate>,
    clock: Arc<dyn ToolHostClock>,
    /// (A3→B) Temp sandbox vs durable workspace — drives the workspace-wipe
    /// damage control in `evaluate`.
    root_mode: crate::toolhost::policy::RootMode,
}

impl ToolHost {
    /// Build a host over a fresh sandbox root with the default (fail-closed)
    /// audit + egress wiring.
    ///
    /// `store` is the shared conductor store (audit rows land in
    /// `toolhost_audit.jsonl`, a sibling of the conductor telemetry files —
    /// never `fae.db`). Networked tools use [`DisabledGate`] (all deny) until
    /// the conductor-backed 3-gate adapter is wired (A2.5/P7).
    ///
    /// # Errors
    /// Returns [`ToolHostError::Sandbox`] if the root cannot be created.
    pub async fn new(
        root: PathBuf,
        limits: Limits,
        store: Arc<ConductorStore>,
    ) -> Result<Self, ToolHostError> {
        Self::with_wiring(
            root,
            limits,
            Arc::new(ConductorStoreAudit::new(store)),
            Arc::new(DisabledGate),
            Arc::new(SystemToolHostClock),
            crate::toolhost::policy::RootMode::TempSandbox,
        )
        .await
    }

    /// (A3→B) Build a host over an owner-approved DURABLE workspace root.
    /// Enables the workspace-wipe damage control (rm -rf . etc. deny before
    /// confirm). Use [`ToolHost::new`] for the ephemeral temp sandbox.
    pub async fn new_durable(
        root: PathBuf,
        limits: Limits,
        store: Arc<ConductorStore>,
    ) -> Result<Self, ToolHostError> {
        Self::with_wiring(
            root,
            limits,
            Arc::new(ConductorStoreAudit::new(store)),
            Arc::new(DisabledGate),
            Arc::new(SystemToolHostClock),
            crate::toolhost::policy::RootMode::DurableWorkspace,
        )
        .await
    }

    /// Build a host with explicit audit/egress/clock wiring.
    async fn with_wiring(
        root: PathBuf,
        limits: Limits,
        audit: Arc<dyn ToolHostAudit>,
        egress: Arc<dyn ToolEgressGate>,
        clock: Arc<dyn ToolHostClock>,
        root_mode: crate::toolhost::policy::RootMode,
    ) -> Result<Self, ToolHostError> {
        // Resolve the canonical real root BEFORE building the env (the seatbelt
        // profile / landlock ruleset are generated from it verbatim). The dir is
        // created by LocalSessionEnv::new, so canonicalize afterwards.
        let env = Arc::new(
            LocalSessionEnv::new(root.clone(), limits)
                .await
                .map_err(|e| ToolHostError::Sandbox(e.to_string()))?,
        );
        let real_root = tokio::fs::canonicalize(&root)
            .await
            .map_err(|e| ToolHostError::Sandbox(e.to_string()))?;

        let index = |tools: Vec<Arc<dyn Tool>>| -> HashMap<String, Arc<dyn Tool>> {
            tools
                .into_iter()
                .map(|t| {
                    let name = t.definition().name.clone();
                    (name, t)
                })
                .collect()
        };
        let registry = index(fluers_runtime::tool::mvp_tools_with_limits(
            Arc::clone(&env) as Arc<dyn SessionEnv>,
            limits,
        ));
        // The jailed toolset shares the same inner env (reads/writes/glob/grep
        // are already fd-anchored); only `exec` is intercepted by the OS jail.
        let jailed_env: Arc<dyn SessionEnv> =
            Arc::new(JailedSessionEnv::new(Arc::clone(&env), real_root));
        let jailed_registry = index(fluers_runtime::tool::mvp_tools_with_limits(
            jailed_env, limits,
        ));
        Ok(Self {
            env,
            registry,
            jailed_registry,
            jail_available: isolation::jail_backend_available(),
            audit,
            egress,
            clock,
            root_mode,
        })
    }

    /// The governed entry point. Runs the policy; on `Allow` dispatches the
    /// tool. This is the ONLY public path to tool execution.
    ///
    /// # Errors
    /// [`ToolHostError::Denied`] for any policy deny (incl. the §4.1 confirm
    /// trap); [`ToolHostError::UnknownTool`] for a classified-but-unregistered
    /// tool; [`ToolHostError::Tool`] for an execution failure.
    pub async fn execute(&self, req: ToolHostRequest) -> Result<ToolHostResult, ToolHostError> {
        let isolation = req.origin.required_isolation();
        let gov = Arc::new(ToolHostGovernance {
            client: req.client.clone(),
            audit: Arc::clone(&self.audit),
            egress: Arc::clone(&self.egress),
            now_ms: self.clock.now_ms(),
            call_id: req.call_id.clone(),
            root_mode: self.root_mode,
            isolation,
        });
        let policy = FaeToolPolicy::new(Arc::clone(&gov));
        self.guard_isolation(&policy, &req, isolation)?;
        let ctx = InvokeContext {
            tool_call_id: req.call_id.clone(),
            cancel: req.cancel.clone(),
        };
        match policy.check(&req.tool, &req.input, &ctx).await {
            fluers_core::PolicyVerdict::Allow => {}
            fluers_core::PolicyVerdict::Confirm(reason) => {
                // Defense-in-depth: FaeToolPolicy must NEVER emit Confirm (the
                // fluers loop treats it as Allow). If it leaks, deny + audit.
                gov.audit
                    .record(crate::toolhost::audit::ToolHostAuditRecord {
                        event_type: "tool_policy",
                        ts_ms: gov.now_ms,
                        tool: req.tool.clone(),
                        call_id: req.call_id.clone(),
                        decision: crate::toolhost::audit::AuditDecision::Denied,
                        reason: "confirm_leaked_from_policy".into(),
                        risk_class: "Unknown",
                        isolation: gov.isolation.as_label(),
                    })
                    .ok();
                return Err(ToolHostError::Denied(format!(
                    "confirm leaked from policy: {reason}"
                )));
            }
            fluers_core::PolicyVerdict::Deny(reason) => {
                return Err(ToolHostError::Denied(reason));
            }
        }
        self.run_tool(&req, isolation).await
    }

    /// Governed execute WITH owner confirmation (A3 — the production path for
    /// `toolhost.execute`). Runs [`FaeToolPolicy::evaluate`]; on
    /// `NeedsConfirmation` performs the `tool.confirm` round-trip via
    /// `confirmation`. On approval the tool runs; any deny / timeout /
    /// disconnect / malformed reply fails closed.
    ///
    /// Distinct from [`execute`](Self::execute) (the fluers-loop path, which
    /// denies on `NeedsConfirmation`): this is the path that actually lets a
    /// dangerous tool proceed, behind the confirmation channel.
    pub async fn execute_governed(
        &self,
        req: ToolHostRequest,
        confirmation: &dyn ToolConfirmation,
    ) -> Result<ToolHostResult, ToolHostError> {
        let isolation = req.origin.required_isolation();
        let gov = Arc::new(ToolHostGovernance {
            client: req.client.clone(),
            audit: Arc::clone(&self.audit),
            egress: Arc::clone(&self.egress),
            now_ms: self.clock.now_ms(),
            call_id: req.call_id.clone(),
            root_mode: self.root_mode,
            isolation,
        });
        let policy = FaeToolPolicy::new(Arc::clone(&gov));
        self.guard_isolation(&policy, &req, isolation)?;
        let ev = policy.evaluate(&req.tool, &req.input).await;
        match ev.decision {
            EvalDecision::Allow => {
                if !policy.record_audit(&req.tool, ev.risk_label, AuditDecision::Allowed, "allowed")
                {
                    return Err(ToolHostError::Denied("audit_write_failed".into()));
                }
                self.run_tool(&req, isolation).await
            }
            EvalDecision::Deny(reason) => {
                let _ =
                    policy.record_audit(&req.tool, ev.risk_label, AuditDecision::Denied, &reason);
                Err(ToolHostError::Denied(reason))
            }
            EvalDecision::NeedsConfirmation(reason) => {
                // Build the bounded, redacted payload (scope §6.3).
                let old_exists = self.probe_old_exists(&req.tool, &req.input).await;
                let detail = match build_detail(&req.tool, &req.input, old_exists) {
                    Some(d) => d,
                    None => {
                        // A dangerous tool we can't summarize: deny rather than
                        // send a useless/ambiguous prompt.
                        let r = "confirm_detail_unbuildable";
                        let _ =
                            policy.record_audit(&req.tool, ev.risk_label, AuditDecision::Denied, r);
                        return Err(ToolHostError::Denied(r.into()));
                    }
                };
                let creq = ConfirmRequest {
                    tool: req.tool.clone(),
                    call_id: req.call_id.clone(),
                    risk_class: ev.risk_label.to_string(),
                    reason,
                    detail,
                };
                match confirmation.confirm(&creq).await {
                    ConfirmReply::Approved => {
                        if !policy.record_audit(
                            &req.tool,
                            ev.risk_label,
                            AuditDecision::Allowed,
                            "confirmed_by_owner",
                        ) {
                            return Err(ToolHostError::Denied("audit_write_failed".into()));
                        }
                        self.run_tool(&req, isolation).await
                    }
                    ConfirmReply::Denied(r) => {
                        let _ = policy.record_audit(
                            &req.tool,
                            ev.risk_label,
                            AuditDecision::Denied,
                            &r,
                        );
                        Err(ToolHostError::Denied(r))
                    }
                }
            }
        }
    }

    /// Fail-closed isolation gate (B2): if the call *requires* the OS jail but
    /// no backend is available, deny + audit BEFORE any policy evaluation or
    /// tool dispatch — never silently degrade to host execution.
    fn guard_isolation(
        &self,
        policy: &FaeToolPolicy,
        req: &ToolHostRequest,
        isolation: IsolationMode,
    ) -> Result<(), ToolHostError> {
        if isolation.requires_backend() && !self.jail_available {
            let reason = "isolation_unavailable";
            let _ = policy.record_audit(&req.tool, "Unknown", AuditDecision::Denied, reason);
            return Err(ToolHostError::Denied(reason.into()));
        }
        Ok(())
    }

    /// Dispatch an already-policy-checked tool call (the shared tail of
    /// [`execute`](Self::execute) and [`execute_governed`](Self::execute_governed)).
    /// `isolation` selects the tier: [`Jailed`](IsolationMode::Jailed) routes to
    /// the OS-sandboxed toolset, [`Host`](IsolationMode::Host) to the bare env.
    async fn run_tool(
        &self,
        req: &ToolHostRequest,
        isolation: IsolationMode,
    ) -> Result<ToolHostResult, ToolHostError> {
        let ctx = InvokeContext {
            tool_call_id: req.call_id.clone(),
            cancel: req.cancel.clone(),
        };
        let registry = match isolation {
            IsolationMode::Jailed => &self.jailed_registry,
            IsolationMode::Host => &self.registry,
        };
        let Some(tool) = registry.get(&req.tool) else {
            return Err(ToolHostError::UnknownTool(req.tool.clone()));
        };
        let output = tool
            .execute(ctx, req.input.clone())
            .await
            .map_err(|e| ToolHostError::Tool(e.to_string()))?;
        Ok(ToolHostResult { output })
    }

    /// Cheap existence probe for the file a write/edit targets (feeds the
    /// confirm payload's `old_exists` flag). Uses `read_file_full` with the edit
    /// byte cap: Ok ⇒ exists; `FileTooLarge` ⇒ exists (big); any other error ⇒
    /// absent. This is informational, not a gate (path/damage already ran in
    /// `evaluate`). (oracle MAJOR-4: was `read_file_full(path, 1)`, which
    /// reported false for any existing file > 1 byte.)
    async fn probe_old_exists(&self, tool: &str, input: &Value) -> bool {
        if !matches!(tool, "write" | "edit") {
            return false;
        }
        let Some(path) = input.get("path").and_then(Value::as_str) else {
            return false;
        };
        use fluers_runtime::RuntimeError;
        match self
            .env
            .read_file_full(std::path::Path::new(path), Limits::default().max_edit_bytes)
            .await
        {
            // File read fully ⇒ exists.
            Ok(_) => true,
            // File exists but exceeds the cap ⇒ exists (just large).
            Err(RuntimeError::FileTooLarge { .. }) => true,
            // Not found / unreadable / path issue ⇒ treat as absent.
            Err(_) => false,
        }
    }
}

#[cfg(test)]
impl ToolHost {
    /// Override the detected jail availability (to exercise the fail-closed
    /// path on a runner that actually has a backend).
    fn set_jail_available(&mut self, available: bool) {
        self.jail_available = available;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::toolhost::audit::CapturingAudit;
    use crate::toolhost::confirm::FakeConfirmation;
    use crate::toolhost::egress::{EgressDenyReason, FakeEgressGate};
    use fae_control_plane::{ClientClass, Scope};
    use fluers_core::ToolPolicy;
    use serde_json::json;

    /// A fixed clock for deterministic `now_ms` / audit timestamps.
    struct FixedClock;
    impl ToolHostClock for FixedClock {
        fn now_ms(&self) -> u64 {
            1_700_000_000_000
        }
    }

    fn client(scopes: &[Scope]) -> ClientRecord {
        ClientRecord {
            client_id: "test".into(),
            class: ClientClass::TestHarness,
            scopes: scopes.iter().cloned().collect(),
            issued_at_ms: 0,
            expires_at_ms: u64::MAX,
            revoked_at_ms: None,
            display_name: "Test".into(),
        }
    }

    fn gov(
        client: ClientRecord,
        audit: Arc<CapturingAudit>,
        egress: Arc<dyn ToolEgressGate>,
    ) -> Arc<ToolHostGovernance> {
        let audit_dyn: Arc<dyn ToolHostAudit> = audit;
        Arc::new(ToolHostGovernance {
            client,
            audit: audit_dyn,
            egress,
            now_ms: FixedClock.now_ms(),
            call_id: "call-1".into(),
            root_mode: crate::toolhost::policy::RootMode::TempSandbox,
            isolation: IsolationMode::Host,
        })
    }

    async fn check(
        client: ClientRecord,
        tool: &str,
        input: Value,
        audit: Arc<CapturingAudit>,
        egress: Arc<dyn ToolEgressGate>,
    ) -> fluers_core::PolicyVerdict {
        let g = gov(client, audit, egress);
        FaeToolPolicy::new(g).check(tool, &input, &ctx()).await
    }

    fn ctx() -> InvokeContext {
        InvokeContext {
            tool_call_id: "call-1".into(),
            cancel: CancellationToken::new(),
        }
    }

    // -----------------------------------------------------------------------
    // Scope + the §4.1 Confirm trap
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn safe_scope_allows_read_glob_grep() {
        let audit = Arc::new(CapturingAudit::new());
        let egress = Arc::new(FakeEgressGate::allow()) as Arc<dyn ToolEgressGate>;
        let c = client(&[Scope::ToolExecuteSafe]);
        assert!(matches!(
            check(
                c.clone(),
                "read",
                json!({"path":"a.txt"}),
                Arc::clone(&audit),
                Arc::clone(&egress)
            )
            .await,
            fluers_core::PolicyVerdict::Allow
        ));
        assert!(matches!(
            check(
                c.clone(),
                "glob",
                json!({"pattern":"*.rs"}),
                Arc::clone(&audit),
                Arc::clone(&egress)
            )
            .await,
            fluers_core::PolicyVerdict::Allow
        ));
        assert!(matches!(
            check(c, "grep", json!({"pattern":"foo"}), audit, egress).await,
            fluers_core::PolicyVerdict::Allow
        ));
    }

    #[tokio::test]
    async fn missing_scope_denies_and_audits() {
        let audit = Arc::new(CapturingAudit::new());
        // Client with NO tool scopes.
        let c = client(&[]);
        let v = check(
            c,
            "read",
            json!({"path":"a.txt"}),
            Arc::clone(&audit),
            Arc::new(FakeEgressGate::allow()) as Arc<dyn ToolEgressGate>,
        )
        .await;
        assert!(matches!(v, fluers_core::PolicyVerdict::Deny(_)));
        let rows = audit.snapshot();
        assert_eq!(rows.len(), 1);
        assert_eq!(
            rows[0].decision,
            crate::toolhost::audit::AuditDecision::Denied
        );
        assert_eq!(rows[0].reason, "missing_scope");
    }

    #[tokio::test]
    async fn dangerous_confirm_required_maps_to_deny_not_confirm() {
        // §4.1 trap: a scoped dangerous tool gets ConfirmRequired from
        // authorize, which we MUST map to Deny (never Confirm).
        let audit = Arc::new(CapturingAudit::new());
        let egress = Arc::new(FakeEgressGate::allow()) as Arc<dyn ToolEgressGate>;
        let c = client(&[Scope::ToolExecuteSafe, Scope::ToolExecuteDangerous]);
        let v = check(
            c,
            "bash",
            json!({"command":"echo hi"}),
            audit.clone(),
            egress,
        )
        .await;
        assert!(
            matches!(v, fluers_core::PolicyVerdict::Deny(_)),
            "dangerous + ConfirmRequired must Deny, got {v:?}"
        );
        // Crucially NOT Confirm:
        assert!(!matches!(v, fluers_core::PolicyVerdict::Confirm(_)));
        assert_eq!(
            audit.snapshot()[0].reason,
            "confirm_required_via_loop_bypass"
        );
    }

    #[tokio::test]
    async fn write_edit_bash_require_dangerous_scope() {
        let audit = Arc::new(CapturingAudit::new());
        let egress = Arc::new(FakeEgressGate::allow()) as Arc<dyn ToolEgressGate>;
        // Safe-only client → MissingScope for each dangerous tool.
        let c = client(&[Scope::ToolExecuteSafe]);
        for (tool, input) in [
            ("write", json!({"path":"a.txt","content":"x"})),
            (
                "edit",
                json!({"path":"a.txt","old_text":"a","new_text":"b"}),
            ),
            ("bash", json!({"command":"ls"})),
        ] {
            let v = check(
                c.clone(),
                tool,
                input,
                Arc::clone(&audit),
                Arc::clone(&egress),
            )
            .await;
            assert!(
                matches!(v, fluers_core::PolicyVerdict::Deny(_)),
                "{tool} must deny"
            );
        }
    }

    // -----------------------------------------------------------------------
    // PathPolicy (reachable for safe tools: read/glob/grep)
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn path_escape_denied_for_safe_read() {
        let audit = Arc::new(CapturingAudit::new());
        let egress = Arc::new(FakeEgressGate::allow()) as Arc<dyn ToolEgressGate>;
        let c = client(&[Scope::ToolExecuteSafe]);
        let v = check(
            c,
            "read",
            json!({"path":"../escape.txt"}),
            audit.clone(),
            egress,
        )
        .await;
        assert!(matches!(v, fluers_core::PolicyVerdict::Deny(r) if r == "path_escape"));
        assert_eq!(audit.snapshot()[0].reason, "path_escape");
    }

    #[tokio::test]
    async fn per_tool_extractor_catches_glob_pattern_and_grep_paths() {
        let audit = Arc::new(CapturingAudit::new());
        let egress = Arc::new(FakeEgressGate::allow()) as Arc<dyn ToolEgressGate>;
        let c = client(&[Scope::ToolExecuteSafe]);
        // glob uses `pattern`, not `path` — the extractor must catch it.
        let v = check(
            c.clone(),
            "glob",
            json!({"pattern":"../**/*"}),
            Arc::clone(&audit),
            Arc::clone(&egress),
        )
        .await;
        assert!(matches!(v, fluers_core::PolicyVerdict::Deny(_)));
        // grep uses `paths` — each entry checked.
        let v = check(
            c,
            "grep",
            json!({"pattern":"x","paths":["ok.txt","../bad"]}),
            audit,
            egress,
        )
        .await;
        assert!(matches!(v, fluers_core::PolicyVerdict::Deny(_)));
    }

    #[tokio::test]
    async fn grep_without_paths_is_allowed() {
        // Owner watch-item (rev 3): absent `paths` is a legitimate path-less
        // search of the contained root — must NOT be denied.
        let audit = Arc::new(CapturingAudit::new());
        let egress = Arc::new(FakeEgressGate::allow()) as Arc<dyn ToolEgressGate>;
        let c = client(&[Scope::ToolExecuteSafe]);
        let v = check(c, "grep", json!({"pattern":"foo"}), audit, egress).await;
        assert!(matches!(v, fluers_core::PolicyVerdict::Allow));
    }

    // -----------------------------------------------------------------------
    // Egress gate (reachable: networked → safe scope)
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn networked_tool_denied_by_disabled_gate() {
        let audit = Arc::new(CapturingAudit::new());
        let egress = Arc::new(DisabledGate) as Arc<dyn ToolEgressGate>;
        let c = client(&[Scope::ToolExecuteSafe]);
        let v = check(
            c,
            "web_search",
            json!({"query":"clean"}),
            audit.clone(),
            egress,
        )
        .await;
        assert!(matches!(v, fluers_core::PolicyVerdict::Deny(_)));
        assert_eq!(audit.snapshot()[0].reason, "egress_disabled");
    }

    #[tokio::test]
    async fn networked_tool_each_egress_deny_reason_audits_correctly() {
        let c = client(&[Scope::ToolExecuteSafe]);
        for (reason, want) in [
            (EgressDenyReason::ModeBlocked, "egress_mode_blocked"),
            (EgressDenyReason::NotProvisioned, "egress_not_provisioned"),
            (EgressDenyReason::PrivacyBlocked, "egress_privacy_blocked"),
        ] {
            let audit = Arc::new(CapturingAudit::new());
            let egress = Arc::new(FakeEgressGate::deny(reason)) as Arc<dyn ToolEgressGate>;
            let v = check(
                c.clone(),
                "fetch_url",
                json!({"url":"https://x"}),
                Arc::clone(&audit),
                egress,
            )
            .await;
            assert!(matches!(v, fluers_core::PolicyVerdict::Deny(_)), "{want}");
            assert_eq!(audit.snapshot()[0].reason, want);
        }
    }

    #[tokio::test]
    async fn networked_egress_allow_does_not_bypass_scope() {
        // A safe-scoped networked tool with an Allow gate is allowed by policy
        // (the gate IS its authorization). But a client WITHOUT safe scope is
        // denied at step 2 regardless of the gate.
        let egress = Arc::new(FakeEgressGate::allow()) as Arc<dyn ToolEgressGate>;
        let audit = Arc::new(CapturingAudit::new());
        let v = check(
            client(&[]),
            "web_search",
            json!({"query":"x"}),
            audit,
            egress,
        )
        .await;
        assert!(matches!(v, fluers_core::PolicyVerdict::Deny(_)));
    }

    // -----------------------------------------------------------------------
    // Unknown tool + audit invariants
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn unknown_tool_fails_closed() {
        let audit = Arc::new(CapturingAudit::new());
        let egress = Arc::new(FakeEgressGate::allow()) as Arc<dyn ToolEgressGate>;
        let c = client(&[Scope::ToolExecuteSafe, Scope::ToolExecuteDangerous]);
        let v = check(c, "rm-rf", json!({}), audit.clone(), egress).await;
        assert!(matches!(v, fluers_core::PolicyVerdict::Deny(_)));
        assert_eq!(audit.snapshot()[0].reason, "unknown_tool");
    }

    #[tokio::test]
    async fn allow_path_audit_failure_denies() {
        // Fail-closed: if the audit write fails on the ALLOW path, deny.
        let audit = Arc::new(CapturingAudit::new());
        audit.set_failing();
        let egress = Arc::new(FakeEgressGate::allow()) as Arc<dyn ToolEgressGate>;
        let c = client(&[Scope::ToolExecuteSafe]);
        let v = check(c, "read", json!({"path":"a.txt"}), audit, egress).await;
        assert!(
            matches!(&v, fluers_core::PolicyVerdict::Deny(r) if r.starts_with("audit_write_failed")),
            "audit failure must deny, got {v:?}"
        );
    }

    // -----------------------------------------------------------------------
    // ToolHost::execute end-to-end (governed dispatch)
    // -----------------------------------------------------------------------

    async fn fresh_host(
        audit: Arc<CapturingAudit>,
        egress: Arc<dyn ToolEgressGate>,
    ) -> (ToolHost, tempfile::TempDir) {
        let dir = tempfile::tempdir().expect("tempdir");
        let audit_dyn: Arc<dyn ToolHostAudit> = audit;
        let host = ToolHost::with_wiring(
            dir.path().to_path_buf(),
            Limits::default(),
            audit_dyn,
            egress,
            Arc::new(FixedClock),
            crate::toolhost::policy::RootMode::TempSandbox,
        )
        .await
        .expect("host");
        (host, dir)
    }

    async fn fresh_durable_host(
        audit: Arc<CapturingAudit>,
        egress: Arc<dyn ToolEgressGate>,
    ) -> (ToolHost, tempfile::TempDir) {
        // A ToolHost bound to a DURABLE root (RootMode::DurableWorkspace) — the
        // workspace-wipe damage control is active. The "project" is a real
        // tempdir (treated as a durable workspace for the test).
        let dir = tempfile::tempdir().expect("tempdir");
        let audit_dyn: Arc<dyn ToolHostAudit> = audit;
        let host = ToolHost::with_wiring(
            dir.path().to_path_buf(),
            Limits::default(),
            audit_dyn,
            egress,
            Arc::new(FixedClock),
            crate::toolhost::policy::RootMode::DurableWorkspace,
        )
        .await
        .expect("host");
        (host, dir)
    }

    #[tokio::test]
    async fn execute_runs_allowed_read_tool() {
        let audit = Arc::new(CapturingAudit::new());
        let (host, _dir) = fresh_host(Arc::clone(&audit), Arc::new(FakeEgressGate::allow())).await;
        // Write a file via the env first, then read it through the host.
        host.env
            .write_file(std::path::Path::new("greet.txt"), "hi")
            .await
            .expect("write");
        let req = ToolHostRequest {
            client: client(&[Scope::ToolExecuteSafe]),
            tool: "read".into(),
            input: serde_json::json!({"path":"greet.txt"}),
            call_id: "c1".into(),
            cancel: CancellationToken::new(),
            origin: ToolOrigin::OwnerInteractive,
        };
        let res = host.execute(req).await.expect("allowed + ran");
        assert!(!res.output.content.is_empty());
        // Exactly one allow audit row.
        assert_eq!(audit.snapshot().len(), 1);
        assert_eq!(
            audit.snapshot()[0].decision,
            crate::toolhost::audit::AuditDecision::Allowed
        );
    }

    #[tokio::test]
    async fn execute_denies_without_dispatching() {
        let audit = Arc::new(CapturingAudit::new());
        let (host, _dir) = fresh_host(Arc::clone(&audit), Arc::new(FakeEgressGate::allow())).await;
        let req = ToolHostRequest {
            client: client(&[]), // no scopes
            tool: "read".into(),
            input: serde_json::json!({"path":"a.txt"}),
            call_id: "c2".into(),
            cancel: CancellationToken::new(),
            origin: ToolOrigin::OwnerInteractive,
        };
        let err = host.execute(req).await.unwrap_err();
        assert!(matches!(err, ToolHostError::Denied(_)));
        // A deny audit row was written.
        assert_eq!(audit.snapshot().len(), 1);
        assert_eq!(audit.snapshot()[0].reason, "missing_scope");
    }

    // -----------------------------------------------------------------------
    // A3 execute_governed: the confirmation channel (scope §6)
    // -----------------------------------------------------------------------

    fn dangerous_client() -> ClientRecord {
        client(&[Scope::ToolExecuteSafe, Scope::ToolExecuteDangerous])
    }

    fn req(client: ClientRecord, tool: &str, input: Value) -> ToolHostRequest {
        req_origin(client, tool, input, ToolOrigin::OwnerInteractive)
    }

    fn req_origin(
        client: ClientRecord,
        tool: &str,
        input: Value,
        origin: ToolOrigin,
    ) -> ToolHostRequest {
        ToolHostRequest {
            client,
            tool: tool.into(),
            input,
            call_id: "call-1".into(),
            cancel: CancellationToken::new(),
            origin,
        }
    }

    #[tokio::test]
    async fn governed_safe_read_runs_without_confirm() {
        // A safe tool (read) takes the Allow path — no confirmation asked.
        let audit = Arc::new(CapturingAudit::new());
        let (host, _dir) = fresh_host(Arc::clone(&audit), Arc::new(FakeEgressGate::allow())).await;
        host.env
            .write_file(std::path::Path::new("a.txt"), "hi")
            .await
            .expect("write");
        let conf = FakeConfirmation::approve();
        let r = host
            .execute_governed(
                req(
                    client(&[Scope::ToolExecuteSafe]),
                    "read",
                    json!({"path":"a.txt"}),
                ),
                &conf,
            )
            .await
            .expect("allowed + ran");
        assert!(!r.output.content.is_empty());
        assert!(!conf.was_called(), "safe read must not prompt");
        assert_eq!(audit.snapshot()[0].reason, "allowed");
    }

    #[tokio::test]
    async fn governed_write_approved_executes_and_audits() {
        // A dangerous write: confirm→approve→runs; audit reason is the confirmed marker.
        let audit = Arc::new(CapturingAudit::new());
        let (host, _dir) = fresh_host(Arc::clone(&audit), Arc::new(FakeEgressGate::allow())).await;
        let conf = FakeConfirmation::approve();
        host.execute_governed(
            req(
                dangerous_client(),
                "write",
                json!({"path":"out.txt","content":"hello"}),
            ),
            &conf,
        )
        .await
        .expect("approved + ran");
        assert!(conf.was_called(), "dangerous write must prompt");
        // The file was actually written to the sandbox root.
        let written = host
            .env
            .read_file_full(std::path::Path::new("out.txt"), 1024)
            .await
            .expect("file exists");
        assert_eq!(written, "hello");
        // The audit row records the owner's confirmation, not a bare allow.
        assert_eq!(audit.snapshot()[0].decision, AuditDecision::Allowed);
        assert_eq!(audit.snapshot()[0].reason, "confirmed_by_owner");
    }

    #[tokio::test]
    async fn governed_dangerous_tool_without_scope_denies_without_prompting() {
        // Server-side dangerous-scope gate (A3-Swift advisor focus + reviewer
        // focus): a client holding ONLY ToolExecuteSafe must NOT be able to run
        // write/edit/bash — even with a confirmation channel that would approve.
        // The gate is enforced inside evaluate() via the inner
        // authorize("tool.execute_dangerous") call against the SERVER's
        // ClientRecord.scopes (not a client claim); client-side opt-in is NOT
        // the security boundary. This proves dangerous execution requires BOTH
        // the ToolExecuteDangerous scope AND an owner confirm.
        let audit = Arc::new(CapturingAudit::new());
        let (host, _dir) = fresh_host(Arc::clone(&audit), Arc::new(FakeEgressGate::allow())).await;
        // A FakeConfirmation that WOULD approve if asked — to prove the gate
        // denies BEFORE the confirm round-trip is ever initiated.
        let conf = FakeConfirmation::approve();
        for (tool, input) in [
            ("write", json!({"path":"out.txt","content":"x"})),
            (
                "edit",
                json!({"path":"a.txt","old_text":"a","new_text":"b"}),
            ),
            ("bash", json!({"command":"echo hi"})),
        ] {
            let r = host
                .execute_governed(req(client(&[Scope::ToolExecuteSafe]), tool, input), &conf)
                .await;
            match r {
                Err(ToolHostError::Denied(reason)) => {
                    assert!(
                        reason.contains("scope"),
                        "{tool} should deny on missing dangerous scope, got: {reason}"
                    );
                }
                other => panic!("{tool} with safe-only client must deny, got {other:?}"),
            }
        }
        // Crucially: the owner was NEVER prompted (the gate ran before confirm).
        assert!(
            !conf.was_called(),
            "a safe-only client must never be prompted for a dangerous tool"
        );
        // And no file was written to the sandbox.
        let wrote = host
            .env
            .read_file_full(std::path::Path::new("out.txt"), 1)
            .await
            .is_ok();
        assert!(
            !wrote,
            "write must not have executed without the dangerous scope"
        );
    }

    #[tokio::test]
    async fn governed_write_denied_does_not_execute() {
        // confirm→deny: the tool must NOT run.
        let audit = Arc::new(CapturingAudit::new());
        let (host, _dir) = fresh_host(Arc::clone(&audit), Arc::new(FakeEgressGate::allow())).await;
        let conf = FakeConfirmation::deny();
        let err = host
            .execute_governed(
                req(
                    dangerous_client(),
                    "write",
                    json!({"path":"out.txt","content":"x"}),
                ),
                &conf,
            )
            .await
            .expect_err("must deny");
        assert!(matches!(err, ToolHostError::Denied(_)), "{err:?}");
        // The file was NOT written.
        assert!(
            host.env
                .read_file_full(std::path::Path::new("out.txt"), 1)
                .await
                .is_err(),
            "denied write must not create the file"
        );
        assert_eq!(audit.snapshot()[0].decision, AuditDecision::Denied);
    }

    #[tokio::test]
    async fn governed_write_path_escape_denies_without_prompting() {
        // §6.2: a path-escaping write denies BEFORE the owner is prompted.
        let audit = Arc::new(CapturingAudit::new());
        let (host, _dir) = fresh_host(Arc::clone(&audit), Arc::new(FakeEgressGate::allow())).await;
        let conf = FakeConfirmation::approve(); // would approve if asked — it must NOT be asked
        let err = host
            .execute_governed(
                req(
                    dangerous_client(),
                    "write",
                    json!({"path":"../escape.txt","content":"x"}),
                ),
                &conf,
            )
            .await
            .expect_err("must deny");
        assert!(matches!(err, ToolHostError::Denied(_)));
        assert!(
            !conf.was_called(),
            "path-escape write must deny WITHOUT prompting"
        );
        assert_eq!(audit.snapshot()[0].reason, "path_escape");
    }

    #[tokio::test]
    async fn governed_bash_catastrophic_denies_without_prompting() {
        // §6.2: a catastrophic bash denies BEFORE the owner is prompted.
        let audit = Arc::new(CapturingAudit::new());
        let (host, _dir) = fresh_host(Arc::clone(&audit), Arc::new(FakeEgressGate::allow())).await;
        let conf = FakeConfirmation::approve();
        let err = host
            .execute_governed(
                req(dangerous_client(), "bash", json!({"command":"rm -rf /"})),
                &conf,
            )
            .await
            .expect_err("must deny");
        assert!(matches!(err, ToolHostError::Denied(_)));
        assert!(
            !conf.was_called(),
            "catastrophic bash must deny WITHOUT prompting"
        );
        assert_eq!(audit.snapshot()[0].reason, "damage_control");
    }

    // --- A3→B: durable-root workspace-wipe damage control ---

    #[tokio::test]
    async fn durable_workspace_wipe_denies_without_prompting() {
        // Under a DURABLE root, `rm -rf .` is catastrophic (real files) and
        // denies BEFORE the confirm (scope §6.2). A FakeConfirmation that WOULD
        // approve proves the gate ran first.
        let audit = Arc::new(CapturingAudit::new());
        let (host, _dir) =
            fresh_durable_host(Arc::clone(&audit), Arc::new(FakeEgressGate::allow())).await;
        let conf = FakeConfirmation::approve();
        let err = host
            .execute_governed(
                req(dangerous_client(), "bash", json!({"command":"rm -rf ."})),
                &conf,
            )
            .await
            .expect_err("workspace wipe must deny");
        match err {
            ToolHostError::Denied(reason) => {
                assert_eq!(reason, "workspace_wipe_blocked", "got: {reason}")
            }
            other => panic!("expected Denied(workspace_wipe_blocked), got {other:?}"),
        }
        assert!(
            !conf.was_called(),
            "workspace wipe must deny WITHOUT prompting"
        );
        assert_eq!(audit.snapshot()[0].reason, "workspace_wipe_blocked");
    }

    #[tokio::test]
    async fn durable_scoped_delete_proceeds_to_confirm() {
        // A scoped subdir delete is NOT a workspace wipe → it reaches the confirm.
        let audit = Arc::new(CapturingAudit::new());
        let (host, _dir) =
            fresh_durable_host(Arc::clone(&audit), Arc::new(FakeEgressGate::allow())).await;
        let conf = FakeConfirmation::approve();
        host.execute_governed(
            req(
                dangerous_client(),
                "bash",
                json!({"command":"rm -rf ./target/debug"}),
            ),
            &conf,
        )
        .await
        .expect("scoped delete should proceed + run after confirm");
        assert!(conf.was_called(), "a scoped delete must reach the confirm");
    }

    #[tokio::test]
    async fn temp_mode_workspace_wipe_is_not_blocked() {
        // Under the TEMP sandbox, `rm -rf .` is harmless (deleted on close) — the
        // workspace-wipe gate does NOT apply. It reaches the confirm normally.
        let audit = Arc::new(CapturingAudit::new());
        let (host, _dir) = fresh_host(Arc::clone(&audit), Arc::new(FakeEgressGate::allow())).await;
        let conf = FakeConfirmation::approve();
        host.execute_governed(
            req(dangerous_client(), "bash", json!({"command":"rm -rf ."})),
            &conf,
        )
        .await
        .expect("temp-mode wipe should proceed (not blocked by workspace_wipe)");
        assert!(conf.was_called(), "temp-mode wipe reaches the confirm");
    }

    #[tokio::test]
    async fn governed_confirm_payload_carries_no_file_content() {
        // §6.3 / owner Q3: the confirm payload is bounded + redacted — the file
        // CONTENT must never reach the confirmation channel.
        let audit = Arc::new(CapturingAudit::new());
        let (host, _dir) = fresh_host(audit, Arc::new(FakeEgressGate::allow())).await;
        let conf = FakeConfirmation::deny(); // deny so nothing runs; we only inspect the request
        let _ = host
            .execute_governed(
                req(
                    dangerous_client(),
                    "write",
                    json!({"path":"out.txt","content":"SECRET-SENTINEL-DO-NOT-ECHO"}),
                ),
                &conf,
            )
            .await;
        let creq = conf.last_request().expect("confirm was called");
        let serialized = serde_json::to_string(&creq).expect("serialize");
        assert!(
            !serialized.contains("SECRET-SENTINEL-DO-NOT-ECHO"),
            "file content leaked into confirm payload: {serialized}"
        );
    }

    #[tokio::test]
    async fn governed_unknown_tool_denies_without_prompting() {
        let audit = Arc::new(CapturingAudit::new());
        let (host, _dir) = fresh_host(audit, Arc::new(FakeEgressGate::allow())).await;
        let conf = FakeConfirmation::approve();
        let err = host
            .execute_governed(req(dangerous_client(), "nope", json!({})), &conf)
            .await
            .expect_err("must deny");
        assert!(matches!(err, ToolHostError::Denied(_)));
        assert!(!conf.was_called());
    }

    // -----------------------------------------------------------------------
    // B2: execution isolation
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn required_jail_without_backend_denies_without_running() {
        // Fail-closed: a non-interactive origin REQUIRES the jail; if no backend
        // is available the call denies BEFORE any policy eval or tool dispatch.
        let audit = Arc::new(CapturingAudit::new());
        let (mut host, _dir) =
            fresh_host(Arc::clone(&audit), Arc::new(FakeEgressGate::allow())).await;
        host.set_jail_available(false); // simulate an old kernel / missing sandbox-exec
        let conf = FakeConfirmation::approve();
        // A plain safe read (no confirm) from a Proactive origin → jailed required.
        let err = host
            .execute_governed(
                req_origin(
                    client(&[Scope::ToolExecuteSafe]),
                    "read",
                    json!({"path":"a.txt"}),
                    ToolOrigin::Proactive,
                ),
                &conf,
            )
            .await
            .expect_err("must deny when the required jail is unavailable");
        match err {
            ToolHostError::Denied(reason) => assert_eq!(reason, "isolation_unavailable"),
            other => panic!("expected Denied(isolation_unavailable), got {other:?}"),
        }
        assert!(!conf.was_called(), "must deny without prompting");
        let rows = audit.snapshot();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].reason, "isolation_unavailable");
        assert_eq!(rows[0].isolation, "jailed");
    }

    #[tokio::test]
    async fn owner_interactive_runs_on_host_even_without_backend() {
        // The owner's interactive turn does NOT require the jail, so it runs on
        // the host tier regardless of backend availability. The audit records
        // the host tier.
        let audit = Arc::new(CapturingAudit::new());
        let (mut host, _dir) =
            fresh_host(Arc::clone(&audit), Arc::new(FakeEgressGate::allow())).await;
        host.set_jail_available(false);
        host.env
            .write_file(std::path::Path::new("a.txt"), "hi")
            .await
            .expect("write");
        let conf = FakeConfirmation::approve();
        let r = host
            .execute_governed(
                req_origin(
                    client(&[Scope::ToolExecuteSafe]),
                    "read",
                    json!({"path":"a.txt"}),
                    ToolOrigin::OwnerInteractive,
                ),
                &conf,
            )
            .await
            .expect("owner-interactive read runs on host");
        assert!(!r.output.content.is_empty());
        assert_eq!(audit.snapshot()[0].isolation, "host");
    }

    #[tokio::test]
    async fn jailed_bash_confines_writes_to_the_root() {
        // The load-bearing proof: a jailed `bash` may write INSIDE the root but
        // NOT to a sibling directory outside it, while the same write on the
        // host tier (control) succeeds — so the denial is the OS jail, not perms.
        //
        // Uses dirs under the crate's `target/` (a non-temp base) so the sibling
        // is outside every write-allowed subpath (root + system temp).
        if !isolation::jail_backend_available() {
            eprintln!("skip: no OS sandbox backend on this runner (jail unavailable)");
            return;
        }
        let audit = Arc::new(CapturingAudit::new());
        // Build a durable host rooted OUTSIDE the system temp so the sibling
        // "outside" dir is not in the allow set.
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let base = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("faejail-it-{nonce}"));
        let root = base.join("root");
        let outside = base.join("outside");
        std::fs::create_dir_all(&root).expect("mk root");
        std::fs::create_dir_all(&outside).expect("mk outside");
        let host = ToolHost::with_wiring(
            root.clone(),
            Limits::default(),
            Arc::clone(&audit) as Arc<dyn ToolHostAudit>,
            Arc::new(FakeEgressGate::allow()),
            Arc::new(FixedClock),
            crate::toolhost::policy::RootMode::DurableWorkspace,
        )
        .await
        .expect("durable host");

        let outside_probe = outside.join("escape.txt");
        let outside_cmd = format!("touch {}", shell_quote(&outside_probe.to_string_lossy()));
        let conf = FakeConfirmation::approve();

        // 1. Jailed write OUTSIDE the root must fail (non-zero exit under jail).
        let jailed_out = host
            .execute_governed(
                req_origin(
                    dangerous_client(),
                    "bash",
                    json!({ "command": outside_cmd }),
                    ToolOrigin::Proactive,
                ),
                &conf,
            )
            .await
            .expect("bash runs (the write inside it is what's denied)");
        let exit_out = jailed_out
            .output
            .details
            .as_ref()
            .and_then(|d| d.get("exit_code"))
            .and_then(|v| v.as_i64())
            .expect("exit_code");
        assert_ne!(exit_out, 0, "jailed write outside the root must fail");
        assert!(
            !outside_probe.exists(),
            "the outside file must not have been created under the jail"
        );

        // 2. Jailed write INSIDE the root must succeed (exit 0 + file present).
        let jailed_in = host
            .execute_governed(
                req_origin(
                    dangerous_client(),
                    "bash",
                    json!({ "command": "touch inside.txt" }),
                    ToolOrigin::Proactive,
                ),
                &conf,
            )
            .await
            .expect("inside write runs");
        let exit_in = jailed_in
            .output
            .details
            .as_ref()
            .and_then(|d| d.get("exit_code"))
            .and_then(|v| v.as_i64())
            .expect("exit_code");
        assert_eq!(exit_in, 0, "jailed write inside the root must succeed");
        assert!(root.join("inside.txt").exists(), "inside file must exist");

        // 3. Control: the SAME outside write on the HOST tier succeeds — proving
        //    the denial above was the OS jail, not a permission error.
        let host_out = host
            .execute_governed(
                req_origin(
                    dangerous_client(),
                    "bash",
                    json!({ "command": outside_cmd }),
                    ToolOrigin::OwnerInteractive,
                ),
                &conf,
            )
            .await
            .expect("host bash runs");
        let exit_host = host_out
            .output
            .details
            .as_ref()
            .and_then(|d| d.get("exit_code"))
            .and_then(|v| v.as_i64())
            .expect("exit_code");
        assert_eq!(exit_host, 0, "host write outside the root should succeed");
        assert!(
            outside_probe.exists(),
            "host tier should have created the outside file"
        );

        let _ = std::fs::remove_dir_all(&base);
    }

    /// Quote a path for safe inclusion in a `sh -c` command (test helper).
    fn shell_quote(s: &str) -> String {
        format!("'{}'", s.replace('\'', "'\\''"))
    }
}
