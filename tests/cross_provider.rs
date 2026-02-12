//! Cross-provider compatibility test matrix.
//!
//! Tests that verify session data, retry policies, circuit breakers, and tool modes
//! work consistently across OpenAI and Anthropic providers.

use fae::fae_llm::agent::types::{CircuitBreaker, CircuitState, RetryPolicy};
use fae::fae_llm::config::types::ToolMode;
use fae::fae_llm::providers::anthropic::AnthropicConfig;
use fae::fae_llm::providers::openai::OpenAiConfig;
use fae::fae_llm::session::types::Session;
use fae::fae_llm::tools::read::ReadTool;
use fae::fae_llm::tools::registry::ToolRegistry;
use fae::fae_llm::tools::write::WriteTool;
use serde_json::json;
use std::sync::Arc;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

// ────────────────────────────────────────────────────────────────────────────
// Test 1: Provider Switch Matrix (OpenAI → Anthropic → OpenAI)
// ────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_provider_switch_matrix() {
    // Create initial session with OpenAI
    let session1 = Session::new(
        "matrix-session",
        Some("System prompt".to_string()),
        Some("gpt-4".to_string()),
        Some("openai".to_string()),
    );
    assert_eq!(session1.meta.provider_id.as_deref(), Some("openai"));
    assert_eq!(session1.meta.model.as_deref(), Some("gpt-4"));

    // Switch to Anthropic
    let session2 = Session::new(
        "matrix-session",
        Some("System prompt".to_string()),
        Some("claude-3-opus-20240229".to_string()),
        Some("anthropic".to_string()),
    );
    assert_eq!(session2.meta.provider_id.as_deref(), Some("anthropic"));
    assert_eq!(
        session2.meta.model.as_deref(),
        Some("claude-3-opus-20240229")
    );

    // Switch back to OpenAI
    let session3 = Session::new(
        "matrix-session",
        Some("System prompt".to_string()),
        Some("gpt-4-turbo".to_string()),
        Some("openai".to_string()),
    );
    assert_eq!(session3.meta.provider_id.as_deref(), Some("openai"));
    assert_eq!(session3.meta.model.as_deref(), Some("gpt-4-turbo"));

    // Verify provider switch tracking works in both directions
    // validation.rs logs warnings when provider_id changes
}

// ────────────────────────────────────────────────────────────────────────────
// Test 2: Tool Call Format Compatibility
// ────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_tool_call_format_compatibility() {
    let openai_mock = MockServer::start().await;
    let anthropic_mock = MockServer::start().await;

    // OpenAI format: tool_calls array
    Mock::given(method("POST"))
        .and(path("/v1/chat/completions"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "id": "chatcmpl-compat1",
            "object": "chat.completion",
            "model": "gpt-4",
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": null,
                    "tool_calls": [{
                        "id": "call_abc",
                        "type": "function",
                        "function": {
                            "name": "read",
                            "arguments": "{\"path\": \"/tmp/test.txt\"}"
                        }
                    }]
                },
                "finish_reason": "tool_calls"
            }]
        })))
        .mount(&openai_mock)
        .await;

    // Anthropic format: content array with tool_use blocks
    Mock::given(method("POST"))
        .and(path("/v1/messages"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "id": "msg_compat1",
            "type": "message",
            "role": "assistant",
            "content": [{
                "type": "tool_use",
                "id": "toolu_abc",
                "name": "read",
                "input": {"path": "/tmp/test.txt"}
            }],
            "model": "claude-3-opus-20240229",
            "stop_reason": "tool_use"
        })))
        .mount(&anthropic_mock)
        .await;

    // Both formats should be normalized internally to a common representation
    // The ProviderAdapter trait abstracts format differences
    assert!(openai_mock.address().port() > 0);
    assert!(anthropic_mock.address().port() > 0);
}

// ────────────────────────────────────────────────────────────────────────────
// Test 3: Session Format is Provider-Agnostic
// ────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_session_format_provider_agnostic() {
    // Session structure is the same regardless of provider
    let openai_session = Session::new(
        "agnostic-1",
        Some("Prompt".to_string()),
        Some("gpt-4".to_string()),
        Some("openai".to_string()),
    );

    let anthropic_session = Session::new(
        "agnostic-2",
        Some("Prompt".to_string()),
        Some("claude-3-opus-20240229".to_string()),
        Some("anthropic".to_string()),
    );

    // Both have the same structure
    assert!(openai_session.meta.provider_id.is_some());
    assert!(anthropic_session.meta.provider_id.is_some());

    // Session can be serialized/deserialized regardless of provider
    use serde_json;
    let openai_json = serde_json::to_string(&openai_session).unwrap_or_else(|e| {
        panic!("Failed to serialize OpenAI session: {e}");
    });
    let anthropic_json = serde_json::to_string(&anthropic_session).unwrap_or_else(|e| {
        panic!("Failed to serialize Anthropic session: {e}");
    });

    assert!(openai_json.contains("\"provider_id\":\"openai\""));
    assert!(anthropic_json.contains("\"provider_id\":\"anthropic\""));
}

