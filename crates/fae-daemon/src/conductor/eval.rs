//! Dormant conductor routing eval corpus + scorer (WP-D7, M2).
//!
//! This module defines the versioned JSON corpus format and the `RoutingScorer`
//! primitive that the M2 reward aggregator will consume. It is deliberately
//! staged here, inside `fae-daemon`, because the scorer evaluates the daemon's
//! in-process [`ConductorRoutingPolicy`] trait without introducing a new crate
//! that would either depend on the daemon binary crate or force an interface
//! split before M2 stabilizes.
//!
//! # F-11: annotation and versioning limits
//!
//! The current corpus is single-annotator: David is the only source of
//! `ideal_route` labels. Treat the score as a regression/selection signal, not
//! universal ground truth. Any change to the annotation rubric, task taxonomy,
//! synthetic-core contents, or real-sample refresh policy must bump
//! `corpus_version`; the F-12 gate only compares scores produced from the same
//! corpus version.
//!
//! # Privacy
//!
//! Corpus entries are metadata-first: `task_class`, `feature_predicates`, and an
//! `ideal_route` label. Synthetic entries carry no prompt/user text. Real-sample
//! ingestion accepts raw text only in memory, runs `fae-pii-membrane`
//! redaction/block checks first, and only then writes a bounded redacted excerpt
//! plus structured membrane labels. No raw user text is required for scoring.

#![allow(dead_code)]
// TODO(M2 2026-06-23): wire into reward aggregator after M2 spec review.
// Per-module forbid for parity with fae-pii-membrane (the parent mod.rs crate-level
// attribute already cascades here; this is belt-and-braces per the privacy-crate
// convention flagged in the WP-D7 reviewer pass, 2026-06-23).
#![forbid(unsafe_code)]

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use fae_pii_membrane::{redact_for_storage, scan, should_block_remote_egress};
use serde::{Deserialize, Serialize};

use crate::conductor::policy::ConductorRoutingPolicy;
use crate::conductor::recipe::{
    ApprovalClass, ConductorTaskClass, ConductorTopology, ConductorTurnContext, OwnedRouteDecision,
    PrivacyLane, WorkerSelector,
};

/// The only JSON schema this implementation accepts.
pub const SUPPORTED_CORPUS_SCHEMA_VERSION: u32 = 1;

/// In-repo synthetic core. Versioned JSON; contains no user text.
pub const SYNTHETIC_CORE_JSON: &str =
    include_str!("../../resources/conductor_eval/synthetic_core_v1.json");

const F12_MIN_RELATIVE_IMPROVEMENT: f64 = 0.05;
const F12_SIGNIFICANCE_ALPHA: f64 = 0.05;
const FLOAT_EPSILON: f64 = 1.0e-12;
const MAX_REAL_SAMPLE_EXCERPT_CHARS: usize = 512;

/// Versioned routing corpus consumed by [`score`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Corpus {
    pub schema_version: u32,
    pub corpus_version: String,
    /// Human annotator id for `ideal_route`. M2 starts single-annotator (David).
    pub annotator: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    pub entries: Vec<CorpusEntry>,
}

impl Corpus {
    /// Parse + validate a corpus JSON document.
    pub fn from_json_str(json: &str) -> Result<Self, CorpusError> {
        let corpus: Self = serde_json::from_str(json)?;
        corpus.validate()?;
        Ok(corpus)
    }

    /// Load the committed synthetic core corpus.
    pub fn synthetic_core() -> Result<Self, CorpusError> {
        Self::from_json_str(SYNTHETIC_CORE_JSON)
    }

