//! Comprehensive tool-calling judgment evaluation suite.
//!
//! This suite focuses on the "should call a tool" vs "should not call a tool"
//! decision boundary. It is intentionally category-heavy so regressions are
//! visible by behavior cluster, not just aggregate score.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use fae::fae_llm::tools::types::ToolResult;
use fae::fae_llm::{
    AgentConfig, AgentLoop, FaeLlmError, FinishReason, LlmEvent, LlmEventStream, Message, ModelRef,
    ProviderAdapter, RequestOptions, Tool, ToolDefinition, ToolMode, ToolRegistry,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
enum ToolJudgmentCategory {
    Arithmetic,
    TextTransform,
    MetaAssistant,
    StaticReasoning,
    PlanningNoState,
    TimeNow,
    LocalRead,
    LocalWrite,
    WebFreshness,
    MultiStepExecution,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ToolExpectation {
    ShouldCall,
    ShouldNotCall,
}

#[derive(Debug, Clone)]
struct ToolJudgmentCase {
    category: ToolJudgmentCategory,
    prompt: &'static str,
    expected: ToolExpectation,
}

#[derive(Debug, Default, Clone)]
struct CategoryScore {
    total: usize,
    correct: usize,
}

#[derive(Debug, Default, Clone)]
struct EvalReport {
    total: usize,
    correct: usize,
    true_positive: usize,
    true_negative: usize,
    false_positive: usize,
    false_negative: usize,
    by_category: BTreeMap<ToolJudgmentCategory, CategoryScore>,
}

impl EvalReport {
    fn record(
        &mut self,
        category: ToolJudgmentCategory,
        expected_called: bool,
        predicted_called: bool,
    ) {
        self.total += 1;
        let is_correct = expected_called == predicted_called;
        if is_correct {
            self.correct += 1;
        }

        match (expected_called, predicted_called) {
            (true, true) => self.true_positive += 1,
            (true, false) => self.false_negative += 1,
            (false, true) => self.false_positive += 1,
            (false, false) => self.true_negative += 1,
        }

        let entry = self.by_category.entry(category).or_default();
        entry.total += 1;
        if is_correct {
            entry.correct += 1;
        }
    }

    fn accuracy(&self) -> f64 {
        if self.total == 0 {
            return 0.0;
        }
        self.correct as f64 / self.total as f64
    }

    fn precision(&self) -> f64 {
        let denom = self.true_positive + self.false_positive;
        if denom == 0 {
            return 0.0;
        }
        self.true_positive as f64 / denom as f64
    }

    fn recall(&self) -> f64 {
        let denom = self.true_positive + self.false_negative;
        if denom == 0 {
            return 0.0;
        }
        self.true_positive as f64 / denom as f64
    }

    fn f1(&self) -> f64 {
        let p = self.precision();
        let r = self.recall();
        if (p + r).abs() < f64::EPSILON {
            return 0.0;
        }
        2.0 * p * r / (p + r)
    }

    fn category_accuracy(&self, category: ToolJudgmentCategory) -> f64 {
        self.by_category
            .get(&category)
            .map(|score| {
                if score.total == 0 {
                    0.0
                } else {
                    score.correct as f64 / score.total as f64
                }
            })
            .unwrap_or(0.0)
    }
}

struct EvalTool {
    name: &'static str,
    schema: serde_json::Value,
}

impl EvalTool {
    fn new(name: &'static str, schema: serde_json::Value) -> Self {
        Self { name, schema }
    }
}

impl Tool for EvalTool {
    fn name(&self) -> &str {
        self.name
    }

    fn description(&self) -> &str {
        "tool for eval harness"
    }

    fn schema(&self) -> serde_json::Value {
        self.schema.clone()
    }

    fn execute(&self, _args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        Ok(ToolResult::success("ok".to_string()))
    }

    fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
        true
    }
}

fn eval_registry() -> Arc<ToolRegistry> {
    let mut registry = ToolRegistry::new(ToolMode::Full);
    registry.register(Arc::new(EvalTool::new(
        "read",
        serde_json::json!({
            "type": "object",
            "properties": { "path": { "type": "string" } },
            "required": ["path"]
        }),
    )));
    registry.register(Arc::new(EvalTool::new(
        "write",
        serde_json::json!({
            "type": "object",
            "properties": {
                "path": { "type": "string" },
                "content": { "type": "string" }
            },
            "required": ["path", "content"]
        }),
    )));
    registry.register(Arc::new(EvalTool::new(
        "web_search",
        serde_json::json!({
            "type": "object",
            "properties": { "query": { "type": "string" } },
            "required": ["query"]
        }),
    )));
    registry.register(Arc::new(EvalTool::new(
        "bash",
        serde_json::json!({
            "type": "object",
            "properties": { "command": { "type": "string" } },
            "required": ["command"]
        }),
    )));
    Arc::new(registry)
}

struct DecisionProvider {
    should_call_tool: bool,
    tool_name: &'static str,
    turn: Mutex<u32>,
}

impl DecisionProvider {
    fn new(should_call_tool: bool, tool_name: &'static str) -> Self {
        Self {
            should_call_tool,
            tool_name,
            turn: Mutex::new(0),
        }
    }

    fn text_response(text: &str) -> Vec<LlmEvent> {
        vec![
            LlmEvent::StreamStart {
                request_id: "eval-req".to_string(),
                model: ModelRef::new("eval-model"),
            },
            LlmEvent::TextDelta {
                text: text.to_string(),
            },
            LlmEvent::StreamEnd {
                finish_reason: FinishReason::Stop,
            },
        ]
    }

    fn tool_call_response(tool_name: &str, args: &str) -> Vec<LlmEvent> {
        vec![
            LlmEvent::StreamStart {
                request_id: "eval-req".to_string(),
                model: ModelRef::new("eval-model"),
            },
            LlmEvent::ToolCallStart {
                call_id: "call_eval_1".to_string(),
                function_name: tool_name.to_string(),
            },
            LlmEvent::ToolCallArgsDelta {
                call_id: "call_eval_1".to_string(),
                args_fragment: args.to_string(),
            },
            LlmEvent::ToolCallEnd {
                call_id: "call_eval_1".to_string(),
            },
            LlmEvent::StreamEnd {
                finish_reason: FinishReason::ToolCalls,
            },
        ]
    }
}

#[async_trait]
impl ProviderAdapter for DecisionProvider {
    fn name(&self) -> &str {
        "tool-judgment-eval"
    }

    async fn send(
        &self,
        _messages: &[Message],
        _options: &RequestOptions,
        _tools: &[ToolDefinition],
    ) -> Result<LlmEventStream, FaeLlmError> {
        let mut turn = self.turn.lock().unwrap_or_else(|e| e.into_inner());
        let events = if *turn == 0 && self.should_call_tool {
            let args = match self.tool_name {
                "read" => r#"{"path":"src/main.rs"}"#,
                "write" => r#"{"path":"src/main.rs","content":"x"}"#,
                "web_search" => r#"{"query":"latest result"}"#,
                "bash" => r#"{"command":"echo ok"}"#,
                _ => r#"{}"#,
            };
            Self::tool_call_response(self.tool_name, args)
        } else {
            Self::text_response("done")
        };
        *turn += 1;
        Ok(Box::pin(futures_util::stream::iter(events)))
    }
}

fn tool_for_category(category: ToolJudgmentCategory) -> &'static str {
    match category {
        ToolJudgmentCategory::LocalRead => "read",
        ToolJudgmentCategory::LocalWrite => "write",
        ToolJudgmentCategory::WebFreshness | ToolJudgmentCategory::TimeNow => "web_search",
        ToolJudgmentCategory::MultiStepExecution => "bash",
        ToolJudgmentCategory::Arithmetic
        | ToolJudgmentCategory::TextTransform
        | ToolJudgmentCategory::MetaAssistant
        | ToolJudgmentCategory::StaticReasoning
        | ToolJudgmentCategory::PlanningNoState => "read",
    }
}