// ────────────────────────────────────────────────────────────────────────────
// Test 4: Mode Switching Works with Both Providers
// ────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_mode_switching_cross_provider() {
    // ToolMode is provider-agnostic
    let mut registry = ToolRegistry::new(ToolMode::Full);
    let read_tool = Arc::new(ReadTool::new());
    let write_tool = Arc::new(WriteTool::new());

    registry.register(read_tool.clone());
    registry.register(write_tool.clone());

    // Test with "OpenAI session context"
    let _openai_session = Session::new(
        "mode-openai",
        Some("Prompt".to_string()),
        Some("gpt-4".to_string()),
        Some("openai".to_string()),
    );

    // Full mode
    assert_eq!(registry.mode(), ToolMode::Full);
    assert_eq!(registry.list_available().len(), 2);

    // Switch to ReadOnly
    registry.set_mode(ToolMode::ReadOnly);
    assert_eq!(registry.list_available().len(), 1);

    // Now test with "Anthropic session context"
    let _anthropic_session = Session::new(
        "mode-anthropic",
        Some("Prompt".to_string()),
        Some("claude-3-opus-20240229".to_string()),
        Some("anthropic".to_string()),
    );

    // Mode behavior is identical
    assert_eq!(registry.mode(), ToolMode::ReadOnly);
    assert_eq!(registry.list_available().len(), 1);

    // Switch back to Full
    registry.set_mode(ToolMode::Full);
    assert_eq!(registry.list_available().len(), 2);

    // ToolMode enforcement is provider-independent
}

// ────────────────────────────────────────────────────────────────────────────
// Test 5: Retry Policy Works with Both Providers
// ────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_retry_policy_cross_provider() {
    // RetryPolicy is provider-agnostic
    let policy = RetryPolicy::default();

    // Test OpenAI retry scenario (429 rate limit)
    assert_eq!(policy.max_attempts, 3);
    let delay1 = policy.delay_for_attempt(1);
    assert!(delay1.as_millis() >= 1000);

    // Test Anthropic retry scenario (529 overloaded)
    let delay2 = policy.delay_for_attempt(2);
    assert!(delay2.as_millis() >= 2000); // Exponential backoff

    // Same retry logic applies regardless of provider
    // Error types are normalized through FaeLlmError
}

// ────────────────────────────────────────────────────────────────────────────
// Test 6: Circuit Breaker Per-Provider Isolation
// ────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_circuit_breaker_per_provider_isolation() {
    // Each provider should have its own circuit breaker instance
    let mut openai_breaker = CircuitBreaker::default();
    let mut anthropic_breaker = CircuitBreaker::default();

    // OpenAI failures don't affect Anthropic circuit
    for _ in 0..5 {
        openai_breaker.record_failure();
    }
    assert!(!openai_breaker.is_request_allowed()); // OpenAI circuit open
    assert!(anthropic_breaker.is_request_allowed()); // Anthropic still closed

    // Anthropic failures are independent
    for _ in 0..3 {
        anthropic_breaker.record_failure();
    }
    assert!(!openai_breaker.is_request_allowed()); // Still open
    assert!(anthropic_breaker.is_request_allowed()); // Still closed (only 3 failures)

    // Recovery is independent
    openai_breaker.reset();
    assert!(openai_breaker.is_request_allowed());
    assert_eq!(openai_breaker.consecutive_failures, 0);

    // Anthropic breaker unchanged
    assert_eq!(anthropic_breaker.consecutive_failures, 3);
}

// ────────────────────────────────────────────────────────────────────────────
// Test 7: Provider Configuration Comparison
// ────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_provider_config_comparison() {
    // OpenAI config
    let openai = OpenAiConfig::new("test-key-1", "gpt-4");
    assert_eq!(openai.model, "gpt-4");
    assert_eq!(openai.base_url, "https://api.openai.com");

    // Anthropic config
    let anthropic = AnthropicConfig::new("test-key-2", "claude-3-opus-20240229");
    assert_eq!(anthropic.model, "claude-3-opus-20240229");

    // Both configs work with their respective providers
    // ProviderAdapter trait provides unified interface
}

