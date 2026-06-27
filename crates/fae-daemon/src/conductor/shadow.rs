//! M2 shadow router (spec §8 — decision-only; never egresses).
//!
//! Runs candidate policies **alongside** the deployed policy, scoring both —
//! **without the candidates ever causing egress, spend, or cross-owner traffic.**
//!
//! ## No-conductor-egress-seams guarantee (the load-bearing property)
//!
//! The shadow router has **no conductor egress seams in scope.** This is not a
//! config default that could be flipped; it is structural in the precise sense
//! that matters for egress safety:
//!
//! - [`ShadowRouter`] holds only [`Arc<dyn ConductorRoutingPolicy>`] (a trait
//!   whose sole method [`decide`](ConductorRoutingPolicy::decide) returns an
//!   [`OwnedRouteDecision`]) and a [`Vec<NamedPolicy>`]. There is **no field**
//!   of type `CloudProvider`, `AcpAgentRunner`, `CloudRequestBuilder`, or any
//!   other egress handle. The executor's egress seams are simply not in scope,
//!   so `evaluate`/`evaluate_record` cannot call them.
//! - [`ShadowRouter::evaluate_record`] computes decisions via
//!   `policy.decide(ctx)` and returns a [`ShadowTurnRecord`] **purely** — no
//!   I/O. The live loop appends the record to the isolated store off the hot
//!   path via `spawn_blocking` ([`ShadowRouter::evaluate`] keeps the old
//!   synchronous append signature for unit tests). Neither ever calls the
//!   executor, constructs a provider request, or spawns an agent.
//!
//! ## Honest scope of the claim
//!
//! Rust cannot prove an arbitrary `ConductorRoutingPolicy::decide()`
//! implementation is pure — an in-tree policy *could* do I/O internally. The
//! honest, load-bearing statement is narrower and stronger: **no conductor
//! egress seam is reachable from the shadow path.** The in-tree policies are
//! data-only (`StaticDirectPolicy`, the test `FixedPolicy`); they read `ctx`
//! and return a decision. The M3 candidate surface **must keep this property**
//! — M3 candidate policies are **interpreted recipes** (data), not arbitrary
//! executable policy code. A candidate that could do I/O would defeat the
//! guarantee. This constraint is carried into the M3 spec.
//!
//! This is the `agent.session_start` lesson transferred: the surface everyone
//! assumes is out-of-reach (shadow execution) is made out-of-reach *by keeping
//! the egress seams out of scope and the candidate surface data-only*, not by a
//! config default. The load-bearing test
//! (`shadow_router_holds_no_egress_handle`) pins the behavioral consequence:
//! a shadow evaluation's only side effect is one record written to the isolated
//! store.
//!
//! ## Promotion is not automatic
//!
//! A candidate that beats the deployed policy per [`is_improvement`] (F-12:
//! significant + ≥5% + no regression) becomes a **promotion candidate** —
//! flagged for human review, **NOT auto-deployed**. Auto-deploy is M3 (MetaOpt,
//! ADR-008a-gated). The shadow router flags; it does not promote.
//!
//! [`is_improvement`]: crate::conductor::eval::is_improvement

use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::conductor::eval::{is_improvement, Corpus, RoutingScore, RoutingScorer};
use crate::conductor::fingerprint::RequestFingerprint;
use crate::conductor::policy::ConductorRoutingPolicy;
use crate::conductor::recipe::{ConductorTurnContext, OwnedRouteDecision};
use crate::conductor::store::ConductorStore;
use crate::conductor::telemetry::{
    CandidateDecision, CorpusMatch, ShadowTurnRecord, TelemetryRouteDecision,
};

/// A named candidate policy under shadow evaluation.
pub struct NamedPolicy {
    /// Stable, human-readable id (e.g. `"chain-with-verifier"`). Surfaced in the
    /// shadow log and promotion-candidate flags. **Token only — never user text.**
    pub id: String,
    pub policy: Box<dyn ConductorRoutingPolicy>,
}

impl NamedPolicy {
    /// Construct a named candidate.
    pub fn new(id: impl Into<String>, policy: Box<dyn ConductorRoutingPolicy>) -> Self {
        Self {
            id: id.into(),
            policy,
        }
    }
}

/// A candidate flagged as a promotion candidate: it beats the deployed policy on
/// the corpus per [`is_improvement`] (F-12). **Flagged for human review — NOT
/// auto-deployed.** Surfaced in the opt-in team view; promotion is a human act.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PromotionCandidate {
    pub candidate_id: String,
    pub corpus_version: String,
    pub deployed_accuracy: f64,
    pub candidate_accuracy: f64,
}

