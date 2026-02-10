//! Integration tests for the local LLM HTTP server.
//!
//! Tests marked `#[ignore]` require a loaded mistralrs model and are too
//! expensive for CI. Run them manually with `cargo test -- --ignored`.

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use fae::config::LlmServerConfig;
use fae::llm::pi_config;
use fae::llm::server::{
    ChatCompletionChunk, ChatCompletionRequest, ChatCompletionResponse, ChatMessage,
    ModelListResponse,
};
use std::path::PathBuf;

// ---------------------------------------------------------------------------
// Pi config tests
// ---------------------------------------------------------------------------

fn temp_pi_path(name: &str) -> PathBuf {
    std::env::temp_dir()
        .join("fae-test-llm-server")
        .join(name)
        .join("models.json")
}

fn cleanup(path: &std::path::Path) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::remove_dir_all(parent);
    }
}

#[test]
fn pi_config_merge_preserves_existing_providers() {
    let path = temp_pi_path("merge-preserve");
    cleanup(&path);

    // Set up an existing provider
    let mut config = pi_config::PiModelsConfig::default();
    config.providers.insert(
        "anthropic".to_owned(),
        pi_config::PiProvider {
            base_url: "https://api.anthropic.com/v1".to_owned(),
            api: "anthropic".to_owned(),
            api_key: "sk-test".to_owned(),
            models: vec![pi_config::PiModel {
                id: "claude-3".to_owned(),
                name: "Claude 3".to_owned(),
                reasoning: true,
                input: vec!["text".to_owned()],
                context_window: 200_000,
                max_tokens: 4096,
                cost: 0.003,
            }],
        },
    );

    // Write the existing config
    let json = serde_json::to_string_pretty(&config).unwrap();
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, &json).unwrap();

    // Now merge fae-local
    pi_config::write_fae_local_provider(&path, 12345).unwrap();

    // Verify both exist
    let result = pi_config::read_pi_config(&path).unwrap();
    assert!(result.providers.contains_key("anthropic"));
    assert!(result.providers.contains_key("fae-local"));
    assert_eq!(
        result.providers["anthropic"].base_url,
        "https://api.anthropic.com/v1"
    );
    assert_eq!(result.providers["anthropic"].api_key, "sk-test");
    assert_eq!(
        result.providers["fae-local"].base_url,
        "http://127.0.0.1:12345/v1"
    );

    cleanup(&path);
}

#[test]
fn pi_config_cleanup_on_remove() {
    let path = temp_pi_path("cleanup");
    cleanup(&path);

    // Write fae-local, then remove it
    pi_config::write_fae_local_provider(&path, 8080).unwrap();
    assert!(pi_config::read_pi_config(&path)
        .unwrap()
        .providers
        .contains_key("fae-local"));

    pi_config::remove_fae_local_provider(&path).unwrap();
    assert!(!pi_config::read_pi_config(&path)
        .unwrap()
        .providers
        .contains_key("fae-local"));

    cleanup(&path);
}

// ---------------------------------------------------------------------------
// Server config tests
// ---------------------------------------------------------------------------

#[test]
fn llm_server_config_defaults_are_sensible() {
    let config = LlmServerConfig::default();
    assert!(config.enabled);
    assert_eq!(config.port, 0); // Auto-assign
    assert_eq!(config.host, "127.0.0.1");
}

#[test]
fn llm_server_config_toml_round_trip() {
    let config = LlmServerConfig {
        enabled: false,
        port: 9090,
        host: "0.0.0.0".to_owned(),
    };
    let toml_str = toml::to_string_pretty(&config).unwrap();
    let parsed: LlmServerConfig = toml::from_str(&toml_str).unwrap();
    assert!(!parsed.enabled);
    assert_eq!(parsed.port, 9090);
    assert_eq!(parsed.host, "0.0.0.0");
}

#[test]
fn llm_server_config_in_speech_config() {
    let toml_str = r#"
[llm_server]
enabled = true
port = 8080
host = "127.0.0.1"
"#;
    let config: fae::config::SpeechConfig = toml::from_str(toml_str).unwrap();
    assert!(config.llm_server.enabled);
    assert_eq!(config.llm_server.port, 8080);
}

