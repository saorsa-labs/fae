#![forbid(unsafe_code)]

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::conductor_recipe::is_protected_config_key;
use crate::traits::{
    BenchmarkRunner, ConfigPort, DirectivePort, HypothesisContext, HypothesisSource,
    ImprovementStore, MemorySeedPort, SkillPort,
};
use crate::types::{
    ConfigBound, DimensionScores, FeedbackEvent, MetaOptBudget, MetaOptChange, MetaOptDecision,
    MetaOptError, MetaOptHypothesis, MetaOptResult, MetaOptSummary,
};

const DEFAULT_TEMPERATURE: f64 = 0.7;
const DEFAULT_MAX_RECALL: u32 = 6;
const MAX_DIRECTIVE_SIZE_CHARS: usize = 4_000;
const MEMORY_SEED_CONFIDENCE: f64 = 0.8;
const MEMORY_SEED_STALE_AFTER_SECS: u64 = 30 * 24 * 3_600;

type RollbackFuture = Pin<Box<dyn Future<Output = Result<(), MetaOptError>> + Send + 'static>>;
type MetaOptRollback = Box<dyn FnOnce() -> RollbackFuture + Send + 'static>;

/// Dormant Rust port of the Swift `MetaOptimizer` actor.
///
/// The optimizer hill-climbs over candidate changes: apply one change, run a
/// benchmark, keep only if the target dimension improves without regressing any
/// other measured dimension, otherwise rollback immediately. No daemon or
/// scheduler path calls this crate yet.
pub struct MetaOptimizer {
    store: Arc<dyn ImprovementStore>,
    hypothesis_source: Arc<dyn HypothesisSource>,
    benchmark_runner: Option<Arc<dyn BenchmarkRunner>>,
    directive_port: Option<Arc<dyn DirectivePort>>,
    config_port: Option<Arc<dyn ConfigPort>>,
    skill_port: Option<Arc<dyn SkillPort>>,
    memory_seed_port: Option<Arc<dyn MemorySeedPort>>,
    current_adapter_path: Option<String>,
    last_kept_rollback: Option<MetaOptRollback>,
    last_kept_description: Option<String>,
    now_ms: Arc<dyn Fn() -> u64 + Send + Sync>,
}

impl MetaOptimizer {
    /// Create a dormant optimizer with the two non-optional seams.
    pub fn new(
        store: Arc<dyn ImprovementStore>,
        hypothesis_source: Arc<dyn HypothesisSource>,
    ) -> Self {
        Self {
            store,
            hypothesis_source,
            benchmark_runner: None,
            directive_port: None,
            config_port: None,
            skill_port: None,
            memory_seed_port: None,
            current_adapter_path: None,
            last_kept_rollback: None,
            last_kept_description: None,
            now_ms: Arc::new(system_now_ms),
        }
    }

    pub fn set_benchmark_runner(&mut self, runner: Arc<dyn BenchmarkRunner>) {
        self.benchmark_runner = Some(runner);
    }

    pub fn set_directive_port(&mut self, port: Arc<dyn DirectivePort>) {
        self.directive_port = Some(port);
    }

    pub fn set_config_port(&mut self, port: Arc<dyn ConfigPort>) {
        self.config_port = Some(port);
    }

    pub fn set_skill_port(&mut self, port: Arc<dyn SkillPort>) {
        self.skill_port = Some(port);
    }

    pub fn set_memory_seed_port(&mut self, port: Arc<dyn MemorySeedPort>) {
        self.memory_seed_port = Some(port);
    }

    pub fn set_current_adapter_path(&mut self, path: Option<String>) {
        self.current_adapter_path = path;
    }

    /// Run with the standard budget.
    pub async fn run_standard(
        &mut self,
        events: &[FeedbackEvent],
    ) -> Result<MetaOptSummary, MetaOptError> {
        self.run(events, MetaOptBudget::standard()).await
    }

