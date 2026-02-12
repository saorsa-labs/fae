//! Anthropic Provider Contract Tests
//!
//! These tests verify exact HTTP API format compliance for the Anthropic provider.
//! Tests verify request format, response parsing, error handling, and stop reason mapping.

use fae::fae_llm::error::FaeLlmError;
use fae::fae_llm::provider::{ProviderAdapter, ToolDefinition};
use fae::fae_llm::providers::anthropic::{AnthropicAdapter, AnthropicConfig};
use fae::fae_llm::providers::message::Message;
use fae::fae_llm::types::RequestOptions;
use serde_json::json;
use wiremock::matchers::{body_partial_json, header, method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

// ────────────────────────────────────────────────────────────────────────────
// Request Format Validation Tests
// ────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_request_includes_required_fields() {
    let mock_server = MockServer::start().await;

    // Anthropic requires: model, messages, max_tokens
    Mock::given(method("POST"))
        .and(path("/v1/messages"))
        .and(body_partial_json(json!({
            "model": "claude-3-5-sonnet-20241022",
            "messages": [{"role": "user", "content": [{"type": "text", "text": "Hello"}]}],
            "max_tokens": 4096
        })))
        .respond_with(ResponseTemplate::new(200).set_body_string(
            concat!(
                "event: message_start\n",
                "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_test\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n",
                "event: message_delta\n",
                "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n",
                "event: message_stop\n",
                "data: {\"type\":\"message_stop\"}\n\n"
            )
        ))
        .expect(1)
        .mount(&mock_server)
        .await;

    let config = AnthropicConfig::new("test-key", "claude-3-5-sonnet-20241022")
        .with_base_url(mock_server.uri());
    let adapter = AnthropicAdapter::new(config);

    let messages = vec![Message::user("Hello")];
    let options = RequestOptions::new().with_max_tokens(4096);
    let result = adapter.send(&messages, &options, &[]).await;

    assert!(result.is_ok(), "Request should succeed");
}

#[tokio::test]
async fn test_request_includes_api_key_header() {
    let mock_server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/v1/messages"))
        .and(header("x-api-key", "test-anthropic-key"))
        .respond_with(ResponseTemplate::new(200).set_body_string(
            concat!(
                "event: message_start\n",
                "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_test\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n",
                "event: message_delta\n",
                "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n",
                "event: message_stop\n",
                "data: {\"type\":\"message_stop\"}\n\n"
            )
        ))
        .expect(1)
        .mount(&mock_server)
        .await;

    let config = AnthropicConfig::new("test-anthropic-key", "claude-3-5-sonnet-20241022")
        .with_base_url(mock_server.uri());
    let adapter = AnthropicAdapter::new(config);

    let messages = vec![Message::user("Test")];
    let options = RequestOptions::new().with_max_tokens(1024);
    let result = adapter.send(&messages, &options, &[]).await;

    assert!(result.is_ok());
}

#[tokio::test]
async fn test_request_includes_stream_option() {
    let mock_server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/v1/messages"))
        .and(body_partial_json(json!({"stream": true})))
        .respond_with(ResponseTemplate::new(200).set_body_string(
            concat!(
                "event: message_start\n",
                "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_test\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n",
                "event: message_delta\n",
                "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n",
                "event: message_stop\n",
                "data: {\"type\":\"message_stop\"}\n\n"
            )
        ))
        .expect(1)
        .mount(&mock_server)
        .await;

    let config = AnthropicConfig::new("test-key", "claude-3-5-sonnet-20241022")
        .with_base_url(mock_server.uri());
    let adapter = AnthropicAdapter::new(config);

    let messages = vec![Message::user("Test")];
    let options = RequestOptions::new()
        .with_stream(true)
        .with_max_tokens(1024);
    let result = adapter.send(&messages, &options, &[]).await;

    assert!(result.is_ok());
}

