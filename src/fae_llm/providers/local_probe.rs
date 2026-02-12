//! Local endpoint probe service.
//!
//! Provides [`LocalProbeService`] for health-checking and model discovery
//! against local LLM endpoints (Ollama, llama.cpp, vLLM, etc.).
//!
//! This is a **read-only diagnostic service** — it never starts, stops,
//! or manages model processes. A future `RuntimeManager` may extend this.
//!
//! # Status Model
//!
//! A probe returns a [`ProbeStatus`] indicating the endpoint state:
//!
//! - [`Available`](ProbeStatus::Available) — endpoint responds and lists models
//! - [`NotRunning`](ProbeStatus::NotRunning) — connection refused / unreachable
//! - [`Timeout`](ProbeStatus::Timeout) — no response within deadline
//! - [`Unhealthy`](ProbeStatus::Unhealthy) — responds with an error status code
//! - [`IncompatibleResponse`](ProbeStatus::IncompatibleResponse) — responds but
//!   payload is not a recognized LLM API format

use serde::{Deserialize, Serialize};
use std::fmt;

// ── Types ──────────────────────────────────────────────────────

/// A model advertised by a local LLM endpoint.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalModel {
    /// Provider-specific model identifier (e.g. `"llama3:8b"`).
    pub id: String,
    /// Optional human-readable display name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

impl LocalModel {
    /// Create a new local model with just an id.
    pub fn new(id: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            name: None,
        }
    }

    /// Attach a display name.
    pub fn with_name(mut self, name: impl Into<String>) -> Self {
        self.name = Some(name.into());
        self
    }

    /// Returns the display name if set, otherwise the id.
    pub fn display_name(&self) -> &str {
        self.name.as_deref().unwrap_or(&self.id)
    }
}

impl fmt::Display for LocalModel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.display_name())
    }
}

/// Status of a local LLM endpoint after probing.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ProbeStatus {
    /// Endpoint is running and lists available models.
    Available {
        /// Models discovered at this endpoint.
        models: Vec<LocalModel>,
        /// The endpoint URL that was probed.
        endpoint_url: String,
        /// Round-trip latency in milliseconds.
        latency_ms: u64,
    },
    /// Endpoint is not running (connection refused / unreachable).
    NotRunning,
    /// Probe timed out waiting for a response.
    Timeout,
    /// Endpoint responded with an HTTP error status.
    Unhealthy {
        /// HTTP status code.
        status_code: u16,
        /// Human-readable error message from the response body.
        message: String,
    },
    /// Endpoint responded but the payload is not a recognized LLM API format.
    IncompatibleResponse {
        /// Description of why the response is incompatible.
        detail: String,
    },
}

impl ProbeStatus {
    /// Returns `true` if the endpoint is available and serving models.
    pub fn is_available(&self) -> bool {
        matches!(self, Self::Available { .. })
    }

    /// Returns the discovered models, or an empty slice if unavailable.
    pub fn models(&self) -> &[LocalModel] {
        match self {
            Self::Available { models, .. } => models,
            _ => &[],
        }
    }

    /// Returns the endpoint URL if available, or `None`.
    pub fn endpoint_url(&self) -> Option<&str> {
        match self {
            Self::Available { endpoint_url, .. } => Some(endpoint_url),
            _ => None,
        }
    }
}

impl fmt::Display for ProbeStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Available {
                models,
                endpoint_url,
                latency_ms,
            } => {
                write!(
                    f,
                    "Available at {endpoint_url} ({latency_ms}ms) — {} model(s)",
                    models.len()
                )
            }
            Self::NotRunning => write!(f, "Not running (connection refused)"),
            Self::Timeout => write!(f, "Timeout (no response)"),
            Self::Unhealthy {
                status_code,
                message,
            } => {
                write!(f, "Unhealthy (HTTP {status_code}): {message}")
            }
            Self::IncompatibleResponse { detail } => {
                write!(f, "Incompatible response: {detail}")
            }
        }
    }
}