    /// Validate schema/version invariants and duplicate ids.
    pub fn validate(&self) -> Result<(), CorpusError> {
        if self.schema_version != SUPPORTED_CORPUS_SCHEMA_VERSION {
            return Err(CorpusError::UnsupportedSchemaVersion {
                found: self.schema_version,
                supported: SUPPORTED_CORPUS_SCHEMA_VERSION,
            });
        }

        let mut seen_ids = std::collections::BTreeSet::new();
        for entry in &self.entries {
            if entry.id.trim().is_empty() {
                return Err(CorpusError::EmptyEntryId);
            }
            if !seen_ids.insert(entry.id.clone()) {
                return Err(CorpusError::DuplicateEntryId {
                    id: entry.id.clone(),
                });
            }
            if entry.source == CorpusEntrySource::SyntheticCore
                && entry.redacted_text_excerpt.is_some()
            {
                return Err(CorpusError::SyntheticEntryCarriesText {
                    id: entry.id.clone(),
                });
            }
        }
        Ok(())
    }

    /// Append a real sample after membrane-scrubbing the raw text in memory.
    ///
    /// The raw text is never stored on `CorpusEntry`: this method runs
    /// `redact_for_storage`, `should_block_remote_egress`, and `scan` before it
    /// returns a serializable entry.
    pub fn append_scrubbed_real_sample(
        &mut self,
        draft: RealSampleDraft,
    ) -> Result<CorpusEntry, CorpusError> {
        let entry = CorpusEntry::from_scrubbed_real_sample(draft)?;
        self.entries.push(entry.clone());
        self.validate()?;
        Ok(entry)
    }

    /// Serialize the current corpus to disk as pretty JSON.
    pub fn write_json_file(&self, path: impl AsRef<Path>) -> Result<(), CorpusError> {
        let bytes = serde_json::to_vec_pretty(self)?;
        fs::write(path, bytes)?;
        Ok(())
    }

    /// Append a membrane-scrubbed real sample, then write the corpus to disk.
    ///
    /// This is the safe ingestion seam for periodically refreshed real samples:
    /// scrub first, persist second.
    pub fn append_scrubbed_real_sample_to_file(
        &mut self,
        path: impl AsRef<Path>,
        draft: RealSampleDraft,
    ) -> Result<CorpusEntry, CorpusError> {
        let entry = self.append_scrubbed_real_sample(draft)?;
        self.write_json_file(path)?;
        Ok(entry)
    }
}

/// Source bucket for an eval entry. Real samples must be membrane-scrubbed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CorpusEntrySource {
    SyntheticCore,
    RealSample,
}

/// One routing example. No raw prompt text is needed to score it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CorpusEntry {
    pub id: String,
    pub source: CorpusEntrySource,
    pub task_class: ConductorTaskClass,
    #[serde(default)]
    pub feature_predicates: Vec<String>,
    #[serde(default = "default_privacy_lane")]
    pub privacy_lane: PrivacyLane,
    #[serde(default)]
    pub available_workers: Vec<WorkerSelector>,
    pub ideal_route: IdealRouteLabel,
    /// Optional, bounded, membrane-redacted audit excerpt for refreshed real
    /// samples. Synthetic entries must leave this absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub redacted_text_excerpt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub membrane: Option<RealSampleMembraneAudit>,
}

impl CorpusEntry {
    fn from_scrubbed_real_sample(draft: RealSampleDraft) -> Result<Self, CorpusError> {
        let remote_egress_blocked = should_block_remote_egress(&draft.raw_text);
        let scan_result = scan(&draft.raw_text);
        let redacted = redact_for_storage(&draft.raw_text);
        if remote_egress_blocked && redacted == draft.raw_text {
            return Err(CorpusError::RedactionInvariant {
                id: draft.id.clone(),
            });
        }

        Ok(Self {
            id: draft.id,
            source: CorpusEntrySource::RealSample,
            task_class: draft.task_class,
            feature_predicates: draft.feature_predicates,
            privacy_lane: draft.privacy_lane,
            available_workers: draft.available_workers,
            ideal_route: draft.ideal_route,
            redacted_text_excerpt: Some(bounded_excerpt(&redacted)),
            membrane: Some(RealSampleMembraneAudit {
                remote_egress_blocked,
                sensitivity_labels: scan_result.matched_labels,
            }),
        })
    }