// ---------------------------------------------------------------------------
// Type serde tests
// ---------------------------------------------------------------------------

#[test]
fn chat_completion_request_from_openai_format() {
    let json = r#"{
        "model": "fae-qwen3",
        "messages": [
            {"role": "system", "content": "You are helpful."},
            {"role": "user", "content": "Hello!"}
        ],
        "stream": true,
        "temperature": 0.5,
        "max_tokens": 100
    }"#;
    let req: ChatCompletionRequest = serde_json::from_str(json).unwrap();
    assert_eq!(req.model, "fae-qwen3");
    assert_eq!(req.messages.len(), 2);
    assert_eq!(req.stream, Some(true));
    assert_eq!(req.temperature, Some(0.5));
    assert_eq!(req.max_tokens, Some(100));
}

#[test]
fn chat_completion_response_matches_openai_format() {
    let resp = ChatCompletionResponse {
        id: "chatcmpl-test".to_owned(),
        object: "chat.completion".to_owned(),
        created: 1_700_000_000,
        model: "fae-qwen3".to_owned(),
        choices: vec![fae::llm::server::Choice {
            index: 0,
            message: ChatMessage {
                role: "assistant".to_owned(),
                content: "Hello!".to_owned(),
            },
            finish_reason: Some("stop".to_owned()),
        }],
        usage: fae::llm::server::Usage {
            prompt_tokens: 10,
            completion_tokens: 5,
            total_tokens: 15,
        },
    };
    let json = serde_json::to_string(&resp).unwrap();
    assert!(json.contains("\"object\":\"chat.completion\""));
    assert!(json.contains("\"finish_reason\":\"stop\""));
}

#[test]
fn chat_completion_chunk_matches_openai_format() {
    let chunk = ChatCompletionChunk {
        id: "chatcmpl-test".to_owned(),
        object: "chat.completion.chunk".to_owned(),
        created: 1_700_000_000,
        model: "fae-qwen3".to_owned(),
        choices: vec![fae::llm::server::ChunkChoice {
            index: 0,
            delta: fae::llm::server::Delta {
                role: None,
                content: Some("world".to_owned()),
            },
            finish_reason: None,
        }],
    };
    let json = serde_json::to_string(&chunk).unwrap();
    assert!(json.contains("\"chat.completion.chunk\""));
    assert!(json.contains("\"content\":\"world\""));
    // role should be absent (skip_serializing_if)
    assert!(!json.contains("\"role\""));
}

#[test]
fn model_list_response_matches_openai_format() {
    let resp = ModelListResponse {
        object: "list".to_owned(),
        data: vec![fae::llm::server::ModelObject {
            id: "fae-qwen3".to_owned(),
            object: "model".to_owned(),
            owned_by: "fae-local".to_owned(),
        }],
    };
    let json = serde_json::to_string(&resp).unwrap();
    assert!(json.contains("\"object\":\"list\""));
    assert!(json.contains("\"owned_by\":\"fae-local\""));
}

// ---------------------------------------------------------------------------
// Server endpoint tests (require a model — expensive, run with --ignored)
// ---------------------------------------------------------------------------

/// Start the server with a real model and test GET /v1/models.
///
/// This test requires a loaded mistralrs model and is too expensive for CI.
#[test]
#[ignore]
fn server_models_endpoint_returns_valid_response() {
    // This would require loading a real model. Placeholder for manual testing.
    // Use: cargo test server_models_endpoint -- --ignored
    todo!("requires real model loading — run manually");
}

/// Test POST /v1/chat/completions with stream: false.
#[test]
#[ignore]
fn server_non_streaming_completion() {
    todo!("requires real model loading — run manually");
}

/// Test POST /v1/chat/completions with stream: true returns valid SSE.
#[test]
#[ignore]
fn server_streaming_completion_returns_valid_sse() {
    todo!("requires real model loading — run manually");
}