/// Errors that can occur during endpoint probing.
///
/// Unlike [`ProbeStatus`] which describes the *state* of the endpoint,
/// `ProbeError` represents failures in the probing machinery itself.
#[derive(Debug, Clone, thiserror::Error)]
pub enum ProbeError {
    /// The probe URL is malformed or invalid.
    #[error("invalid endpoint URL: {0}")]
    InvalidUrl(String),

    /// An unexpected I/O or transport error occurred.
    #[error("transport error: {0}")]
    TransportError(String),
}

/// Result of a probe operation.
pub type ProbeResult = Result<ProbeStatus, ProbeError>;

/// Configuration for the local probe service.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProbeConfig {
    /// Base URL of the local endpoint to probe.
    pub endpoint_url: String,
    /// Maximum time in seconds to wait for a response.
    #[serde(default = "default_timeout_secs")]
    pub timeout_secs: u64,
    /// Number of retries on transient failures (NotRunning, Timeout).
    #[serde(default = "default_retry_count")]
    pub retry_count: u32,
    /// Initial delay between retries in milliseconds.
    #[serde(default = "default_retry_delay_ms")]
    pub retry_delay_ms: u64,
}

fn default_timeout_secs() -> u64 {
    5
}

fn default_retry_count() -> u32 {
    2
}

fn default_retry_delay_ms() -> u64 {
    500
}

impl Default for ProbeConfig {
    fn default() -> Self {
        Self {
            endpoint_url: "http://localhost:11434".to_string(),
            timeout_secs: default_timeout_secs(),
            retry_count: default_retry_count(),
            retry_delay_ms: default_retry_delay_ms(),
        }
    }
}

impl ProbeConfig {
    /// Create a probe config for a specific endpoint URL.
    pub fn new(endpoint_url: impl Into<String>) -> Self {
        Self {
            endpoint_url: endpoint_url.into(),
            ..Default::default()
        }
    }

    /// Set the timeout in seconds.
    pub fn with_timeout_secs(mut self, secs: u64) -> Self {
        self.timeout_secs = secs;
        self
    }

    /// Set the retry count.
    pub fn with_retry_count(mut self, count: u32) -> Self {
        self.retry_count = count;
        self
    }

    /// Set the initial retry delay in milliseconds.
    pub fn with_retry_delay_ms(mut self, ms: u64) -> Self {
        self.retry_delay_ms = ms;
        self
    }
}

/// Service for probing local LLM endpoints.
///
/// Checks endpoint health, discovers available models, and reports
/// diagnostic status for app-menu display and provider selection.
///
/// # Example
///
/// ```rust,no_run
/// use fae::fae_llm::providers::local_probe::{LocalProbeService, ProbeConfig};
///
/// # async fn example() {
/// let service = LocalProbeService::with_defaults();
/// let status = service.probe().await;
/// match status {
///     Ok(s) if s.is_available() => {
///         println!("Models: {:?}", s.models());
///     }
///     Ok(s) => println!("Endpoint status: {s}"),
///     Err(e) => eprintln!("Probe error: {e}"),
/// }
/// # }
/// ```
pub struct LocalProbeService {
    /// Probe configuration.
    config: ProbeConfig,
    /// Shared HTTP client.
    client: reqwest::Client,
}