    /// Run one meta-optimization phase.
    pub async fn run(
        &mut self,
        events: &[FeedbackEvent],
        budget: MetaOptBudget,
    ) -> Result<MetaOptSummary, MetaOptError> {
        let start = Instant::now();
        let Some(benchmark_runner) = self.benchmark_runner.clone() else {
            return Ok(MetaOptSummary::empty(0, 0.0));
        };
        if !benchmark_runner.is_benchmark_available().await {
            return Ok(MetaOptSummary::empty(0, 0.0));
        }

        let mut baseline = benchmark_runner
            .run_benchmark(self.current_adapter_path.as_deref())
            .await?;
        let mut benchmark_runs_used = 1;

        let context = HypothesisContext {
            events: events.to_vec(),
            current_directive: self.current_directive().await,
            current_temperature: self
                .current_config_f64("llm.temperature", DEFAULT_TEMPERATURE)
                .await,
            current_max_recall: self
                .current_config_u32("memory.maxRecallResults", DEFAULT_MAX_RECALL)
                .await,
        };
        let mut hypotheses = self.hypothesis_source.generate_hypotheses(context).await?;
        hypotheses.sort_by_key(|hypothesis| std::cmp::Reverse(hypothesis.evidence_count));

        if hypotheses.is_empty() {
            return Ok(MetaOptSummary::empty(
                benchmark_runs_used,
                start.elapsed().as_secs_f64(),
            ));
        }

        let mut kept_count = 0;
        let mut discarded_count = 0;
        let mut consecutive_discards = 0;
        let mut results = Vec::new();

        for hypothesis in hypotheses {
            if benchmark_runs_used >= budget.max_benchmark_runs {
                break;
            }
            if start.elapsed() >= budget.max_wall_clock {
                break;
            }
            if consecutive_discards >= budget.max_consecutive_discards {
                break;
            }

            let before_scores = baseline;
            let rollback = match self.apply_change(&hypothesis.change).await {
                Ok(rollback) => rollback,
                Err(_) => continue,
            };

            let after_scores = match benchmark_runner
                .run_benchmark(self.current_adapter_path.as_deref())
                .await
            {
                Ok(scores) => {
                    benchmark_runs_used += 1;
                    scores
                }
                Err(_) => {
                    let _rollback_result = rollback().await;
                    continue;
                }
            };

            let delta = after_scores.improvement(before_scores);
            let decision = Self::decide(&hypothesis, before_scores, after_scores, budget);
            let kept = decision.is_keep();
            let reason = decision.reason().to_owned();

            if kept {
                kept_count += 1;
                consecutive_discards = 0;
                baseline = after_scores;
                self.last_kept_rollback = Some(rollback);
                self.last_kept_description = Some(hypothesis.description.clone());
            } else {
                discarded_count += 1;
                consecutive_discards += 1;
                let _rollback_result = rollback().await;
            }

            // INTENTIONAL HARDENING over the Swift source (2026-06-23): Swift
            // mutates `baseline` before constructing `MetaOptResult`, which can
            // record the post-change score as `beforeScores` for kept changes.
            // This Rust port keeps an immutable `before_scores` snapshot so the
            // audit record and persisted delta cannot be corrupted by ordering.
            let result = MetaOptResult {
                hypothesis_id: hypothesis.id,
                surface: hypothesis.surface,
                description: hypothesis.description,
                target_dimension: hypothesis.target_dimension,
                before_scores,
                after_scores,
                delta,
                kept,
                reason,
                timestamp_ms: (self.now_ms)(),
            };
            let _persist_result = self.store.persist_result(&result).await;
            results.push(result);
        }

        let summary = MetaOptSummary {
            hypotheses_tested: results.len(),
            kept_count,
            discarded_count,
            total_benchmark_runs: benchmark_runs_used,
            wall_clock_seconds: start.elapsed().as_secs_f64(),
            results,
        };
        let _summary_result = self.store.record_summary(&summary).await;
        Ok(summary)
    }

    /// Decide whether to keep or discard a tested hypothesis.
    pub fn decide(
        hypothesis: &MetaOptHypothesis,
        baseline: DimensionScores,
        after_score: DimensionScores,
        budget: MetaOptBudget,
    ) -> MetaOptDecision {
        if after_score.any_regression(baseline, budget.regression_threshold) {
            return MetaOptDecision::discard("regression");
        }

        if after_score.improved(
            hypothesis.target_dimension,
            baseline,
            budget.min_improvement_threshold,
        ) {
            return MetaOptDecision::keep("improvement");
        }

        MetaOptDecision::discard("neutral")
    }

    /// Undo the most recently kept meta-optimization change.
    pub async fn rollback_last_change(&mut self) -> String {
        let Some(rollback) = self.last_kept_rollback.take() else {
            return "There's nothing to undo — I haven't made any recent adjustments.".to_owned();
        };
        let mut description = String::new();
        if let Some(value) = self.last_kept_description.take() {
            description = value;
        }

        match rollback().await {
            Ok(()) => describe_rollback(&description),
            Err(_) => {
                self.last_kept_description = Some(description);
                "I tried to undo the change but ran into a problem. You can try clearing the directive with 'clear my directive' as a workaround.".to_owned()
            }
        }
    }

