# FAE LLM Module — Developer Guide

Complete API reference and integration guide for developers building with the fae_llm module.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Core APIs](#core-apis)
3. [Event Model](#event-model)
4. [Error Handling](#error-handling)
5. [Custom Providers](#custom-providers)
6. [Custom Tools](#custom-tools)
7. [Session Management](#session-management)
8. [Testing](#testing)

---

## Quick Start

### Basic Agent Loop

```rust
use fae::fae_llm::{
    AgentLoop, AgentConfig, ConfigService, ToolRegistry, ToolMode,
    ConversationContext, FsSessionStore,
};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Load config
    let config_service = ConfigService::new("~/.config/fae/fae_llm.toml".into());
    config_service.load()?;

    // Create tool registry
    let tools = ToolRegistry::new(ToolMode::Full);

    // Create agent loop
    let agent = AgentLoop::new(AgentConfig::default(), tools);

    // Create session context
    let store = FsSessionStore::new("~/.local/share/fae/sessions")?;
    let mut context = ConversationContext::new("anthropic", "claude-sonnet-4-5", store);

    // Run agent
    let result = agent.run("Help me analyze this codebase", &mut context).await?;

    println!("Response: {}", result.final_response);
    println!("Turns: {}", result.turn_count);
    println!("Tool calls: {}", result.total_tool_calls);

    Ok(())
}
```

---

## Core APIs

### ConfigService

Thread-safe config management with validation and partial updates.

```rust
use fae::fae_llm::{ConfigService, ToolMode, ProviderUpdate};

// Create and load
let service = ConfigService::new(path);
service.load()?;

// Get config
let config = service.get()?;

// Partial updates (safe for app menu)
service.set_default_provider("openai")?;
service.set_default_model("gpt-4o")?;
service.set_tool_mode(ToolMode::ReadOnly)?;

// Update provider
service.update_provider("openai", ProviderUpdate {
    base_url: Some("https://custom.endpoint.com/v1".into()),
    api_key: None,
})?;

// Full update with validation
service.update(|config| {
    config.runtime.request_timeout_secs = 60;
})?;

// Reload from disk
service.reload()?;
```

### AgentLoop

Agentic loop with tool calling and safety guards.

```rust
use fae::fae_llm::{AgentLoop, AgentConfig, ToolRegistry, ToolMode};

// Configure agent
let config = AgentConfig {
    max_turns: 25,               // Maximum turns before stopping
    max_tool_calls_per_turn: 10, // Tool call limit per turn
    request_timeout_secs: 120,   // HTTP request timeout
    tool_timeout_secs: 30,       // Per-tool execution timeout
};

let tools = ToolRegistry::new(ToolMode::Full);
let agent = AgentLoop::new(config, tools);

// Run with context
let result = agent.run(prompt, &mut conversation_context).await?;

// Access results
println!("Final response: {}", result.final_response);
println!("Stop reason: {:?}", result.stop_reason);
println!("Turns: {}", result.turn_count);
println!("Total tokens: {}", result.total_usage.total());
```

### ConversationContext

Manages conversation history with auto-persistence.

```rust
use fae::fae_llm::{ConversationContext, FsSessionStore};

// Create session store
let store = FsSessionStore::new("./sessions")?;

// New conversation
let mut context = ConversationContext::new("anthropic", "claude-sonnet-4-5", store);

// Resume existing session
let mut context = ConversationContext::resume("session-uuid", store).await?;

// Access messages
for message in context.messages() {
    println!("{}: {}", message.role, message.content);
}

// Metadata
println!("Provider: {}", context.provider());
println!("Model: {}", context.model());
println!("Session ID: {}", context.session_id());
```

### ToolRegistry

Manages tool definitions and execution with mode gating.

```rust
use fae::fae_llm::{ToolRegistry, ToolMode, BashTool, ReadTool, EditTool, WriteTool};

// Create with mode
let tools = ToolRegistry::new(ToolMode::Full);

// Get tool definitions for LLM
let definitions = tools.definitions();

// Execute tool (mode-gated)
let result = tools.execute("read", r#"{"path": "README.md"}"#).await?;

// Mode enforcement
let read_only = ToolRegistry::new(ToolMode::ReadOnly);
let result = read_only.execute("bash", r#"{"command": "rm -rf /"}"#).await;
assert!(result.is_err()); // Rejected!
```

---

## Event Model

All providers normalize their output to the `LlmEvent` stream.

### Event Types

```rust
use fae::fae_llm::LlmEvent;

match event {
    LlmEvent::StreamStart { request_id, model } => {
        // Stream started
    }
    LlmEvent::ThinkingStart => {
        // Reasoning/thinking block started (Claude, o1)
    }
    LlmEvent::ThinkingDelta { text } => {
        // Reasoning text chunk
    }
    LlmEvent::ThinkingEnd => {
        // Reasoning complete
    }
    LlmEvent::TextDelta { text } => {
        // Response text chunk
    }
    LlmEvent::ToolCallStart { call_id, function_name } => {
        // Tool call initiated
    }
    LlmEvent::ToolCallArgsDelta { call_id, args_fragment } => {
        // Partial JSON args
    }
    LlmEvent::ToolCallEnd { call_id } => {
        // Tool call complete
    }
    LlmEvent::StreamEnd { finish_reason } => {
        // Stream finished
    }
    LlmEvent::Error { message } => {
        // Error during stream
    }
}
```

### Stream Accumulation

```rust
use fae::fae_llm::StreamAccumulator;

let mut acc = StreamAccumulator::new();

for event in stream {
    acc.push(event);
}

// Extract accumulated text
let text = acc.accumulated_text();

// Extract tool calls
for tool_call in acc.tool_calls() {
    println!("{}: {}", tool_call.function_name, tool_call.args);
}
```

---

## Error Handling

### Error Codes

All errors have stable codes for programmatic matching:

```rust
use fae::fae_llm::FaeLlmError;

match error {
    FaeLlmError::ConfigError(_) => {
        // Code: CONFIG_INVALID, CONFIG_MISSING, etc.
    }
    FaeLlmError::AuthError(_) => {
        // Code: AUTH_FAILED
    }
    FaeLlmError::RequestError(_) => {
        // Code: REQUEST_FAILED
    }
    FaeLlmError::RateLimitError { .. } => {
        // Code: RATE_LIMIT_EXCEEDED
    }
    FaeLlmError::ProviderError(_) => {
        // Code: PROVIDER_ERROR
    }
    FaeLlmError::ToolError(_) => {
        // Code: TOOL_EXECUTION_FAILED
    }
    FaeLlmError::SessionError(_) => {
        // Code: SESSION_INVALID, SESSION_NOT_FOUND
    }
}
```

### Retry Policy

```rust
use fae::fae_llm::RetryPolicy;

let policy = RetryPolicy::default(); // 3 retries, exponential backoff

for attempt in 0..policy.max_retries {
    match make_request().await {
        Ok(response) => return Ok(response),
        Err(e) if e.is_retryable() => {
            tokio::time::sleep(policy.delay_for_attempt(attempt)).await;
        }
        Err(e) => return Err(e),
    }
}
```

### Circuit Breaker

```rust
use fae::fae_llm::CircuitBreaker;

let mut breaker = CircuitBreaker::new(5); // Open after 5 consecutive failures

match breaker.call(|| make_request()).await {
    Ok(response) => {
        breaker.record_success();
        Ok(response)
    }
    Err(e) => {
        breaker.record_failure();
        Err(e)
    }
}

if breaker.is_open() {
    println!("Circuit open, requests blocked");
}
```

---

## Custom Providers

Implement `ProviderAdapter` to add new LLM providers.

### Trait Definition

```rust
use fae::fae_llm::{ProviderAdapter, Message, ToolDefinition, LlmEventStream, FaeLlmError};
use async_trait::async_trait;

#[async_trait]
pub trait ProviderAdapter: Send + Sync {
    async fn stream_completion(
        &self,
        messages: Vec<Message>,
        tools: Vec<ToolDefinition>,
    ) -> Result<LlmEventStream, FaeLlmError>;
}
```

### Example Implementation

```rust
use fae::fae_llm::{ProviderAdapter, LlmEvent, FaeLlmError};
use async_stream::stream;

pub struct CustomProvider {
    api_key: String,
    base_url: String,
}

#[async_trait]
impl ProviderAdapter for CustomProvider {
    async fn stream_completion(
        &self,
        messages: Vec<Message>,
        tools: Vec<ToolDefinition>,
    ) -> Result<LlmEventStream, FaeLlmError> {
        // Build request
        let request = build_custom_request(messages, tools);

        // Make HTTP request
        let response = reqwest::Client::new()
            .post(&self.base_url)
            .json(&request)
            .send()
            .await?;

        // Stream and normalize events
        let stream = stream! {
            yield LlmEvent::StreamStart { ... };

            for line in response.lines() {
                let event = parse_custom_event(&line)?;
                yield normalize_event(event);
            }

            yield LlmEvent::StreamEnd { finish_reason: FinishReason::Stop };
        };

        Ok(Box::pin(stream))
    }
}
```

### Normalization Requirements

1. Emit `StreamStart` first
2. Map thinking/reasoning blocks to `ThinkingStart/Delta/End`
3. Map assistant text to `TextDelta`
4. Map tool calls to `ToolCallStart/ArgsDelta/End`
5. Emit `StreamEnd` last with `FinishReason`

---

## Custom Tools

Implement the `Tool` trait to add new tools.

### Trait Definition

```rust
use fae::fae_llm::{Tool, ToolResult};
use async_trait::async_trait;
use serde_json::Value;

#[async_trait]
pub trait Tool: Send + Sync {
    fn name(&self) -> &str;
    fn description(&self) -> &str;
    fn schema(&self) -> Value;
    async fn execute(&self, args: &str) -> ToolResult;
}
```

### Example Implementation

```rust
use fae::fae_llm::{Tool, ToolResult};

pub struct HttpFetchTool;

#[async_trait]
impl Tool for HttpFetchTool {
    fn name(&self) -> &str {
        "http_fetch"
    }

    fn description(&self) -> &str {
        "Fetch content from a URL via HTTP GET"
    }

    fn schema(&self) -> Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "url": {
                    "type": "string",
                    "description": "URL to fetch"
                }
            },
            "required": ["url"]
        })
    }

    async fn execute(&self, args: &str) -> ToolResult {
        #[derive(serde::Deserialize)]
        struct Args { url: String }

        let args: Args = serde_json::from_str(args)?;

        let response = reqwest::get(&args.url).await?;
        let body = response.text().await?;

        Ok(body)
    }
}
```

### Register Custom Tool

```rust
use fae::fae_llm::ToolRegistry;

let mut registry = ToolRegistry::new(ToolMode::Full);
registry.register(Box::new(HttpFetchTool));
```

---

## Session Management

### Session Types

```rust
use fae::fae_llm::{Session, SessionMeta, Message, Role};

// Create session
let mut session = Session::new("anthropic", "claude-sonnet-4-5");

// Add messages
session.add_message(Message::user("Hello!"));
session.add_message(Message::assistant("Hi! How can I help?"));

// Metadata
session.meta.created_at = chrono::Utc::now();
session.meta.total_tokens = 150;

// Serialize
let json = serde_json::to_string(&session)?;
```

### Session Stores

#### In-Memory Store

```rust
use fae::fae_llm::MemorySessionStore;

let store = MemorySessionStore::new();
store.save(&session).await?;
let loaded = store.load(&session.id).await?;
```

#### Filesystem Store

```rust
use fae::fae_llm::FsSessionStore;

let store = FsSessionStore::new("./sessions")?;
store.save(&session).await?; // Atomic write
let loaded = store.load(&session.id).await?;
```

### Session Validation

```rust
use fae::fae_llm::validate_session;

// Validate message sequence
validate_session(&session)?;

// Catches:
// - Consecutive user messages
// - Assistant messages without prior user message
// - Empty message list
// - Invalid provider/model references
```

---

## Testing

### Unit Tests

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_config_roundtrip() {
        let config = FaeLlmConfig::default();
        let toml = toml::to_string(&config).unwrap();
        let parsed: FaeLlmConfig = toml::from_str(&toml).unwrap();
        assert_eq!(config.runtime.request_timeout_secs, parsed.runtime.request_timeout_secs);
    }

    #[tokio::test]
    async fn test_tool_execution() {
        let tools = ToolRegistry::new(ToolMode::Full);
        let result = tools.execute("read", r#"{"path":"README.md"}"#).await;
        assert!(result.is_ok());
    }
}
```

### Integration Tests

```rust
#[tokio::test]
async fn test_e2e_agent_loop() {
    // Setup
    let config = AgentConfig::default();
    let tools = ToolRegistry::new(ToolMode::Full);
    let agent = AgentLoop::new(config, tools);
    let store = MemorySessionStore::new();
    let mut context = ConversationContext::new("mock", "model", store);

    // Run agent
    let result = agent.run("Test prompt", &mut context).await.unwrap();

    // Verify
    assert!(!result.final_response.is_empty());
    assert!(result.turn_count > 0);
}
```

### Mocking Providers

```rust
use fae::fae_llm::{ProviderAdapter, LlmEventStream, LlmEvent};

pub struct MockProvider {
    responses: Vec<String>,
}

#[async_trait]
impl ProviderAdapter for MockProvider {
    async fn stream_completion(...) -> Result<LlmEventStream, FaeLlmError> {
        let stream = stream! {
            yield LlmEvent::StreamStart { ... };
            yield LlmEvent::TextDelta { text: self.responses[0].clone() };
            yield LlmEvent::StreamEnd { finish_reason: FinishReason::Stop };
        };
        Ok(Box::pin(stream))
    }
}
```

---

## Best Practices

1. **Always use ConfigService for config management** — handles validation and atomic writes
2. **Set appropriate timeouts** — prevent hanging requests
3. **Use tool mode gating** — restrict tools based on trust level
4. **Implement retry policies** — handle transient failures gracefully
5. **Validate tool arguments** — use JSON schema validation
6. **Persist sessions regularly** — ConversationContext auto-persists after each message
7. **Monitor token usage** — track costs via `ResponseMeta::usage`
8. **Enable tracing in production** — structured spans for debugging
9. **Redact secrets in logs** — use `RedactedString` wrapper
10. **Test with mock providers** — avoid real API calls in tests

---

## Next Steps

- [Operator Guide](OPERATOR_GUIDE.md) — Deployment and configuration
- [Architecture Overview](ARCHITECTURE.md) — System design and internals
- [API Documentation](https://docs.rs/fae) — Generated API docs

---

**Version**: 1.0
**Last Updated**: 2026-02-12
**Contact**: david@saorsalabs.com