impl LocalProbeService {
    /// Create a new probe service with the given configuration.
    pub fn new(config: ProbeConfig) -> Self {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(config.timeout_secs))
            .build()
            .unwrap_or_default();
        Self { config, client }
    }

    /// Create a probe service with default configuration (Ollama at localhost:11434).
    pub fn with_defaults() -> Self {
        Self::new(ProbeConfig::default())
    }

    /// Returns a reference to the probe configuration.
    pub fn config(&self) -> &ProbeConfig {
        &self.config
    }

    /// Check if the endpoint is reachable.
    ///
    /// Sends a GET request to the root URL. Maps transport errors to
    /// `ProbeStatus::NotRunning` or `ProbeStatus::Timeout`.
    pub async fn check_health(&self) -> ProbeResult {
        let url = format!("{}/", self.config.endpoint_url.trim_end_matches('/'));

        let start = std::time::Instant::now();
        match self.client.get(&url).send().await {
            Ok(resp) => {
                let latency_ms = start.elapsed().as_millis() as u64;
                let status_code = resp.status().as_u16();

                if resp.status().is_success() {
                    Ok(ProbeStatus::Available {
                        models: Vec::new(),
                        endpoint_url: self.config.endpoint_url.clone(),
                        latency_ms,
                    })
                } else {
                    let body = resp.text().await.unwrap_or_default();
                    let message = if body.is_empty() {
                        format!("HTTP {status_code}")
                    } else {
                        body.chars().take(500).collect()
                    };
                    Ok(ProbeStatus::Unhealthy {
                        status_code,
                        message,
                    })
                }
            }
            Err(e) => Ok(classify_reqwest_error(&e)),
        }
    }

    /// Discover models by querying the `/v1/models` endpoint.
    ///
    /// Falls back to `/api/tags` (Ollama format) if `/v1/models` fails.
    pub async fn discover_models(&self) -> ProbeResult {
        let base = self.config.endpoint_url.trim_end_matches('/');

        // Try OpenAI-compatible /v1/models first
        let start = std::time::Instant::now();
        let v1_url = format!("{base}/v1/models");
        match self.client.get(&v1_url).send().await {
            Ok(resp) if resp.status().is_success() => {
                let latency_ms = start.elapsed().as_millis() as u64;
                let body = resp.text().await.unwrap_or_default();
                match parse_openai_models_response(&body) {
                    Some(models) => {
                        return Ok(ProbeStatus::Available {
                            models,
                            endpoint_url: self.config.endpoint_url.clone(),
                            latency_ms,
                        });
                    }
                    None => {
                        // Fall through to try Ollama format
                    }
                }
            }
            Ok(_) | Err(_) => {
                // Fall through to try Ollama format
            }
        }

        // Try Ollama /api/tags
        let start = std::time::Instant::now();
        let tags_url = format!("{base}/api/tags");
        match self.client.get(&tags_url).send().await {
            Ok(resp) if resp.status().is_success() => {
                let latency_ms = start.elapsed().as_millis() as u64;
                let body = resp.text().await.unwrap_or_default();
                match parse_ollama_tags_response(&body) {
                    Some(models) => Ok(ProbeStatus::Available {
                        models,
                        endpoint_url: self.config.endpoint_url.clone(),
                        latency_ms,
                    }),
                    None => Ok(ProbeStatus::IncompatibleResponse {
                        detail: "neither /v1/models nor /api/tags returned valid model list"
                            .to_string(),
                    }),
                }
            }
            Ok(resp) => {
                let status_code = resp.status().as_u16();
                let body = resp.text().await.unwrap_or_default();
                Ok(ProbeStatus::Unhealthy {
                    status_code,
                    message: body.chars().take(500).collect(),
                })
            }
            Err(e) => Ok(classify_reqwest_error(&e)),
        }
    }

    /// Probe with bounded exponential backoff retry.
    ///
    /// Retries only on `NotRunning` and `Timeout` statuses.
    /// `Unhealthy` and `IncompatibleResponse` are returned immediately.
    pub async fn probe_with_retry(&self) -> ProbeResult {
        let max_attempts = self.config.retry_count.saturating_add(1);
        let mut last_status = ProbeStatus::NotRunning;

        for attempt in 0..max_attempts {
            // Health check first
            match self.check_health().await? {
                ProbeStatus::Available { .. } => {
                    // Endpoint is reachable, try model discovery
                    return self.discover_models().await;
                }
                status @ (ProbeStatus::Unhealthy { .. }
                | ProbeStatus::IncompatibleResponse { .. }) => {
                    // Non-transient failure, return immediately
                    return Ok(status);
                }
                status @ (ProbeStatus::NotRunning | ProbeStatus::Timeout) => {
                    last_status = status;
                    // Transient failure, retry if we have attempts left
                    if attempt + 1 < max_attempts {
                        let shift = attempt.min(63);
                        let multiplier = 1u64.checked_shl(shift).unwrap_or(u64::MAX);
                        let delay_ms = self.config.retry_delay_ms.saturating_mul(multiplier);
                        let max_delay_ms = self.config.timeout_secs.saturating_mul(1000);
                        let capped_delay = delay_ms.min(max_delay_ms);
                        tokio::time::sleep(std::time::Duration::from_millis(capped_delay)).await;
                    }
                }
            }
        }

        Ok(last_status)
    }

    /// Probe the configured endpoint.
    ///
    /// This is the main entry point. It performs a health check, discovers
    /// models, and retries on transient failures according to the config.
    pub async fn probe(&self) -> ProbeResult {
        self.probe_with_retry().await
    }
}

