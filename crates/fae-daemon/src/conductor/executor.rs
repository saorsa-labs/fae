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
use crate::conductor::fingerprint::InstallKey;
use crate::conductor::policy::{
    mode_permits_lane, ConductorRoutingPolicy, ModelMode, StaticDirectPolicy,
};
use crate::conductor::pricing::ProviderPricingTable;
use crate::conductor::recipe::{
    ApprovalClass, ConductorRole, ConductorTopology, OwnedRouteDecision, PrivacyLane, RecipeSet,
    RouteFailure, WorkerLocality,
};
use crate::conductor::store::ConductorStore;
use crate::conductor::telemetry::{ConductorRouteEvent, RouteReceipt, TargetKind};
use crate::conductor::workers::WorkerRegistry;
use crate::session::{inject_text_core, run_turn, SessionBackends};
use fae_control_plane::Command;
use fae_engine::{ChatMessage, ChatRequest, ProviderAdapter, Role};

const DEFAULT_MAX_OUTPUT_TOKENS: u64 = 1024;

/// Structured result from the egress membrane. Labels only; never matched text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MembraneVerdict {
    pub block_remote_egress: bool,
    pub level: String,
    pub labels: Vec<String>,
}

/// Spy-able membrane seam. Production uses [`RealPiiMembrane`], which calls the
/// canonical `fae-pii-membrane` functions. Tests can count calls to prove
/// LocalOnly no-ops without replacing the real membrane in the invariant test.
pub trait PiiMembrane: Send + Sync {
    fn scan_for_remote_egress(&self, text: &str) -> MembraneVerdict;
}

#[derive(Debug, Default)]
pub struct RealPiiMembrane;

impl PiiMembrane for RealPiiMembrane {
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
}

impl ConductorEgress {
    pub fn production(
        mode: ModelMode,
        budget: BudgetGovernor,
        pricing: ProviderPricingTable,
    ) -> Self {
        Self::with_components(
            mode,
            budget,
            pricing,
            Arc::new(RealPiiMembrane),
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
        Self {
            mode,
            budget,
            pricing,
            membrane,
            cloud_request_builder,
            cloud_provider,
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
    policy: StaticDirectPolicy,
    recipes: RecipeSet,
    workers: WorkerRegistry,
    store: ConductorStore,
    install_key: InstallKey,
    chain_enabled: bool,
    egress: ConductorEgress,
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
            policy,
            recipes,
            workers,
            store,
            install_key,
            chain_enabled,
            egress,
        }
    }

    /// The static policy reference, for `inject_text` to call `decide`.
    pub fn policy(&self) -> &dyn ConductorRoutingPolicy {
        &self.policy
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
            ConductorTopology::Direct => self.run_cloud_direct(decision, backends, cmd).await,
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
                } else {
                    self.run_cloud_chain(decision, backends, cmd).await
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
    pub fn emit_event(&self, decision: &OwnedRouteDecision, timestamp_ms: u64) {
        let fp = match self.install_key.fingerprint(&decision.request_id) {
            Ok(fp) => fp,
            Err(e) => {
                tracing::warn!("conductor fingerprint failed, skipping event: {e}");
                return;
            }
        };
        let event = ConductorRouteEvent {
            request_fingerprint: fp,
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
        latency_ms: u64,
        timestamp_ms: u64,
    ) {
        let fp = match self.install_key.fingerprint(&decision.request_id) {
            Ok(fp) => fp,
            Err(e) => {
                tracing::warn!("conductor fingerprint failed, skipping receipt: {e}");
                return;
            }
        };
        let receipt = RouteReceipt {
            request_fingerprint: fp,
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

    fn spawn_telemetry<F>(&self, work: F)
    where
        F: FnOnce(&ConductorStore) + Send + 'static,
    {
        let store = self.store.clone();
        drop(tokio::task::spawn_blocking(move || work(&store)));
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
pub async fn route_turn(
    runtime: &ConductorRuntime,
    backends: &SessionBackends<'_>,
    cmd: &Command,
    ctx: &crate::conductor::recipe::ConductorTurnContext,
) -> Result<Value, &'static str> {
    let decision = runtime.policy().decide(ctx);
    let now = || now_ms();
    runtime.emit_event(&decision, now());
    let started = Instant::now();
    let (wire, outcome) = runtime.run(&decision, backends, cmd).await;
    let latency_ms = started.elapsed().as_millis().min(u64::MAX as u128) as u64;
    runtime.emit_receipt(&decision, &outcome, latency_ms, now());
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
            ),
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
            membrane: Arc::new(RealPiiMembrane),
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

        runtime.runtime.emit_receipt(&decision, &outcome, 1, 1);
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
                membrane: Arc::new(RealPiiMembrane),
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
            membrane: Arc::new(RealPiiMembrane),
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
            membrane: Arc::new(RealPiiMembrane),
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
                membrane: Arc::new(RealPiiMembrane),
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
                membrane: Arc::new(RealPiiMembrane),
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
}