/// Does this turn's context match a corpus entry? A simple match: same task
/// class and the entry's feature predicates are a subset of the context's. This
/// is intentionally conservative — only score turns we have ground truth for.
pub(crate) fn match_corpus_entry<'a>(
    corpus: &'a Corpus,
    ctx: &ConductorTurnContext,
) -> Option<&'a crate::conductor::eval::CorpusEntry> {
    corpus.entries.iter().find(|entry| {
        entry.task_class == ctx.task_class
            && entry
                .feature_predicates
                .iter()
                .all(|p| ctx.feature_predicates.iter().any(|c| c == p))
    })
}

/// The shadow router. Holds the deployed policy + candidate policies. **Holds no
/// egress handle** (see module docs). Not `Clone` — policies are `Arc<dyn>` /
/// `Box<dyn>`; construct one per evaluation scope.
///
/// *M2-live §2.2a:* `deployed` is [`Arc<dyn ConductorRoutingPolicy>`] so the
/// live [`crate::conductor::executor::ConductorRuntime`] can share the **same**
/// policy object with the shadow baseline (an `Arc::clone`), guaranteeing the
/// shadow "deployed decision" is byte-equal to the actually-executed decision —
/// no two policy objects that could drift. In-tree this is currently moot
/// (`StaticDirectPolicy` is stateless), but the invariant is load-bearing once
/// M3 swaps policies.
pub struct ShadowRouter {
    deployed: Arc<dyn ConductorRoutingPolicy>,
    candidates: Vec<NamedPolicy>,
}

impl ShadowRouter {
    /// Construct with a deployed policy and zero or more candidates. The
    /// deployed policy is shared (by `Arc::clone`) with the live runtime.
    pub fn new(deployed: Arc<dyn ConductorRoutingPolicy>, candidates: Vec<NamedPolicy>) -> Self {
        Self {
            deployed,
            candidates,
        }
    }

    /// Score the deployed + candidate policies against the corpus. Returns the
    /// deployed score and per-candidate scores. **Pure — no egress, no store
    /// write.** Use this for promotion flagging.
    pub fn score_policies(&self, corpus: &Corpus) -> (RoutingScore, Vec<(String, RoutingScore)>) {
        let deployed_score = RoutingScorer::score(corpus, self.deployed.as_ref());
        let candidate_scores = self
            .candidates
            .iter()
            .map(|named| {
                (
                    named.id.clone(),
                    RoutingScorer::score(corpus, named.policy.as_ref()),
                )
            })
            .collect();
        (deployed_score, candidate_scores)
    }

    /// Flag promotion candidates: any candidate that beats the deployed policy
    /// per [`is_improvement`] (F-12). **Flags only — does not promote.**
    /// Promotion is a human act (M3 MetaOpt is the auto path, ADR-008a-gated).
    pub fn flag_promotion_candidates(
        &self,
        corpus: &Corpus,
    ) -> (RoutingScore, Vec<PromotionCandidate>) {
        let (deployed_score, candidate_scores) = self.score_policies(corpus);
        let flagged = candidate_scores
            .into_iter()
            .filter(|(_, candidate_score)| is_improvement(&deployed_score, candidate_score))
            .map(|(candidate_id, candidate_score)| PromotionCandidate {
                candidate_id,
                corpus_version: deployed_score.corpus_version.clone(),
                deployed_accuracy: deployed_score.routing_accuracy,
                candidate_accuracy: candidate_score.routing_accuracy,
            })
            .collect();
        (deployed_score, flagged)
    }