// ── Helpers ────────────────────────────────────────────────────

/// Classify a reqwest error into a ProbeStatus.
fn classify_reqwest_error(err: &reqwest::Error) -> ProbeStatus {
    if err.is_timeout() {
        ProbeStatus::Timeout
    } else if err.is_connect() {
        ProbeStatus::NotRunning
    } else {
        ProbeStatus::IncompatibleResponse {
            detail: format!("transport error: {err}"),
        }
    }
}

/// Parse an OpenAI-compatible `/v1/models` response.
///
/// Expected format: `{"data": [{"id": "model-name", ...}, ...]}`
fn parse_openai_models_response(body: &str) -> Option<Vec<LocalModel>> {
    let json: serde_json::Value = serde_json::from_str(body).ok()?;
    let data = json.get("data")?.as_array()?;
    let models: Vec<LocalModel> = data
        .iter()
        .filter_map(|entry| {
            let id = entry.get("id")?.as_str()?;
            Some(LocalModel::new(id))
        })
        .collect();
    Some(models)
}

/// Parse an Ollama `/api/tags` response.
///
/// Expected format: `{"models": [{"name": "llama3:8b", ...}, ...]}`
fn parse_ollama_tags_response(body: &str) -> Option<Vec<LocalModel>> {
    let json: serde_json::Value = serde_json::from_str(body).ok()?;
    let models_arr = json.get("models")?.as_array()?;
    let models: Vec<LocalModel> = models_arr
        .iter()
        .filter_map(|entry| {
            let name = entry.get("name")?.as_str()?;
            Some(LocalModel::new(name))
        })
        .collect();
    Some(models)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── LocalModel ─────────────────────────────────────────────

    #[test]
    fn local_model_new() {
        let m = LocalModel::new("llama3:8b");
        assert_eq!(m.id, "llama3:8b");
        assert!(m.name.is_none());
    }

    #[test]
    fn local_model_with_name() {
        let m = LocalModel::new("llama3:8b").with_name("Llama 3 8B");
        assert_eq!(m.id, "llama3:8b");
        assert_eq!(m.name.as_deref(), Some("Llama 3 8B"));
    }

    #[test]
    fn local_model_display_name_uses_name() {
        let m = LocalModel::new("x").with_name("Nice Name");
        assert_eq!(m.display_name(), "Nice Name");
    }

    #[test]
    fn local_model_display_name_falls_back_to_id() {
        let m = LocalModel::new("llama3:8b");
        assert_eq!(m.display_name(), "llama3:8b");
    }

    #[test]
    fn local_model_display_trait() {
        let m = LocalModel::new("test-model").with_name("Test");
        assert_eq!(m.to_string(), "Test");
    }

    #[test]
    fn local_model_equality() {
        let a = LocalModel::new("x");
        let b = LocalModel::new("x");
        assert_eq!(a, b);

        let c = LocalModel::new("x").with_name("X");
        assert_ne!(a, c);
    }

    #[test]
    fn local_model_serde_round_trip() {
        let original = LocalModel::new("llama3:8b").with_name("Llama 3");
        let json = serde_json::to_string(&original).unwrap_or_default();
        let parsed: LocalModel =
            serde_json::from_str(&json).unwrap_or_else(|_| LocalModel::new(""));
        assert_eq!(parsed, original);
    }

    #[test]
    fn local_model_serde_without_name() {
        let original = LocalModel::new("qwen2:7b");
        let json = serde_json::to_string(&original).unwrap_or_default();
        assert!(!json.contains("name"));
        let parsed: LocalModel =
            serde_json::from_str(&json).unwrap_or_else(|_| LocalModel::new(""));
        assert_eq!(parsed, original);
    }

    // ── ProbeStatus ────────────────────────────────────────────

    #[test]
    fn probe_status_available() {
        let status = ProbeStatus::Available {
            models: vec![LocalModel::new("llama3")],
            endpoint_url: "http://localhost:11434".to_string(),
            latency_ms: 42,
        };
        assert!(status.is_available());
        assert_eq!(status.models().len(), 1);
        assert_eq!(
            status.endpoint_url(),
            Some("http://localhost:11434" as &str)
        );
    }

    #[test]
    fn probe_status_not_running() {
        let status = ProbeStatus::NotRunning;
        assert!(!status.is_available());
        assert!(status.models().is_empty());
        assert!(status.endpoint_url().is_none());
    }

    #[test]
    fn probe_status_timeout() {
        let status = ProbeStatus::Timeout;
        assert!(!status.is_available());
    }

    #[test]
    fn probe_status_unhealthy() {
        let status = ProbeStatus::Unhealthy {
            status_code: 500,
            message: "internal error".to_string(),
        };
        assert!(!status.is_available());
    }

    #[test]
    fn probe_status_incompatible() {
        let status = ProbeStatus::IncompatibleResponse {
            detail: "not JSON".to_string(),
        };
        assert!(!status.is_available());
    }

    #[test]
    fn probe_status_display_available() {
        let status = ProbeStatus::Available {
            models: vec![LocalModel::new("a"), LocalModel::new("b")],
            endpoint_url: "http://localhost:8080".to_string(),
            latency_ms: 15,
        };
        let display = status.to_string();
        assert!(display.contains("Available"));
        assert!(display.contains("8080"));
        assert!(display.contains("15ms"));
        assert!(display.contains("2 model(s)"));
    }

    #[test]
    fn probe_status_display_not_running() {
        assert_eq!(
            ProbeStatus::NotRunning.to_string(),
            "Not running (connection refused)"
        );
    }

    #[test]
    fn probe_status_display_timeout() {
        assert_eq!(ProbeStatus::Timeout.to_string(), "Timeout (no response)");
    }

    #[test]
    fn probe_status_display_unhealthy() {
        let status = ProbeStatus::Unhealthy {
            status_code: 503,
            message: "overloaded".to_string(),
        };
        let display = status.to_string();
        assert!(display.contains("503"));
        assert!(display.contains("overloaded"));
    }

    #[test]
    fn probe_status_display_incompatible() {
        let status = ProbeStatus::IncompatibleResponse {
            detail: "HTML page".to_string(),
        };
        let display = status.to_string();
        assert!(display.contains("HTML page"));
    }

    #[test]
    fn probe_status_serde_available() {
        let status = ProbeStatus::Available {
            models: vec![LocalModel::new("llama3")],
            endpoint_url: "http://localhost:11434".to_string(),
            latency_ms: 25,
        };
        let json = serde_json::to_string(&status).unwrap_or_default();
        assert!(json.contains("available"));
        let parsed: ProbeStatus =
            serde_json::from_str(&json).unwrap_or_else(|_| ProbeStatus::IncompatibleResponse {
                detail: "parse fail".into(),
            });
        assert!(parsed.is_available());
        assert_eq!(parsed.models().len(), 1);
    }

    #[test]
    fn probe_status_serde_not_running() {
        let status = ProbeStatus::NotRunning;
        let json = serde_json::to_string(&status).unwrap_or_default();
        let parsed: ProbeStatus =
            serde_json::from_str(&json).unwrap_or_else(|_| ProbeStatus::IncompatibleResponse {
                detail: "fail".into(),
            });
        assert!(!parsed.is_available());
        assert!(matches!(parsed, ProbeStatus::NotRunning));
    }

    #[test]
    fn probe_status_serde_unhealthy() {
        let status = ProbeStatus::Unhealthy {
            status_code: 502,
            message: "bad gateway".to_string(),
        };
        let json = serde_json::to_string(&status).unwrap_or_default();
        let parsed: ProbeStatus =
            serde_json::from_str(&json).unwrap_or_else(|_| ProbeStatus::IncompatibleResponse {
                detail: "fail".into(),
            });
        assert!(matches!(parsed, ProbeStatus::Unhealthy { .. }));
    }

    #[test]
    fn probe_status_serde_timeout() {
        let status = ProbeStatus::Timeout;
        let json = serde_json::to_string(&status).unwrap_or_default();
        let parsed: ProbeStatus =
            serde_json::from_str(&json).unwrap_or_else(|_| ProbeStatus::IncompatibleResponse {
                detail: "fail".into(),
            });
        assert!(matches!(parsed, ProbeStatus::Timeout));
    }

    #[test]
    fn probe_status_serde_incompatible() {
        let status = ProbeStatus::IncompatibleResponse {
            detail: "not an LLM".to_string(),
        };
        let json = serde_json::to_string(&status).unwrap_or_default();
        let parsed: ProbeStatus =
            serde_json::from_str(&json).unwrap_or_else(|_| ProbeStatus::IncompatibleResponse {
                detail: "fail".into(),
            });
        assert!(matches!(parsed, ProbeStatus::IncompatibleResponse { .. }));
    }

    // ── ProbeError ─────────────────────────────────────────────

    #[test]
    fn probe_error_invalid_url() {
        let err = ProbeError::InvalidUrl("not a url".to_string());
        let display = err.to_string();
        assert!(display.contains("not a url"));
    }

    #[test]
    fn probe_error_transport() {
        let err = ProbeError::TransportError("dns failed".to_string());
        let display = err.to_string();
        assert!(display.contains("dns failed"));
    }

    // ── ProbeConfig ────────────────────────────────────────────

    #[test]
    fn probe_config_defaults() {
        let config = ProbeConfig::default();
        assert_eq!(config.endpoint_url, "http://localhost:11434");
        assert_eq!(config.timeout_secs, 5);
        assert_eq!(config.retry_count, 2);
        assert_eq!(config.retry_delay_ms, 500);
    }

    #[test]
    fn probe_config_new() {
        let config = ProbeConfig::new("http://localhost:8080");
        assert_eq!(config.endpoint_url, "http://localhost:8080");
        assert_eq!(config.timeout_secs, 5);
    }

    #[test]
    fn probe_config_builder() {
        let config = ProbeConfig::new("http://localhost:9090")
            .with_timeout_secs(10)
            .with_retry_count(5)
            .with_retry_delay_ms(200);
        assert_eq!(config.endpoint_url, "http://localhost:9090");
        assert_eq!(config.timeout_secs, 10);
        assert_eq!(config.retry_count, 5);
        assert_eq!(config.retry_delay_ms, 200);
    }

    #[test]
    fn probe_config_serde_round_trip() {
        let config = ProbeConfig::new("http://example.com")
            .with_timeout_secs(15)
            .with_retry_count(3);
        let json = serde_json::to_string(&config).unwrap_or_default();
        let parsed: ProbeConfig =
            serde_json::from_str(&json).unwrap_or_else(|_| ProbeConfig::new("http://bad.com"));
        assert_eq!(parsed.endpoint_url, "http://example.com");
        assert_eq!(parsed.timeout_secs, 15);
        assert_eq!(parsed.retry_count, 3);
    }

    // ── LocalProbeService ──────────────────────────────────────

    #[test]
    fn probe_service_with_defaults() {
        let service = LocalProbeService::with_defaults();
        assert_eq!(service.config().endpoint_url, "http://localhost:11434");
        assert_eq!(service.config().timeout_secs, 5);
    }

    #[test]
    fn probe_service_custom_config() {
        let config = ProbeConfig::new("http://localhost:8080").with_timeout_secs(2);
        let service = LocalProbeService::new(config);
        assert_eq!(service.config().endpoint_url, "http://localhost:8080");
        assert_eq!(service.config().timeout_secs, 2);
    }

    // ── JSON Parsing Helpers ───────────────────────────────────

    #[test]
    fn parse_openai_models_valid() {
        let body = r#"{"data":[{"id":"gpt-4o","object":"model"},{"id":"gpt-3.5-turbo","object":"model"}]}"#;
        let models = parse_openai_models_response(body);
        assert!(models.is_some());
        let models = models.unwrap_or_default();
        assert_eq!(models.len(), 2);
        assert_eq!(models[0].id, "gpt-4o");
        assert_eq!(models[1].id, "gpt-3.5-turbo");
    }

    #[test]
    fn parse_openai_models_empty() {
        let body = r#"{"data":[]}"#;
        let models = parse_openai_models_response(body);
        assert!(models.is_some());
        assert!(models.unwrap_or_default().is_empty());
    }

    #[test]
    fn parse_openai_models_invalid_json() {
        assert!(parse_openai_models_response("not json").is_none());
    }

    #[test]
    fn parse_openai_models_missing_data() {
        assert!(parse_openai_models_response(r#"{"models":[]}"#).is_none());
    }

    #[test]
    fn parse_openai_models_missing_id() {
        let body = r#"{"data":[{"object":"model"}]}"#;
        let models = parse_openai_models_response(body);
        assert!(models.is_some());
        assert!(models.unwrap_or_default().is_empty());
    }

    #[test]
    fn parse_ollama_tags_valid() {
        let body =
            r#"{"models":[{"name":"llama3:8b","size":1234},{"name":"mistral:7b","size":5678}]}"#;
        let models = parse_ollama_tags_response(body);
        assert!(models.is_some());
        let models = models.unwrap_or_default();
        assert_eq!(models.len(), 2);
        assert_eq!(models[0].id, "llama3:8b");
        assert_eq!(models[1].id, "mistral:7b");
    }

    #[test]
    fn parse_ollama_tags_empty() {
        let body = r#"{"models":[]}"#;
        let models = parse_ollama_tags_response(body);
        assert!(models.is_some());
        assert!(models.unwrap_or_default().is_empty());
    }

    #[test]
    fn parse_ollama_tags_invalid_json() {
        assert!(parse_ollama_tags_response("garbage").is_none());
    }

    #[test]
    fn parse_ollama_tags_missing_models() {
        assert!(parse_ollama_tags_response(r#"{"data":[]}"#).is_none());
    }

    // ── classify_reqwest_error (indirectly tested via integration) ─

    // ── Send + Sync ────────────────────────────────────────────

    #[test]
    fn types_are_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<ProbeStatus>();
        assert_send_sync::<ProbeError>();
        assert_send_sync::<ProbeConfig>();
        assert_send_sync::<LocalModel>();
        assert_send_sync::<LocalProbeService>();
    }

    // ── Async Tests ────────────────────────────────────────────

    #[tokio::test]
    async fn probe_unreachable_returns_not_running_or_timeout() {
        // Use a port unlikely to be in use
        let config = ProbeConfig::new("http://127.0.0.1:19999")
            .with_timeout_secs(1)
            .with_retry_count(0);
        let service = LocalProbeService::new(config);
        let result = service.probe().await;
        assert!(result.is_ok());
        let status = result.unwrap_or(ProbeStatus::IncompatibleResponse {
            detail: "bad".into(),
        });
        assert!(
            matches!(status, ProbeStatus::NotRunning | ProbeStatus::Timeout),
            "expected NotRunning or Timeout, got: {status}"
        );
    }
}