    fn to_turn_context(&self, corpus_version: &str) -> ConductorTurnContext {
        ConductorTurnContext {
            request_id: format!("eval:{corpus_version}:{}", self.id),
            task_class: self.task_class,
            feature_predicates: self.feature_predicates.clone(),
            privacy_lane: self.privacy_lane,
            available_workers: self.available_workers.clone(),
            working_directory: None,
            deadline_ms: None,
            route_hint: None,
        }
    }
}

fn default_privacy_lane() -> PrivacyLane {
    PrivacyLane::LocalOnly
}

fn bounded_excerpt(text: &str) -> String {
    text.chars().take(MAX_REAL_SAMPLE_EXCERPT_CHARS).collect()
}

/// Real-sample draft. The raw text is consumed in memory and never stored.
#[derive(Debug, Clone, PartialEq)]
pub struct RealSampleDraft {
    pub id: String,
    pub task_class: ConductorTaskClass,
    pub feature_predicates: Vec<String>,
    pub privacy_lane: PrivacyLane,
    pub available_workers: Vec<WorkerSelector>,
    pub ideal_route: IdealRouteLabel,
    pub raw_text: String,
}

/// Structured membrane result stored with a real-sample entry. Labels only.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RealSampleMembraneAudit {
    pub remote_egress_blocked: bool,
    #[serde(default)]
    pub sensitivity_labels: Vec<String>,
}

/// Ideal route label for a corpus example.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IdealRouteLabel {
    pub recipe_id: String,
    pub topology: ConductorTopology,
    pub worker_id: String,
    #[serde(default)]
    pub approval: IdealApprovalLabel,
}

/// Label-level approval comparison. Standing grants intentionally ignore the
/// opaque grant id so provisioned-provider ids cannot leak into the corpus.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum IdealApprovalLabel {
    #[default]
    None,
    StandingGrant,
    PerTurn,
}

impl IdealApprovalLabel {
    fn matches(self, approval: &ApprovalClass) -> bool {
        matches!(
            (self, approval),
            (IdealApprovalLabel::None, ApprovalClass::None)
                | (
                    IdealApprovalLabel::StandingGrant,
                    ApprovalClass::StandingGrant(_)
                )
                | (IdealApprovalLabel::PerTurn, ApprovalClass::PerTurn)
        )
    }
}

/// Measured dimensions that contribute to route correctness.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RoutingDimension {
    RecipeId,
    Topology,
    WorkerId,
    TaskClass,
    Approval,
}

/// Accuracy for one measured dimension.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DimensionScore {
    pub correct: u64,
    pub total: u64,
    pub accuracy: f64,
}

#[derive(Debug, Clone, Copy, Default)]
struct DimensionCounter {
    correct: u64,
    total: u64,
}

impl DimensionCounter {
    fn record(&mut self, correct: bool) {
        self.total = self.total.saturating_add(1);
        if correct {
            self.correct = self.correct.saturating_add(1);
        }
    }

    fn into_score(self) -> DimensionScore {
        DimensionScore {
            correct: self.correct,
            total: self.total,
            accuracy: accuracy(self.correct, self.total),
        }
    }
}

/// Per-case outcome retained so F-12 can run a paired significance test.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RoutingCaseOutcome {
    pub entry_id: String,
    pub route_correct: bool,
    pub dimension_correct: BTreeMap<RoutingDimension, bool>,
}

/// Score returned by [`score`]. Contains aggregate accuracy plus the paired
/// per-case outcomes required by [`is_improvement`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RoutingScore {
    pub corpus_version: String,
    pub sample_size: u64,
    pub correct_routes: u64,
    pub routing_accuracy: f64,
    pub dimensions: BTreeMap<RoutingDimension, DimensionScore>,
    pub case_outcomes: Vec<RoutingCaseOutcome>,
}

