//! M2 reward aggregator (spec §7 — F-10: reject self-judgment-only).
//!
//! Combines **four** signal sources into a scalar reward in `[-1.0, +1.0]`.
//! The load-bearing rule (F-10): **model self-judgment is advisory-only — it
//! can never be the sole source of positive reward.** This is enforced
//! *structurally* in [`aggregate_reward`]: when the non-self-judgment signals
//! (routing accuracy, user signal, outcome metrics) contribute nothing positive,
//! the self-judgment term is forced to `<= 0.0`. A mutation test
//! (`self_judgment_alone_cannot_produce_positive_reward`) pins this.
//!
//! ## The two scoring surfaces (spec §7 MINOR-4)
//!
//! - **Corpus score** ([`crate::conductor::eval::RoutingScorer::score`]) — a
//!   static, versioned ground-truth measurement over the fixed human-labeled
//!   corpus. Promotion uses [`is_improvement`] on corpus scores (the F-12 gate).
//! - **Reward window** (this module) — [`aggregate_reward`] over a rolling
//!   N-turn slice of the live shadow log. A live-performance measurement;
//!   advisory input to a human reviewer deciding whether to promote a flagged
//!   candidate, NOT an auto-promotion signal.
//!
//! ## Storage isolation
//!
//! User feedback is late-arriving (the receipt is written at turn-end, before
//! feedback exists). It is appended to a separate feedback log
//! (`conductor_feedback.jsonl`) and joined to receipts on `request_fingerprint`
//! at scoring time (§7 MAJOR-4). The feedback log lives in the isolated
//! [`ConductorStore`], never in personal memory. Feedback rows carry
//! enum-like tokens only, never user text (see [`UserSignal`]).
//!
//! [`is_improvement`]: crate::conductor::eval::is_improvement
//! [`UserSignal`]: crate::conductor::telemetry::UserSignal

use serde::{Deserialize, Serialize};

use crate::conductor::eval::RoutingScore;
use crate::conductor::telemetry::{RouteReceipt, UserSignal};

/// Outcome metrics derived from a rolling window of [`RouteReceipt`]s. Lower
/// cost + lower latency + clean privacy = higher reward; a `PrivacyBlocked`
/// fallback, a `fallback`, or a `success: false` (MINOR-6) are negative signals.
#[derive(Debug, Clone, PartialEq)]
pub struct OutcomeMetrics {
    /// Number of receipts in the window.
    pub turns: u64,
    /// Summed cost across the window (micros).
    pub total_cost_micros: u64,
    /// Mean wall-clock latency across the window (ms).
    pub mean_latency_ms: f64,
    /// Turns that degraded to direct-local due to a `PrivacyBlocked` membrane
    /// hit. Strong negative (a privacy-preserving fallback, but a routing miss).
    pub privacy_blocks: u64,
    /// Turns that degraded for any reason (privacy/budget/approval/mode).
    pub fallbacks: u64,
    /// Turns where the provider call itself failed (`success: false`).
    pub failures: u64,
}

impl OutcomeMetrics {
    /// Aggregate a window of receipts into outcome metrics. Empty window ⇒ all
    /// zeros (treated as neutral by [`outcome_metrics_component`]).
    pub fn from_receipts(receipts: &[RouteReceipt]) -> Self {
        let turns = u64::try_from(receipts.len()).unwrap_or(u64::MAX);
        if receipts.is_empty() {
            return Self {
                turns: 0,
                total_cost_micros: 0,
                mean_latency_ms: 0.0,
                privacy_blocks: 0,
                fallbacks: 0,
                failures: 0,
            };
        }
        let total_cost_micros = receipts.iter().filter_map(|r| r.cost_micros).sum();
        let mean_latency_ms = {
            let measured: Vec<u64> = receipts.iter().filter_map(|r| r.latency_ms).collect();
            if measured.is_empty() {
                0.0
            } else {
                (measured.iter().sum::<u64>() as f64) / (measured.len() as f64)
            }
        };
        let privacy_blocks = receipts
            .iter()
            .filter(|r| {
                r.fallback
                    && r.fallback_reason
                        .as_ref()
                        .is_some_and(|reason| reason.contains("PrivacyBlocked"))
            })
            .count() as u64;
        let fallbacks = receipts.iter().filter(|r| r.fallback).count() as u64;
        let failures = receipts.iter().filter(|r| !r.success).count() as u64;
        Self {
            turns,
            total_cost_micros,
            mean_latency_ms,
            privacy_blocks,
            fallbacks,
            failures,
        }
    }