    async fn apply_change(&self, change: &MetaOptChange) -> Result<MetaOptRollback, MetaOptError> {
        match change {
            MetaOptChange::DirectiveAmendment { amendment } => {
                let directive = self.directive_port.clone().ok_or_else(|| {
                    MetaOptError::DirectiveIoError(
                        "Directive reader/writer not configured".to_owned(),
                    )
                })?;

                // INTENTIONAL HARDENING over Swift (2026-06-23): the Swift port
                // treats a directive read error as an empty directive, which can
                // overwrite existing durable instructions. Rust fails closed so a
                // candidate cannot erase state when the read seam is unhealthy.
                let mut current_directive = String::new();
                if let Some(text) = directive.read_directive().await? {
                    current_directive = text;
                }
                let proposed_chars = current_directive
                    .chars()
                    .count()
                    .saturating_add(amendment.chars().count());
                if proposed_chars > MAX_DIRECTIVE_SIZE_CHARS {
                    return Err(MetaOptError::DirectiveIoError(format!(
                        "Directive would exceed {MAX_DIRECTIVE_SIZE_CHARS} char limit"
                    )));
                }

                let mut new_directive = current_directive.clone();
                new_directive.push_str(amendment);
                directive.write_directive(&new_directive).await?;

                Ok(Box::new(move || {
                    Box::pin(async move { directive.write_directive(&current_directive).await })
                }))
            }
            MetaOptChange::ConfigAdjustment {
                key,
                old_value,
                new_value,
            } => {
                // BLOCKER-1 (M3 spec §3.1): reject protected config keys at the TOP
                // of the arm — before port resolution, bounds lookup, and any write.
                // The bounds check below only fires for keys in `ConfigBound::all()`;
                // an unlisted key would otherwise be written verbatim — a latent hole
                // that goes live the moment fae-metaopt is wired into the daemon.
                // Conservative reject (spec §11 Q2): a false positive on a protected
                // pattern is correct; never bypass the gate.
                if is_protected_config_key(key) {
                    return Err(MetaOptError::ProtectedConfigKey(key.clone()));
                }

                let config = self.config_port.clone().ok_or_else(|| {
                    MetaOptError::ConfigChangeError("Config writer not configured".to_owned())
                })?;

                if let Some(bound) = ConfigBound::all().iter().find(|bound| bound.key == key) {
                    let parsed = new_value.parse::<f64>().map_err(|_| {
                        MetaOptError::ConfigChangeError(format!(
                            "Value {new_value} is not numeric for {key}"
                        ))
                    })?;
                    if parsed < bound.min || parsed > bound.max {
                        return Err(MetaOptError::ConfigChangeError(format!(
                            "Value {new_value} outside bounds [{}, {}] for {key}",
                            bound.min, bound.max
                        )));
                    }
                }

                config.write_config(key, new_value).await?;
                let rollback_key = key.clone();
                let rollback_value = old_value.clone();
                Ok(Box::new(move || {
                    Box::pin(
                        async move { config.write_config(&rollback_key, &rollback_value).await },
                    )
                }))
            }
            MetaOptChange::SkillCreation {
                name,
                description,
                body,
            } => {
                let skill = self.skill_port.clone().ok_or_else(|| {
                    MetaOptError::SkillError("SkillPort not configured".to_owned())
                })?;

                skill.create_skill(name, description, body).await?;
                if let Err(error) = skill.activate_skill(name).await {
                    // INTENTIONAL HARDENING over Swift (2026-06-23): activation
                    // is a required part of the tested runtime state. If it fails,
                    // delete the just-created skill before returning the error so
                    // an unmeasured skill cannot linger outside the keep gate.
                    let _delete_result = skill.delete_skill(name).await;
                    return Err(error);
                }

                let rollback_name = name.clone();
                Ok(Box::new(move || {
                    Box::pin(async move {
                        skill.deactivate_skill(&rollback_name).await?;
                        skill.delete_skill(&rollback_name).await
                    })
                }))
            }
            MetaOptChange::MemorySeedInsertion { text, tags } => {
                let memory = self.memory_seed_port.clone().ok_or_else(|| {
                    MetaOptError::MemorySeedError("MemorySeedPort not configured".to_owned())
                })?;
                let seed_id = memory
                    .insert_seed(
                        text,
                        tags,
                        MEMORY_SEED_CONFIDENCE,
                        MEMORY_SEED_STALE_AFTER_SECS,
                    )
                    .await?;

                Ok(Box::new(move || {
                    Box::pin(async move { memory.delete_seed(&seed_id).await })
                }))
            }
        }
    }

    async fn current_directive(&self) -> Option<String> {
        let port = self.directive_port.as_ref()?;
        port.read_directive().await.ok().flatten()
    }

    async fn current_config_f64(&self, key: &str, default: f64) -> f64 {
        self.current_config_value(key)
            .await
            .and_then(|value| value.parse::<f64>().ok())
            .map_or(default, std::convert::identity)
    }

