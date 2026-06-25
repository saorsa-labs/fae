#![forbid(unsafe_code)]

use std::time::Duration;

use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

/// A single benchmark evaluation dimension.
///
/// Mirrors Swift `EvalDimension` and maps one-to-one to the benchmark suites used
/// by the legacy runtime.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EvalDimension {
    /// Tool call structure, name, and argument accuracy.
    ToolCalling,
    /// Tool judgment, instruction following, summarization, and memory.
    FaeCapability,
    /// Advanced tool judgment, memory discipline, and result handling.
    AssistantFit,
    /// JSON/XML/YAML structured output quality.
    Serialization,
}

/// Benchmark scores across all evaluated dimensions (`0.0..=1.0` each).
///
/// Used as both absolute scores and deltas. When representing deltas, positive
/// values indicate improvement.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DimensionScores {
    pub tool_calling: Option<f64>,
    pub fae_capability: Option<f64>,
    pub assistant_fit: Option<f64>,
    pub serialization: Option<f64>,
}

impl DimensionScores {
    /// All-unmeasured scores for cases where no benchmark result is available.
    pub const EMPTY: Self = Self {
        tool_calling: None,
        fae_capability: None,
        assistant_fit: None,
        serialization: None,
    };

    /// Compute per-dimension delta (`self - baseline`). Positive = improvement.
    pub fn improvement(self, baseline: Self) -> Self {
        Self {
            tool_calling: numeric_delta(self.tool_calling, baseline.tool_calling),
            fae_capability: numeric_delta(self.fae_capability, baseline.fae_capability),
            assistant_fit: numeric_delta(self.assistant_fit, baseline.assistant_fit),
            serialization: numeric_delta(self.serialization, baseline.serialization),
        }
    }

    /// True if any measured dimension regressed more than `threshold`.
    pub fn any_regression(self, baseline: Self, threshold: f64) -> bool {
        let delta = self.improvement(baseline);
        [
            delta.tool_calling,
            delta.fae_capability,
            delta.assistant_fit,
            delta.serialization,
        ]
        .into_iter()
        .flatten()
        .any(|value| value < -threshold)
    }

    /// True if `dimension` improved by at least `threshold`.
    pub fn improved(self, dimension: EvalDimension, baseline: Self, threshold: f64) -> bool {
        let delta = self.improvement(baseline);
        delta.score(dimension).map_or(0.0, std::convert::identity) >= threshold
    }

    /// Read one score by dimension.
    pub fn score(self, dimension: EvalDimension) -> Option<f64> {
        match dimension {
            EvalDimension::ToolCalling => self.tool_calling,
            EvalDimension::FaeCapability => self.fae_capability,
            EvalDimension::AssistantFit => self.assistant_fit,
            EvalDimension::Serialization => self.serialization,
        }
    }
}

fn numeric_delta(after: Option<f64>, before: Option<f64>) -> Option<f64> {
    match (after, before) {
        (Some(after), Some(before)) => Some(after - before),
        _ => None,
    }
}

/// A runtime-mutable surface that MetaOpt can modify.
///
/// Scope boundary: the four Swift surfaces are ported exactly. There is
/// deliberately no conductor-recipe surface here; that is gated on the ADR-008
/// amendment for M3.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MetaOptSurface {
    /// Append or modify instructions in directive.md.
    Directive,
    /// Adjust a config.toml knob.
    ConfigKnob,
    /// Create or modify an instruction-only skill.
    Skill,
    /// Seed a strategic meta-memory via the memory seam.
    MemorySeed,
}

/// A concrete change to apply to a mutable surface.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum MetaOptChange {
    /// Append text to directive.md.
    DirectiveAmendment { amendment: String },
    /// Set a config key to a new value, remembering the old value for rollback.
    ConfigAdjustment {
        key: String,
        old_value: String,
        new_value: String,
    },
    /// Create an instruction-only skill and activate it.
    SkillCreation {
        name: String,
        description: String,
        body: String,
    },
    /// Insert a strategic fact into memory that shapes recall-driven behavior.
    MemorySeedInsertion { text: String, tags: Vec<String> },
}