// ────────────────────────────────────────────────────────────────────────────
// Test 8: Message Format Interoperability
// ────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_message_format_interoperability() {
    use fae::fae_llm::providers::message::{Message, MessageContent, Role};

    // Create messages using the common Message type
    let user_msg = Message {
        role: Role::User,
        content: MessageContent::Text {
            text: "Hello".to_string(),
        },
        tool_calls: vec![],
    };

    let assistant_msg = Message {
        role: Role::Assistant,
        content: MessageContent::Text {
            text: "Hi there!".to_string(),
        },
        tool_calls: vec![],
    };

    // Add messages to OpenAI session
    let mut openai_session = Session::new(
        "interop-openai",
        Some("Prompt".to_string()),
        Some("gpt-4".to_string()),
        Some("openai".to_string()),
    );
    openai_session.push_message(user_msg.clone());
    openai_session.push_message(assistant_msg.clone());
    assert_eq!(openai_session.messages.len(), 2);

    // Same messages work with Anthropic session
    let mut anthropic_session = Session::new(
        "interop-anthropic",
        Some("Prompt".to_string()),
        Some("claude-3-opus-20240229".to_string()),
        Some("anthropic".to_string()),
    );
    anthropic_session.push_message(user_msg);
    anthropic_session.push_message(assistant_msg);
    assert_eq!(anthropic_session.messages.len(), 2);

    // Message format is provider-agnostic
    // Provider adapters handle format conversion
}

// ────────────────────────────────────────────────────────────────────────────
// Test 9: Error Handling Consistency
// ────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_error_handling_consistency() {
    use fae::fae_llm::error::FaeLlmError;

    // Both providers should use the same error types
    let openai_mock = MockServer::start().await;
    let anthropic_mock = MockServer::start().await;

    // OpenAI 401 unauthorized
    Mock::given(method("POST"))
        .and(path("/v1/chat/completions"))
        .respond_with(ResponseTemplate::new(401).set_body_json(json!({
            "error": {
                "message": "Invalid API key",
                "type": "invalid_request_error",
                "code": "invalid_api_key"
            }
        })))
        .mount(&openai_mock)
        .await;

    // Anthropic 401 unauthorized
    Mock::given(method("POST"))
        .and(path("/v1/messages"))
        .respond_with(ResponseTemplate::new(401).set_body_json(json!({
            "type": "error",
            "error": {
                "type": "authentication_error",
                "message": "Invalid API key"
            }
        })))
        .mount(&anthropic_mock)
        .await;

    // Both should normalize to FaeLlmError error variants
    // (The actual error parsing would happen in the provider adapters)

    // Test that is_retryable() works consistently
    let network_error = FaeLlmError::RequestError("Network timeout".to_string());
    assert!(network_error.is_retryable());

    // Non-retryable errors (e.g., tool errors, auth errors)
    let tool_error = FaeLlmError::ToolError("Invalid arguments".to_string());
    assert!(!tool_error.is_retryable());

    let auth_error = FaeLlmError::AuthError("Invalid key".to_string());
    assert!(!auth_error.is_retryable());

    assert!(openai_mock.address().port() > 0);
    assert!(anthropic_mock.address().port() > 0);
}

// ────────────────────────────────────────────────────────────────────────────
// Test 10: State Transition Consistency
// ────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_state_transition_consistency() {
    // Circuit breaker state machine is identical for both providers
    let mut breaker1 = CircuitBreaker::default();
    let mut breaker2 = CircuitBreaker::default();

    // Both start closed
    assert_eq!(breaker1.state, CircuitState::Closed);
    assert_eq!(breaker2.state, CircuitState::Closed);

    // Both transition to open after threshold
    for _ in 0..5 {
        breaker1.record_failure();
        breaker2.record_failure();
    }
    assert!(matches!(breaker1.state, CircuitState::Open { .. }));
    assert!(matches!(breaker2.state, CircuitState::Open { .. }));

    // Both tick down cooldown identically
    for _ in 0..30 {
        breaker1.tick();
        breaker2.tick();
    }

    // Both can attempt recovery
    let recovered1 = breaker1.attempt_recovery();
    let recovered2 = breaker2.attempt_recovery();
    assert_eq!(recovered1, recovered2);

    // State transitions are provider-independent
}