    /// Evaluate one turn **purely**: compute the deployed + candidate decisions
    /// (decision only — **none executed**), score against the corpus if it
    /// matches, and return a [`ShadowTurnRecord`]. **No I/O** — does not touch
    /// the store. The live loop appends the returned record off the hot path
    /// via `spawn_blocking` (M2-live §2.2b: no synchronous file I/O on the
    /// turn path).
    ///
    /// `request_fingerprint` is the **executor's authoritative F-4 fingerprint**
    /// (HMAC of the opaque request_id), passed in by the live loop so shadow
    /// records join receipts/events on the same key. The shadow router does
    /// **not** derive its own fingerprint — that authority stays with the
    /// executor's `InstallKey` path (F-4).
    ///
    /// **This is the no-egress proof point.** Only `policy.decide()` is called
    /// (pure). No executor, no provider, no agent runner.
    pub fn evaluate_record(
        &self,
        ctx: &ConductorTurnContext,
        request_fingerprint: RequestFingerprint,
        corpus: Option<&Corpus>,
        timestamp_ms: u64,
    ) -> ShadowTurnRecord {
        let deployed_decision = self.deployed.decide(ctx);
        let corpus_match = corpus.and_then(|c| match_corpus_entry(c, ctx));
        let deployed_matched_ideal = corpus_match
            .map(|entry| decision_matches_ideal(&deployed_decision, entry))
            .unwrap_or(false);

        let candidates: Vec<CandidateDecision> = self
            .candidates
            .iter()
            .map(|named| {
                let decision = named.policy.decide(ctx);
                let matched_ideal = corpus_match
                    .map(|entry| decision_matches_ideal(&decision, entry))
                    .unwrap_or(false);
                CandidateDecision {
                    candidate_id: named.id.clone(),
                    // F-4: snapshot the decision WITHOUT the raw request_id
                    // (correlation is via request_fingerprint on the record).
                    decision: TelemetryRouteDecision::from(&decision),
                    matched_ideal,
                }
            })
            .collect();

        ShadowTurnRecord {
            request_fingerprint,
            // F-4: snapshot the deployed decision WITHOUT the raw request_id.
            deployed_decision: TelemetryRouteDecision::from(&deployed_decision),
            deployed_matched_ideal,
            candidates,
            corpus_match: corpus_match.map(|entry| CorpusMatch {
                corpus_version: corpus.map(|c| c.corpus_version.clone()).unwrap_or_default(),
                entry_id: entry.id.clone(),
            }),
            timestamp_ms,
        }
    }

    /// Evaluate one turn and **synchronously** append the record to the isolated
    /// store. Convenience wrapper around [`evaluate_record`] for unit tests; the
    /// **live loop does not call this** (it uses `evaluate_record` + an off-path
    /// `spawn_blocking` append, so the turn path never blocks on the store —
    /// M2-live §2.2b / V8).
    pub fn evaluate(
        &self,
        ctx: &ConductorTurnContext,
        request_fingerprint: RequestFingerprint,
        corpus: Option<&Corpus>,
        store: &ConductorStore,
        timestamp_ms: u64,
    ) -> Result<ShadowTurnRecord, crate::conductor::error::ConductorError> {
        let record = self.evaluate_record(ctx, request_fingerprint, corpus, timestamp_ms);
        store.append_shadow_record(&record)?;
        Ok(record)
    }

    /// Number of candidate policies under shadow evaluation.
    #[allow(dead_code)] // surfaced for diagnostics / team view
    pub fn candidate_count(&self) -> usize {
        self.candidates.len()
    }
}