impl MetaOptChange {
    /// The mutable surface targeted by this concrete change.
    pub fn surface(&self) -> MetaOptSurface {
        match self {
            Self::DirectiveAmendment { .. } => MetaOptSurface::Directive,
            Self::ConfigAdjustment { .. } => MetaOptSurface::ConfigKnob,
            Self::SkillCreation { .. } => MetaOptSurface::Skill,
            Self::MemorySeedInsertion { .. } => MetaOptSurface::MemorySeed,
        }
    }
}

/// A candidate change proposed by a hypothesis source.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MetaOptHypothesis {
    /// Unique identifier for this hypothesis.
    pub id: Uuid,
    /// Which mutable surface this targets.
    pub surface: MetaOptSurface,
    /// Human-readable description of what this change does and why.
    pub description: String,
    /// Which benchmark dimension this change is expected to improve.
    pub target_dimension: EvalDimension,
    /// The actual change to apply.
    pub change: MetaOptChange,
    /// Number of feedback events supporting this hypothesis.
    pub evidence_count: usize,
}

/// The decision made about a tested hypothesis.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "decision", rename_all = "camelCase")]
pub enum MetaOptDecision {
    /// Keep the change — it improved scores.
    Keep { reason: String },
    /// Discard the change — it regressed, was neutral, or exceeded budget.
    Discard { reason: String },
}

impl MetaOptDecision {
    pub fn keep(reason: impl Into<String>) -> Self {
        Self::Keep {
            reason: reason.into(),
        }
    }

    pub fn discard(reason: impl Into<String>) -> Self {
        Self::Discard {
            reason: reason.into(),
        }
    }

    pub fn is_keep(&self) -> bool {
        matches!(self, Self::Keep { .. })
    }

    pub fn reason(&self) -> &str {
        match self {
            Self::Keep { reason } | Self::Discard { reason } => reason,
        }
    }
}

/// The outcome of testing a single hypothesis.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MetaOptResult {
    /// Which hypothesis was tested.
    pub hypothesis_id: Uuid,
    /// Which surface was modified.
    pub surface: MetaOptSurface,
    /// Human-readable description from the hypothesis.
    pub description: String,
    /// Which benchmark dimension this change targeted.
    pub target_dimension: EvalDimension,
    /// Scores before the change was applied.
    pub before_scores: DimensionScores,
    /// Scores after the change was applied.
    pub after_scores: DimensionScores,
    /// Per-dimension delta (`after - before`).
    pub delta: DimensionScores,
    /// Whether the change was kept.
    pub kept: bool,
    /// Reason for the decision.
    pub reason: String,
    /// Unix timestamp in milliseconds when this test was performed.
    pub timestamp_ms: u64,
}

/// Summary of a complete meta-optimization phase.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MetaOptSummary {
    /// Number of hypotheses that were tested.
    pub hypotheses_tested: usize,
    /// Number of changes that were kept.
    pub kept_count: usize,
    /// Number of changes that were discarded.
    pub discarded_count: usize,
    /// Total benchmark evaluation runs consumed, including the baseline run.
    pub total_benchmark_runs: usize,
    /// Wall-clock time for the entire phase in seconds.
    pub wall_clock_seconds: f64,
    /// Individual results for each tested hypothesis.
    pub results: Vec<MetaOptResult>,
}

impl MetaOptSummary {
    pub fn empty(total_benchmark_runs: usize, wall_clock_seconds: f64) -> Self {
        Self {
            hypotheses_tested: 0,
            kept_count: 0,
            discarded_count: 0,
            total_benchmark_runs,
            wall_clock_seconds,
            results: Vec::new(),
        }
    }
}

