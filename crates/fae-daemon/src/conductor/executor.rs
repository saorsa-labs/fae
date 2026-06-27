//! The conductor executor + runtime. Owns startup-constructed state (policy,
//! recipes, workers, store, install key, chain flag) and runs a routed turn.
//!
//! Safety contract (spec §8, the M1 headline property): the `direct` arm calls
//! [`crate::session::inject_text_core`] **verbatim**. It is not a bare
//! `ChatRequest` → `run_turn`, which would drop the `assistant.generating`
//! event pair and the NaN-logits retry loop. Byte-identity holds by
//! construction: one implementation, called from the conductor's entry point.
//!
//! Telemetry is fire-and-forget on the blocking pool: `spawn_blocking` without
//! awaiting the `JoinHandle` runs on the blocking pool to completion and never
//! makes the user's turn wait on a filesystem write (spec §9). Fingerprint
//! computation lives here (not in the pure policy) because it is fallible by
//! type; on the unreachable `Err` it is logged and the event skipped (spec §9
//! N4) — never a turn failure.

use std::sync::Arc;
use std::time::Instant;

use serde_json::Value;

use crate::conductor::budget::{
    ActualCost, BudgetDimension, BudgetGovernor, BudgetLimits, CostEstimate,
};
use crate::conductor::eval::Corpus;
use crate::conductor::fingerprint::{InstallKey, RequestFingerprint};
use crate::conductor::policy::{
    mode_permits_lane, ConductorRoutingPolicy, ModelMode, StaticDirectPolicy,
};
use crate::conductor::pricing::ProviderPricingTable;
use crate::conductor::recipe::{
    ApprovalClass, ConductorRole, ConductorTopology, OwnedRouteDecision, PrivacyLane, RecipeSet,
    RouteFailure, WorkerLocality,
};
use crate::conductor::shadow::ShadowRouter;
use crate::conductor::store::ConductorStore;
use crate::conductor::telemetry::{ConductorRouteEvent, RouteReceipt, TargetKind};
use crate::conductor::workers::WorkerRegistry;
use crate::session::{inject_text_core, run_turn, SessionBackends};
use fae_control_plane::Command;
use fae_engine::{ChatMessage, ChatRequest, ProviderAdapter, Role};

use crate::conductor::mesh::{
    ConductorMeshDelegationPort, MeshDelegationOutcome, MeshDelegationRequest, MeshOutcomeKind,
    UnavailableMeshDelegationPort,
};

const DEFAULT_MAX_OUTPUT_TOKENS: u64 = 1024;

/// Structured result from the egress membrane. Labels only; never matched text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MembraneVerdict {
    pub block_remote_egress: bool,
    pub level: String,
    pub labels: Vec<String>,
}

/// Spy-able membrane seam. Production uses [`ConductorEgressMembrane`] — the
/// named F-2 egress authority — which wraps the canonical
/// `fae_pii_membrane::should_block_remote_egress` (block decision) and
/// `fae_pii_membrane::scan` (structured labels only). Tests can inject a spy
/// to count calls (e.g. to prove LocalOnly no-ops, or that a credential
/// prompt blocks before any remote-egress dispatch) without replacing the real
/// membrane in the invariant test.
pub trait PiiMembrane: Send + Sync {
    fn scan_for_remote_egress(&self, text: &str) -> MembraneVerdict;
}

/// The F-2 egress authority: the single named surface every remote-egress lane
/// (`CloudBacked` + `OwnerFleet`) routes through before any provider request is
/// constructed. This makes the §5.3 invariant structural, not an incidental
/// call-site convention. (Renamed from `RealPiiMembrane` in M4-A to name F-2;
/// the behavior is unchanged — it delegates to `fae-pii-membrane`.)
#[derive(Debug, Default)]
pub struct ConductorEgressMembrane;

impl PiiMembrane for ConductorEgressMembrane {
    fn scan_for_remote_egress(&self, text: &str) -> MembraneVerdict {
        // Load-bearing order: the egress authority is consulted before this
        // function returns any data that could be used to construct a provider
        // request. The extra `scan` call supplies structured labels only.
        let block_remote_egress = fae_pii_membrane::should_block_remote_egress(text);
        let scan = fae_pii_membrane::scan(text);
        MembraneVerdict {
            block_remote_egress,
            level: format!("{:?}", scan.level),
            labels: scan.matched_labels,
        }
    }
}

/// Inputs to the cloud-request construction boundary. This is intentionally a
/// separate trait call so tests can spy that construction happens only after all
/// pre-egress gates pass.
pub struct CloudRequestBuildInput<'a> {
    pub route: &'a OwnedRouteDecision,
    pub role: Option<ConductorRole>,
    pub prompt: &'a str,
    pub max_output_tokens: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloudRequest {
    pub worker_id: String,
    pub role: Option<ConductorRole>,
    pub prompt: String,
    pub max_output_tokens: u64,
}

pub trait CloudRequestBuilder: Send + Sync {
    fn build(&self, input: CloudRequestBuildInput<'_>) -> CloudRequest;
}

#[derive(Debug, Default)]
pub struct DefaultCloudRequestBuilder;

impl CloudRequestBuilder for DefaultCloudRequestBuilder {
    fn build(&self, input: CloudRequestBuildInput<'_>) -> CloudRequest {
        CloudRequest {
            worker_id: input.route.worker_id.clone(),
            role: input.role,
            prompt: input.prompt.to_string(),
            max_output_tokens: input.max_output_tokens,
        }
    }
}

#[derive(Debug, Clone)]
pub struct CloudCallSuccess {
    pub response: Value,
    pub actual_cost: Option<ActualCost>,
}

#[derive(Debug, Clone)]
pub struct CloudCallError {
    pub code: String,
    pub billed_cost: Option<ActualCost>,
}

pub type CloudCallResult = Result<CloudCallSuccess, CloudCallError>;

/// Mock-backed cloud provider seam. Stage 1 deliberately has no live provider
/// HTTP; production startup wires this deterministic mock until a later stage
/// adds real provider adapters behind the same gates.
pub trait CloudProvider: Send + Sync {
    fn call(&self, request: CloudRequest) -> CloudCallResult;
}

#[derive(Debug, Default)]
pub struct MockCloudProvider;

impl CloudProvider for MockCloudProvider {
    fn call(&self, request: CloudRequest) -> CloudCallResult {
        let role = request.role.map(role_name).unwrap_or("direct");
        Ok(CloudCallSuccess {
            response: serde_json::json!({
                "text": format!("mock-cloud:{role}: {}", request.prompt),
                "tool_calls": Vec::<Value>::new(),
                "finish_reason": "stop",
            }),
            actual_cost: None,
        })
    }
}

/// Runtime egress components constructed once at daemon startup.
pub struct ConductorEgress {
    mode: ModelMode,
    budget: BudgetGovernor,
    pricing: ProviderPricingTable,
    membrane: Arc<dyn PiiMembrane>,
    cloud_request_builder: Arc<dyn CloudRequestBuilder>,
    cloud_provider: Arc<dyn CloudProvider>,
    /// M4-D: the mesh delegation port (OwnerFleet lane). Production uses
    /// [`UnavailableMeshDelegationPort`] (fail-closed); tests inject a mock via
    /// [`Self::with_components_and_mesh`].
    mesh_port: Arc<dyn ConductorMeshDelegationPort>,
}

impl ConductorEgress {
    pub fn mode(&self) -> ModelMode {
        self.mode
    }

    pub fn production(
        mode: ModelMode,
        budget: BudgetGovernor,
        pricing: ProviderPricingTable,
    ) -> Self {
        Self::with_components(
            mode,
            budget,
            pricing,
            Arc::new(ConductorEgressMembrane),
            Arc::new(DefaultCloudRequestBuilder),
            Arc::new(MockCloudProvider),
        )
    }

    #[allow(dead_code)] // Legacy/testing constructor keeps M1 direct runtime easy to instantiate.
    pub fn pure_local(store: &ConductorStore) -> Self {
        let budget = BudgetGovernor::new(store.clone(), BudgetLimits::default());
        Self::production(ModelMode::PureLocal, budget, ProviderPricingTable::empty())
    }

    pub fn with_components(
        mode: ModelMode,
        budget: BudgetGovernor,
        pricing: ProviderPricingTable,
        membrane: Arc<dyn PiiMembrane>,
        cloud_request_builder: Arc<dyn CloudRequestBuilder>,
        cloud_provider: Arc<dyn CloudProvider>,
    ) -> Self {
        // Default mesh port is the fail-closed production default — so the
        // existing `with_components` call sites stay dormant without touching
        // them. M4-D tests inject a mock via `with_components_and_mesh`.
        Self::with_components_and_mesh(
            mode,
            budget,
            pricing,
            membrane,
            cloud_request_builder,
            cloud_provider,
            Arc::new(UnavailableMeshDelegationPort),
        )
    }

