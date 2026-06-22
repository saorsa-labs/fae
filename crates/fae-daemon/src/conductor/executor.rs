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

use crate::conductor::fingerprint::InstallKey;
use crate::conductor::policy::{ConductorRoutingPolicy, StaticDirectPolicy};
use crate::conductor::recipe::{
    OwnedRouteDecision, PrivacyLane, RecipeSet, RouteFailure, WorkerLocality,
};
use crate::conductor::store::ConductorStore;
use crate::conductor::telemetry::{ConductorRouteEvent, RouteReceipt, TargetKind};
use crate::conductor::workers::WorkerRegistry;
use crate::session::{inject_text_core, run_turn, SessionBackends};
use fae_control_plane::Command;
use fae_engine::{ChatMessage, ChatRequest, ProviderAdapter, Role};

/// Internal bookkeeping for a turn's execution, used to populate the receipt.
/// **Never the wire type** — the user-facing result is `Result<Value,
/// &'static str>` returned verbatim from `inject_text_core` (spec §5.1 N2).
/// `TurnResult` is never round-tripped through `Value`; that would re-serialize
/// the payload and break byte-identity.
#[derive(Debug, Clone)]
pub(crate) struct TurnOutcome {
    success: bool,
    fallback: bool,
    fallback_reason: Option<String>,
    target_kind: TargetKind,
    privacy_lane: PrivacyLane,
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
}