    async fn current_config_u32(&self, key: &str, default: u32) -> u32 {
        self.current_config_value(key)
            .await
            .and_then(|value| value.parse::<u32>().ok())
            .map_or(default, std::convert::identity)
    }

    async fn current_config_value(&self, key: &str) -> Option<String> {
        let port = self.config_port.as_ref()?;
        port.read_config(key).await.ok().flatten()
    }

    #[cfg(test)]
    fn set_now_ms_for_test(&mut self, now_ms: u64) {
        self.now_ms = Arc::new(move || now_ms);
    }
}

fn describe_rollback(change_description: &str) -> String {
    let lower = change_description.to_lowercase();
    if lower.contains("temperature") || lower.contains("config") {
        return "Done — I've reverted that thinking adjustment. I'll go back to how I was before."
            .to_owned();
    }
    if lower.contains("concise") || lower.contains("brevity") || lower.contains("interruption") {
        return "Done — I've undone the brevity change. I'll be more detailed again.".to_owned();
    }
    if lower.contains("skill") || lower.contains("routine") {
        return "Done — I've removed that routine. It won't affect my responses anymore."
            .to_owned();
    }
    if lower.contains("memory") || lower.contains("seed") || lower.contains("note") {
        return "Done — I've forgotten that mental note. It won't come up in our conversations."
            .to_owned();
    }
    "Done — I've undone my last overnight adjustment. Things should feel like before.".to_owned()
}

fn system_now_ms() -> u64 {
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => duration_ms_saturating(duration),
        Err(_) => 0,
    }
}