fn add_cases(
    out: &mut Vec<ToolJudgmentCase>,
    category: ToolJudgmentCategory,
    expected: ToolExpectation,
    prompts: &[&'static str],
) {
    out.extend(prompts.iter().map(|prompt| ToolJudgmentCase {
        category,
        prompt,
        expected,
    }));
}

fn benchmark_cases() -> Vec<ToolJudgmentCase> {
    let mut out = Vec::new();

    add_cases(
        &mut out,
        ToolJudgmentCategory::Arithmetic,
        ToolExpectation::ShouldNotCall,
        &[
            "What is 17 multiplied by 24?",
            "Compute 999 + 1234 - 87.",
            "Is 97 a prime number?",
            "What is 12% of 250?",
            "Solve: (44 / 11) + 13.",
            "Convert 3.5 hours into minutes.",
            "What is the average of 10, 20, 40?",
            "Compare which is larger: 2^10 or 10^3.",
        ],
    );

    add_cases(
        &mut out,
        ToolJudgmentCategory::TextTransform,
        ToolExpectation::ShouldNotCall,
        &[
            "Rewrite this sentence to be more concise: We are in the process of reviewing it.",
            "Fix grammar: he don't like apples.",
            "Make this friendlier: Send me the file now.",
            "Summarize this in one line: Rust enables memory safety without GC.",
            "Turn this into bullet points: setup, test, deploy.",
            "Convert to title case: fae tool judgment evaluation",
            "Give me three synonyms for quick.",
            "Rephrase this to sound formal: can you check this?",
        ],
    );

    add_cases(
        &mut out,
        ToolJudgmentCategory::MetaAssistant,
        ToolExpectation::ShouldNotCall,
        &[
            "What tools do you have access to?",
            "Explain when you decide to call tools.",
            "Can you answer without using tools?",
            "What is your response style by default?",
            "How do you handle uncertainty?",
            "Tell me what model behavior you are optimizing for here.",
            "What do you do after a tool call finishes?",
            "When should you ask clarifying questions first?",
        ],
    );

    add_cases(
        &mut out,
        ToolJudgmentCategory::StaticReasoning,
        ToolExpectation::ShouldNotCall,
        &[
            "Why does binary search require sorted input?",
            "Explain what idempotent means in APIs.",
            "What are tradeoffs between mutexes and channels?",
            "How does caching reduce latency in general?",
            "What is a race condition?",
            "Why is input validation important?",
            "Explain big-O notation in one paragraph.",
            "When should you prefer composition over inheritance?",
        ],
    );

    add_cases(
        &mut out,
        ToolJudgmentCategory::PlanningNoState,
        ToolExpectation::ShouldNotCall,
        &[
            "Draft a migration plan from version 1 to version 2 in five steps.",
            "Give me a rollback checklist for a deployment.",
            "Propose a test strategy for a new HTTP endpoint.",
            "Design a code-review rubric for backend changes.",
            "Outline a release process for weekly shipping.",
            "Make a triage framework for bug reports.",
        ],
    );

    add_cases(
        &mut out,
        ToolJudgmentCategory::TimeNow,
        ToolExpectation::ShouldCall,
        &[
            "What time is it right now in New York?",
            "What day of week is it today in UTC?",
            "Tell me the current local time in Los Angeles.",
            "What is today's date right now?",
            "Is it morning or evening now in London?",
            "What time is it currently in Tokyo?",
        ],
    );

    add_cases(
        &mut out,
        ToolJudgmentCategory::LocalRead,
        ToolExpectation::ShouldCall,
        &[
            "Read Cargo.toml and tell me the package name.",
            "Check src/main.rs and summarize the entrypoint.",
            "Open README.md and list setup steps.",
            "Inspect justfile and list test commands.",
            "Read src/config.rs and find default backend.",
            "Open AGENTS.md and summarize guardrails.",
            "Read docs/Memory.md and give key points.",
            "Inspect tests/openai_contract.rs and describe scope.",
        ],
    );

    add_cases(
        &mut out,
        ToolJudgmentCategory::LocalWrite,
        ToolExpectation::ShouldCall,
        &[
            "Create a file named notes.txt with the text hello.",
            "Edit README.md to add a short troubleshooting section.",
            "Add a TODO comment to src/main.rs near startup.",
            "Create docs/plan.md with a four-item checklist.",
            "Update Cargo.toml to include a new feature flag.",
            "Write a basic config example to examples/config.toml.",
            "Append a changelog entry to CHANGELOG.md.",
            "Patch a typo in Prompts/system_prompt.md.",
        ],
    );

    add_cases(
        &mut out,
        ToolJudgmentCategory::WebFreshness,
        ToolExpectation::ShouldCall,
        &[
            "Find the latest Rust stable version released this month.",
            "What are today's top AI headlines?",
            "Check current weather in San Francisco.",
            "What is the latest price of Bitcoin right now?",
            "Find current release notes for OpenAI API updates.",
            "Look up the most recent Ubuntu LTS point release.",
            "What changed in the latest Node.js release?",
            "Find up-to-date guidance for macOS code signing.",
        ],
    );

    add_cases(
        &mut out,
        ToolJudgmentCategory::MultiStepExecution,
        ToolExpectation::ShouldCall,
        &[
            "List files in src and count how many .rs files exist.",
            "Find all TODO comments and summarize by file.",
            "Search for tool_mode in the codebase and report matches.",
            "Run formatting and report whether anything changed.",
            "Run tests for memory module and summarize failures.",
            "Check git status and list modified files.",
        ],
    );

    out
}

async fn evaluate_suite<F>(
    cases: &[ToolJudgmentCase],
    mut policy: F,
) -> Result<EvalReport, FaeLlmError>
where
    F: FnMut(&ToolJudgmentCase) -> ToolExpectation,
{
    let registry = eval_registry();
    let mut report = EvalReport::default();

    for case in cases {
        let predicted = policy(case);
        let predicted_called = matches!(predicted, ToolExpectation::ShouldCall);
        let provider = Arc::new(DecisionProvider::new(
            predicted_called,
            tool_for_category(case.category),
        ));
        let agent = AgentLoop::new(AgentConfig::new(), provider, Arc::clone(&registry));
        let result = agent.run(case.prompt).await?;
        let actual_called = result.turns.iter().any(|t| !t.tool_calls.is_empty());

        // Harness sanity check: the replay provider's decision should be what the loop observes.
        assert_eq!(
            actual_called, predicted_called,
            "harness mismatch for prompt: {}",
            case.prompt
        );

        let expected_called = matches!(case.expected, ToolExpectation::ShouldCall);
        report.record(case.category, expected_called, actual_called);
    }

    Ok(report)
}

#[test]
fn tool_judgment_dataset_is_comprehensive() {
    let cases = benchmark_cases();
    assert!(
        cases.len() >= 72,
        "expected at least 72 benchmark cases, got {}",
        cases.len()
    );

    let mut category_counts: HashMap<ToolJudgmentCategory, usize> = HashMap::new();
    let mut should_call = 0usize;
    let mut should_not_call = 0usize;

    for case in &cases {
        *category_counts.entry(case.category).or_insert(0) += 1;
        match case.expected {
            ToolExpectation::ShouldCall => should_call += 1,
            ToolExpectation::ShouldNotCall => should_not_call += 1,
        }
    }

    assert!(
        category_counts.len() >= 10,
        "expected at least 10 categories, got {}",
        category_counts.len()
    );
    for (category, count) in category_counts {
        assert!(
            count >= 6,
            "category {:?} must include at least 6 cases, got {}",
            category,
            count
        );
    }

    assert!(
        should_call >= 30,
        "expected at least 30 should-call cases, got {}",
        should_call
    );
    assert!(
        should_not_call >= 30,
        "expected at least 30 should-not-call cases, got {}",
        should_not_call
    );
}

#[tokio::test]
async fn tool_judgment_perfect_policy_scores_full_marks() {
    let cases = benchmark_cases();
    let report = evaluate_suite(&cases, |case| case.expected).await;
    assert!(report.is_ok());
    let report = report.unwrap_or_default();

    assert_eq!(report.correct, report.total);
    assert_eq!(report.false_positive, 0);
    assert_eq!(report.false_negative, 0);
    assert!((report.accuracy() - 1.0).abs() < f64::EPSILON);
    assert!((report.precision() - 1.0).abs() < f64::EPSILON);
    assert!((report.recall() - 1.0).abs() < f64::EPSILON);
    assert!((report.f1() - 1.0).abs() < f64::EPSILON);
}

#[tokio::test]
async fn tool_judgment_always_call_policy_fails_eval() {
    let cases = benchmark_cases();
    let report = evaluate_suite(&cases, |_case| ToolExpectation::ShouldCall).await;
    assert!(report.is_ok());
    let report = report.unwrap_or_default();

    assert!(report.false_positive >= 30);
    assert!(report.accuracy() < 0.70);
    assert!(report.precision() < 0.60);
}

#[tokio::test]
async fn tool_judgment_never_call_policy_fails_eval() {
    let cases = benchmark_cases();
    let report = evaluate_suite(&cases, |_case| ToolExpectation::ShouldNotCall).await;
    assert!(report.is_ok());
    let report = report.unwrap_or_default();

    assert!(report.false_negative >= 30);
    assert!(report.accuracy() < 0.70);
    assert_eq!(report.recall(), 0.0);
}

#[tokio::test]
async fn tool_judgment_local_only_policy_exposes_web_time_gaps() {
    let cases = benchmark_cases();
    let report = evaluate_suite(&cases, |case| match case.category {
        ToolJudgmentCategory::LocalRead
        | ToolJudgmentCategory::LocalWrite
        | ToolJudgmentCategory::MultiStepExecution => ToolExpectation::ShouldCall,
        _ => ToolExpectation::ShouldNotCall,
    })
    .await;
    assert!(report.is_ok());
    let report = report.unwrap_or_default();

    assert!(report.false_negative > 0);
    assert!(report.category_accuracy(ToolJudgmentCategory::WebFreshness) < 0.5);
    assert!(report.category_accuracy(ToolJudgmentCategory::TimeNow) < 0.5);
}
