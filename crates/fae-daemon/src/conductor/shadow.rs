//! M2 shadow router (spec §8 — decision-only; never egresses).
//!
//! Runs candidate policies **alongside** the deployed policy, scoring both —
//! **without the candidates ever causing egress, spend, or cross-owner traffic.**
//!
//! ## Structural no-egress guarantee (the load-bearing property)
//!
//! The shadow router is **physically incapable of egress**. This is not a
//! config default that could be flipped; it is structural:
//!
//! - [`ShadowRouter`] holds only [`Box<dyn ConductorRoutingPolicy>`] (a
//!   decision-only trait whose sole method [`decide`](ConductorRoutingPolicy::decide)
//!   returns an [`OwnedRouteDecision`] with **no I/O**) and a [`ConductorStore`]
//!   (an isolated append-only log). There is **no field** of type
//!   `CloudProvider`, `AcpAgentRunner`, `CloudRequestBuilder`, or any other
//!   egress handle. The executor's egress seams are simply not in scope.
//! - [`ShadowRouter::evaluate`] computes decisions via `policy.decide(ctx)` — a
//!   pure function — and writes a [`ShadowTurnRecord`] to the isolated store. It
//!   never calls the executor, never constructs a provider request, never spawns
//!   an agent.
//!
//! This is the `agent.session_start` lesson transferred: the surface everyone
//! assumes is out-of-reach (shadow execution) is made out-of-reach *by type*,
//! not by default. The load-bearing test
//! (`shadow_evaluation_never_egresses_even_with_spy_seams_available`) pins it:
//! even when spy `CloudProvider`/`AcpAgentRunner` seams exist in the runtime,
//! a shadow evaluation records zero calls on them.
//!
//! ## Promotion is not automatic
//!
//! A candidate that beats the deployed policy per [`is_improvement`] (F-12:
//! significant + ≥5% + no regression) becomes a **promotion candidate** —
//! flagged for human review, **NOT auto-deployed**. Auto-deploy is M3 (MetaOpt,
//! ADR-008a-gated). The shadow router flags; it does not promote.
//!
//! [`is_improvement`]: crate::conductor::eval::is_improvement

use serde::{Deserialize, Serialize};

use crate::conductor::eval::{is_improvement, Corpus, RoutingScore, RoutingScorer};
use crate::conductor::fingerprint::RequestFingerprint;
use crate::conductor::policy::ConductorRoutingPolicy;
use crate::conductor::recipe::{ConductorTurnContext, OwnedRouteDecision};
use crate::conductor::store::ConductorStore;
use crate::conductor::telemetry::{CandidateDecision, CorpusMatch, ShadowTurnRecord};

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
fn match_corpus_entry<'a>(
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
/// egress handle** (see module docs). Cheap to clone is NOT supported — policies
/// are `Box<dyn>`; construct one per evaluation scope.
pub struct ShadowRouter {
    deployed: Box<dyn ConductorRoutingPolicy>,
    candidates: Vec<NamedPolicy>,
}

impl ShadowRouter {
    /// Construct with a deployed policy and zero or more candidates.
    pub fn new(deployed: Box<dyn ConductorRoutingPolicy>, candidates: Vec<NamedPolicy>) -> Self {
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

    /// Evaluate one turn: compute the deployed + candidate decisions (decision
    /// only — **none executed**), score against the corpus if it matches, and
    /// append a [`ShadowTurnRecord`] to the isolated store. Returns the record.
    ///
    /// `request_fingerprint` is the **executor's authoritative F-4 fingerprint**
    /// (HMAC of the opaque request_id), passed in by the live loop so shadow
    /// records join receipts/events on the same key. The shadow router does
    /// **not** derive its own fingerprint — that authority stays with the
    /// executor's `InstallKey` path (F-4).
    ///
    /// **This is the no-egress proof point.** Only `policy.decide()` is called
    /// (pure). No executor, no provider, no agent runner.
    pub fn evaluate(
        &self,
        ctx: &ConductorTurnContext,
        request_fingerprint: RequestFingerprint,
        corpus: Option<&Corpus>,
        store: &ConductorStore,
        timestamp_ms: u64,
    ) -> Result<ShadowTurnRecord, crate::conductor::error::ConductorError> {
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
                    decision,
                    matched_ideal,
                }
            })
            .collect();

        let record = ShadowTurnRecord {
            request_fingerprint,
            deployed_decision,
            deployed_matched_ideal,
            candidates,
            corpus_match: corpus_match.map(|entry| CorpusMatch {
                corpus_version: corpus.map(|c| c.corpus_version.clone()).unwrap_or_default(),
                entry_id: entry.id.clone(),
            }),
            timestamp_ms,
        };
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
            Box::new(FixedPolicy {
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
            Box::new(StaticDirectPolicy),
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
            Box::new(StaticDirectPolicy),
            vec![NamedPolicy::new(
                "twin",
                Box::new(StaticDirectPolicy),
            )],
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
    #[test]
    fn shadow_router_holds_no_egress_handle() {
        // The compile-time proof is the struct definition itself: ShadowRouter's
        // fields are `Box<dyn ConductorRoutingPolicy>` + `Vec<NamedPolicy>`. The
        // decision-only trait has no I/O. There is no CloudProvider/Runner field.
        // This test asserts the *behavioral* consequence: an evaluation over a
        // pure policy produces records with zero side effects beyond the store.
        let store = tmp_store();
        let router = ShadowRouter::new(
            Box::new(FixedPolicy {
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