impl RoutingScore {
    /// Candidate-minus-baseline deltas for the route and each measured
    /// dimension. This is the per-dimension signal M2 can log/inspect; promotion
    /// must still go through [`is_improvement`].
    pub fn deltas_from(&self, baseline: &RoutingScore) -> RoutingScoreDelta {
        let mut dimension_deltas = BTreeMap::new();
        for (dimension, candidate_score) in &self.dimensions {
            if let Some(baseline_score) = baseline.dimensions.get(dimension) {
                dimension_deltas.insert(
                    *dimension,
                    candidate_score.accuracy - baseline_score.accuracy,
                );
            }
        }
        RoutingScoreDelta {
            routing_accuracy_delta: self.routing_accuracy - baseline.routing_accuracy,
            routing_accuracy_relative_delta: relative_improvement(
                baseline.routing_accuracy,
                self.routing_accuracy,
            ),
            dimension_deltas,
        }
    }
}

/// Candidate-minus-baseline routing score deltas.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RoutingScoreDelta {
    pub routing_accuracy_delta: f64,
    /// `None` means the baseline was zero and relative improvement is undefined.
    pub routing_accuracy_relative_delta: Option<f64>,
    pub dimension_deltas: BTreeMap<RoutingDimension, f64>,
}

/// Stateless scorer namespace for M2 aggregator call sites.
#[derive(Debug, Clone, Copy, Default)]
pub struct RoutingScorer;

impl RoutingScorer {
    pub fn score(corpus: &Corpus, policy: &dyn ConductorRoutingPolicy) -> RoutingScore {
        score(corpus, policy)
    }

    pub fn is_improvement(baseline: &RoutingScore, candidate: &RoutingScore) -> bool {
        is_improvement(baseline, candidate)
    }
}

/// Score a routing policy against a versioned corpus.
pub fn score(corpus: &Corpus, policy: &dyn ConductorRoutingPolicy) -> RoutingScore {
    let mut correct_routes = 0_u64;
    let mut dimension_counters: BTreeMap<RoutingDimension, DimensionCounter> = BTreeMap::new();
    let mut case_outcomes = Vec::with_capacity(corpus.entries.len());

    for entry in &corpus.entries {
        let ctx = entry.to_turn_context(&corpus.corpus_version);
        let decision = policy.decide(&ctx);
        let dimension_correct = dimension_correctness(entry, &decision);
        let route_correct = dimension_correct.values().all(|correct| *correct);
        if route_correct {
            correct_routes = correct_routes.saturating_add(1);
        }
        for (dimension, correct) in &dimension_correct {
            dimension_counters
                .entry(*dimension)
                .or_default()
                .record(*correct);
        }
        case_outcomes.push(RoutingCaseOutcome {
            entry_id: entry.id.clone(),
            route_correct,
            dimension_correct,
        });
    }

    let sample_size = corpus.entries.len() as u64;
    let dimensions = dimension_counters
        .into_iter()
        .map(|(dimension, counter)| (dimension, counter.into_score()))
        .collect();

    RoutingScore {
        corpus_version: corpus.corpus_version.clone(),
        sample_size,
        correct_routes,
        routing_accuracy: accuracy(correct_routes, sample_size),
        dimensions,
        case_outcomes,
    }
}

fn dimension_correctness(
    entry: &CorpusEntry,
    decision: &OwnedRouteDecision,
) -> BTreeMap<RoutingDimension, bool> {
    let mut results = BTreeMap::new();
    results.insert(
        RoutingDimension::RecipeId,
        decision.recipe_id == entry.ideal_route.recipe_id,
    );
    results.insert(
        RoutingDimension::Topology,
        decision.topology == entry.ideal_route.topology,
    );
    results.insert(
        RoutingDimension::WorkerId,
        decision.worker_id == entry.ideal_route.worker_id,
    );
    results.insert(
        RoutingDimension::TaskClass,
        decision.task_class == entry.task_class,
    );
    results.insert(
        RoutingDimension::Approval,
        entry.ideal_route.approval.matches(&decision.approval),
    );
    results
}

fn accuracy(correct: u64, total: u64) -> f64 {
    if total == 0 {
        0.0
    } else {
        correct as f64 / total as f64
    }
}

