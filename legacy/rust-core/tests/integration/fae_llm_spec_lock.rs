//! Spec-lock tests for the FAE LLM module.
//!
//! These tests pin contract-critical behavior so future refactors do not
//! regress locked requirements.

use std::sync::Arc;

use async_trait::async_trait;
use fae::fae_llm::agent::{AccumulatedToolCall, ToolExecutor};
use fae::fae_llm::config::types::ToolMode;
use fae::fae_llm::provider::{ConversationContext, ProviderAdapter, ToolDefinition};
use fae::fae_llm::providers::message::Message;
use fae::fae_llm::tools::{BashTool, EditTool, ReadTool, ToolRegistry, WriteTool};
use fae::fae_llm::{
    AssistantEvent, ConfigService, EndpointType, FinishReason, LlmEvent, LlmEventStream, ModelRef,
    ReasoningLevel, RequestOptions,
};
use futures_util::StreamExt;
use tempfile::TempDir;

#[test]
fn api_contract_endpoint_and_model_ref() {
    assert_eq!(
        EndpointType::OpenAiCompletions.to_string(),
        "openai_completions"
    );
    assert_eq!(
        EndpointType::OpenAiResponses.to_string(),
        "openai_responses"
    );
    assert_eq!(
        EndpointType::AnthropicMessages.to_string(),
        "anthropic_messages"
    );

    let model = ModelRef::new("gpt-4o")
        .with_provider("openai")
        .with_endpoint_type(EndpointType::OpenAiResponses)
        .with_base_url("https://api.openai.com/v1");

    assert_eq!(model.provider_id, "openai");
    assert_eq!(model.model_id, "gpt-4o");
    assert_eq!(model.endpoint_type, EndpointType::OpenAiResponses);
    assert_eq!(model.base_url, "https://api.openai.com/v1");
}

#[test]
fn api_contract_request_options_locked_fields() {
    let opts = RequestOptions::new()
        .with_max_tokens(2048)
        .with_temperature(0.2)
        .with_reasoning(ReasoningLevel::Minimal)
        .with_timeout_ms(12_000)
        .with_header("x-test", "1")
        .with_stream(true);

    assert_eq!(opts.max_tokens, Some(2048));
    assert_eq!(opts.temperature, Some(0.2));
    assert_eq!(opts.reasoning, Some(ReasoningLevel::Minimal));
    assert_eq!(opts.timeout_ms, Some(12_000));
    assert_eq!(opts.headers.get("x-test"), Some(&"1".to_string()));
}

struct MockProvider;

#[async_trait]
impl ProviderAdapter for MockProvider {
    fn name(&self) -> &str {
        "mock"
    }

    fn endpoint_type(&self) -> EndpointType {
        EndpointType::OpenAiCompletions
    }

    async fn send(
        &self,
        _messages: &[Message],
        _options: &RequestOptions,
        _tools: &[ToolDefinition],
    ) -> Result<LlmEventStream, fae::fae_llm::error::FaeLlmError> {
        Ok(Box::pin(futures_util::stream::iter(vec![
            LlmEvent::StreamEnd {
                finish_reason: FinishReason::Stop,
            },
        ])))
    }
}

#[tokio::test]
async fn api_contract_provider_stream_method_exists_and_works() {
    let provider = MockProvider;
    let model = ModelRef::new("test-model");
    let context =
        ConversationContext::from_messages(vec![Message::user("hello")]).with_tools(vec![
            ToolDefinition::new("read", "Read a file", serde_json::json!({"type":"object"})),
        ]);

    let mut stream = provider
        .stream(&model, &context, &RequestOptions::new())
        .await
        .expect("stream should start");

    let event = stream.next().await;
    assert!(matches!(event, Some(AssistantEvent::Done { .. })));
}