/// Resource budget for a single meta-optimization phase.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MetaOptBudget {
    /// Maximum number of benchmark evaluation runs per cycle.
    pub max_benchmark_runs: usize,
    /// Maximum wall-clock time for the meta-optimization phase.
    pub max_wall_clock: Duration,
    /// Stop after N consecutive discarded candidates (plateau detection).
    pub max_consecutive_discards: usize,
    /// Minimum target-dimension improvement required to keep a change.
    pub min_improvement_threshold: f64,
    /// Regression on any dimension exceeding this threshold triggers discard.
    pub regression_threshold: f64,
}

impl MetaOptBudget {
    /// Default budget for nightly meta-optimization.
    pub const fn standard() -> Self {
        Self {
            max_benchmark_runs: 10,
            max_wall_clock: Duration::from_secs(30 * 60),
            max_consecutive_discards: 3,
            min_improvement_threshold: 0.01,
            regression_threshold: 0.05,
        }
    }
}

impl Default for MetaOptBudget {
    fn default() -> Self {
        Self::standard()
    }
}

/// Safe bounds for a tunable config knob.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ConfigBound {
    /// Config key path, e.g. `llm.temperature`.
    pub key: &'static str,
    /// Minimum allowed value.
    pub min: f64,
    /// Maximum allowed value.
    pub max: f64,
    /// Minimum step size for adjustments.
    pub step: f64,
    /// Which benchmark dimension this knob primarily affects.
    pub target_dimension: EvalDimension,
}

impl ConfigBound {
    /// All tunable config knobs with their safe bounds.
    pub const fn all() -> &'static [Self] {
        CONFIG_BOUNDS
    }
}

const CONFIG_BOUNDS: &[ConfigBound] = &[
    ConfigBound {
        key: "llm.temperature",
        min: 0.1,
        max: 1.0,
        step: 0.1,
        target_dimension: EvalDimension::ToolCalling,
    },
    ConfigBound {
        key: "memory.maxRecallResults",
        min: 2.0,
        max: 12.0,
        step: 1.0,
        target_dimension: EvalDimension::FaeCapability,
    },
];

/// Minimal feedback event vocabulary accepted by hypothesis sources.
///
/// The Rust primitive does not include the Swift pattern or LLM-backed generators;
/// M3 wiring can adapt richer event stores into this provider-neutral shape.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FeedbackEvent {
    pub signal_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_input: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assistant_output: Option<String>,
}

/// Errors from the meta-optimization phase and its runtime seams.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum MetaOptError {
    /// Benchmark evaluation is not available.
    #[error("benchmark evaluation is not available")]
    BenchmarkNotAvailable,
    /// The benchmark runner is not set.
    #[error("benchmark runner is not configured")]
    TrainingBridgeNotAvailable,
    /// Failed to read or write the directive.
    #[error("directive I/O error: {0}")]
    DirectiveIoError(String),
    /// Failed to apply a config change.
    #[error("config change error: {0}")]
    ConfigChangeError(String),
    /// A protected config key (controls egress/safety posture — e.g. `model_mode` /
    /// `availability_mode`) was targeted for mutation. Hard reject — no write.
    /// (BLOCKER-1, M3 spec §3.1: Layer 1 proposal-time closure. The M2 §5 Layer 2
    /// runtime gates remain authoritative regardless of config content.)
    #[error("protected config key rejected: {0}")]
    ProtectedConfigKey(String),
    /// Failed to create, activate, or delete a skill.
    #[error("skill error: {0}")]
    SkillError(String),
    /// Failed to insert or delete a memory seed.
    #[error("memory seed error: {0}")]
    MemorySeedError(String),
    /// Failed to persist optimizer audit results.
    #[error("improvement store error: {0}")]
    ImprovementStoreError(String),
    /// Failed to generate candidate hypotheses.
    #[error("hypothesis source error: {0}")]
    HypothesisSourceError(String),
}