    /// M4-D: inject a mesh delegation port (tests). Production uses
    /// [`Self::production`] / [`Self::with_components`], which default to
    /// [`UnavailableMeshDelegationPort`].
    #[allow(clippy::too_many_arguments)]
    pub fn with_components_and_mesh(
        mode: ModelMode,
        budget: BudgetGovernor,
        pricing: ProviderPricingTable,
        membrane: Arc<dyn PiiMembrane>,
        cloud_request_builder: Arc<dyn CloudRequestBuilder>,
        cloud_provider: Arc<dyn CloudProvider>,
        mesh_port: Arc<dyn ConductorMeshDelegationPort>,
    ) -> Self {
        Self {
            mode,
            budget,
            pricing,
            membrane,
            cloud_request_builder,
            cloud_provider,
            mesh_port,
        }
    }
}

/// Internal bookkeeping for a turn's execution, used to populate the receipt.
/// **Never the wire type** — the user-facing result is `Result<Value,
/// &'static str>` returned verbatim from `inject_text_core` (spec §5.1 N2).
/// `TurnResult` is never round-tripped through `Value`; that would re-serialize
/// the payload and break byte-identity.
#[derive(Debug, Clone)]
pub(crate) struct TurnOutcome {
    pub(crate) success: bool,
    pub(crate) fallback: bool,
    pub(crate) fallback_reason: Option<String>,
    pub(crate) target_kind: TargetKind,
    pub(crate) privacy_lane: PrivacyLane,
    pub(crate) cost_micros: Option<u64>,
}

/// Startup-constructed conductor state. Cheap to share (`Arc`) across the
/// session. Constructed once in `main`; borrowed by `SessionBackends`.
pub struct ConductorRuntime {
    policy: Arc<dyn ConductorRoutingPolicy>,
    recipes: RecipeSet,
    workers: WorkerRegistry,
    store: ConductorStore,
    install_key: InstallKey,
    chain_enabled: bool,
    egress: ConductorEgress,
    /// M2-live §2.2: optional shadow router. `None` ⇒ no per-turn shadow
    /// capture (legacy/test/`new` default). `Some` when constructed via
    /// [`Self::with_shadow`]. Shares the **same** `policy` `Arc` as the live
    /// route decision (anti-divergence, spec §2.2a).
    shadow: Option<ShadowRouter>,
    /// M2-live §2.2: the corpus parsed once at startup (`with_shadow`).
    /// `None` when shadow is disabled or the (embedded, tested) corpus failed
    /// to parse (non-fatal — §8 decision 2: start with shadow disabled + warn).
    corpus: Option<Corpus>,
}

impl ConductorRuntime {
    #[allow(dead_code)] // Legacy/tests use the M1-compatible pure-local constructor.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        policy: StaticDirectPolicy,
        recipes: RecipeSet,
        workers: WorkerRegistry,
        store: ConductorStore,
        install_key: InstallKey,
        chain_enabled: bool,
    ) -> Self {
        let egress = ConductorEgress::pure_local(&store);
        Self::new_with_egress(
            policy,
            recipes,
            workers,
            store,
            install_key,
            chain_enabled,
            egress,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn new_with_egress(
        policy: StaticDirectPolicy,
        recipes: RecipeSet,
        workers: WorkerRegistry,
        store: ConductorStore,
        install_key: InstallKey,
        chain_enabled: bool,
        egress: ConductorEgress,
    ) -> Self {
        Self {
            policy: Arc::new(policy),
            recipes,
            workers,
            store,
            install_key,
            chain_enabled,
            egress,
            shadow: None,
            corpus: None,
        }
    }

    /// M2-live §2.2: enable per-turn shadow capture. Parses the embedded
    /// corpus once and builds a [`ShadowRouter`] whose deployed policy is an
    /// `Arc::clone` of this runtime's routing policy (so the shadow "deployed
    /// decision" is byte-equal to the executed decision — anti-divergence,
    /// spec §2.2a / V2). Ships with **zero candidates** (M2 has none).
    ///
    /// Corpus parse failure is non-fatal (§8 decision 2): the embedded corpus
    /// is tested, but if it ever fails to parse, shadow stays disabled and a
    /// warning is logged rather than gating the daemon.
    pub fn with_shadow(mut self) -> Self {
        let corpus = match Corpus::synthetic_core() {
            Ok(corpus) => corpus,
            Err(error) => {
                tracing::warn!(
                    "conductor synthetic corpus failed to parse; shadow capture disabled: {error}"
                );
                return self;
            }
        };
        let deployed = Arc::clone(&self.policy);
        self.shadow = Some(ShadowRouter::new(deployed, Vec::new()));
        self.corpus = Some(corpus);
        self
    }

    /// The static policy reference, for `inject_text` to call `decide`.
    pub fn policy(&self) -> &dyn ConductorRoutingPolicy {
        self.policy.as_ref()
    }

    /// Compute the F-4 fingerprint for a request id (M2-live §2.1 lift:
    /// computed once per turn in `route_turn` and threaded to every emitter).
    /// Best-effort callers log + skip telemetry on the unreachable `Err`.
    pub(crate) fn fingerprint(
        &self,
        request_id: &str,
    ) -> Result<RequestFingerprint, crate::conductor::error::ConductorError> {
        self.install_key.fingerprint(request_id)
    }

    /// True iff per-turn shadow capture is active (a [`ShadowRouter`] + corpus
    /// are configured). Used for the startup banner; `false` when `with_shadow`
    /// was never called or the embedded corpus failed to parse (§8 decision 2).
    pub(crate) fn shadow_enabled(&self) -> bool {
        self.shadow.is_some()
    }

    /// Operator-selected lane cap for all egress surfaces, including ACP agent
    /// commands that gate at session entry.
    pub fn model_mode(&self) -> ModelMode {
        self.egress.mode()
    }

    /// Startup-vetted worker registry used by entry-point egress gates.
    pub fn workers(&self) -> &WorkerRegistry {
        &self.workers
    }

    /// Run a routed turn. Returns the wire-type result verbatim; tracks a
    /// `TurnOutcome` internally for the receipt. Never aborts the turn on a
    /// routing failure — every `RouteFailure` fails closed to `direct`-local
    /// (spec §5.3).
    pub async fn run(
        &self,
        decision: &OwnedRouteDecision,
        backends: &SessionBackends<'_>,
        cmd: &Command,
    ) -> (Result<Value, &'static str>, TurnOutcome) {
        // 5.1 Recipe resolution (M1, unchanged). The static-direct recipe is a
        // policy invariant, not a loadable artifact, so it always resolves to
        // the local-only direct profile without a RecipeSet lookup.
        let is_static_direct =
            decision.recipe_id == crate::conductor::policy::STATIC_DIRECT_RECIPE_ID;
        let _recipe = if is_static_direct {
            None
        } else {
            match self.recipes.get(&decision.recipe_id) {
                Some(r) => Some(r),
                None => {
                    return self
                        .fail_closed_direct(
                            decision,
                            backends,
                            cmd,
                            RouteFailure::InvalidRecipe {
                                recipe_id: decision.recipe_id.clone(),
                            },
                        )
                        .await;
                }
            }
        };

        if !self.workers.contains(&decision.worker_id) {
            return self
                .fail_closed_direct(
                    decision,
                    backends,
                    cmd,
                    RouteFailure::WorkerUnavailable {
                        worker_id: decision.worker_id.clone(),
                    },
                )
                .await;
        }

        // 5.2 Mode cap. Runs before the membrane so pure-local never scans a
        // route that cannot execute anyway.
        if !mode_permits_lane(self.egress.mode, decision.lane) {
            return self
                .fail_closed_direct(
                    decision,
                    backends,
                    cmd,
                    RouteFailure::ModeBlocked {
                        mode: self.egress.mode.as_str().to_string(),
                        lane: decision.lane,
                    },
                )
                .await;
        }

        match decision.topology {
            ConductorTopology::Direct if decision.lane == PrivacyLane::LocalOnly => {
                if let Err(failure) = self.assert_local_approval(decision) {
                    return self
                        .fail_closed_direct(decision, backends, cmd, failure)
                        .await;
                }
                // BYTE-IDENTICAL: run inject_text's existing body verbatim.
                let wire = inject_text_core(backends, cmd).await;
                let outcome = TurnOutcome {
                    success: wire.is_ok(),
                    fallback: false,
                    fallback_reason: None,
                    target_kind: TargetKind::LocalModel,
                    privacy_lane: decision.lane,
                    cost_micros: None,
                };
                (wire, outcome)
            }
            ConductorTopology::Direct => match decision.lane {
                PrivacyLane::LocalOnly => {
                    // Unreachable: the `if LocalOnly` arm above handles this.
                    // Defense-in-depth if the match arms are reordered.
                    self.run_cloud_direct(decision, backends, cmd).await
                }
                PrivacyLane::CloudBacked => self.run_cloud_direct(decision, backends, cmd).await,
                PrivacyLane::OwnerFleet => self.run_mesh_direct(decision, backends, cmd).await,
                // TrustedPeer / RemoteAllowed: not implemented (M6+/ADR-gated).
                // Fail closed rather than flowing through the cloud path.
                lane => {
                    self.fail_closed_direct(
                        decision,
                        backends,
                        cmd,
                        RouteFailure::RecipeDisabled {
                            recipe_id: decision.recipe_id.clone(),
                            reason: format!("{lane:?} lane not implemented"),
                        },
                    )
                    .await
                }
            },
            ConductorTopology::Chain => {
                if !self.chain_enabled {
                    return self
                        .fail_closed_direct(
                            decision,
                            backends,
                            cmd,
                            RouteFailure::RecipeDisabled {
                                recipe_id: decision.recipe_id.clone(),
                                reason: "chain-disabled".to_string(),
                            },
                        )
                        .await;
                }
                if decision.lane == PrivacyLane::LocalOnly {
                    if let Err(failure) = self.assert_local_approval(decision) {
                        return self
                            .fail_closed_direct(decision, backends, cmd, failure)
                            .await;
                    }
                    self.run_chain(decision, backends, cmd, decision.lane).await
                } else if decision.lane == PrivacyLane::CloudBacked {
                    self.run_cloud_chain(decision, backends, cmd).await
                } else {
                    // Mesh-chain and unimplemented lanes (M6+/ADR-gated) are
                    // NOT routed to the cloud chain. Fail closed explicitly.
                    self.fail_closed_direct(
                        decision,
                        backends,
                        cmd,
                        RouteFailure::RecipeDisabled {
                            recipe_id: decision.recipe_id.clone(),
                            reason: format!("chain+{:?} lane not implemented", decision.lane),
                        },
                    )
                    .await
                }
            }
        }
    }

    async fn run_cloud_direct(
        &self,
        decision: &OwnedRouteDecision,
        backends: &SessionBackends<'_>,
        cmd: &Command,
    ) -> (Result<Value, &'static str>, TurnOutcome) {
        let prompt = prompt_from_command(cmd);
        let max_output_tokens = max_output_tokens_from_command(cmd);
        match self.execute_cloud_role_call(decision, None, &prompt, max_output_tokens) {
            Ok(output) => {
                let outcome = TurnOutcome {
                    success: true,
                    fallback: false,
                    fallback_reason: None,
                    target_kind: self.target_kind_for_worker(&decision.worker_id),
                    privacy_lane: decision.lane,
                    cost_micros: Some(output.actual_cost.cost_micros),
                };
                (Ok(output.value), outcome)
            }
            Err(CloudRoleCallFailure::Blocked(failure)) => {
                self.fail_closed_direct(decision, backends, cmd, failure)
                    .await
            }
            Err(CloudRoleCallFailure::ProviderFailed(failure)) => {
                self.fail_closed_direct_with_success(decision, backends, cmd, failure, Some(false))
                    .await
            }
        }
    }

    /// M4-D: delegate a direct `OwnerFleet` route to the mesh port. Runs the
    /// non-local preflight (§5.3 membrane → §5.4 budget → §5.5 approval) BEFORE
    /// the port call, so the port receives only a post-gate slice and the gate
    /// pipeline is never bypassed. Mesh budget is governance-only (token/timeout
    /// estimate, NO cost — economics deferred). Every non-`Completed` outcome
    /// (incl. `TransportError` from the dormant production default) fails closed
    /// to direct-local.
    async fn run_mesh_direct(
        &self,
        decision: &OwnedRouteDecision,
        backends: &SessionBackends<'_>,
        cmd: &Command,
    ) -> (Result<Value, &'static str>, TurnOutcome) {
        let prompt = prompt_from_command(cmd);
        let max_output_tokens = max_output_tokens_from_command(cmd);

        // 5.3 PII membrane — the ConductorEgressMembrane (F-2 authority).
        // Runs before the port call so a credential-shaped prompt is blocked
        // BEFORE the slice crosses the mesh boundary. This is the load-bearing
        // egress invariant, identical to the cloud path.
        let membrane = self.egress.membrane.scan_for_remote_egress(&prompt);
        if membrane.block_remote_egress {
            return self
                .fail_closed_direct(
                    decision,
                    backends,
                    cmd,
                    RouteFailure::PrivacyBlocked {
                        level: membrane.level,
                        labels: membrane.labels,
                    },
                )
                .await;
        }

        // 5.4 Budget — governance caps bind (turn-count/timeout/wall-clock);
        // cost/pricing is deferred per owner directive. Mesh budget must NOT
        // depend on ProviderPricingTable (a peer's model may be unpriced), so
        // cost_micros is 0; but wall_clock_ms uses the recipe's timeout so the
        // governor's wall-clock cap genuinely binds (governance, not billing).
        let mesh_estimate = CostEstimate {
            cost_micros: 0, // no cost authority (economics deferred)
            wall_clock_ms: self.mesh_timeout_ms(decision),
            input_tokens: u64::try_from(prompt.chars().count() / 4).unwrap_or(u64::MAX),
            output_tokens: max_output_tokens,
        };
        if let Some(failure) = self
            .egress
            .budget
            .check(decision, &mesh_estimate)
            .into_route_failure()
        {
            return self
                .fail_closed_direct(decision, backends, cmd, failure)
                .await;
        }

        // 5.5 Approval — provisioned StandingGrant is the consent for a
        // same-owner fleet worker (ADR-012 principle 2).
        if let Err(failure) = self.assert_non_local_approval(decision) {
            return self
                .fail_closed_direct(decision, backends, cmd, failure)
                .await;
        }

        // 5.6 Delegate. mesh_request_id is FRESH (never the conductor
        // request_id) so the peer can't correlate turns across time.
        let request = MeshDelegationRequest {
            mesh_request_id: self.fresh_mesh_request_id(decision),
            peer_worker_id: decision.worker_id.clone(),
            prompt_slice: prompt.clone(),
            max_output_tokens: u32::try_from(max_output_tokens).unwrap_or(u32::MAX),
            timeout_ms: self.mesh_timeout_ms(decision),
        };
        let outcome: MeshDelegationOutcome = self.egress.mesh_port.delegate(request).await;
        match outcome.outcome_kind {
            MeshOutcomeKind::Completed if outcome.answer.is_some() => {
                let value = wire_value_from_text(&outcome.answer.unwrap_or_default());
                let turn_outcome = TurnOutcome {
                    success: true,
                    fallback: false,
                    fallback_reason: None,
                    target_kind: self.target_kind_for_worker(&decision.worker_id),
                    privacy_lane: decision.lane,
                    cost_micros: None, // mesh carries no cost (economics deferred)
                };
                (Ok(value), turn_outcome)
            }
            // Every non-Completed outcome (incl. TransportError from the dormant
            // production default) fails closed to direct-local.
            kind => {
                self.fail_closed_direct(
                    decision,
                    backends,
                    cmd,
                    RouteFailure::MeshDelegationFailed {
                        worker_id: decision.worker_id.clone(),
                        outcome_label: kind.as_label().to_string(),
                    },
                )
                .await
            }
        }
    }

    async fn run_cloud_chain(
        &self,
        decision: &OwnedRouteDecision,
        backends: &SessionBackends<'_>,
        cmd: &Command,
    ) -> (Result<Value, &'static str>, TurnOutcome) {
        let user_prompt = prompt_from_command(cmd);
        let max_output_tokens = max_output_tokens_from_command(cmd);

        let thinker = match self.execute_cloud_role_call(
            decision,
            Some(ConductorRole::Thinker),
            &user_prompt,
            max_output_tokens,
        ) {
            Ok(output) => output,
            Err(CloudRoleCallFailure::Blocked(failure)) => {
                return self
                    .fail_closed_direct(decision, backends, cmd, failure)
                    .await;
            }
            Err(CloudRoleCallFailure::ProviderFailed(failure)) => {
                return self
                    .fail_closed_direct_with_success(decision, backends, cmd, failure, Some(false))
                    .await;
            }
        };

        let worker = match self.execute_cloud_role_call(
            decision,
            Some(ConductorRole::Worker),
            &thinker.text,
            max_output_tokens,
        ) {
            Ok(output) => output,
            Err(CloudRoleCallFailure::Blocked(failure)) => {
                return self
                    .fail_closed_direct(decision, backends, cmd, failure)
                    .await;
            }
            Err(CloudRoleCallFailure::ProviderFailed(failure)) => {
                return self
                    .fail_closed_direct_with_success(decision, backends, cmd, failure, Some(false))
                    .await;
            }
        };

        let verify_input = format!("{user_prompt}\n\nProposed answer:\n{}", worker.text);
        let verifier = match self.execute_cloud_role_call(
            decision,
            Some(ConductorRole::Verifier),
            &verify_input,
            max_output_tokens,
        ) {
            Ok(output) => output,
            Err(CloudRoleCallFailure::Blocked(failure)) => {
                return self
                    .fail_closed_direct(decision, backends, cmd, failure)
                    .await;
            }
            Err(CloudRoleCallFailure::ProviderFailed(failure)) => {
                return self
                    .fail_closed_direct_with_success(decision, backends, cmd, failure, Some(false))
                    .await;
            }
        };

        let passed = verifier
            .text
            .lines()
            .next()
            .map(|line| line.trim() == "PASS")
            .unwrap_or(false);
        let final_text = if passed {
            worker.text.clone()
        } else if !verifier.text.is_empty() {
            verifier.text.clone()
        } else {
            worker.text.clone()
        };
        let cost_micros = thinker
            .actual_cost
            .cost_micros
            .saturating_add(worker.actual_cost.cost_micros)
            .saturating_add(verifier.actual_cost.cost_micros);

        (
            Ok(serde_json::json!({
                "text": final_text,
                "tool_calls": Vec::<Value>::new(),
                "finish_reason": "stop",
            })),
            TurnOutcome {
                success: true,
                fallback: false,
                fallback_reason: None,
                target_kind: self.target_kind_for_worker(&decision.worker_id),
                privacy_lane: decision.lane,
                cost_micros: Some(cost_micros),
            },
        )
    }

    fn execute_cloud_role_call(
        &self,
        decision: &OwnedRouteDecision,
        role: Option<ConductorRole>,
        prompt: &str,
        max_output_tokens: u64,
    ) -> Result<CloudRoleOutput, CloudRoleCallFailure> {
        // 5.3 PII membrane: before pricing, approval, request construction, or
        // provider call. This is the load-bearing egress invariant.
        let membrane = self.egress.membrane.scan_for_remote_egress(prompt);
        if membrane.block_remote_egress {
            return Err(CloudRoleCallFailure::Blocked(
                RouteFailure::PrivacyBlocked {
                    level: membrane.level,
                    labels: membrane.labels,
                },
            ));
        }

        // 5.4 Budget estimate/check. Missing pricing is uncostable and fails
        // closed as BudgetExceeded before request construction.
        let estimate = self
            .egress
            .pricing
            .estimate_cost(&decision.worker_id, prompt, max_output_tokens)
            .map_err(|_| CloudRoleCallFailure::Blocked(uncostable_worker_failure()))?;
        if let Some(failure) = self
            .egress
            .budget
            .check(decision, &estimate)
            .into_route_failure()
        {
            return Err(CloudRoleCallFailure::Blocked(failure));
        }

        // 5.5 Approval assertion. Provisioned StandingGrant is allowed for
        // cloud-backed/owner-fleet Tier B workers; all other non-local approval
        // mismatches fail closed.
        self.assert_non_local_approval(decision)
            .map_err(CloudRoleCallFailure::Blocked)?;

        // 5.6 Request construction/call. The builder is spy-able and invoked
        // only after gates 5.2–5.5 pass.
        let request = self
            .egress
            .cloud_request_builder
            .build(CloudRequestBuildInput {
                route: decision,
                role,
                prompt,
                max_output_tokens,
            });
        match self.egress.cloud_provider.call(request) {
            Ok(success) => {
                let actual_cost = success
                    .actual_cost
                    .unwrap_or_else(|| actual_from_estimate(&estimate));
                self.egress.budget.record(decision, &actual_cost);
                Ok(CloudRoleOutput {
                    text: text_from_value(&success.response),
                    value: success.response,
                    actual_cost,
                })
            }
            Err(error) => {
                if let Some(actual_cost) = error.billed_cost {
                    self.egress.budget.record(decision, &actual_cost);
                }
                Err(CloudRoleCallFailure::ProviderFailed(
                    RouteFailure::RecipeDisabled {
                        recipe_id: decision.recipe_id.clone(),
                        reason: format!("cloud-provider-error:{}", error.code),
                    },
                ))
            }
        }
    }

    fn assert_local_approval(&self, decision: &OwnedRouteDecision) -> Result<(), RouteFailure> {
        if matches!(decision.approval, ApprovalClass::None) {
            Ok(())
        } else {
            Err(RouteFailure::UnexpectedApproval {
                approval: decision.approval.clone(),
            })
        }
    }

    fn assert_non_local_approval(&self, decision: &OwnedRouteDecision) -> Result<(), RouteFailure> {
        match (&decision.lane, &decision.approval) {
            (
                PrivacyLane::CloudBacked | PrivacyLane::OwnerFleet,
                ApprovalClass::StandingGrant(_),
            ) if self.workers.is_provisioned(&decision.worker_id)
                && self.worker_lane_matches_locality(&decision.worker_id, decision.lane) =>
            {
                Ok(())
            }
            _ => Err(RouteFailure::UnexpectedApproval {
                approval: decision.approval.clone(),
            }),
        }
    }

    /// Defense-in-depth (M2 Stage 1 red-team MINOR): a non-local decision's
    /// lane must match the targeted worker's locality-derived lane. Prevents a
    /// buggy or compromised policy from routing a cloud lane to a local-model
    /// worker, which would otherwise pass the provisioned-approval gate and
    /// rely only on the incidental absence of worker pricing to fail closed.
    fn worker_lane_matches_locality(&self, worker_id: &str, lane: PrivacyLane) -> bool {
        match self.workers.locality(worker_id) {
            Some(locality) => crate::conductor::recipe::locality_to_lane(locality) == lane,
            None => false,
        }
    }

    /// Fail closed to `direct`-local: run the user's turn via the byte-identical
    /// path and mark the receipt as a fallback with the routing reason. The user
    /// is never blocked by the conductor (spec §5.3).
    async fn fail_closed_direct(
        &self,
        decision: &OwnedRouteDecision,
        backends: &SessionBackends<'_>,
        cmd: &Command,
        failure: RouteFailure,
    ) -> (Result<Value, &'static str>, TurnOutcome) {
        self.fail_closed_direct_with_success(decision, backends, cmd, failure, None)
            .await
    }

    async fn fail_closed_direct_with_success(
        &self,
        decision: &OwnedRouteDecision,
        backends: &SessionBackends<'_>,
        cmd: &Command,
        failure: RouteFailure,
        success_override: Option<bool>,
    ) -> (Result<Value, &'static str>, TurnOutcome) {
        tracing::warn!(
            recipe_id = %decision.recipe_id,
            reason = %route_failure_display(&failure),
            "conductor failing closed to direct-local"
        );
        let wire = inject_text_core(backends, cmd).await;
        let success = success_override.unwrap_or_else(|| wire.is_ok());
        let outcome = TurnOutcome {
            success,
            fallback: true,
            fallback_reason: Some(route_failure_display(&failure)),
            target_kind: TargetKind::LocalModel,
            privacy_lane: PrivacyLane::LocalOnly,
            cost_micros: None,
        };
        (wire, outcome)
    }

    /// Chain topology execution (Thinker → Worker → Verifier). Dormant in M1
    /// unless `FAE_CONDUCTOR_CHAIN` is set. Implemented as a sequence of
    /// `run_turn` calls with role-conditioned prompts; on Verifier FAIL the
    /// corrected answer is used if present, else the Worker's answer.
    #[allow(dead_code)]
    async fn run_chain(
        &self,
        decision: &OwnedRouteDecision,
        backends: &SessionBackends<'_>,
        cmd: &Command,
        privacy_lane: PrivacyLane,
    ) -> (Result<Value, &'static str>, TurnOutcome) {
        use crate::conductor::prompts::{THINKER_SYSTEM, VERIFIER_SYSTEM, WORKER_SYSTEM};

        let user_prompt = cmd
            .payload
            .get("prompt")
            .and_then(Value::as_str)
            .unwrap_or("");

        let engine: &dyn ProviderAdapter = backends.engine;
        async fn run_one(
            engine: &dyn ProviderAdapter,
            system: String,
            user: String,
        ) -> Result<Value, String> {
            let request = ChatRequest {
                system: Some(system),
                messages: vec![ChatMessage {
                    role: Role::User,
                    content: user,
                    audio_wav_base64: None,
                }],
                tools: Vec::new(),
                max_tokens: 1024,
            };
            run_turn(engine, request).await
        }

        let thinker_out =
            run_one(engine, THINKER_SYSTEM.to_string(), user_prompt.to_string()).await;
        let thinker_text = match thinker_out {
            Ok(v) => v
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            Err(detail) => {
                tracing::warn!("conductor chain Thinker failed: {detail}");
                return self
                    .fail_closed_direct(
                        decision,
                        backends,
                        cmd,
                        RouteFailure::RecipeDisabled {
                            recipe_id: decision.recipe_id.clone(),
                            reason: "chain-thinker-failed".to_string(),
                        },
                    )
                    .await;
            }
        };
        let worker_out = run_one(engine, WORKER_SYSTEM.to_string(), thinker_text.clone()).await;
        let worker_text = match worker_out {
            Ok(v) => v
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            Err(detail) => {
                tracing::warn!("conductor chain Worker failed: {detail}");
                return self
                    .fail_closed_direct(
                        decision,
                        backends,
                        cmd,
                        RouteFailure::RecipeDisabled {
                            recipe_id: decision.recipe_id.clone(),
                            reason: "chain-worker-failed".to_string(),
                        },
                    )
                    .await;
            }
        };
        let verify_input = format!("{user_prompt}\n\nProposed answer:\n{worker_text}");
        let verifier_out = run_one(engine, VERIFIER_SYSTEM.to_string(), verify_input).await;
        let verifier_text = verifier_out
            .ok()
            .and_then(|v| v.get("text").and_then(Value::as_str).map(str::to_string))
            .unwrap_or_default();
        let passed = verifier_text
            .lines()
            .next()
            .map(|line| line.trim() == "PASS")
            .unwrap_or(false);
        let final_text = if passed {
            worker_text.clone()
        } else if !verifier_text.is_empty() {
            verifier_text
        } else {
            worker_text.clone()
        };

        (
            Ok(serde_json::json!({
                "text": final_text,
                "tool_calls": Vec::<Value>::new(),
                "finish_reason": "stop",
            })),
            TurnOutcome {
                success: true,
                fallback: false,
                fallback_reason: None,
                target_kind: TargetKind::LocalModel,
                privacy_lane,
                cost_micros: None,
            },
        )
    }

    /// Emit a `ConductorRouteEvent` at decision time. Fire-and-forget on the
    /// blocking pool; the turn never waits on this write (spec §9).
    pub fn emit_event(
        &self,
        decision: &OwnedRouteDecision,
        request_fingerprint: &RequestFingerprint,
        timestamp_ms: u64,
    ) {
        let event = ConductorRouteEvent {
            request_fingerprint: request_fingerprint.clone(),
            task_class: decision.task_class,
            recipe_id: Some(decision.recipe_id.clone()),
            topology: decision.topology,
            role: None,
            worker_id: Some(decision.worker_id.clone()),
            target_kind: self.target_kind_for_worker(&decision.worker_id),
            privacy_lane: decision.lane,
            latency_ms: None,
            cost_micros: None,
            success: true,
            fallback_used: false,
            eval_delta: None,
            user_signal: None,
            timestamp_ms,
        };
        self.spawn_telemetry(move |store| match store.append_event(&event) {
            Ok(()) => {}
            Err(e) => tracing::warn!("conductor event write failed: {e}"),
        });
    }

    /// Emit a `RouteReceipt` after execution. Fire-and-forget; best-effort.
    pub fn emit_receipt(
        &self,
        decision: &OwnedRouteDecision,
        outcome: &TurnOutcome,
        request_fingerprint: &RequestFingerprint,
        latency_ms: u64,
        timestamp_ms: u64,
    ) {
        let receipt = RouteReceipt {
            request_fingerprint: request_fingerprint.clone(),
            recipe_id: decision.recipe_id.clone(),
            topology: decision.topology,
            worker_id: decision.worker_id.clone(),
            target_kind: outcome.target_kind,
            privacy_lane: outcome.privacy_lane,
            roles: None,
            latency_ms: Some(latency_ms),
            cost_micros: outcome.cost_micros,
            success: outcome.success,
            fallback: outcome.fallback,
            fallback_reason: outcome.fallback_reason.clone(),
            payload_hash: None,
            eval_delta: None,
            user_signal: None,
            timestamp_ms,
        };
        self.spawn_telemetry(move |store| match store.append_receipt(&receipt) {
            Ok(()) => {}
            Err(e) => tracing::warn!("conductor receipt write failed: {e}"),
        });
    }

    /// M2-live §2.2: capture a shadow record for this turn and append it to the
    /// isolated store **off the hot path** (`spawn_blocking`). Decision-only —
    /// `evaluate_record` is pure (only `policy.decide`); no executor, no
    /// provider, no agent runner is reachable (V1 no-egress-seam). No-op when
    /// shadow is disabled (no [`ShadowRouter`] / corpus). The record shares the
    /// turn's F-4 fingerprint so it joins the receipt at reward-scoring time,
    /// and shares the receipt's `timestamp_ms` (§8 decision 1).
    pub(crate) fn capture_shadow(
        &self,
        ctx: &crate::conductor::recipe::ConductorTurnContext,
        request_fingerprint: RequestFingerprint,
        timestamp_ms: u64,
    ) {
        let Some(router) = self.shadow.as_ref() else {
            return;
        };
        let corpus = self.corpus.as_ref();
        let record = router.evaluate_record(ctx, request_fingerprint, corpus, timestamp_ms);
        self.spawn_telemetry(move |store| match store.append_shadow_record(&record) {
            Ok(()) => {}
            Err(e) => tracing::warn!("conductor shadow write failed: {e}"),
        });
    }

    /// M2-live §3.2 step 2: record one explicit user-feedback signal against a
    /// prior turn's `target_request_id`. **Not** best-effort (unlike passive
    /// telemetry): feedback is an explicit user action, so a store write failure
    /// propagates as an error the client can retry (§3.2 step 3 — never silently
    /// drop a negative signal). `target_request_id` is fingerprinted with the
    /// install key (F-4 continuity) and joins the prior turn's receipt/event/
    /// shadow rows on `request_fingerprint`.
    ///
    /// Synchronous on purpose: this is a low-frequency RPC, not the
    /// [`route_turn`](Self::run) hot path that V8 governs. `append_feedback` is
    /// a single-line JSONL append.
    pub(crate) fn record_feedback(
        &self,
        target_request_id: &str,
        signal: crate::conductor::telemetry::UserSignal,
        timestamp_ms: u64,
    ) -> Result<(), crate::conductor::error::ConductorError> {
        let request_fingerprint = self.fingerprint(target_request_id)?;
        let record = crate::conductor::telemetry::FeedbackRecord {
            request_fingerprint,
            signal,
            timestamp_ms,
        };
        self.store.append_feedback(&record)
    }

    /// M2-live §4.2: advisory reward snapshot. Read-only — joins three isolated-
    /// store reads (receipts + shadow + feedback) and returns the auditable
    /// breakdown. Constructs no provider request, spawns no agent, writes
    /// nothing. `window_turns` is clamped to `>= 1`.
    #[allow(clippy::too_many_lines)] // join logic reads best linearly
    pub(crate) fn reward_snapshot(
        &self,
        window_turns: usize,
    ) -> Result<crate::conductor::reward::RewardSnapshot, crate::conductor::error::ConductorError>
    {
        use std::collections::{BTreeMap, HashSet};

        use crate::conductor::eval::{RoutingScore, RoutingScorer};
        use crate::conductor::reward::{
            aggregate_reward, OutcomeMetrics, RewardRoutingSource, RewardSignals, RewardSnapshot,
            RewardSnapshotBaseline, RewardSnapshotWindow,
        };
        use crate::conductor::telemetry::{RouteReceipt, ShadowTurnRecord};

        // 1. Receipts window — trailing-N by timestamp_ms (ascending).
        let mut receipts = self.store.read_receipts()?;
        receipts.sort_by_key(|r| r.timestamp_ms);
        let window_turns = window_turns.max(1);
        let start = receipts.len().saturating_sub(window_turns);
        let window: Vec<RouteReceipt> = receipts[start..].to_vec();
        let window_fps: HashSet<RequestFingerprint> = window
            .iter()
            .map(|r| r.request_fingerprint.clone())
            .collect();

        // 2. Outcome metrics (fully real).
        let outcome = OutcomeMetrics::from_receipts(&window);

        // 3. User signals — join feedback to the window on request_fingerprint.
        let feedback = self.store.read_feedback()?;
        let user_signals: Vec<crate::conductor::telemetry::UserSignal> = feedback
            .iter()
            .filter(|f| window_fps.contains(&f.request_fingerprint))
            .map(|f| f.signal)
            .collect();

        // 4. Routing — LIVE shadow window (not the static corpus re-score).
        let shadow = self.store.read_shadow_records()?;
        let window_shadow: Vec<&ShadowTurnRecord> = shadow
            .iter()
            .filter(|s| window_fps.contains(&s.request_fingerprint))
            .collect();
        let corpus_matches = window_shadow
            .iter()
            .filter(|s| s.corpus_match.is_some())
            .count();
        let matched = corpus_matches;
        let correct = window_shadow
            .iter()
            .filter(|s| s.corpus_match.is_some() && s.deployed_matched_ideal)
            .count();
        let corpus_version = self
            .corpus
            .as_ref()
            .map(|c| c.corpus_version.clone())
            .unwrap_or_default();

        let (routing_accuracy, routing_source) = if matched >= 1 {
            (
                (correct as f64) / (matched as f64),
                RewardRoutingSource::LiveShadow,
            )
        } else {
            // Neutral: 0.5 → routing_accuracy_component maps to 0.0. Honest
            // default — the common case until a classifier lands (§2.5).
            (0.5, RewardRoutingSource::NeutralNoGroundTruth)
        };

        // MINOR-2 guardrail: synthesized score with EMPTY case_outcomes — valid
        // only as input to aggregate_reward's routing component (reads
        // routing_accuracy alone). NEVER pass to is_improvement() (F-12 N=0).
        let live_score = RoutingScore {
            corpus_version: corpus_version.clone(),
            sample_size: u64::try_from(matched).unwrap_or(u64::MAX),
            correct_routes: u64::try_from(correct).unwrap_or(u64::MAX),
            routing_accuracy,
            dimensions: BTreeMap::new(),
            case_outcomes: Vec::new(),
        };

        // 6. Aggregate (self_judgment: None — F-10 honest; the snapshot surface
        // never injects model self-judgment).
        let reward = aggregate_reward(&RewardSignals {
            routing_score: &live_score,
            user_signal: &user_signals,
            outcome_metrics: &outcome,
            self_judgment: None,
        });

        Ok(RewardSnapshot {
            score: reward.score,
            self_judgment_was_capped: reward.self_judgment_was_capped,
            components: reward.components,
            routing_source,
            window: RewardSnapshotWindow {
                turns: outcome.turns,
                feedback_count: u64::try_from(user_signals.len()).unwrap_or(u64::MAX),
                shadow_records: u64::try_from(window_shadow.len()).unwrap_or(u64::MAX),
                corpus_matches: u64::try_from(corpus_matches).unwrap_or(u64::MAX),
                corpus_version,
            },
            baseline: RewardSnapshotBaseline {
                static_corpus_routing_accuracy: self.static_corpus_routing_accuracy(),
            },
        })
    }

    /// §4.2 step 5 baseline: static corpus routing accuracy of the deployed
    /// policy. Uses the startup-cached corpus; if shadow was never enabled
    /// (corpus `None`) re-parses the embedded synthetic core (advisory,
    /// low-frequency). Metadata only — NOT the live reward input. On the
    /// unreachable parse failure (the embedded corpus is tested) returns `0.0`.
    fn static_corpus_routing_accuracy(&self) -> f64 {
        use crate::conductor::eval::RoutingScorer;
        if let Some(corpus) = self.corpus.as_ref() {
            return RoutingScorer::score(corpus, self.policy.as_ref()).routing_accuracy;
        }
        match Corpus::synthetic_core() {
            Ok(corpus) => RoutingScorer::score(&corpus, self.policy.as_ref()).routing_accuracy,
            Err(error) => {
                tracing::warn!("conductor baseline corpus parse failed: {error}");
                0.0
            }
        }
    }

    fn spawn_telemetry<F>(&self, work: F)
    where
        F: FnOnce(&ConductorStore) + Send + 'static,
    {
        let store = self.store.clone();
        drop(tokio::task::spawn_blocking(move || work(&store)));
    }

    /// The recipe's budget timeout in ms, or a conservative default. Used as the
    /// mesh delegation deadline + the budget wall-clock estimate.
    fn mesh_timeout_ms(&self, decision: &OwnedRouteDecision) -> u64 {
        self.recipes
            .get(&decision.recipe_id)
            .map(|r| u64::try_from(r.budget.timeout.as_millis()).unwrap_or(30_000))
            .unwrap_or(30_000)
    }

    /// A FRESH per-delegation correlation id for mesh requests — NEVER the
    /// conductor `request_id` (which is stable across telemetry and would let a
    /// peer correlate turns across time). Derived from the HMAC fingerprint of
    /// the conductor request_id + the worker id, so it's unique per
    /// (turn, peer) yet unlinkable to the conductor's internal id space.
    fn fresh_mesh_request_id(&self, decision: &OwnedRouteDecision) -> String {
        // Composite input: the HMAC is over the opaque request_id (F-4 — no user
        // text) plus the worker id, so two peers seeing the same turn get
        // different ids, and the same (turn, peer) is stable for idempotency.
        let composite = format!("mesh:{}:{}", decision.request_id, decision.worker_id);
        match self.install_key.fingerprint(&composite) {
            Ok(fp) => format!("mesh:{}", fp.0),
            // Fallback: still composite + unlinkable to the raw request_id.
            // Never returns the raw conductor request_id.
            Err(_) => format!("mesh:{}:unkeyed", decision.worker_id),
        }
    }

    fn target_kind_for_worker(&self, worker_id: &str) -> TargetKind {
        self.workers
            .locality(worker_id)
            .map(TargetKind::from)
            .unwrap_or(TargetKind::LocalModel)
    }
}

#[derive(Debug, Clone)]
struct CloudRoleOutput {
    text: String,
    value: Value,
    actual_cost: ActualCost,
}

#[derive(Debug, Clone)]
enum CloudRoleCallFailure {
    Blocked(RouteFailure),
    ProviderFailed(RouteFailure),
}

fn route_failure_display(f: &RouteFailure) -> String {
    match f {
        RouteFailure::InvalidRecipe { recipe_id } => {
            format!("invalid recipe {recipe_id:?}")
        }
        RouteFailure::WorkerUnavailable { worker_id } => {
            format!("worker unavailable {worker_id:?}")
        }
        RouteFailure::RecipeDisabled { recipe_id, reason } => {
            format!("recipe {recipe_id:?} disabled: {reason}")
        }
        RouteFailure::ModeBlocked { mode, lane } => {
            format!("mode {mode:?} does not permit lane {lane:?}")
        }
        RouteFailure::UnexpectedApproval { approval } => {
            format!("unexpected approval class {approval:?}")
        }
        RouteFailure::PrivacyBlocked { level, labels } => {
            format!("privacy membrane blocked (level={level}, labels={labels:?})")
        }
        RouteFailure::BudgetExceeded {
            dimension,
            limit,
            attempted,
            used,
            window_ms,
        } => {
            format!(
                "budget exceeded (dimension={dimension:?}, limit={limit}, attempted={attempted}, used={used}, window_ms={window_ms})"
            )
        }
        RouteFailure::MeshDelegationFailed {
            worker_id,
            outcome_label,
        } => {
            format!("mesh delegation failed (worker={worker_id:?}, {outcome_label})")
        }
    }
}

fn uncostable_worker_failure() -> RouteFailure {
    RouteFailure::BudgetExceeded {
        dimension: BudgetDimension::CostMicros,
        limit: 0,
        attempted: 0,
        used: 0,
        window_ms: 0,
    }
}

fn actual_from_estimate(estimate: &CostEstimate) -> ActualCost {
    ActualCost {
        cost_micros: estimate.cost_micros,
        wall_clock_ms: estimate.wall_clock_ms,
        input_tokens: estimate.input_tokens,
        output_tokens: estimate.output_tokens,
    }
}

/// Build the user-facing wire `Value` from a plain text answer, mirroring the
/// cloud path's `CloudRoleOutput.value` shape (`{text, tool_calls, finish_reason}`)
/// so downstream consumers (`text_from_value`, the session) treat mesh and cloud
/// answers identically. M4: mesh answers carry no tool calls.
fn wire_value_from_text(text: &str) -> Value {
    serde_json::json!({
        "text": text,
        "tool_calls": Vec::<Value>::new(),
        "finish_reason": "stop",
    })
}

fn text_from_value(value: &Value) -> String {
    value
        .get("text")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn prompt_from_command(cmd: &Command) -> String {
    if let Some(text) = cmd.payload.get("text").and_then(Value::as_str) {
        return text.to_string();
    }
    if let Some(prompt) = cmd.payload.get("prompt").and_then(Value::as_str) {
        return prompt.to_string();
    }
    if let Some(messages) = cmd.payload.get("messages").and_then(Value::as_array) {
        let mut joined = String::new();
        for message in messages {
            if let Some(content) = message.get("content").and_then(Value::as_str) {
                if !joined.is_empty() {
                    joined.push('\n');
                }
                joined.push_str(content);
            }
        }
        return joined;
    }
    String::new()
}

fn max_output_tokens_from_command(cmd: &Command) -> u64 {
    cmd.payload
        .get("max_tokens")
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_MAX_OUTPUT_TOKENS)
}

fn role_name(role: ConductorRole) -> &'static str {
    match role {
        ConductorRole::Thinker => "thinker",
        ConductorRole::Worker => "worker",
        ConductorRole::Verifier => "verifier",
    }
}

/// Convenience: run a full conductor turn for `inject_text`. Builds the context,
/// decides, emits the decision event, runs, emits the receipt, returns the wire
/// result. This is the only entry point the session layer calls.
///
/// M2-live §2.1: the F-4 fingerprint is computed **once** per turn and threaded
/// to the event, receipt, and shadow record (which join on it). Telemetry is
/// best-effort — a fingerprint/store failure is logged and the turn still
/// succeeds (§9 N4). M2-live §2.2/§8-1: shadow capture runs **post-`run`**, off
/// the hot path, sharing the receipt's `timestamp_ms`.
pub async fn route_turn(
    runtime: &ConductorRuntime,
    backends: &SessionBackends<'_>,
    cmd: &Command,
    ctx: &crate::conductor::recipe::ConductorTurnContext,
) -> Result<Value, &'static str> {
    let decision = runtime.policy().decide(ctx);
    let event_ts = now_ms();
    // §2.1 fingerprint lift: one HMAC per turn, threaded to every emitter. On
    // the unreachable `Err`, all telemetry is skipped (the join key is absent)
    // but the turn still runs.
    let fingerprint = match runtime.fingerprint(&decision.request_id) {
        Ok(fp) => fp,
        Err(error) => {
            tracing::warn!("conductor fingerprint failed, skipping telemetry: {error}");
            return runtime.run(&decision, backends, cmd).await.0;
        }
    };
    runtime.emit_event(&decision, &fingerprint, event_ts);
    let started = Instant::now();
    let (wire, outcome) = runtime.run(&decision, backends, cmd).await;
    let latency_ms = started.elapsed().as_millis().min(u64::MAX as u128) as u64;
    // §8 decision 1: receipt + shadow share the post-run timestamp so the
    // window join is consistent.
    let end_ts = now_ms();
    runtime.emit_receipt(&decision, &outcome, &fingerprint, latency_ms, end_ts);
    runtime.capture_shadow(ctx, fingerprint, end_ts);
    wire
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis().min(u64::MAX as u128) as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conductor::budget::{BudgetLimits, DEFAULT_DAILY_WINDOW_MS};
    use crate::conductor::policy::{StaticDirectPolicy, STATIC_DIRECT_RECIPE_ID};
    use crate::conductor::recipe::{
        AggregationMode, AggregationPolicy, BudgetPolicy, ConductorTaskClass, EscalationPolicy,
        FaeConductorRecipe, RoleSlot, StopPolicy, WorkerSelector,
    };
    use crate::conductor::workers::{CODEX_CLOUD_WORKER_ID, LOCAL_MODEL_WORKER_ID};
    use crate::events::{EventBus, PlaybackRegistry};
    use crate::session::SessionBackends;
    use fae_audio::AudioManager;
    use fae_engine::{MockAdapter, MockTtsAdapter};
    use std::collections::HashMap;
    use std::error::Error;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;
    use tempfile::TempDir;