    /// Fraction of turns that succeeded at the routed target (not fallback,
    /// not failed). `0.0` for an empty window.
    pub fn clean_success_rate(&self) -> f64 {
        if self.turns == 0 {
            return 0.0;
        }
        let dirty = self.failures + self.fallbacks;
        let clean = self.turns.saturating_sub(dirty);
        (clean as f64) / (self.turns as f64)
    }
}

/// A model's self-assessment of an output. **Advisory only (F-10).** May
/// contribute a negative weight ("this output looks wrong") but may never be
/// the sole source of positive reward — enforced structurally in
/// [`aggregate_reward`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SelfJudgment {
    /// Model's self-assessed quality in `[-1.0, +1.0]`. Negative = "looks
    /// wrong"; positive = "looks right". Clamped on construction.
    pub score: f64,
}

impl SelfJudgment {
    /// Construct, clamping to the valid `[-1.0, +1.0]` range.
    pub fn new(score: f64) -> Self {
        Self {
            score: score.clamp(-1.0, 1.0),
        }
    }
}

/// The four reward signal sources (spec §7).
#[derive(Debug, Clone)]
pub struct RewardSignals<'a> {
    /// (1) Routing accuracy against the versioned human-labeled corpus — the
    /// primary positive signal. Ground truth, not model output. Always present
    /// when scoring a policy (the shadow router computes it via `RoutingScorer`).
    pub routing_score: &'a RoutingScore,
    /// (2) Explicit user feedback joined from the feedback log (§7 MAJOR-4).
    /// Late-arriving; joined on `request_fingerprint`. May be empty.
    pub user_signal: &'a [UserSignal],
    /// (3) Cost + latency + privacy outcomes from the receipt window.
    pub outcome_metrics: &'a OutcomeMetrics,
    /// (4) Model self-judgment — **ADVISORY ONLY** (F-10).
    pub self_judgment: Option<SelfJudgment>,
}

/// Per-component breakdown of an aggregated reward. Logged for auditability so
/// a reviewer can see *why* a window scored as it did (NOTE-1: typed struct,
/// not a bare f64).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RewardComponents {
    /// Routing-accuracy contribution. Primary positive signal.
    pub routing: f64,
    /// User-feedback contribution. Reject/edit are negative.
    pub user: f64,
    /// Outcome-metrics contribution. Failures/fallbacks/cost are negative.
    pub outcome: f64,
    /// Self-judgment contribution *after* the F-10 cap (may be forced `<= 0`).
    pub self_judgment: f64,
}

/// The aggregated reward. `score` is the scalar a reviewer sees; `components`
/// is the auditable breakdown. NOTE-1: this is a typed struct, not a bare f64.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Reward {
    /// Scalar reward in `[-1.0, +1.0]`. `> 0` only if a non-self-judgment signal
    /// contributes positively (F-10).
    pub score: f64,
    /// Per-component breakdown for audit.
    pub components: RewardComponents,
    /// True iff the self-judgment term was capped (forced `<= 0`) by F-10.
    /// Surfaced so a reviewer can see when self-judgment was silenced.
    pub self_judgment_was_capped: bool,
}

// ── M2-live §4: advisory reward snapshot (read-only response surface) ──
//
// Returned by `ConductorRuntime::reward_snapshot`. Carries aggregates +
// fingerprints + enum tokens only (no user text) — observation, not egress.

/// How the routing component of a snapshot was derived.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RewardRoutingSource {
    /// `>= 1` shadow record in the window matched the corpus ⇒ routing
    /// component is a live accuracy derived from the window.
    LiveShadow,
    /// Zero shadow matches ⇒ no routing ground truth; routing component is `0.0`
    /// (neutral). The common case until a content-aware classifier lands (§2.5).
    NeutralNoGroundTruth,
}

/// The scored window's row counts (audit context for a snapshot).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RewardSnapshotWindow {
    pub turns: u64,
    pub feedback_count: u64,
    pub shadow_records: u64,
    pub corpus_matches: u64,
    pub corpus_version: String,
}

/// Static metadata for a snapshot (NOT the live reward input — §4.2 step 5).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RewardSnapshotBaseline {
    /// Static corpus routing accuracy of the deployed policy. Context only; the
    /// live routing component comes from the shadow window, not this value.
    pub static_corpus_routing_accuracy: f64,
}

