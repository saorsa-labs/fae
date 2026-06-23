#![forbid(unsafe_code)]

use async_trait::async_trait;

use crate::types::{
    DimensionScores, FeedbackEvent, MetaOptError, MetaOptHypothesis, MetaOptResult, MetaOptSummary,
};

/// Context supplied to a hypothesis source for one optimizer run.
///
/// The source is deliberately abstract. Pattern-based, LLM-backed, or store-backed
/// generators can be wired later without coupling this primitive to a provider.
#[derive(Debug, Clone, PartialEq)]
pub struct HypothesisContext {
    pub events: Vec<FeedbackEvent>,
    pub current_directive: Option<String>,
    pub current_temperature: f64,
    pub current_max_recall: u32,
}

/// Produces candidate hypotheses for a run.
///
/// This replaces the Swift `MetaOptHypothesisGenerator` family as a seam. The
/// dormant Rust crate contains no LLM-coupled generator implementation.
#[async_trait]
pub trait HypothesisSource: Send + Sync {
    async fn generate_hypotheses(
        &self,
        context: HypothesisContext,
    ) -> Result<Vec<MetaOptHypothesis>, MetaOptError>;
}

/// Persist optimizer audit results.
#[async_trait]
pub trait ImprovementStore: Send + Sync {
    async fn persist_result(&self, result: &MetaOptResult) -> Result<(), MetaOptError>;

    async fn record_summary(&self, _summary: &MetaOptSummary) -> Result<(), MetaOptError> {
        Ok(())
    }
}

/// Runs benchmark evaluations for the current runtime state.
#[async_trait]
pub trait BenchmarkRunner: Send + Sync {
    async fn is_benchmark_available(&self) -> bool;

    async fn run_benchmark(
        &self,
        adapter_path: Option<&str>,
    ) -> Result<DimensionScores, MetaOptError>;
}

/// Reads and writes directive text.
#[async_trait]
pub trait DirectivePort: Send + Sync {
    async fn read_directive(&self) -> Result<Option<String>, MetaOptError>;

    async fn write_directive(&self, text: &str) -> Result<(), MetaOptError>;
}

/// Reads and writes tunable config knobs.
#[async_trait]
pub trait ConfigPort: Send + Sync {
    async fn read_config(&self, key: &str) -> Result<Option<String>, MetaOptError>;

    async fn write_config(&self, key: &str, value: &str) -> Result<(), MetaOptError>;
}

/// Creates, activates, deactivates, and deletes instruction-only skills.
#[async_trait]
pub trait SkillPort: Send + Sync {
    async fn create_skill(
        &self,
        name: &str,
        description: &str,
        body: &str,
    ) -> Result<(), MetaOptError>;

    async fn activate_skill(&self, name: &str) -> Result<(), MetaOptError>;

    async fn deactivate_skill(&self, name: &str) -> Result<(), MetaOptError>;

    async fn delete_skill(&self, name: &str) -> Result<(), MetaOptError>;
}

/// Opaque identifier returned after inserting a strategic memory seed.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct MemorySeedId(pub String);

/// Inserts and deletes strategic memory seeds.
#[async_trait]
pub trait MemorySeedPort: Send + Sync {
    async fn insert_seed(
        &self,
        text: &str,
        tags: &[String],
        confidence: f64,
        stale_after_secs: u64,
    ) -> Result<MemorySeedId, MetaOptError>;

    async fn delete_seed(&self, id: &MemorySeedId) -> Result<(), MetaOptError>;
}