fn duration_ms_saturating(duration: Duration) -> u64 {
    let millis = duration.as_millis();
    if millis > u128::from(u64::MAX) {
        u64::MAX
    } else {
        millis as u64
    }
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, BTreeSet, VecDeque};

    use async_trait::async_trait;
    use tokio::sync::Mutex;
    use uuid::Uuid;

    use super::*;
    use crate::traits::MemorySeedId;
    use crate::types::EvalDimension;

    #[derive(Default)]
    struct NullState {
        directive: String,
        config: BTreeMap<String, String>,
        skills: BTreeMap<String, String>,
        active_skills: BTreeSet<String>,
        seeds: BTreeMap<String, (String, Vec<String>)>,
        next_seed_id: u64,
        persisted_results: Vec<MetaOptResult>,
        recorded_summaries: Vec<MetaOptSummary>,
        hypotheses: Vec<MetaOptHypothesis>,
        benchmark_scores: VecDeque<DimensionScores>,
        benchmark_available: bool,
        rollback_writes: usize,
    }

    #[derive(Clone, Default)]
    struct NullMetaOptDeps {
        state: Arc<Mutex<NullState>>,
    }

    impl NullMetaOptDeps {
        async fn with_state(mutator: impl FnOnce(&mut NullState)) -> Self {
            let deps = Self::default();
            {
                let mut state = deps.state.lock().await;
                state.benchmark_available = true;
                mutator(&mut state);
            }
            deps
        }

        fn optimizer(deps: &Arc<Self>) -> MetaOptimizer {
            let store: Arc<dyn ImprovementStore> = deps.clone();
            let source: Arc<dyn HypothesisSource> = deps.clone();
            let mut optimizer = MetaOptimizer::new(store, source);
            let benchmark: Arc<dyn BenchmarkRunner> = deps.clone();
            let directive: Arc<dyn DirectivePort> = deps.clone();
            let config: Arc<dyn ConfigPort> = deps.clone();
            let skill: Arc<dyn SkillPort> = deps.clone();
            let memory: Arc<dyn MemorySeedPort> = deps.clone();
            optimizer.set_benchmark_runner(benchmark);
            optimizer.set_directive_port(directive);
            optimizer.set_config_port(config);
            optimizer.set_skill_port(skill);
            optimizer.set_memory_seed_port(memory);
            optimizer.set_now_ms_for_test(1_234);
            optimizer
        }

        async fn snapshot(&self) -> NullSnapshot {
            let state = self.state.lock().await;
            NullSnapshot {
                directive: state.directive.clone(),
                config: state.config.clone(),
                skills: state.skills.clone(),
                active_skills: state.active_skills.clone(),
                seeds: state.seeds.clone(),
                persisted_results: state.persisted_results.clone(),
                recorded_summaries: state.recorded_summaries.clone(),
                rollback_writes: state.rollback_writes,
            }
        }
    }

    struct NullSnapshot {
        directive: String,
        config: BTreeMap<String, String>,
        skills: BTreeMap<String, String>,
        active_skills: BTreeSet<String>,
        seeds: BTreeMap<String, (String, Vec<String>)>,
        persisted_results: Vec<MetaOptResult>,
        recorded_summaries: Vec<MetaOptSummary>,
        rollback_writes: usize,
    }

    #[async_trait]
    impl ImprovementStore for NullMetaOptDeps {
        async fn persist_result(&self, result: &MetaOptResult) -> Result<(), MetaOptError> {
            self.state
                .lock()
                .await
                .persisted_results
                .push(result.clone());
            Ok(())
        }

        async fn record_summary(&self, summary: &MetaOptSummary) -> Result<(), MetaOptError> {
            self.state
                .lock()
                .await
                .recorded_summaries
                .push(summary.clone());
            Ok(())
        }
    }

    #[async_trait]
    impl HypothesisSource for NullMetaOptDeps {
        async fn generate_hypotheses(
            &self,
            _context: HypothesisContext,
        ) -> Result<Vec<MetaOptHypothesis>, MetaOptError> {
            Ok(self.state.lock().await.hypotheses.clone())
        }
    }

    #[async_trait]
    impl BenchmarkRunner for NullMetaOptDeps {
        async fn is_benchmark_available(&self) -> bool {
            self.state.lock().await.benchmark_available
        }

        async fn run_benchmark(
            &self,
            _adapter_path: Option<&str>,
        ) -> Result<DimensionScores, MetaOptError> {
            let mut state = self.state.lock().await;
            match state.benchmark_scores.pop_front() {
                Some(scores) => Ok(scores),
                None => Ok(DimensionScores::EMPTY),
            }
        }
    }

    #[async_trait]
    impl DirectivePort for NullMetaOptDeps {
        async fn read_directive(&self) -> Result<Option<String>, MetaOptError> {
            Ok(Some(self.state.lock().await.directive.clone()))
        }

        async fn write_directive(&self, text: &str) -> Result<(), MetaOptError> {
            let mut state = self.state.lock().await;
            if text.is_empty() || state.directive != text {
                state.rollback_writes = state.rollback_writes.saturating_add(1);
            }
            state.directive = text.to_owned();
            Ok(())
        }
    }

    #[async_trait]
    impl ConfigPort for NullMetaOptDeps {
        async fn read_config(&self, key: &str) -> Result<Option<String>, MetaOptError> {
            Ok(self.state.lock().await.config.get(key).cloned())
        }

        async fn write_config(&self, key: &str, value: &str) -> Result<(), MetaOptError> {
            self.state
                .lock()
                .await
                .config
                .insert(key.to_owned(), value.to_owned());
            Ok(())
        }
    }

    #[async_trait]
    impl SkillPort for NullMetaOptDeps {
        async fn create_skill(
            &self,
            name: &str,
            _description: &str,
            body: &str,
        ) -> Result<(), MetaOptError> {
            self.state
                .lock()
                .await
                .skills
                .insert(name.to_owned(), body.to_owned());
            Ok(())
        }

        async fn activate_skill(&self, name: &str) -> Result<(), MetaOptError> {
            self.state
                .lock()
                .await
                .active_skills
                .insert(name.to_owned());
            Ok(())
        }

        async fn deactivate_skill(&self, name: &str) -> Result<(), MetaOptError> {
            self.state.lock().await.active_skills.remove(name);
            Ok(())
        }

        async fn delete_skill(&self, name: &str) -> Result<(), MetaOptError> {
            self.state.lock().await.skills.remove(name);
            Ok(())
        }
    }

    #[async_trait]
    impl MemorySeedPort for NullMetaOptDeps {
        async fn insert_seed(
            &self,
            text: &str,
            tags: &[String],
            _confidence: f64,
            _stale_after_secs: u64,
        ) -> Result<MemorySeedId, MetaOptError> {
            let mut state = self.state.lock().await;
            state.next_seed_id = state.next_seed_id.saturating_add(1);
            let id = format!("seed-{}", state.next_seed_id);
            state
                .seeds
                .insert(id.clone(), (text.to_owned(), tags.to_vec()));
            Ok(MemorySeedId(id))
        }

        async fn delete_seed(&self, id: &MemorySeedId) -> Result<(), MetaOptError> {
            self.state.lock().await.seeds.remove(&id.0);
            Ok(())
        }
    }

    fn scores(tool: f64, fae: f64, fit: f64, serialization: f64) -> DimensionScores {
        DimensionScores {
            tool_calling: Some(tool),
            fae_capability: Some(fae),
            assistant_fit: Some(fit),
            serialization: Some(serialization),
        }
    }

    fn hypothesis(
        id: u128,
        target_dimension: EvalDimension,
        change: MetaOptChange,
    ) -> MetaOptHypothesis {
        MetaOptHypothesis {
            id: Uuid::from_u128(id),
            surface: change.surface(),
            description: format!("hypothesis-{id}"),
            target_dimension,
            change,
            evidence_count: 10,
        }
    }

    fn budget() -> MetaOptBudget {
        MetaOptBudget {
            max_benchmark_runs: 10,
            max_wall_clock: Duration::from_secs(60),
            max_consecutive_discards: 3,
            min_improvement_threshold: 0.01,
            regression_threshold: 0.05,
        }
    }

    #[test]
    fn decision_keeps_target_improvement_without_regression() {
        let candidate = hypothesis(
            1,
            EvalDimension::ToolCalling,
            MetaOptChange::DirectiveAmendment {
                amendment: "\n[auto]".to_owned(),
            },
        );
        let decision = MetaOptimizer::decide(
            &candidate,
            scores(0.70, 0.80, 0.80, 0.80),
            scores(0.72, 0.80, 0.80, 0.80),
            budget(),
        );
        assert_eq!(decision, MetaOptDecision::keep("improvement"));
    }

    #[test]
    fn decision_discards_regression_or_neutral() {
        let candidate = hypothesis(
            2,
            EvalDimension::ToolCalling,
            MetaOptChange::DirectiveAmendment {
                amendment: "\n[auto]".to_owned(),
            },
        );
        let regression = MetaOptimizer::decide(
            &candidate,
            scores(0.70, 0.80, 0.80, 0.80),
            scores(0.72, 0.74, 0.80, 0.80),
            budget(),
        );
        assert_eq!(regression, MetaOptDecision::discard("regression"));

        let neutral = MetaOptimizer::decide(
            &candidate,
            scores(0.70, 0.80, 0.80, 0.80),
            scores(0.705, 0.80, 0.80, 0.80),
            budget(),
        );
        assert_eq!(neutral, MetaOptDecision::discard("neutral"));
    }

    #[tokio::test]
    async fn budget_stop_terminates_when_benchmark_count_exhausted() -> Result<(), MetaOptError> {
        let deps = Arc::new(
            NullMetaOptDeps::with_state(|state| {
                state.directive = "base".to_owned();
                state
                    .benchmark_scores
                    .push_back(scores(0.70, 0.80, 0.80, 0.80));
                state
                    .benchmark_scores
                    .push_back(scores(0.72, 0.80, 0.80, 0.80));
                state
                    .benchmark_scores
                    .push_back(scores(0.74, 0.80, 0.80, 0.80));
                state.hypotheses = vec![
                    hypothesis(
                        3,
                        EvalDimension::ToolCalling,
                        MetaOptChange::DirectiveAmendment {
                            amendment: "\n[first]".to_owned(),
                        },
                    ),
                    hypothesis(
                        4,
                        EvalDimension::ToolCalling,
                        MetaOptChange::DirectiveAmendment {
                            amendment: "\n[second]".to_owned(),
                        },
                    ),
                ];
            })
            .await,
        );
        let mut optimizer = NullMetaOptDeps::optimizer(&deps);
        let mut limited = budget();
        limited.max_benchmark_runs = 2;

        let summary = optimizer.run(&[], limited).await?;

        assert_eq!(summary.hypotheses_tested, 1);
        assert_eq!(summary.total_benchmark_runs, 2);
        let snapshot = deps.snapshot().await;
        assert_eq!(snapshot.directive, "base\n[first]");
        Ok(())
    }

    #[tokio::test]
    async fn budget_stop_terminates_when_wall_clock_exhausted() -> Result<(), MetaOptError> {
        let deps = Arc::new(
            NullMetaOptDeps::with_state(|state| {
                state.directive = "base".to_owned();
                state
                    .benchmark_scores
                    .push_back(scores(0.70, 0.80, 0.80, 0.80));
                state.hypotheses.push(hypothesis(
                    5,
                    EvalDimension::ToolCalling,
                    MetaOptChange::DirectiveAmendment {
                        amendment: "\n[not applied]".to_owned(),
                    },
                ));
            })
            .await,
        );
        let mut optimizer = NullMetaOptDeps::optimizer(&deps);
        let mut limited = budget();
        limited.max_wall_clock = Duration::from_secs(0);

        let summary = optimizer.run(&[], limited).await?;

        assert_eq!(summary.hypotheses_tested, 0);
        assert_eq!(summary.total_benchmark_runs, 1);
        assert_eq!(deps.snapshot().await.directive, "base");
        Ok(())
    }

    #[tokio::test]
    async fn rollback_invoked_for_discard_and_state_restored() -> Result<(), MetaOptError> {
        let deps = Arc::new(
            NullMetaOptDeps::with_state(|state| {
                state.directive = "base".to_owned();
                state
                    .benchmark_scores
                    .push_back(scores(0.70, 0.80, 0.80, 0.80));
                state
                    .benchmark_scores
                    .push_back(scores(0.705, 0.80, 0.80, 0.80));
                state.hypotheses.push(hypothesis(
                    6,
                    EvalDimension::ToolCalling,
                    MetaOptChange::DirectiveAmendment {
                        amendment: "\n[neutral]".to_owned(),
                    },
                ));
            })
            .await,
        );
        let mut optimizer = NullMetaOptDeps::optimizer(&deps);

        let summary = optimizer.run(&[], budget()).await?;

        assert_eq!(summary.discarded_count, 1);
        let snapshot = deps.snapshot().await;
        assert_eq!(snapshot.directive, "base");
        assert!(snapshot.rollback_writes >= 2);
        Ok(())
    }

    #[tokio::test]
    async fn no_auto_deploy_failed_improvement_gate() -> Result<(), MetaOptError> {
        let deps = Arc::new(
            NullMetaOptDeps::with_state(|state| {
                state
                    .config
                    .insert("llm.temperature".to_owned(), "0.7".to_owned());
                state
                    .benchmark_scores
                    .push_back(scores(0.70, 0.80, 0.80, 0.80));
                state
                    .benchmark_scores
                    .push_back(scores(0.70, 0.70, 0.80, 0.80));
                state.hypotheses.push(hypothesis(
                    7,
                    EvalDimension::ToolCalling,
                    MetaOptChange::ConfigAdjustment {
                        key: "llm.temperature".to_owned(),
                        old_value: "0.7".to_owned(),
                        new_value: "0.5".to_owned(),
                    },
                ));
            })
            .await,
        );
        let mut optimizer = NullMetaOptDeps::optimizer(&deps);

        let summary = optimizer.run(&[], budget()).await?;

        assert_eq!(summary.kept_count, 0);
        assert_eq!(summary.discarded_count, 1);
        let snapshot = deps.snapshot().await;
        assert_eq!(
            snapshot.config.get("llm.temperature"),
            Some(&"0.7".to_owned())
        );
        assert_eq!(snapshot.persisted_results.len(), 1);
        assert!(!snapshot.persisted_results[0].kept);
        Ok(())
    }

    #[tokio::test]
    async fn surface_round_trips_each_existing_surface() -> Result<(), MetaOptError> {
        let deps = Arc::new(
            NullMetaOptDeps::with_state(|state| {
                state.directive = "base".to_owned();
                state
                    .config
                    .insert("llm.temperature".to_owned(), "0.7".to_owned());
            })
            .await,
        );
        let optimizer = NullMetaOptDeps::optimizer(&deps);

        let directive_rollback = optimizer
            .apply_change(&MetaOptChange::DirectiveAmendment {
                amendment: "\n[round-trip]".to_owned(),
            })
            .await?;
        assert_eq!(deps.snapshot().await.directive, "base\n[round-trip]");
        directive_rollback().await?;
        assert_eq!(deps.snapshot().await.directive, "base");

        let config_rollback = optimizer
            .apply_change(&MetaOptChange::ConfigAdjustment {
                key: "llm.temperature".to_owned(),
                old_value: "0.7".to_owned(),
                new_value: "0.5".to_owned(),
            })
            .await?;
        assert_eq!(
            deps.snapshot().await.config.get("llm.temperature"),
            Some(&"0.5".to_owned())
        );
        config_rollback().await?;
        assert_eq!(
            deps.snapshot().await.config.get("llm.temperature"),
            Some(&"0.7".to_owned())
        );

        let skill_rollback = optimizer
            .apply_change(&MetaOptChange::SkillCreation {
                name: "auto-test".to_owned(),
                description: "test".to_owned(),
                body: "body".to_owned(),
            })
            .await?;
        let snapshot = deps.snapshot().await;
        assert!(snapshot.skills.contains_key("auto-test"));
        assert!(snapshot.active_skills.contains("auto-test"));
        skill_rollback().await?;
        let snapshot = deps.snapshot().await;
        assert!(!snapshot.skills.contains_key("auto-test"));
        assert!(!snapshot.active_skills.contains("auto-test"));

        let seed_rollback = optimizer
            .apply_change(&MetaOptChange::MemorySeedInsertion {
                text: "seed".to_owned(),
                tags: vec!["meta_opt_seed".to_owned()],
            })
            .await?;
        assert_eq!(deps.snapshot().await.seeds.len(), 1);
        seed_rollback().await?;
        assert!(deps.snapshot().await.seeds.is_empty());
        Ok(())
    }

    #[tokio::test]
    async fn kept_change_can_be_rolled_back_later() -> Result<(), MetaOptError> {
        let deps = Arc::new(
            NullMetaOptDeps::with_state(|state| {
                state.directive = "base".to_owned();
                state
                    .benchmark_scores
                    .push_back(scores(0.70, 0.80, 0.80, 0.80));
                state
                    .benchmark_scores
                    .push_back(scores(0.72, 0.80, 0.80, 0.80));
                state.hypotheses.push(hypothesis(
                    8,
                    EvalDimension::ToolCalling,
                    MetaOptChange::DirectiveAmendment {
                        amendment: "\n[kept]".to_owned(),
                    },
                ));
            })
            .await,
        );
        let mut optimizer = NullMetaOptDeps::optimizer(&deps);

        let summary = optimizer.run(&[], budget()).await?;
        assert_eq!(summary.kept_count, 1);
        assert_eq!(deps.snapshot().await.directive, "base\n[kept]");

        let message = optimizer.rollback_last_change().await;
        assert!(message.starts_with("Done"));
        assert_eq!(deps.snapshot().await.directive, "base");
        Ok(())
    }

    // ── M3-A (BLOCKER-1, spec §3.1): protected-config-key denylist ──

    // V-B1a: a protected key is rejected with ProtectedConfigKey AND performs no
    // write (the NullMetaOptDeps config port is the spy — a rejected apply must not
    // land the key in state.config). This is the load-bearing guard; mutation-tested
    // (comment out the guard → the write happens → this test fails).
    #[tokio::test]
    async fn protected_config_key_rejected_with_no_write() -> Result<(), MetaOptError> {
        let deps = Arc::new(
            NullMetaOptDeps::with_state(|state| {
                state
                    .config
                    .insert("llm.temperature".to_owned(), "0.7".to_owned());
            })
            .await,
        );
        let optimizer = NullMetaOptDeps::optimizer(&deps);

        let result = optimizer
            .apply_change(&MetaOptChange::ConfigAdjustment {
                key: "model_mode".to_owned(),
                old_value: "local".to_owned(),
                new_value: "agent".to_owned(),
            })
            .await;

        assert!(
            matches!(result, Err(MetaOptError::ProtectedConfigKey(ref k)) if k.as_str() == "model_mode"),
            "expected ProtectedConfigKey(model_mode)"
        );

        // Spy: no write occurred.
        let snapshot = deps.snapshot().await;
        assert!(
            !snapshot.config.contains_key("model_mode"),
            "protected key must not be written"
        );
        // An unrelated bounded key is untouched.
        assert_eq!(
            snapshot.config.get("llm.temperature"),
            Some(&"0.7".to_owned())
        );
        Ok(())
    }

    // V-B1b: the denylist closes obfuscation variants — separator + case forms of
    // `model_mode` / `availability_mode` are rejected too (canonicalization, §3.1).
    #[tokio::test]
    async fn protected_config_key_rejects_separator_and_case_variants() {
        let deps = Arc::new(NullMetaOptDeps::with_state(|_| {}).await);
        let optimizer = NullMetaOptDeps::optimizer(&deps);

        for key in [
            "model-mode",
            "modelMode",
            "availability.mode",
            "AvailabilityMode",
            "FAE_MODEL_MODE",
            "conductor_model_mode",
            "my_model_mode_flag",
        ] {
            let result = optimizer
                .apply_change(&MetaOptChange::ConfigAdjustment {
                    key: key.to_owned(),
                    old_value: "a".to_owned(),
                    new_value: "b".to_owned(),
                })
                .await;
            assert!(
                matches!(result, Err(MetaOptError::ProtectedConfigKey(_))),
                "expected {key:?} rejected as protected"
            );
            assert!(
                !deps.snapshot().await.config.contains_key(key),
                "{key:?} must not be written"
            );
        }
    }

    // V-B1c: regression — a normal bounded key still applies (the denylist is
    // additive; it must not over-reject legitimate knobs).
    #[tokio::test]
    async fn normal_config_key_still_applies() -> Result<(), MetaOptError> {
        let deps = Arc::new(
            NullMetaOptDeps::with_state(|state| {
                state
                    .config
                    .insert("llm.temperature".to_owned(), "0.7".to_owned());
            })
            .await,
        );
        let optimizer = NullMetaOptDeps::optimizer(&deps);
        let rollback = optimizer
            .apply_change(&MetaOptChange::ConfigAdjustment {
                key: "llm.temperature".to_owned(),
                old_value: "0.7".to_owned(),
                new_value: "0.5".to_owned(),
            })
            .await?;
        assert_eq!(
            deps.snapshot().await.config.get("llm.temperature"),
            Some(&"0.5".to_owned())
        );
        rollback().await?;
        assert_eq!(
            deps.snapshot().await.config.get("llm.temperature"),
            Some(&"0.7".to_owned())
        );
        Ok(())
    }
}
