# FAE LLM Module — Operator Guide

This guide is for system operators deploying and configuring the fae_llm module in production environments.

---

## Table of Contents

1. [Configuration Reference](#configuration-reference)
2. [Provider Setup Guides](#provider-setup-guides)
3. [Secret Management](#secret-management)
4. [Tool Mode Configuration](#tool-mode-configuration)
5. [Local Endpoint Probing](#local-endpoint-probing)
6. [Session Persistence](#session-persistence)
7. [Tracing and Metrics](#tracing-and-metrics)
8. [Troubleshooting](#troubleshooting)

---

## Configuration Reference

### File Location

The default config location is `~/.config/fae/fae_llm.toml` (Linux/macOS) or `%APPDATA%\fae\fae_llm.toml` (Windows).

### Config Schema

```toml
# ──────────────────────────────────────────────────────────────
# Providers
# ──────────────────────────────────────────────────────────────

[providers.<provider_id>]
endpoint_type = "openai" | "anthropic" | "local" | "custom"
base_url = "https://api.example.com/v1"
api_key = { type = "env", var = "API_KEY_VAR" }  # See Secret Management below
models = ["model-id-1", "model-id-2"]  # Optional: list of available models
profile = { max_tokens_field = "max_tokens", ... }  # Optional: compatibility profile

# ──────────────────────────────────────────────────────────────
# Models
# ──────────────────────────────────────────────────────────────

[models.<model_id>]
model_id = "gpt-4o"  # API model identifier
display_name = "GPT-4o"  # Human-readable name
tier = "fast" | "balanced" | "reasoning"  # Performance tier
max_tokens = 16384  # Maximum tokens this model can generate

# ──────────────────────────────────────────────────────────────
# Tools
# ──────────────────────────────────────────────────────────────

[tools.<tool_name>]
name = "read" | "bash" | "edit" | "write"
enabled = true
options = {}  # Tool-specific options (reserved for future use)

# ──────────────────────────────────────────────────────────────
# Defaults
# ──────────────────────────────────────────────────────────────

[defaults]
default_provider = "anthropic"  # Default provider ID
default_model = "claude-sonnet-4-5"  # Default model ID
tool_mode = "read_only" | "full"  # See Tool Mode Configuration below

# ──────────────────────────────────────────────────────────────
# Runtime
# ──────────────────────────────────────────────────────────────

[runtime]
request_timeout_secs = 30  # HTTP request timeout
max_retries = 3  # Number of retries for transient failures
log_level = "info"  # Options: trace, debug, info, warn, error
```

---

## Provider Setup Guides

### OpenAI

**Endpoint**: `https://api.openai.com/v1`
**Endpoint Type**: `openai`

```toml
[providers.openai]
endpoint_type = "openai"
base_url = "https://api.openai.com/v1"
api_key = { type = "env", var = "OPENAI_API_KEY" }
models = ["gpt-4o", "gpt-4o-mini"]

[models.gpt-4o]
model_id = "gpt-4o"
display_name = "GPT-4o"
tier = "balanced"
max_tokens = 16384
```

**API Key**: Sign up at [platform.openai.com](https://platform.openai.com) and generate an API key under "API Keys".

**Environment Variable**:
```bash
export OPENAI_API_KEY="sk-proj-..."
```

---

### Anthropic

**Endpoint**: `https://api.anthropic.com`
**Endpoint Type**: `anthropic`

```toml
[providers.anthropic]
endpoint_type = "anthropic"
base_url = "https://api.anthropic.com"
api_key = { type = "env", var = "ANTHROPIC_API_KEY" }
models = ["claude-sonnet-4-5-20250929", "claude-haiku-4-5-20251001"]

[models.claude-sonnet-4-5]
model_id = "claude-sonnet-4-5-20250929"
display_name = "Claude Sonnet 4.5"
tier = "balanced"
max_tokens = 8192
```

**API Key**: Sign up at [console.anthropic.com](https://console.anthropic.com) and create an API key.

**Environment Variable**:
```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

---

### z.ai

**Endpoint**: `https://api.z.ai/v1`
**Endpoint Type**: `openai` (OpenAI-compatible)
**Profile**: `z_ai`

```toml
[providers.zai]
endpoint_type = "openai"
base_url = "https://api.z.ai/v1"
api_key = { type = "env", var = "ZAI_API_KEY" }
profile = { max_tokens_field = "max_tokens", reasoning_mode = "native" }

[models.zai-model]
model_id = "z-model-id"
display_name = "Z.ai Model"
tier = "balanced"
max_tokens = 8192
```

---

### MiniMax

**Endpoint**: `https://api.minimax.chat/v1`
**Endpoint Type**: `openai` (OpenAI-compatible)
**Profile**: `minimax`

```toml
[providers.minimax]
endpoint_type = "openai"
base_url = "https://api.minimax.chat/v1"
api_key = { type = "env", var = "MINIMAX_API_KEY" }
profile = { max_tokens_field = "tokens_to_generate" }
```

---

### DeepSeek

**Endpoint**: `https://api.deepseek.com/v1`
**Endpoint Type**: `openai` (OpenAI-compatible)
**Profile**: `deepseek`

```toml
[providers.deepseek]
endpoint_type = "openai"
base_url = "https://api.deepseek.com/v1"
api_key = { type = "env", var = "DEEPSEEK_API_KEY" }
profile = { max_tokens_field = "max_tokens" }

[models.deepseek-coder]
model_id = "deepseek-coder"
display_name = "DeepSeek Coder"
tier = "reasoning"
max_tokens = 16384
```

---

### Local Endpoints (Ollama, llama.cpp, vLLM)

**Endpoint**: `http://localhost:11434` (Ollama), `http://localhost:8080` (llama.cpp)
**Endpoint Type**: `local`
**Profile**: Auto-detected or explicit

```toml
[providers.local]
endpoint_type = "local"
base_url = "http://localhost:11434"
api_key = { type = "none" }  # No API key for local endpoints
profile = { max_tokens_field = "max_tokens", tool_call_format = "native" }
```

**Health Probing**: The `LocalProbeService` will automatically detect available models via `/v1/models` or `/api/tags` (Ollama fallback).

---

## Secret Management

### Secret Modes

The `api_key` field supports multiple resolution modes:

#### 1. Environment Variable (Recommended)

```toml
api_key = { type = "env", var = "OPENAI_API_KEY" }
```

- Reads from environment variable at runtime
- Secure: secrets never stored in config file
- Suitable for production deployments with proper env var management

#### 2. Literal (Development Only)

```toml
api_key = { type = "literal", value = "sk-proj-..." }
```

- **⚠️ INSECURE**: API key stored in plaintext in config file
- **Only use for local development/testing**
- **Never commit configs with literal secrets to version control**

#### 3. Command Execution (Feature-Gated, Off by Default)

```toml
api_key = { type = "command", cmd = "security find-generic-password -w -s 'openai' -a 'api-key'" }
```

- Executes a shell command to retrieve the secret
- **Disabled by default** — requires feature flag to enable
- Use with caution: arbitrary command execution risk

#### 4. Keychain (Planned, Not Yet Implemented)

```toml
api_key = { type = "keychain", service = "openai", account = "api-key" }
```

- Integrates with OS keychain (macOS Keychain, Windows Credential Manager, etc.)
- Planned for future release

#### 5. None

```toml
api_key = { type = "none" }
```

- No API key required (for local endpoints)

### Security Recommendations

1. **Always use `env` mode in production**
2. **Never commit literal secrets**
3. **Rotate API keys regularly**
4. **Use read-only keys when possible** (provider-specific)
5. **Store environment variables securely** (use secret management systems like HashiCorp Vault, AWS Secrets Manager, etc.)

---

## Tool Mode Configuration

The `tool_mode` setting controls which tools the LLM can execute.

### Read-Only Mode

```toml
[defaults]
tool_mode = "read_only"
```

- **Enabled Tools**: `read` only
- **Blocked Tools**: `bash`, `edit`, `write`
- **Use Case**: Inspect files without modification (safe for untrusted input)

### Full Mode

```toml
[defaults]
tool_mode = "full"
```

- **Enabled Tools**: All 4 tools (`read`, `bash`, `edit`, `write`)
- **Security Risk**: LLM can execute arbitrary commands and modify files
- **Use Case**: Autonomous agents, code assistants with full filesystem access

### Switching Modes at Runtime

```rust
use fae::fae_llm::{ConfigService, ToolMode};

let service = ConfigService::new("path/to/config.toml".into());
service.set_tool_mode(ToolMode::ReadOnly)?;
```

---

## Local Endpoint Probing

The `LocalProbeService` automatically discovers and validates local LLM endpoints.

### Probe Configuration

```rust
use fae::fae_llm::{LocalProbeService, ProbeConfig};

let probe = ProbeConfig::builder()
    .endpoint_url("http://localhost:11434")
    .timeout_secs(5)
    .retry_count(3)
    .retry_delay_ms(500)
    .build();

let result = LocalProbeService::probe(&probe).await?;
```

### Probe Status

| Status | Meaning |
|--------|---------|
| `Available` | Endpoint is healthy and models are available |
| `NotRunning` | Connection refused (service not started) |
| `Timeout` | Request timed out (service may be overloaded) |
| `Unhealthy` | Service returned non-200 status |
| `IncompatibleResponse` | Response format is invalid or unexpected |

### Troubleshooting Probes

1. **NotRunning**: Start your local LLM server (e.g., `ollama serve`)
2. **Timeout**: Increase `timeout_secs` or check server load
3. **IncompatibleResponse**: Verify endpoint URL and API compatibility (OpenAI vs Ollama format)

---

## Session Persistence

Sessions are persisted to disk after every completed message exchange.

### Storage Location

Default: `~/.local/share/fae/sessions/` (Linux/macOS) or `%LOCALAPPDATA%\fae\sessions\` (Windows)

### Session Format

Each session is stored as a JSON file: `<session_id>.json`

```json
{
  "id": "session-uuid",
  "provider": "anthropic",
  "model": "claude-sonnet-4-5-20250929",
  "messages": [
    { "role": "user", "content": "..." },
    { "role": "assistant", "content": "..." }
  ],
  "metadata": {
    "created_at": "2025-01-15T10:00:00Z",
    "last_updated": "2025-01-15T10:05:00Z"
  }
}
```

### Session Cleanup

Sessions are never auto-deleted. Implement cleanup policy based on your requirements:

```bash
# Delete sessions older than 30 days
find ~/.local/share/fae/sessions -name "*.json" -mtime +30 -delete
```

### Backup

Session files can be backed up via standard filesystem tools:

```bash
cp -r ~/.local/share/fae/sessions /backup/fae-sessions
```

---

## Tracing and Metrics

### Structured Tracing

Enable tracing spans by configuring a tracing subscriber:

```rust
use tracing_subscriber::EnvFilter;

tracing_subscriber::fmt()
    .with_env_filter(EnvFilter::from_default_env())
    .init();
```

**Environment Variable**:
```bash
export RUST_LOG=fae_llm=debug
```

### Tracing Spans

| Span | Description |
|------|-------------|
| `llm_request` | Full request lifecycle |
| `llm_turn` | Single agent loop turn |
| `tool_execution` | Tool call execution |
| `provider_stream` | Provider SSE stream |

### Custom Metrics

Implement the `MetricsCollector` trait to collect custom metrics:

```rust
use fae::fae_llm::{MetricsCollector, RequestMeta, ResponseMeta};

struct MyMetrics;

impl MetricsCollector for MyMetrics {
    fn record_request(&self, meta: &RequestMeta) {
        // Record request start
    }

    fn record_response(&self, meta: &ResponseMeta) {
        // Record latency, tokens, cost
    }

    fn record_error(&self, error: &str) {
        // Record error rate
    }
}
```

### Secret Redaction

API keys and auth headers are automatically redacted in logs:

```
[DEBUG] Request headers: Authorization: Bearer [REDACTED]
```

---

## Troubleshooting

### Config Parse Errors

**Problem**: `TOML parse error at line X, column Y`

**Solution**:
1. Validate TOML syntax: `toml-cli validate fae_llm.toml` (install `toml-cli` via cargo)
2. Check for missing quotes, commas, or braces
3. Ensure `endpoint_type` is lowercase: `"openai"` not `"OpenAI"`

### Authentication Failures

**Problem**: `AuthError: API key rejected (401 Unauthorized)`

**Solution**:
1. Verify API key is correct: `echo $OPENAI_API_KEY`
2. Check API key has not expired or been revoked
3. Ensure correct provider endpoint URL
4. For local endpoints, verify no API key is configured

### Rate Limiting

**Problem**: `RateLimitError: Too many requests (429)`

**Solution**:
1. Reduce request frequency
2. Implement exponential backoff (built-in retry policy handles this automatically)
3. Upgrade to higher tier API plan

### Tool Execution Failures

**Problem**: `ToolError: bash tool failed with exit code 1`

**Solution**:
1. Check tool mode: `read_only` blocks bash/edit/write
2. Verify file paths exist and are accessible
3. Check permissions for bash command execution
4. Review tool output in debug logs: `RUST_LOG=fae_llm=debug`

### Local Endpoint Not Detected

**Problem**: `ProbeStatus::NotRunning`

**Solution**:
1. Verify local server is running: `curl http://localhost:11434/v1/models`
2. Check port number matches config
3. Ensure firewall allows localhost connections
4. For Ollama: run `ollama serve`

### Session Resume Errors

**Problem**: `SessionResumeError: provider mismatch`

**Solution**:
1. Provider switch mid-session not supported in current version
2. Create new session with desired provider
3. Session validation enforces provider/model consistency

---

## Next Steps

- [Developer Guide](DEVELOPER_GUIDE.md) — API reference and integration examples
- [Architecture Overview](ARCHITECTURE.md) — System design and internals
- [GitHub Issues](https://github.com/saorsa-labs/fae/issues) — Report bugs or request features

---

**Version**: 1.0
**Last Updated**: 2026-02-12
**Contact**: david@saorsalabs.com