#[tokio::test]
async fn test_request_includes_temperature() {
    let mock_server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/v1/messages"))
        .and(body_partial_json(json!({"temperature": 0.7})))
        .respond_with(ResponseTemplate::new(200).set_body_string(
            concat!(
                "event: message_start\n",
                "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_test\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n",
                "event: message_delta\n",
                "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n",
                "event: message_stop\n",
                "data: {\"type\":\"message_stop\"}\n\n"
            )
        ))
        .expect(1)
        .mount(&mock_server)
        .await;

    let config = AnthropicConfig::new("test-key", "claude-3-5-sonnet-20241022")
        .with_base_url(mock_server.uri());
    let adapter = AnthropicAdapter::new(config);

    let messages = vec![Message::user("Test")];
    let options = RequestOptions::new()
        .with_temperature(0.7)
        .with_max_tokens(1024);
    let result = adapter.send(&messages, &options, &[]).await;

    assert!(result.is_ok());
}

#[tokio::test]
async fn test_request_includes_tools() {
    let mock_server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/v1/messages"))
        .and(body_partial_json(json!({
            "tools": [{
                "name": "read_file",
                "description": "Read a file",
                "input_schema": {"type": "object", "properties": {}}
            }]
        })))
        .respond_with(ResponseTemplate::new(200).set_body_string(
            concat!(
                "event: message_start\n",
                "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_test\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n",
                "event: message_delta\n",
                "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n",
                "event: message_stop\n",
                "data: {\"type\":\"message_stop\"}\n\n"
            )
        ))
        .expect(1)
        .mount(&mock_server)
        .await;

    let config = AnthropicConfig::new("test-key", "claude-3-5-sonnet-20241022")
        .with_base_url(mock_server.uri());
    let adapter = AnthropicAdapter::new(config);

    let messages = vec![Message::user("Test")];
    let options = RequestOptions::new().with_max_tokens(1024);
    let tools = vec![ToolDefinition::new(
        "read_file",
        "Read a file",
        json!({"type": "object", "properties": {}}),
    )];

    let result = adapter.send(&messages, &options, &tools).await;
    assert!(result.is_ok());
}

// ────────────────────────────────────────────────────────────────────────────
// Error Response Tests
// ────────────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_error_401_unauthorized() {
    let mock_server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/v1/messages"))
        .respond_with(ResponseTemplate::new(401).set_body_json(json!({
            "type": "error",
            "error": {
                "type": "authentication_error",
                "message": "Invalid API key"
            }
        })))
        .mount(&mock_server)
        .await;

    let config = AnthropicConfig::new("bad-key", "claude-3-5-sonnet-20241022")
        .with_base_url(mock_server.uri());
    let adapter = AnthropicAdapter::new(config);

    let messages = vec![Message::user("Test")];
    let options = RequestOptions::new().with_max_tokens(1024);
    let result = adapter.send(&messages, &options, &[]).await;

    assert!(result.is_err(), "401 error should return Err");
    let err = result.err();
    assert!(err.is_some());
    match err {
        Some(FaeLlmError::AuthError(_)) => {
            // Expected auth error
        }
        _ => panic!("Expected AuthError for 401"),
    }
}

#[tokio::test]
async fn test_error_429_rate_limit() {
    let mock_server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/v1/messages"))
        .respond_with(ResponseTemplate::new(429).set_body_json(json!({
            "type": "error",
            "error": {
                "type": "rate_limit_error",
                "message": "Rate limit exceeded"
            }
        })))
        .mount(&mock_server)
        .await;

    let config = AnthropicConfig::new("test-key", "claude-3-5-sonnet-20241022")
        .with_base_url(mock_server.uri());
    let adapter = AnthropicAdapter::new(config);

    let messages = vec![Message::user("Test")];
    let options = RequestOptions::new().with_max_tokens(1024);
    let result = adapter.send(&messages, &options, &[]).await;

    assert!(result.is_err(), "429 error should return Err");
}

#[tokio::test]
async fn test_error_500_server_error() {
    let mock_server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/v1/messages"))
        .respond_with(ResponseTemplate::new(500).set_body_json(json!({
            "type": "error",
            "error": {
                "type": "api_error",
                "message": "Internal server error"
            }
        })))
        .mount(&mock_server)
        .await;

    let config = AnthropicConfig::new("test-key", "claude-3-5-sonnet-20241022")
        .with_base_url(mock_server.uri());
    let adapter = AnthropicAdapter::new(config);

    let messages = vec![Message::user("Test")];
    let options = RequestOptions::new().with_max_tokens(1024);
    let result = adapter.send(&messages, &options, &[]).await;

    assert!(result.is_err(), "500 error should return Err");
}