impl ConductorRuntime {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        policy: StaticDirectPolicy,
        recipes: RecipeSet,
        workers: WorkerRegistry,
        store: ConductorStore,
        install_key: InstallKey,
        chain_enabled: bool,
    ) -> Self {
        Self {
            policy,
            recipes,
            workers,
            store,
            install_key,
            chain_enabled,
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
        // 1. Recipe resolution (spec §5.4).
        let recipe = match self.recipes.get(&decision.recipe_id) {
            Some(r) => r,
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
        };
        // 2. Worker resolution.
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
        // 3. Approval gate (F-7 Tier A defense-in-depth).
        if !matches!(
            decision.approval,
            crate::conductor::recipe::ApprovalClass::None
        ) {
            return self
                .fail_closed_direct(
                    decision,
                    backends,
                    cmd,
                    RouteFailure::UnexpectedApproval {
                        approval: decision.approval.clone(),
                    },
                )
                .await;
        }
        // 4. Topology dispatch.
        match decision.topology {
            crate::conductor::recipe::ConductorTopology::Direct => {
                // BYTE-IDENTICAL: run inject_text's existing body verbatim.
                let wire = inject_text_core(backends, cmd).await;
                let outcome = TurnOutcome {
                    success: wire.is_ok(),
                    fallback: false,
                    fallback_reason: None,
                    target_kind: TargetKind::LocalModel,
                    privacy_lane: recipe.privacy_lane,
                };
                (wire, outcome)
            }
            crate::conductor::recipe::ConductorTopology::Chain => {
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
                // Chain execution is implemented but gated behind the flag.
                // M1 ships with chain_enabled defaulting to false; the arm is
                // exercised only when FAE_CONDUCTOR_CHAIN is set AND a vetted
                // chain recipe is loaded. See `run_chain`.
                self.run_chain(decision, backends, cmd, recipe.privacy_lane)
                    .await
            }
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
        eprintln!(
            "fae-daemon: conductor failing closed to direct-local for recipe {}: {}",
            decision.recipe_id,
            route_failure_display(&failure)
        );
        let wire = inject_text_core(backends, cmd).await;
        let outcome = TurnOutcome {
            success: wire.is_ok(),
            fallback: true,
            fallback_reason: Some(route_failure_display(&failure)),
            target_kind: TargetKind::LocalModel,
            privacy_lane: PrivacyLane::LocalOnly,
        };
        (wire, outcome)
    }

    /// Chain topology execution (Thinker → Worker → Verifier). Dormant in M1
    /// unless `FAE_CONDUCTOR_CHAIN` is set. Implemented as a sequence of
    /// `run_turn` calls with role-conditioned prompts; on Verifier FAIL the
    /// corrected answer is used if present, else the Worker's answer.
    ///
    /// Marked `#[allow(dead_code)]` because M1 ships with chain disabled by
    /// default; the dead-code gate (spec §13.7) allows this single scoped
    /// suppression, documented and removed when chain becomes default-curated.
    #[allow(dead_code)]
    async fn run_chain(
        &self,
        decision: &OwnedRouteDecision,
        backends: &SessionBackends<'_>,
        cmd: &Command,
        privacy_lane: PrivacyLane,
    ) -> (Result<Value, &'static str>, TurnOutcome) {
        use crate::conductor::prompts::{THINKER_SYSTEM, VERIFIER_SYSTEM, WORKER_SYSTEM};

        // Extract the original user prompt from the command payload.
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

        // Thinker.
        let thinker_out =
            run_one(engine, THINKER_SYSTEM.to_string(), user_prompt.to_string()).await;
        let thinker_text = match thinker_out {
            Ok(v) => v
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            Err(detail) => {
                eprintln!("fae-daemon: conductor chain Thinker failed: {detail}");
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
        // Worker.
        let worker_out = run_one(engine, WORKER_SYSTEM.to_string(), thinker_text.clone()).await;
        let worker_text = match worker_out {
            Ok(v) => v
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            Err(detail) => {
                eprintln!("fae-daemon: conductor chain Worker failed: {detail}");
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
        // Verifier.
        let verify_input = format!("{user_prompt}\n\nProposed answer:\n{worker_text}");
        let verifier_out = run_one(engine, VERIFIER_SYSTEM.to_string(), verify_input).await;
        let verifier_text = verifier_out
            .ok()
            .and_then(|v| v.get("text").and_then(Value::as_str).map(str::to_string))
            .unwrap_or_default();
        let passed = verifier_text
            .lines()
            .next()
            .map(|l| l.trim() == "PASS")
            .unwrap_or(false);
        let final_text = if passed {
            worker_text.clone()
        } else if !verifier_text.is_empty() {
            // FAIL with a corrected answer: prefer the verifier's body.
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
            },
        )
    }

    /// Emit a `ConductorRouteEvent` at decision time. Fire-and-forget on the
    /// blocking pool; the turn never waits on this write (spec §9).
    pub fn emit_event(&self, decision: &OwnedRouteDecision, timestamp_ms: u64) {
        let fp = match self.install_key.fingerprint(&decision.request_id) {
            Ok(fp) => fp,
            Err(e) => {
                // N4: unreachable for a 32-byte key + SHA-256; logged + skipped.
                eprintln!("fae-daemon: conductor fingerprint failed, skipping event: {e}");
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
            target_kind: locality_to_target(&decision.worker_id),
            privacy_lane: PrivacyLane::LocalOnly,
            latency_ms: None,
            cost_micros: None,
            success: true, // decision-time; outcome filled in the receipt
            fallback_used: false,
            eval_delta: None,
            user_signal: None,
            timestamp_ms,
        };
        self.spawn_telemetry(move |store| match store.append_event(&event) {
            Ok(()) => {}
            Err(e) => eprintln!("fae-daemon: conductor event write failed: {e}"),
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
                eprintln!("fae-daemon: conductor fingerprint failed, skipping receipt: {e}");
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
            cost_micros: None,
            success: outcome.success,
            fallback: outcome.fallback,
            fallback_reason: outcome.fallback_reason.clone(),
            payload_hash: None, // M2: SHA-256 of the outbound payload
            eval_delta: None,
            user_signal: None,
            timestamp_ms,
        };
        self.spawn_telemetry(move |store| match store.append_receipt(&receipt) {
            Ok(()) => {}
            Err(e) => eprintln!("fae-daemon: conductor receipt write failed: {e}"),
        });
    }

    /// Fire-and-forget a telemetry write on the blocking pool. The `JoinHandle`
    /// is dropped (not awaited): `spawn_blocking` runs to completion on the
    /// blocking pool, so the user's turn never waits on a filesystem write.
    /// Captures a clone of the (cheap, path-only) store — no borrows cross the
    /// `'static` boundary.
    fn spawn_telemetry<F>(&self, work: F)
    where
        F: FnOnce(&ConductorStore) + Send + 'static,
    {
        let store = self.store.clone();
        // Fire-and-forget: `drop()` of the JoinHandle does NOT cancel the
        // task — `spawn_blocking` runs to completion on the blocking pool, so
        // the user's turn never waits on a filesystem write (spec §9).
        drop(tokio::task::spawn_blocking(move || work(&store)));
    }
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
        RouteFailure::UnexpectedApproval { approval } => {
            format!("unexpected approval class {approval:?}")
        }
    }
}

/// Resolve a worker id to a telemetry `TargetKind`. M1 only routes
/// `local-model` → `LocalModel`; any other id is unreachable (it fails
/// `WorkerRegistry::contains` before this is consulted) and recorded as
/// `LocalModel` for receipt stability.
fn locality_to_target(_worker_id: &str) -> TargetKind {
    // The registry guarantees only local-model is routable in M1. Kept as a
    // function so M2 can map worker ids → richer target kinds.
    TargetKind::from(WorkerLocality::LocalModel)
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
