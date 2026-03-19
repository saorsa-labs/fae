# Phase 5.1: Local LLM HTTP Server

> Expose Fae's Qwen 3 (mistralrs GGUF) as an OpenAI-compatible HTTP endpoint on
> localhost. Pi and other local tools can use Fae's brain without cloud API keys.

## Task 1: Add axum dependency and create server types module

**Files**: `Cargo.toml`, `src/llm/server.rs`, `src/llm/mod.rs`

**Requirements**:
- Add `axum` (latest) to `[dependencies]` in Cargo.toml
- Add `tower-http` with `cors` feature for CORS support
- Create `src/llm/server.rs` with OpenAI-compatible request/response types:
  - `ChatCompletionRequest` (model, messages, stream, temperature, top_p, max_tokens)
  - `ChatCompletionResponse` (id, object, created, model, choices, usage)
  - `ChatCompletionChunk` (SSE streaming variant)
  - `ChatMessage` { role, content }
  - `Choice`, `ChunkChoice`, `Delta`, `Usage`
- Add `pub mod server;` to `src/llm/mod.rs`
- All types derive `Serialize, Deserialize, Debug, Clone`
- Tests: verify serde round-trips for all request/response types

**Acceptance**: `just lint && just test` passes, types are importable.

---

## Task 2: Create LlmServer struct and GET /v1/models endpoint

**Files**: `src/llm/server.rs`

**Requirements**:
- Create `LlmServer` struct holding `Arc<Model>`, port, and model metadata
- Implement `LlmServer::new(model: Arc<Model>, config: &LlmServerConfig)`
- Implement `GET /v1/models` handler returning OpenAI-compatible model list:
  ```json
  {"object":"list","data":[{"id":"fae-qwen3","object":"model","owned_by":"fae-local"}]}
  ```
- Create `LlmServerConfig` struct (port: u16, enabled: bool) with defaults
- Implement `LlmServer::start()` -> binds to `127.0.0.1:{port}`, returns `JoinHandle`
- Use `TcpListener::bind("127.0.0.1:0")` for auto port assignment when port=0
- Store actual bound port in `LlmServer` for later retrieval
- Tests: unit test for models response shape

**Acceptance**: Server binds and `/v1/models` returns valid JSON.

---

## Task 3: Implement POST /v1/chat/completions (non-streaming)

**Files**: `src/llm/server.rs`

**Requirements**:
- Implement `POST /v1/chat/completions` handler (non-streaming path: `stream: false`)
- Convert `ChatCompletionRequest.messages` to mistralrs `TextMessages`
- Configure `RequestBuilder` with temperature, top_p, max_tokens from request
- Call `model.send_chat_request(request)` for non-streaming response
- Build and return `ChatCompletionResponse` with generated text and usage stats
- Handle errors: return HTTP 500 with `{"error":{"message":"...","type":"server_error"}}`
- Filter `<think>...</think>` blocks from response content
- Tests: verify response structure, error handling

**Acceptance**: Non-streaming completions return valid OpenAI-format responses.

---

## Task 4: Add SSE streaming to POST /v1/chat/completions

**Files**: `src/llm/server.rs`

**Requirements**:
- When `stream: true` in request, return SSE (Server-Sent Events) response
- Content-Type: `text/event-stream`
- Use `model.stream_chat_request(request)` for token-by-token streaming
- Each chunk: `data: {"id":"...","object":"chat.completion.chunk","choices":[{"delta":{"content":"token"}}]}\n\n`
- Final message: `data: [DONE]\n\n`
- Filter `<think>...</think>` blocks from streamed tokens
- Generate unique request IDs (format: `chatcmpl-{uuid}`)
- Tests: verify SSE format of streamed responses

**Acceptance**: Streaming completions produce valid SSE with correct chunk format.

---

## Task 5: Add LlmServerConfig to SpeechConfig and error variant

**Files**: `src/config.rs`, `src/error.rs`

**Requirements**:
- Add `LlmServerConfig` struct to `src/config.rs`:
  - `enabled: bool` (default: `true`)
  - `port: u16` (default: `0` for auto-assign)
  - `host: String` (default: `"127.0.0.1"`)
- Add `pub llm_server: LlmServerConfig` field to `SpeechConfig`
- Add `#[serde(default)]` for backward compatibility
- Add `Server(String)` variant to `SpeechError` enum in `src/error.rs`
- Update `LlmServer` to use `LlmServerConfig` from `SpeechConfig`
- Tests: default config round-trips, new config field deserializes from TOML

**Acceptance**: Config loads with new section, error type compiles.

---

## Task 6: Create Pi config writer (models.json merge)

**Files**: `src/llm/pi_config.rs`, `src/llm/mod.rs`

**Requirements**:
- Create `src/llm/pi_config.rs` module
- Add `pub mod pi_config;` to `src/llm/mod.rs`
- Define `PiModelsConfig` struct matching Pi's `~/.pi/agent/models.json` schema:
  - `providers: HashMap<String, PiProvider>`
  - `PiProvider { base_url, api, api_key, models: Vec<PiModel> }`
  - `PiModel { id, name, reasoning, input, context_window, max_tokens, cost }`
- Implement `read_pi_config(path) -> Result<PiModelsConfig>` (returns empty if missing)
- Implement `write_fae_local_provider(path, port) -> Result<()>`:
  - Read existing config
  - Add/update `"fae-local"` provider with `http://127.0.0.1:{port}/v1`
  - Preserve all other providers
  - Write back atomically (write to temp, rename)
- Implement `remove_fae_local_provider(path) -> Result<()>` for cleanup on shutdown
- Tests: round-trip read/write, merge preserves existing providers, atomic write

**Acceptance**: Pi config writer correctly merges without clobbering user's providers.

---

## Task 7: Wire LlmServer into startup and runtime

**Files**: `src/startup.rs`, `src/llm/server.rs`, `src/llm/pi_config.rs`

**Requirements**:
- Add `llm_server: Option<LlmServer>` to `InitializedModels`
- In `initialize_models_with_progress`: if LLM is loaded and server enabled:
  - Create `LlmServer` with shared model
  - Call `server.start()` to bind and begin serving
  - Call `write_fae_local_provider()` with the actual bound port
  - Log server URL: `info!("LLM server listening on http://127.0.0.1:{port}/v1")`
- Provide `InitializedModels::llm_server_port() -> Option<u16>` accessor
- On drop/shutdown: `remove_fae_local_provider()` to clean up models.json
- Tests: verify server starts when enabled, skipped when disabled

**Acceptance**: Server auto-starts on app launch, Pi config written with correct port.

---

## Task 8: Integration tests and documentation

**Files**: `tests/llm_server.rs`, `src/llm/server.rs`, `src/llm/pi_config.rs`

**Requirements**:
- Create integration test `tests/llm_server.rs`:
  - Test `/v1/models` endpoint returns valid response
  - Test `/v1/chat/completions` with `stream: false` returns valid response
  - Test `/v1/chat/completions` with `stream: true` returns valid SSE
  - Test Pi config merge preserves existing providers
  - Test Pi config cleanup on remove
- Note: Integration tests that require a loaded model should be `#[ignore]` (expensive)
  and include a mock/stub path for CI
- Add doc comments to all public items in `server.rs` and `pi_config.rs`
- Ensure `just check` passes (fmt, lint, build, test, doc, panic-scan)

**Acceptance**: All tests pass, all public APIs documented, zero warnings.