    fn budget_limits() -> BudgetLimits {
        BudgetLimits {
            max_cost_micros_per_call: 1_000_000,
            max_wall_clock_ms_per_call: 0,
            max_daily_cost_micros: 10_000_000,
            daily_window: Duration::from_millis(DEFAULT_DAILY_WINDOW_MS),
        }
    }

    /// M4: a budget that permits OwnerFleet mesh routes. The default
    /// [`budget_limits`] sets `max_wall_clock_ms_per_call: 0` (the cloud path's
    /// estimate carries wall_clock_ms: 0, so it passes). The mesh governance
    /// estimate uses the recipe's real timeout, so it needs a nonzero wall-clock
    /// cap to pass — reflecting that governance caps (turn-count/timeout) bind
    /// mesh while cost is deferred.
    fn mesh_friendly_budget_limits() -> BudgetLimits {
        BudgetLimits {
            max_cost_micros_per_call: 1_000_000,
            max_wall_clock_ms_per_call: 60_000,
            max_daily_cost_micros: 10_000_000,
            daily_window: Duration::from_millis(DEFAULT_DAILY_WINDOW_MS),
        }
    }

    fn cloud_pricing(worker_id: &str) -> ProviderPricingTable {
        let mut table = ProviderPricingTable::empty();
        table.insert(
            worker_id,
            crate::conductor::pricing::ProviderPricing {
                input_micros_per_token: 1,
                output_micros_per_token: 1,
            },
        );
        table
    }