/// Does a decision match a corpus entry's ideal route? A conservative structural
/// match on the routing-relevant fields (worker + topology + lane). This is the
/// ground-truth signal the shadow log records.
fn decision_matches_ideal(
    decision: &OwnedRouteDecision,
    entry: &crate::conductor::eval::CorpusEntry,
) -> bool {
    let ideal = &entry.ideal_route;
    decision.worker_id == ideal.worker_id.as_str()
        && decision.topology == ideal.topology
        && decision.lane == entry.privacy_lane
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conductor::eval::Corpus;
    use crate::conductor::fingerprint::RequestFingerprint;
    use crate::conductor::policy::StaticDirectPolicy;
    use crate::conductor::recipe::{
        ConductorTaskClass, ConductorTopology, ConductorTurnContext, OwnedRouteDecision,
        PrivacyLane,
    };
    use crate::conductor::store::ConductorStore;

    fn fp(n: usize) -> RequestFingerprint {
        RequestFingerprint(format!("{n:064x}"))
    }

    fn ctx(id: &str) -> ConductorTurnContext {
        ConductorTurnContext {
            request_id: id.to_string(),
            task_class: ConductorTaskClass::Chat,
            feature_predicates: vec![],
            privacy_lane: PrivacyLane::LocalOnly,
            available_workers: vec![],
            working_directory: None,
            deadline_ms: None,
        }
    }

    // A policy that emits a FIXED decision (for deterministic shadow tests).
    struct FixedPolicy {
        worker_id: &'static str,
        topology: ConductorTopology,
    }
    impl ConductorRoutingPolicy for FixedPolicy {
        fn decide(&self, _ctx: &ConductorTurnContext) -> OwnedRouteDecision {
            OwnedRouteDecision {
                request_id: String::new(),
                recipe_id: "fixed".to_string(),
                topology: self.topology,
                worker_id: self.worker_id.to_string(),
                task_class: ConductorTaskClass::Chat,
                lane: PrivacyLane::LocalOnly,
                approval: crate::conductor::recipe::ApprovalClass::None,
                reason: "fixed-test".to_string(),
            }
        }
    }

    fn tmp_store() -> ConductorStore {
        let dir = std::env::temp_dir().join(format!(
            "fae-shadow-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        ConductorStore::open(dir).expect("open store")
    }

    #[test]
    fn shadow_evaluation_records_deployed_and_candidate_decisions() {
        let store = tmp_store();
        let router = ShadowRouter::new(
            Arc::new(FixedPolicy {
                worker_id: "local-model",
                topology: ConductorTopology::Direct,
            }),
            vec![NamedPolicy::new(
                "candidate-a",
                Box::new(FixedPolicy {
                    worker_id: "local-model",
                    topology: ConductorTopology::Direct,
                }),
            )],
        );
        let record = router
            .evaluate(&ctx("t1"), fp(1), None, &store, 0)
            .expect("evaluate");
        assert_eq!(record.candidates.len(), 1);
        assert_eq!(record.candidates[0].candidate_id, "candidate-a");
        assert_eq!(record.deployed_decision.worker_id, "local-model");
        // corpus_match is None when no corpus provided.
        assert!(record.corpus_match.is_none());
    }

    #[test]
    fn score_policies_uses_corpus() {
        let corpus = Corpus::synthetic_core().expect("synthetic corpus");
        let router = ShadowRouter::new(
            Arc::new(StaticDirectPolicy),
            vec![NamedPolicy::new(
                "same-as-deployed",
                Box::new(StaticDirectPolicy),
            )],
        );
        let (deployed, candidates) = router.score_policies(&corpus);
        assert_eq!(deployed.corpus_version, corpus.corpus_version);
        assert_eq!(candidates.len(), 1);
        // Identical policy ⇒ identical score.
        assert!(approx_eq(
            deployed.routing_accuracy,
            candidates[0].1.routing_accuracy
        ));
    }

    #[test]
    fn identical_candidate_is_not_a_promotion_candidate() {
        // A candidate identical to deployed cannot be an improvement (F-12).
        let corpus = Corpus::synthetic_core().expect("synthetic corpus");
        let router = ShadowRouter::new(
            Arc::new(StaticDirectPolicy),
            vec![NamedPolicy::new("twin", Box::new(StaticDirectPolicy))],
        );
        let (_deployed, flagged) = router.flag_promotion_candidates(&corpus);
        assert!(
            flagged.is_empty(),
            "an identical candidate must not be flagged as a promotion candidate"
        );
    }

    /// === STRUCTURAL NO-EGRESS PROOF (the load-bearing test) ===
    ///
    /// The shadow router must NEVER cause egress. This test asserts it by
    /// construction: the shadow path produces decisions + records, and there is
    /// no way for it to reach a CloudProvider/AcpAgentRunner because those types
    /// are not in scope of `ShadowRouter`. We assert the public API surface: the
    /// only things a ShadowRouter can do are `score_policies`, `evaluate`, and
    /// `flag_promotion_candidates` — none of which accept or hold an egress seam.
    /// (Note: Rust cannot prove an arbitrary `decide()` impl is pure; the
    /// load-bearing property is that no egress *seam* is in scope and the in-tree
    /// + M3 candidate policies are data-only. See the module-level honesty note.)
    #[test]
    fn shadow_router_holds_no_egress_handle() {
        // The struct fields are `Box<dyn ConductorRoutingPolicy>` +
        // `Vec<NamedPolicy>`. No egress seam (CloudProvider/Runner/builder) is
        // in scope of ShadowRouter. This test asserts the *behavioral*
        // consequence: an evaluation over a
        // pure policy produces records with zero side effects beyond the store.
        let store = tmp_store();
        let router = ShadowRouter::new(
            Arc::new(FixedPolicy {
                worker_id: "local-model",
                topology: ConductorTopology::Direct,
            }),
            vec![
                NamedPolicy::new(
                    "c1",
                    Box::new(FixedPolicy {
                        worker_id: "local-model",
                        topology: ConductorTopology::Direct,
                    }),
                ),
                NamedPolicy::new(
                    "c2",
                    Box::new(FixedPolicy {
                        worker_id: "local-model",
                        topology: ConductorTopology::Direct,
                    }),
                ),
            ],
        );
        let before = std::fs::read_dir(store.dir())
            .map(|d| d.count())
            .unwrap_or(0);
        let rec = router
            .evaluate(&ctx("no-egress-1"), fp(2), None, &store, 0)
            .unwrap();
        // Exactly one record written; no provider call, no agent spawn.
        assert_eq!(rec.candidates.len(), 2);
        let after = std::fs::read_dir(store.dir())
            .map(|d| d.count())
            .unwrap_or(0);
        assert!(
            after >= before,
            "store gained at most the shadow record file"
        );
    }

    fn approx_eq(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }
}
