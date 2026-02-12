//! Integration tests for `LocalProbeService`.
//!
//! Tests cover all probe scenarios: health checks, model discovery, error
//! handling, backoff retry logic, and concurrent safety.

use super::local_probe::{LocalModel, LocalProbeService, ProbeConfig, ProbeStatus};
use std::sync::Arc;
use std::time::Duration;
use tokio::time::Instant;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

// ── Health Check Tests ────────────────────────────────────────────

#[tokio::test]
async fn test_health_check_success() {
    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/"))
        .respond_with(ResponseTemplate::new(200).set_body_string("OK"))
        .mount(&server)
        .await;

    let config = ProbeConfig::new(server.uri())
        .with_timeout_secs(2)
        .with_retry_count(0);
    let service = LocalProbeService::new(config);

    let result = service.check_health().await;
    assert!(result.is_ok());

    let status = result.unwrap_or_else(|e| panic!("Expected Ok, got Err: {e}"));
    assert!(
        matches!(status, ProbeStatus::Available { .. }),
        "Expected Available, got: {status:?}"
    );
}

#[tokio::test]
async fn test_health_check_500_error() {
    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/"))
        .respond_with(ResponseTemplate::new(500).set_body_string("Internal Server Error"))
        .mount(&server)
        .await;

    let config = ProbeConfig::new(server.uri())
        .with_timeout_secs(2)
        .with_retry_count(0);
    let service = LocalProbeService::new(config);

    let result = service.check_health().await;
    assert!(result.is_ok());

    let status = result.unwrap_or_else(|e| panic!("Expected Ok, got Err: {e}"));
    match status {
        ProbeStatus::Unhealthy {
            status_code,
            message,
        } => {
            assert_eq!(status_code, 500);
            assert!(message.contains("Internal Server Error"));
        }
        _ => panic!("Expected Unhealthy, got: {status:?}"),
    }
}

#[tokio::test]
async fn test_health_check_timeout() {
    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_string("delayed")
                .set_delay(Duration::from_secs(10)),
        )
        .mount(&server)
        .await;

    let config = ProbeConfig::new(server.uri())
        .with_timeout_secs(1)
        .with_retry_count(0);
    let service = LocalProbeService::new(config);

    let result = service.check_health().await;
    assert!(result.is_ok());

    let status = result.unwrap_or_else(|e| panic!("Expected Ok, got Err: {e}"));
    assert!(
        matches!(status, ProbeStatus::Timeout),
        "Expected Timeout, got: {status:?}"
    );
}

#[tokio::test]
async fn test_health_check_connection_refused() {
    // Use a port that's guaranteed to not have a server
    let config = ProbeConfig::new("http://localhost:59999")
        .with_timeout_secs(1)
        .with_retry_count(0);
    let service = LocalProbeService::new(config);

    let result = service.check_health().await;
    assert!(result.is_ok());

    let status = result.unwrap_or_else(|e| panic!("Expected Ok, got Err: {e}"));
    assert!(
        matches!(status, ProbeStatus::NotRunning),
        "Expected NotRunning, got: {status:?}"
    );
}

// ── Model Discovery Tests ─────────────────────────────────────────

#[tokio::test]
async fn test_discover_models_openai_format() {
    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/v1/models"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "data": [
                {"id": "gpt-4", "object": "model"},
                {"id": "gpt-3.5-turbo", "object": "model"}
            ]
        })))
        .mount(&server)
        .await;

    let config = ProbeConfig::new(server.uri())
        .with_timeout_secs(2)
        .with_retry_count(0);
    let service = LocalProbeService::new(config);

    let result = service.discover_models().await;
    assert!(result.is_ok());

    let status = result.unwrap_or_else(|e| panic!("Expected Ok, got Err: {e}"));
    match status {
        ProbeStatus::Available { models, .. } => {
            assert_eq!(models.len(), 2);
            assert_eq!(models[0].id, "gpt-4");
            assert_eq!(models[1].id, "gpt-3.5-turbo");
        }
        _ => panic!("Expected Available, got: {status:?}"),
    }
}

#[tokio::test]
async fn test_discover_models_ollama_format() {
    let server = MockServer::start().await;

    // /v1/models returns 404, forcing fallback to /api/tags
    Mock::given(method("GET"))
        .and(path("/v1/models"))
        .respond_with(ResponseTemplate::new(404))
        .mount(&server)
        .await;

    Mock::given(method("GET"))
        .and(path("/api/tags"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "models": [
                {"name": "llama3:8b"},
                {"name": "mistral:7b"}
            ]
        })))
        .mount(&server)
        .await;

    let config = ProbeConfig::new(server.uri())
        .with_timeout_secs(2)
        .with_retry_count(0);
    let service = LocalProbeService::new(config);

    let result = service.discover_models().await;
    assert!(result.is_ok());

    let status = result.unwrap_or_else(|e| panic!("Expected Ok, got Err: {e}"));
    match status {
        ProbeStatus::Available { models, .. } => {
            assert_eq!(models.len(), 2);
            assert_eq!(models[0].id, "llama3:8b");
            assert_eq!(models[1].id, "mistral:7b");
        }
        _ => panic!("Expected Available, got: {status:?}"),
    }
}