    fn cloud_worker(worker_id: &str) -> WorkerSelector {
        WorkerSelector {
            id: worker_id.to_string(),
            kind: "acp".to_string(),
            locality: WorkerLocality::CloudBackedAcp,
            capabilities: vec!["coding".to_string()],
            provider: Some("mock".to_string()),
            model: Some("mock-cloud".to_string()),
            trust_scope: None,
        }
    }

    fn recipe(recipe_id: &str, worker_id: &str, topology: ConductorTopology) -> FaeConductorRecipe {
        let worker = cloud_worker(worker_id);
        let roles = match topology {
            ConductorTopology::Direct => vec![RoleSlot {
                role: ConductorRole::Worker,
                worker: worker.clone(),
                prompt_template_id: "direct".to_string(),
                prompt_template: "Answer.".to_string(),
                output_schema: None,
                required: true,
            }],
            ConductorTopology::Chain => [
                (ConductorRole::Thinker, "think"),
                (ConductorRole::Worker, "work"),
                (ConductorRole::Verifier, "verify"),
            ]
            .into_iter()
            .map(|(role, name)| RoleSlot {
                role,
                worker: worker.clone(),
                prompt_template_id: name.to_string(),
                prompt_template: name.to_string(),
                output_schema: None,
                required: true,
            })
            .collect(),
        };
        FaeConductorRecipe {
            id: recipe_id.to_string(),
            version: 1,
            task_class: ConductorTaskClass::Coding,
            feature_predicates: Vec::new(),
            allowed_workers: vec![worker],
            privacy_lane: PrivacyLane::CloudBacked,
            topology,
            role_slots: roles,
            budget: BudgetPolicy {
                max_turns: 3,
                max_role_calls: 3,
                timeout: Duration::from_millis(30_000),
                max_tokens: None,
                max_cost_micros: None,
            },
            escalation: EscalationPolicy {
                min_confidence_to_stay_local: 0.5,
                allow_acp: true,
                allow_mesh: false,
            },
            aggregation: AggregationPolicy {
                mode: AggregationMode::FirstAnswer,
                require_verifier_approval: false,
            },
            stop: StopPolicy {
                stop_after_verifier: true,
                stop_on_budget_exhaustion: true,
                max_correction_loops: 0,
            },
        }
    }

    fn decision(
        request_id: &str,
        recipe_id: &str,
        worker_id: &str,
        topology: ConductorTopology,
        lane: PrivacyLane,
        approval: ApprovalClass,
    ) -> OwnedRouteDecision {
        OwnedRouteDecision {
            request_id: request_id.to_string(),
            recipe_id: recipe_id.to_string(),
            topology,
            worker_id: worker_id.to_string(),
            task_class: ConductorTaskClass::Coding,
            lane,
            approval,
            reason: "test".to_string(),
        }
    }

    fn command(request_id: &str, text: &str) -> Command {
        Command {
            v: 2,
            request_id: request_id.to_string(),
            command: "conversation.inject_text".to_string(),
            payload: serde_json::json!({ "text": text }),
        }
    }

    struct CountingBuilder {
        calls: Arc<AtomicUsize>,
    }

    impl CountingBuilder {
        fn new() -> (Arc<Self>, Arc<AtomicUsize>) {
            let calls = Arc::new(AtomicUsize::new(0));
            (
                Arc::new(Self {
                    calls: Arc::clone(&calls),
                }),
                calls,
            )
        }
    }

    impl CloudRequestBuilder for CountingBuilder {
        fn build(&self, input: CloudRequestBuildInput<'_>) -> CloudRequest {
            self.calls.fetch_add(1, Ordering::SeqCst);
            DefaultCloudRequestBuilder.build(input)
        }
    }

    struct CountingProvider {
        calls: Arc<AtomicUsize>,
        outputs: Mutex<Vec<String>>,
    }

    impl CountingProvider {
        fn new(outputs: Vec<String>) -> (Arc<Self>, Arc<AtomicUsize>) {
            let calls = Arc::new(AtomicUsize::new(0));
            (
                Arc::new(Self {
                    calls: Arc::clone(&calls),
                    outputs: Mutex::new(outputs),
                }),
                calls,
            )
        }
    }

    impl CloudProvider for CountingProvider {
        fn call(&self, request: CloudRequest) -> CloudCallResult {
            self.calls.fetch_add(1, Ordering::SeqCst);
            let text = self
                .outputs
                .lock()
                .expect("provider outputs lock in test")
                .pop()
                .unwrap_or_else(|| format!("cloud ok: {}", request.prompt));
            Ok(CloudCallSuccess {
                response: serde_json::json!({
                    "text": text,
                    "tool_calls": Vec::<Value>::new(),
                    "finish_reason": "stop",
                }),
                actual_cost: None,
            })
        }
    }

    struct CountingMembrane {
        calls: Arc<AtomicUsize>,
        block: bool,
    }

    impl CountingMembrane {
        fn new(block: bool) -> (Arc<Self>, Arc<AtomicUsize>) {
            let calls = Arc::new(AtomicUsize::new(0));
            (
                Arc::new(Self {
                    calls: Arc::clone(&calls),
                    block,
                }),
                calls,
            )
        }
    }

    impl PiiMembrane for CountingMembrane {
        fn scan_for_remote_egress(&self, _text: &str) -> MembraneVerdict {
            self.calls.fetch_add(1, Ordering::SeqCst);
            MembraneVerdict {
                block_remote_egress: self.block,
                level: if self.block {
                    "LikelyCredential"
                } else {
                    "Normal"
                }
                .to_string(),
                labels: if self.block {
                    vec!["test".to_string()]
                } else {
                    Vec::new()
                },
            }
        }
    }

    struct TestRuntime {
        _tmp: TempDir,
        runtime: ConductorRuntime,
        engine: MockAdapter,
        tts: MockTtsAdapter,
        audio: AudioManager,
        events: EventBus,
        playbacks: PlaybackRegistry,
        agents: crate::agents::AgentSessionRegistry,
    }

