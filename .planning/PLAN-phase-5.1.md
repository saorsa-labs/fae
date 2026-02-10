# Phase 5.1: Local LLM HTTP Server

## Overview
Expose Fae's Qwen 3 (running via mistralrs GGUF with Metal GPU) as an OpenAI-compatible HTTP server on localhost. This allows Pi and any other local tool to use Fae's brain without needing cloud API keys.

## Tasks

### Task 1: Create `src/llm/server.rs` — HTTP server scaffold
**Files:** `src/llm/server.rs` (new), `src/llm/mod.rs` (edit)

Create an async HTTP server using `axum` (already a transitive dep via dioxus).
- Bind to `127.0.0.1:0` (auto-assign port) or configurable port
- Store assigned port for Pi config writing
- `LlmServer::new(model: SharedModel, config: LlmServerConfig) -> Self`
- `LlmServer::start() -> JoinHandle` spawns the server task
- `LlmServer::port() -> u16` returns the bound port
- Add `axum` as direct dependency if needed

### Task 2: Implement `/v1/chat/completions` endpoint
**Files:** `src/llm/server.rs`

OpenAI-compatible chat completions endpoint:
- Accept `POST /v1/chat/completions` with standard OpenAI request body
- Parse messages array (role + content)
- Forward to mistralrs shared model for inference
- Return standard OpenAI response format with `choices[0].message`
- Support `stream: true` for SSE streaming (Pi uses streaming)
- Map mistralrs token events to `data: {"choices":[{"delta":{"content":"..."}}]}` SSE chunks

### Task 3: Implement `/v1/models` endpoint
**Files:** `src/llm/server.rs`

List available models:
- Return the loaded Qwen 3 model info
- Model ID: `"fae-qwen3"` (or from config)
- Standard OpenAI models list response format

### Task 4: Write Pi provider config to `~/.pi/agent/models.json`
**Files:** `src/llm/server.rs`

When the LLM server starts, write/update `~/.pi/agent/models.json` to include:
```json
{
  "providers": {
    "fae-local": {
      "baseUrl": "http://127.0.0.1:{PORT}/v1",
      "api": "openai-completions",
      "apiKey": "fae-local",
      "models": [{
        "id": "fae-qwen3",
        "name": "Fae Local (Qwen 3)",
        "reasoning": false,
        "input": ["text"],
        "contextWindow": 32768,
        "maxTokens": 8192,
        "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
      }]
    }
  }
}
```
- Merge with existing models.json (don't overwrite user providers)
- Use serde_json to read/merge/write
- Create `~/.pi/agent/` directory if missing

### Task 5: Wire LLM server into GUI startup
**Files:** `src/bin/gui.rs`, `src/startup.rs`

- Start LLM server after model loads, before pipeline starts
- Pass the same `SharedModel` used by the voice pipeline
- Log the port: "Fae LLM server listening on http://127.0.0.1:{PORT}"
- Store server handle for graceful shutdown
- Add `llm_server_port` to GUI state for display in settings

### Task 6: Add LLM server config to `config.rs`
**Files:** `src/config.rs`

New config section `[llm_server]`:
- `enabled: bool` (default true)
- `port: u16` (default 0 = auto-assign)
- `model_id: String` (default "fae-qwen3")

### Task 7: Add LLM server status to GUI settings
**Files:** `src/bin/gui.rs`

In the settings panel:
- Show "Local LLM Server" section
- Display: status (running/stopped), port, model ID
- Show the Pi provider config that was written
- Toggle to enable/disable

### Task 8: Tests
**Files:** `src/llm/server.rs`

- Server binds and responds to health check
- `/v1/models` returns model list
- `/v1/chat/completions` returns valid response format
- Pi models.json is written correctly with merge behavior
- Server shutdown is clean

**Acceptance:**
- LLM server starts with Fae and serves OpenAI-compatible API
- Pi can be configured to use `fae-local` provider
- `~/.pi/agent/models.json` is updated without destroying existing config
- `cargo clippy` zero warnings