#[tokio::test]
async fn test_discover_models_incompatible_response() {
    let server = MockServer::start().await;

    // Both endpoints return invalid JSON
    Mock::given(method("GET"))
        .and(path("/v1/models"))
        .respond_with(ResponseTemplate::new(200).set_body_string("not json"))
        .mount(&server)
        .await;

    Mock::given(method("GET"))
        .and(path("/api/tags"))
        .respond_with(ResponseTemplate::new(200).set_body_string("also not json"))
        .mount(&server)
        .await;

    let config = ProbeConfig::new(server.uri())
        .with_timeout_secs(2)
        .with_retry_count(0);
    let service = LocalProbeService::new(config);

    let result = service.discover_models().await;
    assert!(result.is_ok());

    let status = result.unwrap_or_else(|e| panic!("Expected Ok, got Err: {e}"));
    match status {
        ProbeStatus::IncompatibleResponse { detail } => {
            assert!(detail.contains("neither /v1/models nor /api/tags"));
        }
        _ => panic!("Expected IncompatibleResponse, got: {status:?}"),
    }
}

// ── Retry Logic Tests ─────────────────────────────────────────────

#[tokio::test]
async fn test_probe_with_retry_exponential_backoff() {
    // Use a port that's guaranteed to not have a server
    let config = ProbeConfig::new("http://localhost:59998")
        .with_timeout_secs(1)
        .with_retry_count(2)
        .with_retry_delay_ms(100);

    let service = LocalProbeService::new(config);

    let start = Instant::now();
    let result = service.probe_with_retry().await;
    let elapsed = start.elapsed();

    assert!(result.is_ok());
    let status = result.unwrap_or_else(|e| panic!("Expected Ok, got Err: {e}"));
    assert!(
        matches!(status, ProbeStatus::NotRunning | ProbeStatus::Timeout),
        "Expected NotRunning or Timeout, got: {status:?}"
    );

    // Verify exponential backoff occurred
    // Expected delays: 100ms, 200ms (total ~300ms + overhead)
    assert!(
        elapsed >= Duration::from_millis(250),
        "Backoff should have added at least 250ms, but elapsed: {elapsed:?}"
    );
}

#[tokio::test]
async fn test_probe_retry_stops_on_unhealthy() {
    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/"))
        .respond_with(ResponseTemplate::new(503).set_body_string("Service Unavailable"))
        .expect(1) // Should only be called once, not retried
        .mount(&server)
        .await;

    let config = ProbeConfig::new(server.uri())
        .with_timeout_secs(2)
        .with_retry_count(3);
    let service = LocalProbeService::new(config);

    let result = service.probe_with_retry().await;
    assert!(result.is_ok());

    let status = result.unwrap_or_else(|e| panic!("Expected Ok, got Err: {e}"));
    match status {
        ProbeStatus::Unhealthy { status_code, .. } => {
            assert_eq!(status_code, 503);
        }
        _ => panic!("Expected Unhealthy, got: {status:?}"),
    }
}

// ── Concurrent Safety Tests ───────────────────────────────────────

#[tokio::test]
async fn test_concurrent_probes_do_not_interfere() {
    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/"))
        .respond_with(ResponseTemplate::new(200))
        .expect(3..)
        .mount(&server)
        .await;

    let config = ProbeConfig::new(server.uri())
        .with_timeout_secs(2)
        .with_retry_count(0);
    let service = Arc::new(LocalProbeService::new(config));

    // Spawn 3 concurrent probes
    let handles: Vec<_> = (0..3)
        .map(|_| {
            let svc = Arc::clone(&service);
            tokio::spawn(async move { svc.check_health().await })
        })
        .collect();

    let results = futures_util::future::join_all(handles).await;

    for result in results {
        let probe_result = result.unwrap_or_else(|e| panic!("Task panicked: {e}"));
        assert!(probe_result.is_ok());
        let status = probe_result.unwrap_or_else(|e| panic!("Expected Ok, got Err: {e}"));
        assert!(
            matches!(status, ProbeStatus::Available { .. }),
            "Expected Available, got: {status:?}"
        );
    }
}

// ── Backoff Cap Tests ─────────────────────────────────────────────