/// F-12 promotion predicate: statistically significant AND >=5% relative
/// improvement AND no measured-dimension regression.
pub fn is_improvement(baseline: &RoutingScore, candidate: &RoutingScore) -> bool {
    if baseline.corpus_version != candidate.corpus_version {
        return false;
    }
    if candidate.routing_accuracy <= baseline.routing_accuracy + FLOAT_EPSILON {
        return false;
    }
    if !has_min_relative_improvement(baseline.routing_accuracy, candidate.routing_accuracy) {
        return false;
    }
    if !has_no_dimension_regression(baseline, candidate) {
        return false;
    }
    statistically_significant_route_delta(baseline, candidate)
}

fn has_min_relative_improvement(baseline_accuracy: f64, candidate_accuracy: f64) -> bool {
    match relative_improvement(baseline_accuracy, candidate_accuracy) {
        Some(relative) => relative + FLOAT_EPSILON >= F12_MIN_RELATIVE_IMPROVEMENT,
        None => candidate_accuracy > baseline_accuracy + FLOAT_EPSILON,
    }
}

fn relative_improvement(baseline_accuracy: f64, candidate_accuracy: f64) -> Option<f64> {
    let delta = candidate_accuracy - baseline_accuracy;
    if baseline_accuracy.abs() <= FLOAT_EPSILON {
        None
    } else {
        Some(delta / baseline_accuracy)
    }
}

fn has_no_dimension_regression(baseline: &RoutingScore, candidate: &RoutingScore) -> bool {
    for (dimension, baseline_score) in &baseline.dimensions {
        if baseline_score.total == 0 {
            continue;
        }
        let Some(candidate_score) = candidate.dimensions.get(dimension) else {
            return false;
        };
        if candidate_score.accuracy + FLOAT_EPSILON < baseline_score.accuracy {
            return false;
        }
    }
    true
}