fn write_config_with_unknown_fields(dir: &TempDir) -> std::path::PathBuf {
    let path = dir.path().join("fae_llm.toml");
    let toml = r#"
# top-level comment
[providers.openai]
endpoint_type = "openai"
base_url = "https://api.openai.com/v1"
api_key = { type = "env", var = "OPENAI_API_KEY" }
models = ["gpt4"]
custom_field = "preserve_me"

[models.gpt4]
model_id = "gpt-4o"
display_name = "GPT-4o"
tier = "balanced"
max_tokens = 4096

[defaults]
default_provider = "openai"
default_model = "gpt4"
tool_mode = "full"

[runtime]
request_timeout_secs = 30
max_retries = 3
log_level = "info"

[custom.section]
keep = "yes"
"#;
    std::fs::write(&path, toml).expect("failed to write test config");
    path
}

#[test]
fn config_service_preserves_unknown_fields_and_comments_on_update() {
    let dir = TempDir::new().expect("failed to create temp dir");
    let path = write_config_with_unknown_fields(&dir);

    let service = ConfigService::new(path.clone());
    service.load().expect("config load should succeed");
    service
        .set_tool_mode(ToolMode::ReadOnly)
        .expect("tool mode update should succeed");

    let raw = std::fs::read_to_string(&path).expect("failed to read updated config");
    assert!(raw.contains("# top-level comment"));
    assert!(raw.contains("custom_field = \"preserve_me\""));
    assert!(raw.contains("[custom.section]"));
    assert!(raw.contains("keep = \"yes\""));
    assert!(raw.contains("[tools]"));
    assert!(raw.contains("mode = \"read_only\""));

    let backup_path = path.with_extension("toml.backup");
    assert!(
        backup_path.exists(),
        "backup should be created before update"
    );
}

#[test]
fn config_service_partial_provider_update_keeps_unknown_provider_keys() {
    let dir = TempDir::new().expect("failed to create temp dir");
    let path = write_config_with_unknown_fields(&dir);

    let service = ConfigService::new(path.clone());
    service.load().expect("config load should succeed");
    service
        .update_provider(
            "openai",
            fae::fae_llm::config::ProviderUpdate {
                base_url: Some("https://custom.example/v1".to_string()),
                ..Default::default()
            },
        )
        .expect("provider update should succeed");

    let raw = std::fs::read_to_string(&path).expect("failed to read updated config");
    assert!(raw.contains("base_url = \"https://custom.example/v1\""));
    assert!(raw.contains("custom_field = \"preserve_me\""));
}

#[test]
fn tool_mode_lock_exact_sets_for_read_only_and_full() {
    let mut registry = ToolRegistry::new(ToolMode::ReadOnly);
    registry.register(Arc::new(ReadTool::new()));
    registry.register(Arc::new(BashTool::new()));
    registry.register(Arc::new(EditTool::new()));
    registry.register(Arc::new(WriteTool::new()));

    assert_eq!(registry.list_available(), vec!["read"]);

    registry.set_mode(ToolMode::Full);
    assert_eq!(
        registry.list_available(),
        vec!["bash", "edit", "read", "write"]
    );
}

#[tokio::test]
async fn tool_mode_lock_rejects_mutation_tools_in_read_only() {
    let mut registry = ToolRegistry::new(ToolMode::ReadOnly);
    registry.register(Arc::new(ReadTool::new()));
    registry.register(Arc::new(BashTool::new()));
    registry.register(Arc::new(EditTool::new()));
    registry.register(Arc::new(WriteTool::new()));

    let executor = ToolExecutor::new(Arc::new(registry), 5);
    let call = AccumulatedToolCall {
        call_id: "call_1".to_string(),
        function_name: "bash".to_string(),
        arguments_json: r#"{"command":"echo hi"}"#.to_string(),
    };

    let cancel = tokio_util::sync::CancellationToken::new();
    let result = executor.execute_tool(&call, &cancel).await;
    assert!(result.is_err(), "bash should be rejected in read_only mode");

    let msg = result
        .err()
        .map(|e| e.to_string())
        .unwrap_or_else(|| "missing error".to_string());
    assert!(msg.contains("blocked by current mode"));
}