/// Advisory reward snapshot (spec §4). Joins three isolated-store reads
/// (receipts + shadow + feedback) into an auditable breakdown. Read-only.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RewardSnapshot {
    /// Scalar reward in `[-1.0, +1.0]`.
    pub score: f64,
    /// True iff the self-judgment term was capped by F-10. Always `false` for
    /// snapshots (self-judgment is `None`); kept for shape parity with [`Reward`].
    pub self_judgment_was_capped: bool,
    /// Per-component breakdown.
    pub components: RewardComponents,
    /// How the routing component was derived.
    pub routing_source: RewardRoutingSource,
    /// The scored window's row counts.
    pub window: RewardSnapshotWindow,
    /// Static metadata (not the live reward input).
    pub baseline: RewardSnapshotBaseline,
}

/// Map a corpus routing accuracy `acc ∈ [0,1]` to a reward contribution in
/// `[-1.0, +1.0]`. Chance routing (0.5 on a binary task) maps to `0.0` (neutral);
/// perfect routing maps to `+1.0`; worse-than-chance maps negative.
fn routing_accuracy_component(routing_score: &RoutingScore) -> f64 {
    ((routing_score.routing_accuracy - 0.5) * 2.0).clamp(-1.0, 1.0)
}

/// Map a slice of user signals to a reward contribution. Reject = strong
/// negative (-0.5 each); Edit = mild negative (-0.2 each); Accept = +0.3 each;
/// Rating(n) = `(n/5 - 0.5) * 0.4` each. Sum clamped to `[-1.0, +1.0]`. Empty ⇒ 0.
fn user_signal_component(signals: &[UserSignal]) -> f64 {
    if signals.is_empty() {
        return 0.0;
    }
    let mut sum = 0.0_f64;
    for signal in signals {
        sum += match signal {
            UserSignal::Accept => 0.3,
            UserSignal::Reject => -0.5,
            UserSignal::Edit => -0.2,
            UserSignal::Rating(n) => {
                let frac = (*n as f64).clamp(0.0, 5.0) / 5.0;
                (frac - 0.5) * 0.4
            }
        };
    }
    sum.clamp(-1.0, 1.0)
}

/// Map outcome metrics to a reward contribution. Anchored on clean-success
/// rate (the dominant factor), with penalties for cost, latency, and privacy
/// blocks. Empty window ⇒ 0 (neutral, not punitive).
fn outcome_metrics_component(metrics: &OutcomeMetrics) -> f64 {
    if metrics.turns == 0 {
        return 0.0;
    }
    // Clean success rate ∈ [0,1] mapped to [-1, +1] around 0.5.
    let success_term = (metrics.clean_success_rate() - 0.5) * 2.0;
    // Privacy blocks are a strong negative (a routing miss that fell back).
    let privacy_term = -0.3 * (metrics.privacy_blocks as f64) / (metrics.turns as f64);
    // Mild cost pressure (log-scaled so large budgets don't dominate). Only
    // applies to non-zero spend (local-only windows spend nothing).
    let cost_term = if metrics.total_cost_micros > 0 {
        let log_cost = (metrics.total_cost_micros as f64).ln_1p();
        -0.02 * (log_cost / 10.0).min(1.0)
    } else {
        0.0
    };
    (success_term + privacy_term + cost_term).clamp(-1.0, 1.0)
}