    impl TestRuntime {
        fn backends(&self) -> SessionBackends<'_> {
            SessionBackends {
                engine: &self.engine,
                asr_fallback: None,
                tts: &self.tts,
                audio: &self.audio,
                events: &self.events,
                playbacks: &self.playbacks,
                agents: &self.agents,
                conductor: Some(&self.runtime),
                acp_runner: &crate::session::REAL_ACP_RUNNER,
            }
        }
    }

    struct TestRuntimeOptions {
        mode: ModelMode,
        topology: ConductorTopology,
        provisioned: bool,
        pricing: ProviderPricingTable,
        membrane: Arc<dyn PiiMembrane>,
        builder: Arc<dyn CloudRequestBuilder>,
        provider: Arc<dyn CloudProvider>,
        chain_enabled: bool,
    }

    fn test_runtime(options: TestRuntimeOptions) -> Result<TestRuntime, Box<dyn Error>> {
        let tmp = tempfile::tempdir()?;
        let store = ConductorStore::open(tmp.path().join("store"))?;
        let install_key = InstallKey::load_or_create(&tmp.path().join("install.key"))?;
        let recipes = RecipeSet::from_iter([(
            "recipe-cloud".to_string(),
            recipe("recipe-cloud", CODEX_CLOUD_WORKER_ID, options.topology),
        )]);
        let mut workers = WorkerRegistry::m1();
        workers.register_cloud_backed(CODEX_CLOUD_WORKER_ID, options.provisioned);
        let budget = BudgetGovernor::new(store.clone(), budget_limits());
        let egress = ConductorEgress::with_components(
            options.mode,
            budget,
            options.pricing,
            options.membrane,
            options.builder,
            options.provider,
        );
        Ok(TestRuntime {
            _tmp: tmp,
            runtime: ConductorRuntime::new_with_egress(
                StaticDirectPolicy,
                recipes,
                workers,
                store,
                install_key,
                options.chain_enabled,
                egress,
            )
            .with_shadow(),
            engine: MockAdapter::new("local"),
            tts: MockTtsAdapter::new("tts"),
            audio: AudioManager::new(),
            events: EventBus::new(),
            playbacks: PlaybackRegistry::new(),
            agents: crate::agents::AgentSessionRegistry::new(),
        })
    }

    fn budget_usage_content(runtime: &TestRuntime) -> String {
        let path = runtime
            ._tmp
            .path()
            .join("store")
            .join("conductor_budget_usage.jsonl");
        std::fs::read_to_string(path).unwrap_or_default()
    }

    /// Defense-in-depth for the red-team MINOR (lane/worker locality
    /// mismatch): a `CloudBacked` decision targeting the local-model worker
    /// must fail closed at the approval gate even when the worker is
    /// provisioned AND has pricing, so that neither the PII membrane nor the
    /// budget gate blocks first. The locality assertion is the sole remaining
    /// defense; without it the request would be constructed and egressed.
    #[tokio::test]
    async fn locality_mismatch_blocks_cloud_lane_to_provisioned_local_worker(
    ) -> Result<(), Box<dyn Error>> {
        let (builder, builder_calls) = CountingBuilder::new();
        let (provider, provider_calls) = CountingProvider::new(Vec::new());
        // Deterministic non-blocking membrane: isolates the test from any
        // real-membrane benign-text behavior so only the approval gate can
        // stop egress.
        let (membrane, _membrane_calls) = CountingMembrane::new(false);
        // Price the LOCAL worker so the budget gate (uncostable => fail closed)
        // does NOT block. This isolates the locality assertion as the sole
        // defense: without the fix this test would observe cloud egress.
        let runtime = test_runtime(TestRuntimeOptions {
            mode: ModelMode::AllAvailable,
            topology: ConductorTopology::Direct,
            provisioned: true,
            pricing: cloud_pricing(LOCAL_MODEL_WORKER_ID),
            membrane,
            builder,
            provider,
            chain_enabled: false,
        })?;
        let cmd = command("req-mismatch", "plan a small function");
        let decision = decision(
            "req-mismatch",
            "recipe-cloud",
            LOCAL_MODEL_WORKER_ID,
            ConductorTopology::Direct,
            PrivacyLane::CloudBacked,
            ApprovalClass::StandingGrant("grant".to_string()),
        );

        let backends = runtime.backends();
        let (wire, outcome) = runtime.runtime.run(&decision, &backends, &cmd).await;
        assert!(wire.is_ok());
        assert_eq!(builder_calls.load(Ordering::SeqCst), 0);
        assert_eq!(provider_calls.load(Ordering::SeqCst), 0);
        assert!(outcome.fallback);
        assert!(outcome
            .fallback_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("approval")));
        assert!(budget_usage_content(&runtime).is_empty());
        Ok(())
    }

    #[tokio::test]
    async fn membrane_blocks_before_cloud_request_construction() -> Result<(), Box<dyn Error>> {
        let (builder, builder_calls) = CountingBuilder::new();
        let (provider, provider_calls) = CountingProvider::new(Vec::new());
        let runtime = test_runtime(TestRuntimeOptions {
            mode: ModelMode::AllAvailable,
            topology: ConductorTopology::Direct,
            provisioned: true,
            pricing: cloud_pricing(CODEX_CLOUD_WORKER_ID),
            membrane: Arc::new(ConductorEgressMembrane),
            builder,
            provider,
            chain_enabled: false,
        })?;
        let cmd = command(
            "req-secret",
            "please review this sk-abcdefghijklmnopqrstuvwxyz",
        );
        let decision = decision(
            "req-secret",
            "recipe-cloud",
            CODEX_CLOUD_WORKER_ID,
            ConductorTopology::Direct,
            PrivacyLane::CloudBacked,
            ApprovalClass::StandingGrant("grant".to_string()),
        );

        let backends = runtime.backends();
        let (wire, outcome) = runtime.runtime.run(&decision, &backends, &cmd).await;
        assert!(wire.is_ok());
        assert_eq!(builder_calls.load(Ordering::SeqCst), 0);
        assert_eq!(provider_calls.load(Ordering::SeqCst), 0);
        assert!(outcome.fallback);
        assert!(outcome
            .fallback_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("privacy membrane blocked")));
        assert!(budget_usage_content(&runtime).is_empty());

        let fingerprint = runtime
            .runtime
            .fingerprint(&decision.request_id)
            .map_err(|e| format!("fingerprint: {e}"))?;
        runtime
            .runtime
            .emit_receipt(&decision, &outcome, &fingerprint, 1, 1);
        tokio::time::sleep(Duration::from_millis(50)).await;
        let receipts = std::fs::read_to_string(
            runtime
                ._tmp
                .path()
                .join("store")
                .join("conductor_receipts.jsonl"),
        )?;
        assert!(receipts.contains("privacy membrane blocked"));
        Ok(())
    }

    /// Build an OwnerFleet test runtime with an injectable mesh port. M4-D
    /// acceptance tests share this; M4-A keeps its inline construction (it
    /// only needs the membrane proof). Returns the runtime + the fleet worker
    /// id + recipe id (for constructing a decision).
    fn ownerfleet_runtime(
        mesh_port: Arc<dyn ConductorMeshDelegationPort>,
        membrane: Arc<dyn PiiMembrane>,
    ) -> Result<
        (
            ConductorRuntime,
            tempfile::TempDir,
            &'static str,
            &'static str,
        ),
        Box<dyn Error>,
    > {
        const FLEET_WORKER_ID: &str = "fleet:peer-laptop";
        const RECIPE_ID: &str = "recipe-fleet";
        let fleet_worker = WorkerSelector {
            id: FLEET_WORKER_ID.to_string(),
            kind: "fleet".to_string(),
            locality: WorkerLocality::OwnerFleet,
            capabilities: vec!["coding".to_string()],
            provider: None,
            model: Some("qwen3.5-32b".to_string()),
            trust_scope: None,
        };
        let recipes = RecipeSet::from_iter([(
            RECIPE_ID.to_string(),
            FaeConductorRecipe {
                id: RECIPE_ID.to_string(),
                version: 1,
                task_class: ConductorTaskClass::Coding,
                feature_predicates: Vec::new(),
                allowed_workers: vec![fleet_worker.clone()],
                privacy_lane: PrivacyLane::OwnerFleet,
                topology: ConductorTopology::Direct,
                role_slots: vec![RoleSlot {
                    role: ConductorRole::Worker,
                    worker: fleet_worker,
                    prompt_template_id: "direct".to_string(),
                    prompt_template: "Answer.".to_string(),
                    output_schema: None,
                    required: true,
                }],
                budget: BudgetPolicy {
                    max_turns: 3,
                    max_role_calls: 3,
                    timeout: Duration::from_millis(30_000),
                    max_tokens: None,
                    max_cost_micros: None,
                },
                escalation: EscalationPolicy {
                    min_confidence_to_stay_local: 0.5,
                    allow_acp: true,
                    allow_mesh: true,
                },
                aggregation: AggregationPolicy {
                    mode: AggregationMode::FirstAnswer,
                    require_verifier_approval: false,
                },
                stop: StopPolicy {
                    stop_after_verifier: true,
                    stop_on_budget_exhaustion: true,
                    max_correction_loops: 0,
                },
            },
        )]);
        let mut workers = WorkerRegistry::m1();
        workers.register_owner_fleet(FLEET_WORKER_ID, true);
        let tmp = tempfile::tempdir()?;
        let store = ConductorStore::open(tmp.path().join("store"))?;
        let install_key = InstallKey::load_or_create(&tmp.path().join("install.key"))?;
        let budget = BudgetGovernor::new(store.clone(), mesh_friendly_budget_limits());
        let (builder, _builder_calls) = CountingBuilder::new();
        let (provider, _provider_calls) = CountingProvider::new(Vec::new());
        let egress = ConductorEgress::with_components_and_mesh(
            ModelMode::LocalSymphony,
            budget,
            ProviderPricingTable::empty(),
            membrane,
            builder,
            provider,
            mesh_port,
        );
        let runtime = ConductorRuntime::new_with_egress(
            StaticDirectPolicy,
            recipes,
            workers,
            store,
            install_key,
            false,
            egress,
        )
        .with_shadow();
        Ok((runtime, tmp, FLEET_WORKER_ID, RECIPE_ID))
    }

    /// M4-A (F-2): an `OwnerFleet` route carrying a credential-shaped prompt is
    /// blocked by the `ConductorEgressMembrane` at §5.3 BEFORE any remote-egress
    /// dispatch — proving the same-owner mesh lane is membrane-covered today,
    /// structurally (via the named authority), not incidentally. The route is
    /// constructed to clear the earlier gates (mode cap under `LocalSymphony`, +
    /// a provisioned OwnerFleet worker with a matching standing grant) so it
    /// genuinely reaches the membrane, then fails closed to direct-local.
    #[tokio::test]
    async fn ownerfleet_credential_prompt_blocked_before_remote_dispatch(
    ) -> Result<(), Box<dyn Error>> {
        let (builder, builder_calls) = CountingBuilder::new();
        let (provider, provider_calls) = CountingProvider::new(Vec::new());
        // A provisioned same-owner fleet worker (the OwnerFleet lane). Real mesh
        // transport is dormant; this exercises the registry/egress-gate path only.
        const FLEET_WORKER_ID: &str = "fleet:peer-laptop";
        let fleet_worker = WorkerSelector {
            id: FLEET_WORKER_ID.to_string(),
            kind: "fleet".to_string(),
            locality: WorkerLocality::OwnerFleet,
            capabilities: vec!["coding".to_string()],
            provider: None,
            model: Some("qwen3.5-32b".to_string()),
            trust_scope: None,
        };
        let recipes = RecipeSet::from_iter([(
            "recipe-fleet".to_string(),
            FaeConductorRecipe {
                id: "recipe-fleet".to_string(),
                version: 1,
                task_class: ConductorTaskClass::Coding,
                feature_predicates: Vec::new(),
                allowed_workers: vec![fleet_worker.clone()],
                privacy_lane: PrivacyLane::OwnerFleet,
                topology: ConductorTopology::Direct,
                role_slots: vec![RoleSlot {
                    role: ConductorRole::Worker,
                    worker: fleet_worker.clone(),
                    prompt_template_id: "direct".to_string(),
                    prompt_template: "Answer.".to_string(),
                    output_schema: None,
                    required: true,
                }],
                budget: BudgetPolicy {
                    max_turns: 3,
                    max_role_calls: 3,
                    timeout: Duration::from_millis(30_000),
                    max_tokens: None,
                    max_cost_micros: None,
                },
                escalation: EscalationPolicy {
                    min_confidence_to_stay_local: 0.5,
                    allow_acp: true,
                    allow_mesh: true,
                },
                aggregation: AggregationPolicy {
                    mode: AggregationMode::FirstAnswer,
                    require_verifier_approval: false,
                },
                stop: StopPolicy {
                    stop_after_verifier: true,
                    stop_on_budget_exhaustion: true,
                    max_correction_loops: 0,
                },
            },
        )]);
        let mut workers = WorkerRegistry::m1();
        workers.register_owner_fleet(FLEET_WORKER_ID, true);
        let tmp = tempfile::tempdir()?;
        let store = ConductorStore::open(tmp.path().join("store"))?;
        let install_key = InstallKey::load_or_create(&tmp.path().join("install.key"))?;
        let budget = BudgetGovernor::new(store.clone(), budget_limits());
        let egress = ConductorEgress::with_components(
            // LocalSymphony permits OwnerFleet (verified: mode_permits_lane).
            ModelMode::LocalSymphony,
            budget,
            ProviderPricingTable::empty(),
            Arc::new(ConductorEgressMembrane),
            builder,
            provider,
        );
        let runtime = ConductorRuntime::new_with_egress(
            StaticDirectPolicy,
            recipes,
            workers,
            store,
            install_key,
            false,
            egress,
        )
        .with_shadow();
        // Credential-shaped prompt: the membrane must block it at §5.3.
        let cmd = command(
            "req-fleet-secret",
            "please review this sk-abcdefghijklmnopqrstuvwxyz",
        );
        let decision = decision(
            "req-fleet-secret",
            "recipe-fleet",
            FLEET_WORKER_ID,
            ConductorTopology::Direct,
            PrivacyLane::OwnerFleet,
            ApprovalClass::StandingGrant("fleet-grant".to_string()),
        );
        // Backends for the fail-closed direct-local path (the turn must reach
        // inject_text_core, which needs backends, but must NOT reach a cloud call).
        let engine = MockAdapter::new("local");
        let tts = MockTtsAdapter::new("tts");
        let audio = AudioManager::new();
        let events = EventBus::new();
        let playbacks = PlaybackRegistry::new();
        let agents = crate::agents::AgentSessionRegistry::new();
        let backends = SessionBackends {
            engine: &engine,
            asr_fallback: None,
            tts: &tts,
            audio: &audio,
            events: &events,
            playbacks: &playbacks,
            agents: &agents,
            conductor: Some(&runtime),
            acp_runner: &crate::session::REAL_ACP_RUNNER,
        };
        let (wire, outcome) = runtime.run(&decision, &backends, &cmd).await;
        // The user still gets an answer (fail-closed direct-local), but the turn
        // is a fallback: the membrane blocked before any remote dispatch.
        assert!(wire.is_ok());
        assert_eq!(
            builder_calls.load(Ordering::SeqCst),
            0,
            "no cloud request built"
        );
        assert_eq!(
            provider_calls.load(Ordering::SeqCst),
            0,
            "no provider call made"
        );
        assert!(
            outcome.fallback,
            "OwnerFleet route must fail-closed (fallback)"
        );
        assert!(
            outcome
                .fallback_reason
                .as_deref()
                .is_some_and(|r| r.contains("privacy membrane blocked")),
            "expected privacy-membrane-blocked reason, got: {:?}",
            outcome.fallback_reason
        );
        // Budget never ran (membrane is §5.3, before budget §5.4).
        let budget_usage = std::fs::read_to_string(
            tmp.path()
                .join("store")
                .join("conductor_budget_usage.jsonl"),
        )
        .unwrap_or_default();
        assert!(
            budget_usage.is_empty(),
            "budget must not record: {budget_usage}"
        );
        Ok(())
    }

    /// M4-D: happy path — a non-secret OwnerFleet route after clearing §5 gates
    /// delegates through the mesh port exactly once, returns the peer's answer,
    /// and does NOT fall back. Verifies mesh_request_id != conductor request_id
    /// (no stable cross-turn id leaks to the peer).
    #[tokio::test]
    async fn ownerfleet_route_delegates_through_mesh_port() -> Result<(), Box<dyn Error>> {
        use crate::conductor::mesh::test_support::MockMeshDelegationPort;
        let mesh = Arc::new(MockMeshDelegationPort::completed("peer answered"));
        let mesh_ref = mesh.clone();
        let (runtime, _tmp, worker, recipe) =
            ownerfleet_runtime(mesh, Arc::new(ConductorEgressMembrane))?;
        let cmd = command("req-fleet-ok", "summarize the rust async book");
        let decision = decision(
            "req-fleet-ok",
            recipe,
            worker,
            ConductorTopology::Direct,
            PrivacyLane::OwnerFleet,
            ApprovalClass::StandingGrant("fleet-grant".to_string()),
        );
        let engine = MockAdapter::new("local");
        let tts = MockTtsAdapter::new("tts");
        let audio = AudioManager::new();
        let events = EventBus::new();
        let playbacks = PlaybackRegistry::new();
        let agents = crate::agents::AgentSessionRegistry::new();
        let backends = SessionBackends {
            engine: &engine,
            asr_fallback: None,
            tts: &tts,
            audio: &audio,
            events: &events,
            playbacks: &playbacks,
            agents: &agents,
            conductor: Some(&runtime),
            acp_runner: &crate::session::REAL_ACP_RUNNER,
        };
        let (wire, outcome) = runtime.run(&decision, &backends, &cmd).await;
        assert!(wire.is_ok(), "mesh turn must succeed: {:?}", wire.err());
        assert!(!outcome.fallback, "no fallback on mesh success");
        assert_eq!(outcome.privacy_lane, PrivacyLane::OwnerFleet);
        // The port was invoked exactly once.
        assert_eq!(mesh_ref.call_count(), 1);
        // ...with the post-membrane slice, the right peer worker, and a FRESH
        // mesh_request_id (never the conductor request_id).
        let last = mesh_ref
            .last_request
            .lock()
            .unwrap()
            .clone()
            .expect("mesh port was called");
        assert_eq!(last.prompt_slice, "summarize the rust async book");
        assert_eq!(last.peer_worker_id, worker);
        assert_ne!(
            last.mesh_request_id, decision.request_id,
            "mesh_request_id must NOT be the conductor request_id (metadata hygiene)"
        );
        assert!(last.mesh_request_id.starts_with("mesh:"));
        // The answer reaches the wire in the cloud-mirrored shape ({text,...}).
        let value = wire.unwrap();
        assert_eq!(
            value.get("text").and_then(|v| v.as_str()),
            Some("peer answered")
        );
        Ok(())
    }

    /// M4-D: F-2 integration proof — an OwnerFleet route with a credential
    /// prompt is blocked by the membrane AND the mesh port is NEVER invoked
    /// (call-count 0). This is the strong F-2 guarantee now that the port exists.
    #[tokio::test]
    async fn ownerfleet_credential_prompt_mesh_port_not_invoked() -> Result<(), Box<dyn Error>> {
        use crate::conductor::mesh::test_support::MockMeshDelegationPort;
        let mesh = Arc::new(MockMeshDelegationPort::completed("should not be reached"));
        let mesh_ref = mesh.clone();
        let (runtime, _tmp, worker, recipe) =
            ownerfleet_runtime(mesh, Arc::new(ConductorEgressMembrane))?;
        let cmd = command(
            "req-fleet-leak",
            "please review this sk-abcdefghijklmnopqrstuvwxyz",
        );
        let decision = decision(
            "req-fleet-leak",
            recipe,
            worker,
            ConductorTopology::Direct,
            PrivacyLane::OwnerFleet,
            ApprovalClass::StandingGrant("fleet-grant".to_string()),
        );
        let engine = MockAdapter::new("local");
        let tts = MockTtsAdapter::new("tts");
        let audio = AudioManager::new();
        let events = EventBus::new();
        let playbacks = PlaybackRegistry::new();
        let agents = crate::agents::AgentSessionRegistry::new();
        let backends = SessionBackends {
            engine: &engine,
            asr_fallback: None,
            tts: &tts,
            audio: &audio,
            events: &events,
            playbacks: &playbacks,
            agents: &agents,
            conductor: Some(&runtime),
            acp_runner: &crate::session::REAL_ACP_RUNNER,
        };
        let (wire, outcome) = runtime.run(&decision, &backends, &cmd).await;
        assert!(wire.is_ok(), "fail-closed direct-local still answers");
        assert!(outcome.fallback, "must fail-closed (fallback)");
        assert!(outcome
            .fallback_reason
            .as_deref()
            .is_some_and(|r| r.contains("privacy membrane blocked")));
        // The strong F-2 proof: the mesh port was NEVER called.
        assert_eq!(
            mesh_ref.call_count(),
            0,
            "mesh port must not be invoked when membrane blocks"
        );
        Ok(())
    }

    /// M4-D: the dormant production default — with UnavailableMeshDelegationPort,
    /// an OwnerFleet route degrades to direct-local (no mock ever answers a real
    /// turn). This is the dormancy guarantee.
    #[tokio::test]
    async fn ownerfleet_no_port_configured_fails_closed() -> Result<(), Box<dyn Error>> {
        use crate::conductor::mesh::UnavailableMeshDelegationPort;
        let (runtime, _tmp, worker, recipe) = ownerfleet_runtime(
            Arc::new(UnavailableMeshDelegationPort),
            Arc::new(ConductorEgressMembrane),
        )?;
        let cmd = command("req-fleet-noport", "summarize the rust async book");
        let decision = decision(
            "req-fleet-noport",
            recipe,
            worker,
            ConductorTopology::Direct,
            PrivacyLane::OwnerFleet,
            ApprovalClass::StandingGrant("fleet-grant".to_string()),
        );
        let engine = MockAdapter::new("local");
        let tts = MockTtsAdapter::new("tts");
        let audio = AudioManager::new();
        let events = EventBus::new();
        let playbacks = PlaybackRegistry::new();
        let agents = crate::agents::AgentSessionRegistry::new();
        let backends = SessionBackends {
            engine: &engine,
            asr_fallback: None,
            tts: &tts,
            audio: &audio,
            events: &events,
            playbacks: &playbacks,
            agents: &agents,
            conductor: Some(&runtime),
            acp_runner: &crate::session::REAL_ACP_RUNNER,
        };
        let (wire, outcome) = runtime.run(&decision, &backends, &cmd).await;
        assert!(wire.is_ok(), "fail-closed direct-local still answers");
        assert!(outcome.fallback, "no-port OwnerFleet must fail-closed");
        assert!(outcome
            .fallback_reason
            .as_deref()
            .is_some_and(|r| r.contains("mesh delegation failed")));
        Ok(())
    }

    /// M4-D: mesh failure (timeout/unreachable/denied) fail-closes to direct-local.
    #[tokio::test]
    async fn ownerfleet_mesh_failure_fails_closed() -> Result<(), Box<dyn Error>> {
        use crate::conductor::mesh::{test_support::MockMeshDelegationPort, MeshOutcomeKind};
        for kind in [
            MeshOutcomeKind::Timeout,
            MeshOutcomeKind::PeerUnreachable,
            MeshOutcomeKind::Denied,
            MeshOutcomeKind::TransportError,
        ] {
            let mesh = Arc::new(MockMeshDelegationPort::failing(kind));
            let (runtime, _tmp, worker, recipe) =
                ownerfleet_runtime(mesh, Arc::new(ConductorEgressMembrane))?;
            let req_id = format!("req-fleet-fail-{kind:?}");
            let cmd = command(&req_id, "summarize the rust async book");
            let decision = decision(
                &req_id,
                recipe,
                worker,
                ConductorTopology::Direct,
                PrivacyLane::OwnerFleet,
                ApprovalClass::StandingGrant("fleet-grant".to_string()),
            );
            let engine = MockAdapter::new("local");
            let tts = MockTtsAdapter::new("tts");
            let audio = AudioManager::new();
            let events = EventBus::new();
            let playbacks = PlaybackRegistry::new();
            let agents = crate::agents::AgentSessionRegistry::new();
            let backends = SessionBackends {
                engine: &engine,
                asr_fallback: None,
                tts: &tts,
                audio: &audio,
                events: &events,
                playbacks: &playbacks,
                agents: &agents,
                conductor: Some(&runtime),
                acp_runner: &crate::session::REAL_ACP_RUNNER,
            };
            let (wire, outcome) = runtime.run(&decision, &backends, &cmd).await;
            assert!(wire.is_ok(), "{kind:?}: fail-closed must still answer");
            assert!(outcome.fallback, "{kind:?}: must fail-closed");
            assert!(
                outcome
                    .fallback_reason
                    .as_deref()
                    .is_some_and(|r| r.contains("mesh delegation failed")),
                "{kind:?}: reason={:?}",
                outcome.fallback_reason
            );
        }
        Ok(())
    }

    /// M4-D: Chain + OwnerFleet is NOT routed to the cloud chain — it fails
    /// closed explicitly (mesh-chain is unimplemented; a future slice). Must not
    /// call the cloud builder/provider OR the mesh port.
    #[tokio::test]
    async fn ownerfleet_chain_topology_fails_closed_without_egress() -> Result<(), Box<dyn Error>> {
        use crate::conductor::mesh::test_support::MockMeshDelegationPort;
        let mesh = Arc::new(MockMeshDelegationPort::completed("should not be reached"));
        let mesh_ref = mesh.clone();
        const FLEET_WORKER_ID: &str = "fleet:peer-laptop";
        let fleet_worker = WorkerSelector {
            id: FLEET_WORKER_ID.to_string(),
            kind: "fleet".to_string(),
            locality: WorkerLocality::OwnerFleet,
            capabilities: vec!["coding".to_string()],
            provider: None,
            model: Some("qwen3.5-32b".to_string()),
            trust_scope: None,
        };
        let chain_recipe = FaeConductorRecipe {
            id: "recipe-fleet-chain".to_string(),
            version: 1,
            task_class: ConductorTaskClass::Coding,
            feature_predicates: Vec::new(),
            allowed_workers: vec![fleet_worker.clone()],
            privacy_lane: PrivacyLane::OwnerFleet,
            topology: ConductorTopology::Chain,
            role_slots: [
                ConductorRole::Thinker,
                ConductorRole::Worker,
                ConductorRole::Verifier,
            ]
            .iter()
            .zip(["think", "work", "verify"])
            .map(|(role, name)| RoleSlot {
                role: *role,
                worker: fleet_worker.clone(),
                prompt_template_id: name.to_string(),
                prompt_template: name.to_string(),
                output_schema: None,
                required: true,
            })
            .collect(),
            budget: BudgetPolicy {
                max_turns: 3,
                max_role_calls: 3,
                timeout: Duration::from_millis(30_000),
                max_tokens: None,
                max_cost_micros: None,
            },
            escalation: EscalationPolicy {
                min_confidence_to_stay_local: 0.5,
                allow_acp: true,
                allow_mesh: true,
            },
            aggregation: AggregationPolicy {
                mode: AggregationMode::FirstAnswer,
                require_verifier_approval: false,
            },
            stop: StopPolicy {
                stop_after_verifier: true,
                stop_on_budget_exhaustion: true,
                max_correction_loops: 0,
            },
        };
        let recipes = RecipeSet::from_iter([("recipe-fleet-chain".to_string(), chain_recipe)]);
        let mut workers = WorkerRegistry::m1();
        workers.register_owner_fleet(FLEET_WORKER_ID, true);
        let tmp = tempfile::tempdir()?;
        let store = ConductorStore::open(tmp.path().join("store"))?;
        let install_key = InstallKey::load_or_create(&tmp.path().join("install.key"))?;
        let budget = BudgetGovernor::new(store.clone(), mesh_friendly_budget_limits());
        let (builder, _builder_calls) = CountingBuilder::new();
        let (provider, _provider_calls) = CountingProvider::new(Vec::new());
        let egress = ConductorEgress::with_components_and_mesh(
            ModelMode::LocalSymphony,
            budget,
            ProviderPricingTable::empty(),
            Arc::new(ConductorEgressMembrane),
            builder,
            provider,
            mesh,
        );
        let runtime = ConductorRuntime::new_with_egress(
            StaticDirectPolicy,
            recipes,
            workers,
            store,
            install_key,
            true, // chain_enabled, but Chain+OwnerFleet still fails closed.
            egress,
        )
        .with_shadow();
        let cmd = command("req-fleet-chain", "summarize the rust async book");
        let decision = decision(
            "req-fleet-chain",
            "recipe-fleet-chain",
            FLEET_WORKER_ID,
            ConductorTopology::Chain,
            PrivacyLane::OwnerFleet,
            ApprovalClass::StandingGrant("fleet-grant".to_string()),
        );
        let engine = MockAdapter::new("local");
        let tts = MockTtsAdapter::new("tts");
        let audio = AudioManager::new();
        let events = EventBus::new();
        let playbacks = PlaybackRegistry::new();
        let agents = crate::agents::AgentSessionRegistry::new();
        let backends = SessionBackends {
            engine: &engine,
            asr_fallback: None,
            tts: &tts,
            audio: &audio,
            events: &events,
            playbacks: &playbacks,
            agents: &agents,
            conductor: Some(&runtime),
            acp_runner: &crate::session::REAL_ACP_RUNNER,
        };
        let (wire, outcome) = runtime.run(&decision, &backends, &cmd).await;
        assert!(wire.is_ok(), "fail-closed direct-local still answers");
        assert!(outcome.fallback, "Chain+OwnerFleet must fail-closed");
        assert!(outcome
            .fallback_reason
            .as_deref()
            .is_some_and(|r| r.contains("chain+OwnerFleet lane not implemented")));
        assert_eq!(
            mesh_ref.call_count(),
            0,
            "mesh port must not be called for chain+OwnerFleet"
        );
        Ok(())
    }

    /// M4-D regression: CloudBacked direct still uses the cloud path (builder +
    /// provider both called) after the dispatch split — the split didn't divert
    /// cloud routes to mesh or local.
    #[tokio::test]
    async fn cloudblackbacked_still_uses_cloud_path_after_dispatch_split(
    ) -> Result<(), Box<dyn Error>> {
        let (builder, builder_calls) = CountingBuilder::new();
        let (provider, provider_calls) = CountingProvider::new(Vec::new());
        let runtime = test_runtime(TestRuntimeOptions {
            mode: ModelMode::AllAvailable,
            topology: ConductorTopology::Direct,
            provisioned: true,
            pricing: cloud_pricing(CODEX_CLOUD_WORKER_ID),
            membrane: Arc::new(ConductorEgressMembrane),
            builder,
            provider,
            chain_enabled: false,
        })?;
        let cmd = command("req-cloud-regress", "what is 2+2");
        let decision = decision(
            "req-cloud-regress",
            "recipe-cloud",
            CODEX_CLOUD_WORKER_ID,
            ConductorTopology::Direct,
            PrivacyLane::CloudBacked,
            ApprovalClass::StandingGrant("grant".to_string()),
        );
        let backends = runtime.backends();
        let (wire, outcome) = runtime.runtime.run(&decision, &backends, &cmd).await;
        assert!(wire.is_ok(), "cloud turn must succeed: {:?}", wire.err());
        assert!(!outcome.fallback, "cloud direct must not fallback");
        assert!(
            builder_calls.load(Ordering::SeqCst) > 0,
            "cloud builder must be called"
        );
        assert!(
            provider_calls.load(Ordering::SeqCst) > 0,
            "cloud provider must be called"
        );
        Ok(())
    }

    #[tokio::test]
    async fn chain_membrane_blocks_thinker_worker_or_verifier_prompt() -> Result<(), Box<dyn Error>>
    {
        struct Case {
            name: &'static str,
            prompt: &'static str,
            outputs: Vec<String>,
            expected_builder_calls: usize,
            expected_provider_calls: usize,
        }

        let cases = vec![
            Case {
                name: "thinker",
                prompt: "sk-abcdefghijklmnopqrstuvwxyz",
                outputs: Vec::new(),
                expected_builder_calls: 0,
                expected_provider_calls: 0,
            },
            Case {
                name: "worker",
                prompt: "clean planning prompt",
                // pop() returns from the end: first provider call returns a
                // credential, so the Worker prompt (Thinker output) is blocked.
                outputs: vec![
                    "unused".to_string(),
                    "sk-abcdefghijklmnopqrstuvwxyz".to_string(),
                ],
                expected_builder_calls: 1,
                expected_provider_calls: 1,
            },
            Case {
                name: "verifier",
                prompt: "clean planning prompt",
                // Thinker output is clean; Worker output is credential-shaped,
                // so the Verifier prompt is blocked before the third request.
                outputs: vec![
                    "sk-abcdefghijklmnopqrstuvwxyz".to_string(),
                    "clean plan".to_string(),
                ],
                expected_builder_calls: 2,
                expected_provider_calls: 2,
            },
        ];

        for case in cases {
            let (builder, builder_calls) = CountingBuilder::new();
            let (provider, provider_calls) = CountingProvider::new(case.outputs);
            let runtime = test_runtime(TestRuntimeOptions {
                mode: ModelMode::AllAvailable,
                topology: ConductorTopology::Chain,
                provisioned: true,
                pricing: cloud_pricing(CODEX_CLOUD_WORKER_ID),
                membrane: Arc::new(ConductorEgressMembrane),
                builder,
                provider,
                chain_enabled: true,
            })?;
            let cmd = command(case.name, case.prompt);
            let decision = decision(
                case.name,
                "recipe-cloud",
                CODEX_CLOUD_WORKER_ID,
                ConductorTopology::Chain,
                PrivacyLane::CloudBacked,
                ApprovalClass::StandingGrant("grant".to_string()),
            );

            let backends = runtime.backends();
            let (_wire, outcome) = runtime.runtime.run(&decision, &backends, &cmd).await;
            assert!(outcome.fallback, "{} case should fallback", case.name);
            assert!(
                outcome
                    .fallback_reason
                    .as_deref()
                    .is_some_and(|reason| reason.contains("privacy membrane blocked")),
                "{} case should be privacy-blocked",
                case.name
            );
            assert_eq!(
                builder_calls.load(Ordering::SeqCst),
                case.expected_builder_calls,
                "{} builder calls",
                case.name
            );
            assert_eq!(
                provider_calls.load(Ordering::SeqCst),
                case.expected_provider_calls,
                "{} provider calls",
                case.name
            );
        }
        Ok(())
    }

    #[tokio::test]
    async fn local_route_under_all_available_skips_membrane_and_budget(
    ) -> Result<(), Box<dyn Error>> {
        let (membrane, membrane_calls) = CountingMembrane::new(true);
        let (builder, builder_calls) = CountingBuilder::new();
        let (provider, provider_calls) = CountingProvider::new(Vec::new());
        let tmp = tempfile::tempdir()?;
        let store = ConductorStore::open(tmp.path().join("store"))?;
        std::fs::write(
            tmp.path()
                .join("store")
                .join("conductor_budget_usage.jsonl"),
            "not-json\n",
        )?;
        let install_key = InstallKey::load_or_create(&tmp.path().join("install.key"))?;
        let egress = ConductorEgress::with_components(
            ModelMode::AllAvailable,
            BudgetGovernor::new(store.clone(), budget_limits()),
            ProviderPricingTable::empty(),
            membrane,
            builder,
            provider,
        );
        let runtime = ConductorRuntime::new_with_egress(
            StaticDirectPolicy,
            RecipeSet::default(),
            WorkerRegistry::m1(),
            store,
            install_key,
            false,
            egress,
        );
        let engine = MockAdapter::new("local");
        let tts = MockTtsAdapter::new("tts");
        let audio = AudioManager::new();
        let events = EventBus::new();
        let playbacks = PlaybackRegistry::new();
        let agents = crate::agents::AgentSessionRegistry::new();
        let backends = SessionBackends {
            engine: &engine,
            asr_fallback: None,
            tts: &tts,
            audio: &audio,
            events: &events,
            playbacks: &playbacks,
            agents: &agents,
            conductor: Some(&runtime),
            acp_runner: &crate::session::REAL_ACP_RUNNER,
        };
        let cmd = command("req-local", "hello");
        let local_decision = decision(
            "req-local",
            STATIC_DIRECT_RECIPE_ID,
            LOCAL_MODEL_WORKER_ID,
            ConductorTopology::Direct,
            PrivacyLane::LocalOnly,
            ApprovalClass::None,
        );

        let (wire, outcome) = runtime.run(&local_decision, &backends, &cmd).await;
        assert!(wire.is_ok());
        assert!(!outcome.fallback);
        assert_eq!(membrane_calls.load(Ordering::SeqCst), 0);
        assert_eq!(builder_calls.load(Ordering::SeqCst), 0);
        assert_eq!(provider_calls.load(Ordering::SeqCst), 0);
        Ok(())
    }

    #[tokio::test]
    async fn default_pure_local_mode_blocks_cloud_before_membrane_or_builder(
    ) -> Result<(), Box<dyn Error>> {
        let (membrane, membrane_calls) = CountingMembrane::new(false);
        let (builder, builder_calls) = CountingBuilder::new();
        let (provider, provider_calls) = CountingProvider::new(Vec::new());
        let runtime = test_runtime(TestRuntimeOptions {
            mode: ModelMode::from_env_value(None),
            topology: ConductorTopology::Direct,
            provisioned: true,
            pricing: cloud_pricing(CODEX_CLOUD_WORKER_ID),
            membrane,
            builder,
            provider,
            chain_enabled: false,
        })?;
        let cmd = command("req-default", "clean prompt");
        let decision = decision(
            "req-default",
            "recipe-cloud",
            CODEX_CLOUD_WORKER_ID,
            ConductorTopology::Direct,
            PrivacyLane::CloudBacked,
            ApprovalClass::StandingGrant("grant".to_string()),
        );

        let backends = runtime.backends();
        let (_wire, outcome) = runtime.runtime.run(&decision, &backends, &cmd).await;
        assert!(outcome.fallback);
        assert!(outcome
            .fallback_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("does not permit lane")));
        assert_eq!(membrane_calls.load(Ordering::SeqCst), 0);
        assert_eq!(builder_calls.load(Ordering::SeqCst), 0);
        assert_eq!(provider_calls.load(Ordering::SeqCst), 0);
        Ok(())
    }

    #[tokio::test]
    async fn uncostable_worker_fails_closed_with_no_egress_or_spend() -> Result<(), Box<dyn Error>>
    {
        let (builder, builder_calls) = CountingBuilder::new();
        let (provider, provider_calls) = CountingProvider::new(Vec::new());
        let runtime = test_runtime(TestRuntimeOptions {
            mode: ModelMode::AllAvailable,
            topology: ConductorTopology::Direct,
            provisioned: true,
            pricing: ProviderPricingTable::empty(),
            membrane: Arc::new(ConductorEgressMembrane),
            builder,
            provider,
            chain_enabled: false,
        })?;
        let cmd = command("req-uncostable", "clean prompt");
        let decision = decision(
            "req-uncostable",
            "recipe-cloud",
            CODEX_CLOUD_WORKER_ID,
            ConductorTopology::Direct,
            PrivacyLane::CloudBacked,
            ApprovalClass::StandingGrant("grant".to_string()),
        );

        let backends = runtime.backends();
        let (_wire, outcome) = runtime.runtime.run(&decision, &backends, &cmd).await;
        assert!(outcome.fallback);
        assert!(outcome
            .fallback_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("budget exceeded")));
        assert_eq!(builder_calls.load(Ordering::SeqCst), 0);
        assert_eq!(provider_calls.load(Ordering::SeqCst), 0);
        assert!(budget_usage_content(&runtime).is_empty());
        Ok(())
    }

    #[tokio::test]
    async fn approval_gate_permits_provisioned_standing_grant_and_rejects_mismatches(
    ) -> Result<(), Box<dyn Error>> {
        let (builder, builder_calls) = CountingBuilder::new();
        let (provider, provider_calls) = CountingProvider::new(Vec::new());
        let runtime = test_runtime(TestRuntimeOptions {
            mode: ModelMode::AllAvailable,
            topology: ConductorTopology::Direct,
            provisioned: true,
            pricing: cloud_pricing(CODEX_CLOUD_WORKER_ID),
            membrane: Arc::new(ConductorEgressMembrane),
            builder: builder.clone(),
            provider: provider.clone(),
            chain_enabled: false,
        })?;
        let cmd = command("req-approval-ok", "clean prompt");
        let ok_decision = decision(
            "req-approval-ok",
            "recipe-cloud",
            CODEX_CLOUD_WORKER_ID,
            ConductorTopology::Direct,
            PrivacyLane::CloudBacked,
            ApprovalClass::StandingGrant("grant".to_string()),
        );
        let backends = runtime.backends();
        let (_wire, outcome) = runtime.runtime.run(&ok_decision, &backends, &cmd).await;
        assert!(!outcome.fallback);
        assert_eq!(builder_calls.load(Ordering::SeqCst), 1);
        assert_eq!(provider_calls.load(Ordering::SeqCst), 1);

        for (approval, provisioned) in [
            (ApprovalClass::StandingGrant("grant".to_string()), false),
            (ApprovalClass::PerTurn, false),
            (ApprovalClass::None, true),
        ] {
            let (builder, builder_calls) = CountingBuilder::new();
            let (provider, provider_calls) = CountingProvider::new(Vec::new());
            let runtime = test_runtime(TestRuntimeOptions {
                mode: ModelMode::AllAvailable,
                topology: ConductorTopology::Direct,
                provisioned,
                pricing: cloud_pricing(CODEX_CLOUD_WORKER_ID),
                membrane: Arc::new(ConductorEgressMembrane),
                builder,
                provider,
                chain_enabled: false,
            })?;
            let cmd = command("req-approval-bad", "clean prompt");
            let bad_decision = decision(
                "req-approval-bad",
                "recipe-cloud",
                CODEX_CLOUD_WORKER_ID,
                ConductorTopology::Direct,
                PrivacyLane::CloudBacked,
                approval,
            );
            let backends = runtime.backends();
            let (_wire, outcome) = runtime.runtime.run(&bad_decision, &backends, &cmd).await;
            assert!(outcome.fallback);
            assert!(outcome
                .fallback_reason
                .as_deref()
                .is_some_and(|reason| reason.contains("unexpected approval")));
            assert_eq!(builder_calls.load(Ordering::SeqCst), 0);
            assert_eq!(provider_calls.load(Ordering::SeqCst), 0);
            assert!(budget_usage_content(&runtime).is_empty());
        }
        Ok(())
    }

    #[tokio::test]
    async fn mode_budget_and_approval_blocks_write_no_phantom_spend() -> Result<(), Box<dyn Error>>
    {
        for (mode, pricing, approval) in [
            (
                ModelMode::from_env_value(None),
                cloud_pricing(CODEX_CLOUD_WORKER_ID),
                ApprovalClass::StandingGrant("grant".to_string()),
            ),
            (
                ModelMode::AllAvailable,
                ProviderPricingTable::empty(),
                ApprovalClass::StandingGrant("grant".to_string()),
            ),
            (
                ModelMode::AllAvailable,
                cloud_pricing(CODEX_CLOUD_WORKER_ID),
                ApprovalClass::None,
            ),
        ] {
            let (builder, _builder_calls) = CountingBuilder::new();
            let (provider, _provider_calls) = CountingProvider::new(Vec::new());
            let runtime = test_runtime(TestRuntimeOptions {
                mode,
                topology: ConductorTopology::Direct,
                provisioned: true,
                pricing,
                membrane: Arc::new(ConductorEgressMembrane),
                builder,
                provider,
                chain_enabled: false,
            })?;
            let cmd = command("req-no-spend", "clean prompt");
            let decision = decision(
                "req-no-spend",
                "recipe-cloud",
                CODEX_CLOUD_WORKER_ID,
                ConductorTopology::Direct,
                PrivacyLane::CloudBacked,
                approval,
            );
            let backends = runtime.backends();
            let (_wire, outcome) = runtime.runtime.run(&decision, &backends, &cmd).await;
            assert!(outcome.fallback);
            assert!(budget_usage_content(&runtime).is_empty());
        }
        Ok(())
    }

    // === M2-live Stage A wiring tests (spec §6: V1, V2, V3, V4b, V8) ===
    //
    // These exercise the live `route_turn` path with shadow capture ON
    // (`test_runtime` calls `.with_shadow()`). They pin the load-bearing
    // wiring claims: no new egress seam (V1), shared-policy identity (V2),
    // fingerprint join-correctness (V3), and the honest degenerate-routing
    // signal (V4b — corpus_match is None for a content-blind local turn).

    /// A content-blind turn context mirroring `session::build_turn_context`
    /// (task_class Unknown, empty feature_predicates) — exactly what a real
    /// `conversation.inject_text` turn produces today (F-4 content-blindness).
    fn turn_ctx(request_id: &str) -> crate::conductor::recipe::ConductorTurnContext {
        use crate::conductor::recipe::{ConductorTaskClass, ConductorTurnContext, PrivacyLane};
        ConductorTurnContext {
            request_id: request_id.to_string(),
            task_class: ConductorTaskClass::Unknown,
            feature_predicates: Vec::new(),
            privacy_lane: PrivacyLane::LocalOnly,
            available_workers: Vec::new(),
            working_directory: None,
            deadline_ms: None,
        }
    }

    /// Read + parse the shadow log written under the test store dir.
    fn shadow_records(runtime: &TestRuntime) -> Vec<crate::conductor::telemetry::ShadowTurnRecord> {
        let content = shadow_raw(runtime);
        content
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| serde_json::from_str(line).expect("shadow record parses in test"))
            .collect()
    }

    /// Raw (unparsed) contents of the shadow log — for F-4 leak assertions the
    /// parsed struct cannot catch (a leaked raw request_id survives parsing).
    fn shadow_raw(runtime: &TestRuntime) -> String {
        let path = runtime
            ._tmp
            .path()
            .join("store")
            .join("conductor_shadow.jsonl");
        std::fs::read_to_string(path).unwrap_or_default()
    }

    /// V1 + V8: a routed local turn with shadow ON produces a shadow record and
    /// **zero** cloud-provider calls (no new egress seam). The shadow append is
    /// fire-and-forget off the hot path: `route_turn` returns without awaiting
    /// it (V8 — same `spawn_blocking` pattern as existing telemetry), so we yield
    /// briefly then read.
    #[tokio::test]
    async fn route_turn_with_shadow_writes_record_without_egress() -> Result<(), Box<dyn Error>> {
        let (builder, builder_calls) = CountingBuilder::new();
        let (provider, provider_calls) = CountingProvider::new(Vec::new());
        let runtime = test_runtime(TestRuntimeOptions {
            mode: ModelMode::PureLocal,
            topology: ConductorTopology::Direct,
            provisioned: false,
            pricing: ProviderPricingTable::empty(),
            membrane: Arc::new(ConductorEgressMembrane),
            builder,
            provider,
            chain_enabled: false,
        })?;
        assert!(
            runtime.runtime.shadow_enabled(),
            "test_runtime must enable shadow for the wiring tests"
        );

        let cmd = command("req-shadow", "a benign local prompt");
        let ctx = turn_ctx("req-shadow");
        let backends = runtime.backends();
        let wire = route_turn(&runtime.runtime, &backends, &cmd, &ctx).await;
        assert!(wire.is_ok(), "turn must succeed: {:?}", wire.err());
        // No egress seam: a pure-local turn never builds or calls a provider.
        assert_eq!(builder_calls.load(Ordering::SeqCst), 0);
        assert_eq!(provider_calls.load(Ordering::SeqCst), 0);

        // V8: route_turn returned without awaiting the shadow append; yield so
        // the fire-and-forget `spawn_blocking` lands the record.
        tokio::time::sleep(Duration::from_millis(50)).await;
        let records = shadow_records(&runtime);
        assert_eq!(
            records.len(),
            1,
            "exactly one shadow record per turn (zero candidates)"
        );
        assert!(records[0].candidates.is_empty(), "M2 ships zero candidates");

        // F-4 file-level regression (oracle ea2dc52c BLOCKER-1): the raw shadow
        // log must NOT carry the opaque request_id (correlation is via the
        // fingerprint only) nor any prompt text. The parsed-struct read above
        // cannot catch a leaked raw id that survives deserialization.
        let raw = shadow_raw(&runtime);
        assert!(!raw.is_empty(), "shadow file written");
        assert!(
            !raw.contains("req-shadow"),
            "raw request_id leaked into conductor_shadow.jsonl: {raw}"
        );
        assert!(
            !raw.contains("benign"),
            "prompt text leaked into conductor_shadow.jsonl: {raw}"
        );
        Ok(())
    }

    /// M4-B §5.3: with the classifier now reading the prompt (the F-4/n crossing),
    /// the prompt text MUST NOT appear in ANY conductor telemetry file. The
    /// content-blind test above checks `shadow` for "benign"; this one uses the
    /// REAL classified wiring (`session::build_turn_context`) and greps all three
    /// telemetry files for a unique sentinel embedded in a credential prompt.
    #[tokio::test]
    async fn classified_turn_leaks_no_prompt_text_to_conductor_telemetry(
    ) -> Result<(), Box<dyn Error>> {
        let (builder, _builder_calls) = CountingBuilder::new();
        let (provider, _provider_calls) = CountingProvider::new(Vec::new());
        let runtime = test_runtime(TestRuntimeOptions {
            mode: ModelMode::PureLocal,
            topology: ConductorTopology::Direct,
            provisioned: false,
            pricing: ProviderPricingTable::empty(),
            membrane: Arc::new(ConductorEgressMembrane),
            builder,
            provider,
            chain_enabled: false,
        })?;
        const SENTINEL: &str = "ZZQ_SENTINEL_PROMPT_NO_LEAK_98765";
        // Credential-shaped so the classifier actually fires (PersonalData) —
        // proving the prompt WAS read, yet still never serialized.
        let prompt = format!("my password is hunter2 {SENTINEL} please store it");
        let cmd = command("req-noleak", &prompt);
        // Classify locally (the session wrapper delegates to this same classifier);
        // the no-leak property is about route_turn's emitters, not the wrapper.
        use crate::conductor::classifier::TurnClassifier as _;
        let cls = crate::conductor::classifier::RuleBasedTurnClassifier.classify(&prompt);
        let mut ctx = turn_ctx("req-noleak");
        ctx.task_class = cls.task_class;
        ctx.feature_predicates = cls.feature_predicates;
        assert_eq!(ctx.task_class, ConductorTaskClass::PersonalData);
        assert!(ctx
            .feature_predicates
            .iter()
            .any(|p| p == "credential_shaped"));
        let backends = runtime.backends();
        let wire = route_turn(&runtime.runtime, &backends, &cmd, &ctx).await;
        assert!(wire.is_ok(), "turn must succeed: {:?}", wire.err());
        tokio::time::sleep(Duration::from_millis(50)).await;
        // Sanity: exactly one shadow record landed (the turn ran through telemetry).
        assert_eq!(shadow_records(&runtime).len(), 1);
        let store_dir = runtime._tmp.path().join("store");
        // Each telemetry file MUST be non-empty (else the sentinel assertion is
        // vacuous) AND must not contain the sentinel prompt text.
        for file in [
            "conductor_shadow.jsonl",
            "conductor_route_events.jsonl",
            "conductor_receipts.jsonl",
        ] {
            let content = std::fs::read_to_string(store_dir.join(file))
                .unwrap_or_else(|_| panic!("telemetry file {file} missing"));
            assert!(
                !content.is_empty(),
                "telemetry file {file} empty — test vacuous"
            );
            assert!(
                !content.contains(SENTINEL),
                "PROMPT LEAK: sentinel present in {file}: {content}"
            );
        }
        Ok(())
    }

    /// M4-F (observability): an OwnerFleet mesh turn is fully observable yet
    /// prompt-free. The sentinel prompt text NEVER appears in any conductor
    /// telemetry file (shadow/route_events/receipts/budget); a budget receipt
    /// IS recorded (governance, not cost); and the isolated conductor store
    /// contains NO fae.db (the memory store is never touched — ADR-012
    /// principle 3: the durable store never egresses).
    #[tokio::test]
    async fn ownerfleet_mesh_turn_is_prompt_free_and_observable() -> Result<(), Box<dyn Error>> {
        use crate::conductor::mesh::test_support::MockMeshDelegationPort;
        const SENTINEL: &str = "ZZQ_MESH_SENTINEL_NO_LEAK_424242";
        let mesh = Arc::new(MockMeshDelegationPort::completed("peer answered"));
        // Build the OwnerFleet runtime directly so we own the tmp dir (the
        // ownerfleet_runtime helper returns the runtime + tmp).
        let (runtime, tmp, worker, recipe) =
            ownerfleet_runtime(mesh, Arc::new(ConductorEgressMembrane))?;
        // Non-secret prompt (so it clears the membrane) carrying a unique
        // sentinel — the mesh path will run, but the prompt must never persist.
        let prompt = format!("summarize the rust async book {SENTINEL} chapter on pinning");
        let cmd = command("req-mesh-obs", &prompt);
        let decision = decision(
            "req-mesh-obs",
            recipe,
            worker,
            ConductorTopology::Direct,
            PrivacyLane::OwnerFleet,
            ApprovalClass::StandingGrant("fleet-grant".to_string()),
        );
        let engine = MockAdapter::new("local");
        let tts = MockTtsAdapter::new("tts");
        let audio = AudioManager::new();
        let events = EventBus::new();
        let playbacks = PlaybackRegistry::new();
        let agents = crate::agents::AgentSessionRegistry::new();
        let backends = SessionBackends {
            engine: &engine,
            asr_fallback: None,
            tts: &tts,
            audio: &audio,
            events: &events,
            playbacks: &playbacks,
            agents: &agents,
            conductor: Some(&runtime),
            acp_runner: &crate::session::REAL_ACP_RUNNER,
        };
        // The mesh path is only reachable via run() with a hand-built OwnerFleet
        // decision: StaticDirectPolicy::decide always returns LocalOnly (M1-
        // inert), so route_turn() — which calls decide() — never produces an
        // OwnerFleet decision. To exercise the FULL telemetry surface (not just
        // receipts), we manually emit event + receipt + shadow, mirroring exactly
        // what route_turn does for a normal turn (executor.rs:1499-1507). This
        // makes "observable" honest: all three conductor telemetry files are
        // written and checked for the sentinel.
        let fingerprint = runtime
            .fingerprint(&decision.request_id)
            .map_err(|e| format!("fingerprint: {e}"))?;
        let ts = now_ms();
        runtime.emit_event(&decision, &fingerprint, ts);
        let (wire, outcome) = runtime.run(&decision, &backends, &cmd).await;
        assert!(wire.is_ok(), "mesh turn must succeed: {:?}", wire.err());
        assert!(!outcome.fallback);
        runtime.emit_receipt(&decision, &outcome, &fingerprint, 1, ts + 1);
        // A context for shadow capture (label-only by design — F-4).
        let mut ctx = turn_ctx("req-mesh-obs");
        ctx.task_class = ConductorTaskClass::Coding;
        runtime.capture_shadow(&ctx, fingerprint, ts + 2);
        tokio::time::sleep(Duration::from_millis(50)).await;
        let store_dir = tmp.path().join("store");
        // The three conductor telemetry files the mesh turn wrote MUST all exist
        // (event + receipt + shadow were all emitted), be non-empty, and be free
        // of the sentinel prompt text. budget_usage is intentionally NOT in this
        // set: run_mesh_direct enforces the budget GATE (§5.4) but records no
        // cost (economics deferred per owner directive 2026-06-26; a dormant
        // mesh path with no real transport has no usage to persist).
        for file in [
            "conductor_shadow.jsonl",
            "conductor_route_events.jsonl",
            "conductor_receipts.jsonl",
        ] {
            let path = store_dir.join(file);
            assert!(
                path.exists(),
                "telemetry file {file} must exist (we emitted it)"
            );
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|_| panic!("telemetry file {file} unreadable"));
            assert!(
                !content.is_empty(),
                "telemetry file {file} empty — test vacuous"
            );
            assert!(
                !content.contains(SENTINEL),
                "PROMPT LEAK: sentinel present in {file}: {content}"
            );
        }
        // No memory-store egress: the isolated conductor store contains NO
        // fae.db (the memory store lives elsewhere and is never written here).
        assert!(
            !store_dir.join("fae.db").exists(),
            "fae.db must not exist in the conductor store (memory isolation)"
        );
        Ok(())
    }

    /// V1 mutation: a runtime WITHOUT shadow produces no shadow record, proving
    /// the record in the test above came from `capture_shadow` (not some other
    /// path). Uses the legacy `new` constructor (shadow disabled by default).
    #[tokio::test]
    async fn shadow_disabled_writes_no_shadow_record() -> Result<(), Box<dyn Error>> {
        let tmp = tempfile::tempdir()?;
        let store = ConductorStore::open(tmp.path().join("store"))?;
        let install_key = InstallKey::load_or_create(&tmp.path().join("install.key"))?;
        let runtime = ConductorRuntime::new(
            StaticDirectPolicy,
            RecipeSet::default(),
            WorkerRegistry::m1(),
            store,
            install_key,
            false,
        );
        assert!(!runtime.shadow_enabled());

        let cmd = command("req-no-shadow", "a benign local prompt");
        let ctx = turn_ctx("req-no-shadow");
        let engine = MockAdapter::new("local");
        let tts = MockTtsAdapter::new("tts");
        let backends = SessionBackends {
            engine: &engine,
            asr_fallback: None,
            tts: &tts,
            audio: &AudioManager::new(),
            events: &EventBus::new(),
            playbacks: &PlaybackRegistry::new(),
            agents: &crate::agents::AgentSessionRegistry::new(),
            conductor: None,
            acp_runner: &crate::session::REAL_ACP_RUNNER,
        };
        let wire = route_turn(&runtime, &backends, &cmd, &ctx).await;
        assert!(wire.is_ok());
        tokio::time::sleep(Duration::from_millis(50)).await;
        let shadow_path = tmp.path().join("store").join("conductor_shadow.jsonl");
        assert!(
            !shadow_path.exists(),
            "no shadow record when shadow is disabled"
        );
        Ok(())
    }

    /// V2: the shadow record's deployed decision is byte-equal to the decision
    /// the live policy makes for the same context — because `ShadowRouter`
    /// shares the runtime's policy `Arc` (anti-divergence, spec §2.2a).
    #[tokio::test]
    async fn shadow_deployed_decision_equals_executed_decision() -> Result<(), Box<dyn Error>> {
        let runtime = test_runtime(TestRuntimeOptions {
            mode: ModelMode::PureLocal,
            topology: ConductorTopology::Direct,
            provisioned: false,
            pricing: ProviderPricingTable::empty(),
            membrane: Arc::new(ConductorEgressMembrane),
            builder: CountingBuilder::new().0,
            provider: CountingProvider::new(Vec::new()).0,
            chain_enabled: false,
        })?;
        let ctx = turn_ctx("req-identity");
        let cmd = command("req-identity", "benign");
        let backends = runtime.backends();
        let _ = route_turn(&runtime.runtime, &backends, &cmd, &ctx).await;
        tokio::time::sleep(Duration::from_millis(50)).await;

        let executed = runtime.runtime.policy().decide(&ctx);
        let records = shadow_records(&runtime);
        assert_eq!(records.len(), 1);
        assert_eq!(
            records[0].deployed_decision,
            crate::conductor::telemetry::TelemetryRouteDecision::from(&executed),
            "shadow deployed decision must equal the executed decision (shared Arc)"
        );
        Ok(())
    }

    /// V3: the event, receipt, and shadow record for one turn share an identical
    /// F-4 `request_fingerprint` (computed once in `route_turn`, threaded to
    /// every emitter — §2.1 lift).
    #[tokio::test]
    async fn telemetry_records_share_one_fingerprint() -> Result<(), Box<dyn Error>> {
        let runtime = test_runtime(TestRuntimeOptions {
            mode: ModelMode::PureLocal,
            topology: ConductorTopology::Direct,
            provisioned: false,
            pricing: ProviderPricingTable::empty(),
            membrane: Arc::new(ConductorEgressMembrane),
            builder: CountingBuilder::new().0,
            provider: CountingProvider::new(Vec::new()).0,
            chain_enabled: false,
        })?;
        let ctx = turn_ctx("req-join");
        let cmd = command("req-join", "benign");
        let backends = runtime.backends();
        let _ = route_turn(&runtime.runtime, &backends, &cmd, &ctx).await;
        tokio::time::sleep(Duration::from_millis(50)).await;

        let store_dir = runtime._tmp.path().join("store");
        let read_first_fp = |file: &str| -> Option<String> {
            let content = std::fs::read_to_string(store_dir.join(file)).unwrap_or_default();
            content
                .lines()
                .next()
                .and_then(|line| serde_json::from_str::<serde_json::Value>(line).ok())
                .and_then(|v| v.get("request_fingerprint")?.as_str().map(str::to_string))
        };
        let event_fp = read_first_fp("conductor_route_events.jsonl");
        let receipt_fp = read_first_fp("conductor_receipts.jsonl");
        let shadow_fp = shadow_records(&runtime)
            .first()
            .map(|r| r.request_fingerprint.0.clone());
        assert!(event_fp.is_some(), "event written");
        assert_eq!(
            event_fp, receipt_fp,
            "event + receipt share the fingerprint"
        );
        assert_eq!(
            event_fp, shadow_fp,
            "shadow record shares the fingerprint (one HMAC, threaded)"
        );
        Ok(())
    }

    /// V4b: routing signal honesty. A real local `conversation.inject_text` turn
    /// is content-blind (task_class Unknown, empty feature_predicates), so
    /// `match_corpus_entry` matches ZERO corpus entries (every entry carries
    /// non-empty predicates that empty ctx predicates cannot satisfy). The
    /// shadow record therefore carries `corpus_match = None`. This is the
    /// degenerate-routing-accuracy state stated plainly in spec §2.5 — not a
    /// defect; the plumbing is in place for when a classifier lands.
    #[tokio::test]
    async fn local_turn_corpus_match_is_none_no_routing_ground_truth() {
        let runtime = test_runtime(TestRuntimeOptions {
            mode: ModelMode::PureLocal,
            topology: ConductorTopology::Direct,
            provisioned: false,
            pricing: ProviderPricingTable::empty(),
            membrane: Arc::new(ConductorEgressMembrane),
            builder: CountingBuilder::new().0,
            provider: CountingProvider::new(Vec::new()).0,
            chain_enabled: false,
        })
        .expect("test runtime");
        let ctx = turn_ctx("req-v4b");
        let cmd = command("req-v4b", "benign");
        let backends = runtime.backends();
        let _ = route_turn(&runtime.runtime, &backends, &cmd, &ctx).await;
        tokio::time::sleep(Duration::from_millis(50)).await;
        let records = shadow_records(&runtime);
        assert_eq!(records.len(), 1);
        assert!(
            records[0].corpus_match.is_none(),
            "content-blind local turn ⇒ no corpus match (§2.5): {:?}",
            records[0].corpus_match
        );
    }

    // ── M2-live Stage C (§4): conductor.reward_snapshot ──

    // V4a — F-10 holds on the snapshot surface: an empty window (no turns, no
    // feedback, no self-judgment) ⇒ every component is 0.0, score 0.0. The
    // snapshot surface never injects self-judgment, so score tracks only the
    // real (empty) inputs. routing_source is honest neutral (no ground truth).
    #[tokio::test]
    async fn snapshot_empty_window_is_neutral_zero() {
        let runtime = test_runtime(TestRuntimeOptions {
            mode: ModelMode::PureLocal,
            topology: ConductorTopology::Direct,
            provisioned: false,
            pricing: ProviderPricingTable::empty(),
            membrane: Arc::new(ConductorEgressMembrane),
            builder: CountingBuilder::new().0,
            provider: CountingProvider::new(Vec::new()).0,
            chain_enabled: false,
        })
        .expect("test runtime");
        let snap = runtime.runtime.reward_snapshot(100).expect("snapshot");
        assert!(
            snap.score.abs() < 1e-9,
            "empty window ⇒ score 0 (got {})",
            snap.score
        );
        assert_eq!(snap.window.turns, 0);
        assert_eq!(snap.window.feedback_count, 0);
        assert_eq!(snap.window.shadow_records, 0);
        assert_eq!(snap.window.corpus_matches, 0);
        assert_eq!(
            snap.routing_source,
            crate::conductor::RewardRoutingSource::NeutralNoGroundTruth
        );
        // F-10: self-judgment never inflates the snapshot (None injected).
        assert!(snap.components.self_judgment.abs() < 1e-9);
        assert!(
            snap.components.routing.abs() < 1e-9,
            "neutral routing ⇒ 0.0"
        );
        assert!(!snap.self_judgment_was_capped);
    }

    // V4b-snapshot: a real content-blind local turn ⇒ the shadow record's
    // corpus_match is None (V4b) ⇒ the snapshot reports routing_source ==
    // NeutralNoGroundTruth and routing component 0.0. Connects the shadow
    // honesty to the snapshot surface.
    #[tokio::test]
    async fn snapshot_after_local_turn_reports_neutral_routing() {
        let runtime = test_runtime(TestRuntimeOptions {
            mode: ModelMode::PureLocal,
            topology: ConductorTopology::Direct,
            provisioned: false,
            pricing: ProviderPricingTable::empty(),
            membrane: Arc::new(ConductorEgressMembrane),
            builder: CountingBuilder::new().0,
            provider: CountingProvider::new(Vec::new()).0,
            chain_enabled: false,
        })
        .expect("test runtime");
        let ctx = turn_ctx("req-snap");
        let cmd = command("req-snap", "benign");
        let backends = runtime.backends();
        let _ = route_turn(&runtime.runtime, &backends, &cmd, &ctx).await;
        tokio::time::sleep(Duration::from_millis(50)).await;

        let snap = runtime.runtime.reward_snapshot(100).expect("snapshot");
        assert_eq!(snap.window.turns, 1, "one receipt in window");
        assert_eq!(snap.window.shadow_records, 1, "one shadow record joined");
        assert_eq!(snap.window.corpus_matches, 0, "content-blind ⇒ no match");
        assert_eq!(
            snap.routing_source,
            crate::conductor::RewardRoutingSource::NeutralNoGroundTruth
        );
        assert!(snap.components.routing.abs() < 1e-9, "neutral ⇒ 0.0");
        // F-4: no raw request id leaked into the serialized snapshot.
        let json = serde_json::to_string(&snap).expect("serialize in test");
        assert!(
            !json.contains("req-snap"),
            "no raw request_id in snapshot json"
        );
    }

    // V11 — read-only: the snapshot constructs no provider request, writes
    // nothing to the store. Pinned by capturing the provider counter and the
    // store file sizes before/after the snapshot.
    #[tokio::test]
    async fn snapshot_is_read_only_no_provider_no_write() {
        use std::fs;
        let (provider, provider_calls) = CountingProvider::new(Vec::new());
        let runtime = test_runtime(TestRuntimeOptions {
            mode: ModelMode::PureLocal,
            topology: ConductorTopology::Direct,
            provisioned: false,
            pricing: ProviderPricingTable::empty(),
            membrane: Arc::new(ConductorEgressMembrane),
            builder: CountingBuilder::new().0,
            provider,
            chain_enabled: false,
        })
        .expect("test runtime");
        // Drive one turn so the store has rows to read.
        let ctx = turn_ctx("req-ro");
        let cmd = command("req-ro", "benign");
        let backends = runtime.backends();
        let _ = route_turn(&runtime.runtime, &backends, &cmd, &ctx).await;
        tokio::time::sleep(Duration::from_millis(50)).await;
        let provider_before = provider_calls.load(Ordering::SeqCst);
        assert_eq!(provider_before, 0, "pure-local turn made no provider call");

        // Capture store file sizes before the snapshot.
        let store_dir = runtime._tmp.path().join("store");
        let size = |file: &str| {
            fs::metadata(store_dir.join(file))
                .map(|m| m.len())
                .unwrap_or(0)
        };
        let receipts_before = size("conductor_receipts.jsonl");
        let shadow_before = size("conductor_shadow.jsonl");
        let feedback_before = size("conductor_feedback.jsonl");

        let _snap = runtime.runtime.reward_snapshot(100).expect("snapshot");

        // V11: no provider call, no store write (sizes unchanged).
        assert_eq!(
            provider_calls.load(Ordering::SeqCst),
            0,
            "snapshot made no provider call"
        );
        assert_eq!(
            size("conductor_receipts.jsonl"),
            receipts_before,
            "snapshot wrote no receipt"
        );
        assert_eq!(
            size("conductor_shadow.jsonl"),
            shadow_before,
            "snapshot wrote no shadow record"
        );
        assert_eq!(
            size("conductor_feedback.jsonl"),
            feedback_before,
            "snapshot wrote no feedback"
        );
    }
}