fn statistically_significant_route_delta(
    baseline: &RoutingScore,
    candidate: &RoutingScore,
) -> bool {
    let Some(disagreements) = paired_route_disagreements(baseline, candidate) else {
        return false;
    };
    if disagreements.baseline_wrong_candidate_right <= disagreements.baseline_right_candidate_wrong
    {
        return false;
    }
    mcnemar_exact_two_sided_p_value(
        disagreements.baseline_wrong_candidate_right,
        disagreements.baseline_right_candidate_wrong,
    ) <= F12_SIGNIFICANCE_ALPHA
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PairedDisagreements {
    baseline_wrong_candidate_right: u64,
    baseline_right_candidate_wrong: u64,
}

fn paired_route_disagreements(
    baseline: &RoutingScore,
    candidate: &RoutingScore,
) -> Option<PairedDisagreements> {
    if baseline.sample_size != candidate.sample_size {
        return None;
    }

    let baseline_by_id: BTreeMap<&str, bool> = baseline
        .case_outcomes
        .iter()
        .map(|outcome| (outcome.entry_id.as_str(), outcome.route_correct))
        .collect();

    let mut paired = 0_u64;
    let mut baseline_wrong_candidate_right = 0_u64;
    let mut baseline_right_candidate_wrong = 0_u64;

    for candidate_outcome in &candidate.case_outcomes {
        let baseline_correct = baseline_by_id.get(candidate_outcome.entry_id.as_str())?;
        paired = paired.saturating_add(1);
        match (*baseline_correct, candidate_outcome.route_correct) {
            (false, true) => {
                baseline_wrong_candidate_right = baseline_wrong_candidate_right.saturating_add(1);
            }
            (true, false) => {
                baseline_right_candidate_wrong = baseline_right_candidate_wrong.saturating_add(1);
            }
            _ => {}
        }
    }

    if paired != baseline.sample_size {
        return None;
    }

    Some(PairedDisagreements {
        baseline_wrong_candidate_right,
        baseline_right_candidate_wrong,
    })
}

fn mcnemar_exact_two_sided_p_value(improvements: u64, regressions: u64) -> f64 {
    let total = improvements.saturating_add(regressions);
    if total == 0 {
        return 1.0;
    }
    let lower_tail_count = improvements.min(regressions);
    (2.0 * binomial_half_cdf(lower_tail_count, total)).min(1.0)
}

fn binomial_half_cdf(k: u64, n: u64) -> f64 {
    if n <= 1024 {
        return binomial_half_cdf_recurrence(k, n);
    }
    binomial_half_cdf_logsum(k, n)
}

fn binomial_half_cdf_recurrence(k: u64, n: u64) -> f64 {
    let mut term = 2.0_f64.powi(-(n as i32));
    let mut sum = term;
    let mut i = 1_u64;
    while i <= k {
        term *= (n - i + 1) as f64 / i as f64;
        sum += term;
        i = i.saturating_add(1);
    }
    sum
}

fn binomial_half_cdf_logsum(k: u64, n: u64) -> f64 {
    let mut max_log = f64::NEG_INFINITY;
    let mut i = 0_u64;
    while i <= k {
        let log_p = log_binomial_probability_half(n, i);
        if log_p > max_log {
            max_log = log_p;
        }
        i = i.saturating_add(1);
    }

    let mut scaled_sum = 0.0_f64;
    let mut j = 0_u64;
    while j <= k {
        scaled_sum += (log_binomial_probability_half(n, j) - max_log).exp();
        j = j.saturating_add(1);
    }
    (max_log + scaled_sum.ln()).exp()
}

fn log_binomial_probability_half(n: u64, k: u64) -> f64 {
    log_factorial(n) - log_factorial(k) - log_factorial(n - k) - (n as f64) * std::f64::consts::LN_2
}

fn log_factorial(n: u64) -> f64 {
    let mut sum = 0.0_f64;
    let mut i = 2_u64;
    while i <= n {
        sum += (i as f64).ln();
        i = i.saturating_add(1);
    }
    sum
}

/// Corpus parse/ingestion failures.
#[derive(Debug, thiserror::Error)]
pub enum CorpusError {
    #[error("corpus JSON parse failed: {0}")]
    Json(#[from] serde_json::Error),
    #[error("corpus I/O failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("unsupported corpus schema_version {found}; supported {supported}")]
    UnsupportedSchemaVersion { found: u32, supported: u32 },
    #[error("corpus entry id must not be empty")]
    EmptyEntryId,
    #[error("duplicate corpus entry id {id}")]
    DuplicateEntryId { id: String },
    #[error("synthetic corpus entry {id} carries text; synthetic entries must be metadata-only")]
    SyntheticEntryCarriesText { id: String },
    #[error("real sample {id} was remote-egress-blocked but redaction made no change")]
    RedactionInvariant { id: String },
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conductor::policy::{StaticDirectPolicy, STATIC_DIRECT_RECIPE_ID};
    use crate::conductor::workers::LOCAL_MODEL_WORKER_ID;

    fn route_label(
        recipe_id: &str,
        topology: ConductorTopology,
        worker_id: &str,
    ) -> IdealRouteLabel {
        IdealRouteLabel {
            recipe_id: recipe_id.to_string(),
            topology,
            worker_id: worker_id.to_string(),
            approval: IdealApprovalLabel::None,
        }
    }

    #[test]
    fn synthetic_core_static_direct_score_is_stable() {
        let corpus = Corpus::synthetic_core().expect("synthetic core parses");
        assert_eq!(corpus.schema_version, 1);
        assert_eq!(corpus.entries.len(), 10);

        let score = score(&corpus, &StaticDirectPolicy);
        assert_eq!(score.sample_size, 10);
        assert_eq!(score.correct_routes, 6);
        assert_eq!(score.routing_accuracy, 0.6);

        let recipe = score
            .dimensions
            .get(&RoutingDimension::RecipeId)
            .expect("recipe dimension");
        assert_eq!(recipe.correct, 6);
        assert_eq!(recipe.total, 10);
        assert_eq!(recipe.accuracy, 0.6);

        let task_class = score
            .dimensions
            .get(&RoutingDimension::TaskClass)
            .expect("task class dimension");
        assert_eq!(task_class.correct, 10);
        assert_eq!(task_class.accuracy, 1.0);
    }

    #[test]
    fn improvement_rejects_sub_five_percent_relative_gain() {
        let baseline = manual_score(1000, 800, 0.80);
        let candidate = manual_score(1000, 839, 0.84);
        assert!(!is_improvement(&baseline, &candidate));
    }

    #[test]
    fn improvement_rejects_single_dimension_regression() {
        let baseline = manual_score(1000, 800, 0.80);
        let candidate = manual_score(1000, 860, 0.79);
        assert!(!is_improvement(&baseline, &candidate));
    }

    #[test]
    fn improvement_rejects_statistically_insignificant_delta() {
        let baseline = manual_score(100, 45, 0.45);
        let candidate = manual_score(100, 50, 0.50);
        assert!(!is_improvement(&baseline, &candidate));
    }

    #[test]
    fn improvement_accepts_strong_significant_non_regressing_gain() {
        let baseline = manual_score(1000, 800, 0.80);
        let candidate = manual_score(1000, 860, 0.86);
        assert!(is_improvement(&baseline, &candidate));
    }

    #[test]
    fn real_sample_ingestion_redacts_before_disk_write() {
        let mut corpus = Corpus {
            schema_version: SUPPORTED_CORPUS_SCHEMA_VERSION,
            corpus_version: "conductor-routing-hybrid.v1.test".to_string(),
            annotator: "david".to_string(),
            notes: None,
            entries: Vec::new(),
        };
        let draft = RealSampleDraft {
            id: "real.credential.001".to_string(),
            task_class: ConductorTaskClass::PersonalData,
            feature_predicates: vec!["credential_shaped".to_string()],
            privacy_lane: PrivacyLane::RemoteAllowed,
            available_workers: Vec::new(),
            ideal_route: route_label(
                STATIC_DIRECT_RECIPE_ID,
                ConductorTopology::Direct,
                LOCAL_MODEL_WORKER_ID,
            ),
            raw_text: "Please debug this. API key is sk-abcdefghijklmnopqrstuvwxyz".to_string(),
        };

        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("real_samples.json");
        let entry = corpus
            .append_scrubbed_real_sample_to_file(&path, draft)
            .expect("ingest real sample");
        let stored = fs::read_to_string(path).expect("read stored corpus");

        assert!(entry
            .redacted_text_excerpt
            .as_ref()
            .expect("redacted excerpt")
            .contains("[REDACTED_SENSITIVE]"));
        assert!(!stored.contains("sk-abcdefghijklmnopqrstuvwxyz"));
        assert!(stored.contains("[REDACTED_SENSITIVE]"));
        assert!(stored.contains("api_key_assignment"));
    }

    fn manual_score(total: u64, correct: u64, worker_dimension_accuracy: f64) -> RoutingScore {
        let mut case_outcomes = Vec::new();
        let mut i = 0_u64;
        while i < total {
            case_outcomes.push(RoutingCaseOutcome {
                entry_id: format!("case-{i:04}"),
                route_correct: i < correct,
                dimension_correct: BTreeMap::new(),
            });
            i += 1;
        }
        let worker_correct = (worker_dimension_accuracy * total as f64).round() as u64;
        let mut dimensions = BTreeMap::new();
        for dimension in [
            RoutingDimension::RecipeId,
            RoutingDimension::Topology,
            RoutingDimension::WorkerId,
            RoutingDimension::TaskClass,
            RoutingDimension::Approval,
        ] {
            let dimension_correct = if dimension == RoutingDimension::WorkerId {
                worker_correct
            } else {
                correct
            };
            dimensions.insert(
                dimension,
                DimensionScore {
                    correct: dimension_correct,
                    total,
                    accuracy: accuracy(dimension_correct, total),
                },
            );
        }
        RoutingScore {
            corpus_version: "conductor-routing-hybrid.v1.test".to_string(),
            sample_size: total,
            correct_routes: correct,
            routing_accuracy: accuracy(correct, total),
            dimensions,
            case_outcomes,
        }
    }
}