#[tokio::test]
async fn test_backoff_delay_capped_at_timeout() {
    // Verify that exponential backoff is capped at timeout_secs * 1000
    let config = ProbeConfig::new("http://localhost:59997")
        .with_timeout_secs(2)
        .with_retry_count(10)
        .with_retry_delay_ms(1000);

    let service = LocalProbeService::new(config);

    let start = Instant::now();
    let result = service.probe_with_retry().await;
    let elapsed = start.elapsed();

    assert!(result.is_ok());

    // With 10 retries and exponential backoff, without capping we'd expect
    // delays like 1000, 2000, 4000, 8000, 16000... which would be huge.
    // With capping at 2000ms, each delay is at most 2000ms.
    // Total should be roughly 10 * 2000ms = 20s, but we'll check it's under 25s.
    assert!(
        elapsed < Duration::from_secs(25),
        "Backoff should be capped, but elapsed: {elapsed:?}"
    );
}

// ── Edge Case Tests ───────────────────────────────────────────────

#[tokio::test]
async fn test_probe_with_zero_retries() {
    let config = ProbeConfig::new("http://localhost:59996")
        .with_timeout_secs(1)
        .with_retry_count(0);
    let service = LocalProbeService::new(config);

    let start = Instant::now();
    let result = service.probe_with_retry().await;
    let elapsed = start.elapsed();

    assert!(result.is_ok());
    let status = result.unwrap_or_else(|e| panic!("Expected Ok, got Err: {e}"));
    assert!(
        matches!(status, ProbeStatus::NotRunning),
        "Expected NotRunning, got: {status:?}"
    );

    // Should return quickly (no retries)
    assert!(
        elapsed < Duration::from_secs(3),
        "No retries should complete quickly, but elapsed: {elapsed:?}"
    );
}

#[tokio::test]
async fn test_probe_with_invalid_json_in_models_endpoint() {
    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/v1/models"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(serde_json::json!({"data": "not an array"})),
        )
        .mount(&server)
        .await;

    Mock::given(method("GET"))
        .and(path("/api/tags"))
        .respond_with(ResponseTemplate::new(404))
        .mount(&server)
        .await;

    let config = ProbeConfig::new(server.uri())
        .with_timeout_secs(2)
        .with_retry_count(0);
    let service = LocalProbeService::new(config);

    let result = service.discover_models().await;
    assert!(result.is_ok());

    let status = result.unwrap_or_else(|e| panic!("Expected Ok, got Err: {e}"));
    match status {
        ProbeStatus::IncompatibleResponse { .. } | ProbeStatus::Unhealthy { .. } => {
            // Either is acceptable - invalid JSON or 404 on fallback
        }
        _ => panic!("Expected IncompatibleResponse or Unhealthy, got: {status:?}"),
    }
}

#[tokio::test]
async fn test_local_model_display_name() {
    let model1 = LocalModel::new("llama3:8b");
    assert_eq!(model1.display_name(), "llama3:8b");
    assert_eq!(model1.to_string(), "llama3:8b");

    let model2 = LocalModel::new("gpt-4").with_name("GPT-4");
    assert_eq!(model2.display_name(), "GPT-4");
    assert_eq!(model2.to_string(), "GPT-4");
}

#[tokio::test]
async fn test_probe_status_is_available() {
    let available = ProbeStatus::Available {
        models: vec![LocalModel::new("test")],
        endpoint_url: "http://localhost:11434".to_string(),
        latency_ms: 50,
    };
    assert!(available.is_available());

    let not_running = ProbeStatus::NotRunning;
    assert!(!not_running.is_available());

    let timeout = ProbeStatus::Timeout;
    assert!(!timeout.is_available());

    let unhealthy = ProbeStatus::Unhealthy {
        status_code: 500,
        message: "error".to_string(),
    };
    assert!(!unhealthy.is_available());

    let incompatible = ProbeStatus::IncompatibleResponse {
        detail: "bad format".to_string(),
    };
    assert!(!incompatible.is_available());
}

#[tokio::test]
async fn test_probe_status_models_accessor() {
    let models = vec![LocalModel::new("model1"), LocalModel::new("model2")];
    let available = ProbeStatus::Available {
        models: models.clone(),
        endpoint_url: "http://localhost:11434".to_string(),
        latency_ms: 50,
    };
    assert_eq!(available.models().len(), 2);
    assert_eq!(available.models()[0].id, "model1");

    let not_running = ProbeStatus::NotRunning;
    assert_eq!(not_running.models().len(), 0);
}

#[tokio::test]
async fn test_probe_status_endpoint_url_accessor() {
    let available = ProbeStatus::Available {
        models: vec![],
        endpoint_url: "http://localhost:11434".to_string(),
        latency_ms: 50,
    };
    assert_eq!(available.endpoint_url(), Some("http://localhost:11434"));

    let not_running = ProbeStatus::NotRunning;
    assert_eq!(not_running.endpoint_url(), None);
}
