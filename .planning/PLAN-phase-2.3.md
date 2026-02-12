# Phase 2.3: Local Probe Service

## Goal
Implement a service that probes local LLM endpoints (Ollama, llama.cpp, vLLM, etc.) to determine if they are running, healthy, and what models are available. This is a read-only diagnostic service -- it does NOT start or manage model processes (that is deferred to a future RuntimeManager).

## Files
- `src/fae_llm/providers/local_probe.rs` — Core probe service implementation
- `src/fae_llm/providers/mod.rs` — Wire in local_probe module
- `src/fae_llm/mod.rs` — Re-export probe types

## Tasks

### Task 1: Define ProbeStatus and ProbeError types
Create `src/fae_llm/providers/local_probe.rs` with:
- `ProbeStatus` enum: `Available { models, endpoint_url, latency_ms }`, `NotRunning`, `Timeout`, `Unhealthy { status_code, message }`, `IncompatibleResponse { detail }`
- `ProbeError` enum with typed failure modes (not just strings)
- `ProbeResult` type alias = `Result<ProbeStatus, ProbeError>`
- `LocalModel` struct with `id: String` and `name: Option<String>`
- All types: Debug, Clone, Serialize, Deserialize
- Unit tests for type construction, equality, serde round-trip

### Task 2: Define ProbeConfig and LocalProbeService struct
Add to `local_probe.rs`:
- `ProbeConfig` struct: `endpoint_url: String`, `timeout_secs: u64` (default 5), `retry_count: u32` (default 2), `retry_delay_ms: u64` (default 500)
- `ProbeConfig::default()` targeting `http://localhost:11434` (Ollama default)
- `LocalProbeService` struct holding `config: ProbeConfig` and `client: reqwest::Client`
- `LocalProbeService::new(config)` constructor
- `LocalProbeService::with_defaults()` convenience constructor
- Unit tests for config defaults, construction

### Task 3: Implement health check probe
Add to `LocalProbeService`:
- `async fn check_health(&self) -> ProbeResult` — GET `{base_url}/` or `{base_url}/health`
- Maps HTTP status codes to ProbeStatus variants
- Connection refused → `NotRunning`
- Timeout → `Timeout`
- HTTP 200 → healthy (proceed to model discovery)
- HTTP 4xx/5xx → `Unhealthy { status_code, message }`
- Non-JSON/unexpected response → `IncompatibleResponse`
- Unit tests with expected mappings (no real HTTP needed for type logic)

### Task 4: Implement model discovery
Add to `LocalProbeService`:
- `async fn discover_models(&self) -> ProbeResult` — GET `{base_url}/v1/models` or `{base_url}/api/tags`
- Parse JSON response into `Vec<LocalModel>`
- Return `Available { models, endpoint_url, latency_ms }`
- Handle non-JSON responses gracefully → `IncompatibleResponse`
- Handle empty model lists → `Available` with empty vec (not an error)
- Unit tests for JSON parsing logic (separate from HTTP)

### Task 5: Implement bounded backoff retry
Add to `LocalProbeService`:
- `async fn probe_with_retry(&self) -> ProbeResult` — Orchestrates health check + model discovery with retry
- Bounded exponential backoff: `retry_delay_ms * 2^attempt`, capped at `timeout_secs`
- Only retry on `NotRunning` and `Timeout` (not `Unhealthy` or `IncompatibleResponse`)
- After all retries exhausted, return last error status
- Unit tests for retry logic (mock-friendly structure)

### Task 6: Implement full probe entry point and display
Add to `LocalProbeService`:
- `async fn probe(&self) -> ProbeResult` — The main entry point that calls `probe_with_retry()`
- `Display` impl for `ProbeStatus` (human-readable diagnostic output)
- `ProbeStatus::is_available()` convenience method
- `ProbeStatus::models()` convenience method (returns `&[LocalModel]` or empty slice)
- `ProbeStatus::endpoint_url()` convenience method
- Unit tests for display output, convenience methods

### Task 7: Wire into module tree
- Add `pub mod local_probe;` to `providers/mod.rs`
- Update providers/mod.rs doc comment
- Add re-exports to `fae_llm/mod.rs`: `LocalProbeService`, `ProbeConfig`, `ProbeStatus`, `ProbeResult`, `LocalModel`
- Ensure `cargo check` and `cargo clippy` pass

### Task 8: Integration tests
Add integration tests to `fae_llm/mod.rs`:
- `probe_config_defaults()` — verify default endpoint, timeout, retry settings
- `probe_status_construction()` — all variants constructible
- `probe_status_serde_round_trip()` — JSON serialization for all variants
- `probe_status_convenience_methods()` — is_available, models, endpoint_url
- `probe_not_running_no_server()` — probe against unreachable port returns NotRunning/Timeout
- `probe_display_output()` — Display impl produces readable output
- Verify all types are Send + Sync