/// Aggregate the four signals into a scalar reward (spec §7).
///
/// **Load-bearing invariant (F-10):** self-judgment may never be the sole source
/// of positive reward. When the non-self-judgment signals (routing, user,
/// outcome) contribute nothing positive, the self-judgment term is forced to
/// `<= 0.0`. Pinned by `self_judgment_alone_cannot_produce_positive_reward`.
pub fn aggregate_reward(signals: &RewardSignals<'_>) -> Reward {
    let routing = routing_accuracy_component(signals.routing_score);
    let user = user_signal_component(signals.user_signal);
    let outcome = outcome_metrics_component(signals.outcome_metrics);
    let raw_self_judgment = signals.self_judgment.map(|sj| sj.score).unwrap_or(0.0);

    // F-10: self-judgment may never be the sole source of positive reward.
    let non_self_positive = routing.max(0.0) + user.max(0.0) + outcome.max(0.0);
    let (self_judgment, was_capped) = if non_self_positive <= 0.0 {
        // No non-self positive contribution ⇒ self-judgment may only negative-weight.
        (raw_self_judgment.min(0.0), raw_self_judgment > 0.0)
    } else {
        (raw_self_judgment, false)
    };

    let score = (routing + user + outcome + self_judgment).clamp(-1.0, 1.0);

    Reward {
        score,
        components: RewardComponents {
            routing,
            user,
            outcome,
            self_judgment,
        },
        self_judgment_was_capped: was_capped,
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;
    use crate::conductor::eval::{RoutingDimension, RoutingScore};
    use crate::conductor::RequestFingerprint;

    fn approx_eq(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    fn score_for(accuracy: f64) -> RoutingScore {
        let correct = (accuracy * 10.0) as u64;
        RoutingScore {
            corpus_version: "test-v1".to_string(),
            sample_size: 10,
            correct_routes: correct,
            routing_accuracy: accuracy,
            dimensions: BTreeMap::from([(
                RoutingDimension::Topology,
                crate::conductor::eval::DimensionScore {
                    correct,
                    total: 10,
                    accuracy,
                },
            )]),
            case_outcomes: Vec::new(),
        }
    }

    fn empty_outcomes() -> OutcomeMetrics {
        OutcomeMetrics {
            turns: 0,
            total_cost_micros: 0,
            mean_latency_ms: 0.0,
            privacy_blocks: 0,
            fallbacks: 0,
            failures: 0,
        }
    }

    fn fp() -> RequestFingerprint {
        RequestFingerprint("a".repeat(64))
    }

    #[test]
    fn routing_accuracy_maps_neutral_at_chance() {
        // 0.5 accuracy (chance on a binary task) ⇒ neutral routing contribution.
        let s = score_for(0.5);
        let metrics = empty_outcomes();
        let signals = RewardSignals {
            routing_score: &s,
            user_signal: &[],
            outcome_metrics: &metrics,
            self_judgment: None,
        };
        let r = aggregate_reward(&signals);
        assert!(approx_eq(r.components.routing, 0.0));
        assert!(approx_eq(r.score, 0.0));
    }

    #[test]
    fn perfect_routing_is_positive_without_self_judgment() {
        let s = score_for(1.0);
        let metrics = empty_outcomes();
        let signals = RewardSignals {
            routing_score: &s,
            user_signal: &[],
            outcome_metrics: &metrics,
            self_judgment: None,
        };
        let r = aggregate_reward(&signals);
        assert!(r.score > 0.0, "perfect routing must be positive");
        assert!(r.components.routing > 0.0);
    }

    #[test]
    fn user_reject_is_strong_negative() {
        let s = score_for(0.5);
        let metrics = empty_outcomes();
        let signals = RewardSignals {
            routing_score: &s,
            user_signal: &[UserSignal::Reject, UserSignal::Reject],
            outcome_metrics: &metrics,
            self_judgment: None,
        };
        let r = aggregate_reward(&signals);
        assert!(r.score < 0.0, "two rejects must be net negative");
        assert!(r.components.user < 0.0);
    }

    #[test]
    fn user_accept_is_positive() {
        let s = score_for(0.5);
        let metrics = empty_outcomes();
        let signals = RewardSignals {
            routing_score: &s,
            user_signal: &[UserSignal::Accept],
            outcome_metrics: &metrics,
            self_judgment: None,
        };
        let r = aggregate_reward(&signals);
        assert!(r.score > 0.0);
        assert!(r.components.user > 0.0);
    }

    #[test]
    fn outcome_failures_are_negative() {
        // Build receipts with a failure.
        let receipt = RouteReceipt {
            request_fingerprint: fp(),
            recipe_id: "r".to_string(),
            topology: crate::conductor::recipe::ConductorTopology::Direct,
            worker_id: "local-model".to_string(),
            target_kind: crate::conductor::telemetry::TargetKind::LocalModel,
            privacy_lane: crate::conductor::recipe::PrivacyLane::LocalOnly,
            roles: None,
            latency_ms: Some(100),
            cost_micros: None,
            success: false,
            fallback: false,
            fallback_reason: None,
            payload_hash: None,
            eval_delta: None,
            user_signal: None,
            timestamp_ms: 0,
        };
        let metrics = OutcomeMetrics::from_receipts(&[receipt]);
        assert_eq!(metrics.failures, 1);
        assert_eq!(metrics.turns, 1);
        assert!(approx_eq(metrics.clean_success_rate(), 0.0));
        // Outcome contribution should be negative (0% clean success).
        assert!(outcome_metrics_component(&metrics) < 0.0);
    }

    #[test]
    fn outcome_metrics_empty_window_is_neutral() {
        let metrics = OutcomeMetrics::from_receipts(&[]);
        assert_eq!(metrics.turns, 0);
        assert!(approx_eq(outcome_metrics_component(&metrics), 0.0));
    }

    // === F-10 LOAD-BEARING INVARIANT TESTS ===

    #[test]
    fn self_judgment_alone_cannot_produce_positive_reward() {
        // No routing edge (chance), no user signal, empty outcomes ⇒ all
        // non-self signals neutral. Self-judgment is strongly positive.
        // F-10: the reward must NOT be positive, and self_judgment_was_capped
        // must be true.
        let s = score_for(0.5);
        let metrics = empty_outcomes();
        let signals = RewardSignals {
            routing_score: &s,
            user_signal: &[],
            outcome_metrics: &metrics,
            self_judgment: Some(SelfJudgment::new(0.9)),
        };
        let r = aggregate_reward(&signals);
        assert!(
            r.score <= 0.0,
            "F-10 violated: self-judgment alone produced a positive reward ({})",
            r.score
        );
        assert!(r.self_judgment_was_capped);
        assert!(r.components.self_judgment <= 0.0);
    }

    #[test]
    fn self_judgment_can_negative_weight_without_other_signals() {
        // Same neutral non-self setup, but self-judgment is negative. It should
        // pass through (negative-weighting is always allowed) and NOT be capped.
        let s = score_for(0.5);
        let metrics = empty_outcomes();
        let signals = RewardSignals {
            routing_score: &s,
            user_signal: &[],
            outcome_metrics: &metrics,
            self_judgment: Some(SelfJudgment::new(-0.8)),
        };
        let r = aggregate_reward(&signals);
        assert!(r.score < 0.0);
        assert!(!r.self_judgment_was_capped);
        assert!(approx_eq(r.components.self_judgment, -0.8));
    }

    #[test]
    fn self_judgment_passes_through_when_routing_is_positive() {
        // When a non-self signal contributes positively, self-judgment is NOT
        // capped (it may add or subtract freely).
        let s = score_for(1.0); // routing +1.0
        let metrics = empty_outcomes();
        let signals = RewardSignals {
            routing_score: &s,
            user_signal: &[],
            outcome_metrics: &metrics,
            self_judgment: Some(SelfJudgment::new(0.5)),
        };
        let r = aggregate_reward(&signals);
        assert!(!r.self_judgment_was_capped);
        assert!(approx_eq(r.components.self_judgment, 0.5));
        assert!(r.score > 0.0);
    }

    #[test]
    fn reward_is_bounded() {
        // Every signal maximally positive ⇒ still bounded to +1.0.
        let s = score_for(1.0);
        let good_outcomes = OutcomeMetrics {
            turns: 10,
            total_cost_micros: 0,
            mean_latency_ms: 1.0,
            privacy_blocks: 0,
            fallbacks: 0,
            failures: 0,
        };
        let signals = RewardSignals {
            routing_score: &s,
            user_signal: &[UserSignal::Accept; 10],
            outcome_metrics: &good_outcomes,
            self_judgment: Some(SelfJudgment::new(1.0)),
        };
        let r = aggregate_reward(&signals);
        assert!(r.score <= 1.0 + 1e-9);
        assert!(r.score >= -1.0 - 1e-9);
    }

    #[test]
    fn self_judgment_new_clamps() {
        assert!(approx_eq(SelfJudgment::new(5.0).score, 1.0));
        assert!(approx_eq(SelfJudgment::new(-5.0).score, -1.0));
    }

    #[test]
    fn rating_maps_neutral_at_midpoint() {
        let s = score_for(0.5);
        let metrics = empty_outcomes();
        // Rating(3) of 5 ⇒ frac 0.6 ⇒ (0.6-0.5)*0.4 = +0.04 (slightly positive)
        let signals = RewardSignals {
            routing_score: &s,
            user_signal: &[UserSignal::Rating(3)],
            outcome_metrics: &metrics,
            self_judgment: None,
        };
        let r = aggregate_reward(&signals);
        assert!(
            r.components.user > 0.0,
            "rating 3/5 should be mildly positive"
        );
    }
}
