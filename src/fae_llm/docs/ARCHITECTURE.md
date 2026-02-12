# FAE LLM Module — Architecture Overview

System design, data flow, and implementation details for the fae_llm module.

---

## Table of Contents

1. [Module Structure](#module-structure)
2. [Data Flow](#data-flow)
3. [Key Abstractions](#key-abstractions)
4. [Provider Adapters](#provider-adapters)
5. [Agent Loop Engine](#agent-loop-engine)
6. [Session Persistence](#session-persistence)
7. [Observability](#observability)
8. [Design Decisions](#design-decisions)

---

## Module Structure

```
src/fae_llm/
├── mod.rs                    # Public API exports
├── error.rs                  # FaeLlmError with stable codes
├── types.rs                  # Core domain types (ModelRef, RequestOptions, etc.)
├── events.rs                 # LlmEvent normalized streaming events
├── usage.rs                  # TokenUsage, CostEstimate, pricing
├── metadata.rs               # RequestMeta, ResponseMeta
├── provider.rs               # ProviderAdapter trait
│
├── config/
│   ├── types.rs              # Config schema (FaeLlmConfig, ProviderConfig, etc.)
│   ├── persist.rs            # Atomic file I/O (temp→fsync→rename)
│   ├── editor.rs             # ConfigEditor (toml_edit round-trip safe)
│   ├── service.rs            # ConfigService (cached, thread-safe)
│   └── defaults.rs           # Default config generation
│
├── providers/
│   ├── openai.rs             # OpenAI Completions + Responses API
│   ├── anthropic.rs          # Anthropic Messages API
│   ├── local_probe.rs        # Local endpoint health check + model discovery
│   ├── profile.rs            # Compatibility profiles (z.ai, MiniMax, DeepSeek, etc.)
│   ├── sse.rs                # SSE line parser
│   └── message.rs            # Normalized message types (Role, Message, etc.)
│
├── agent/
│   ├── loop_engine.rs        # AgentLoop core implementation
│   ├── types.rs              # AgentConfig, AgentLoopResult, StopReason
│   ├── accumulator.rs        # StreamAccumulator (events→text+tool calls)
│   ├── validation.rs         # Tool argument schema validation
│   └── executor.rs           # ToolExecutor (timeout, cancellation)
│
├── tools/
│   ├── types.rs              # Tool trait, ToolResult
│   ├── registry.rs           # ToolRegistry (mode gating)
│   ├── read.rs               # ReadTool (file content with pagination)
│   ├── bash.rs               # BashTool (shell command with timeout)
│   ├── edit.rs               # EditTool (deterministic find/replace)
│   ├── write.rs              # WriteTool (create/overwrite with validation)
│   └── path_validation.rs    # Safe path resolution
│
├── session/
│   ├── types.rs              # Session, SessionMeta, SessionId
│   ├── store.rs              # SessionStore trait
│   ├── fs_store.rs           # FsSessionStore (atomic JSON writes)
│   ├── validation.rs         # Session validation (message sequence, etc.)
│   └── context.rs            # ConversationContext (auto-persistence)
│
└── observability/
    ├── spans.rs              # Tracing span constants + helpers
    ├── metrics.rs            # MetricsCollector trait + NoopMetrics
    └── redact.rs             # RedactedString for secret masking
```

---

## Data Flow

### Request Flow

```
User Prompt
    ↓
ConversationContext::add_user_message()
    ↓
AgentLoop::run()
    ↓
    ┌─────────────────────────────────────┐
    │ Turn Loop (max 25 turns)            │
    │                                     │
    │  ProviderAdapter::stream_completion()
    │       ↓                             │
    │  LlmEventStream (normalized)        │
    │       ↓                             │
    │  StreamAccumulator                  │
    │       ↓                             │
    │  Tool calls extracted?              │
    │       ├── Yes → ToolExecutor        │
    │       │         ↓                   │
    │       │    Tool results → context   │
    │       │         ↓                   │
    │       │    Continue turn loop       │
    │       │                             │
    │       └── No → Exit loop            │
    └─────────────────────────────────────┘
    ↓
AgentLoopResult (final_response, turns, usage)
    ↓
ConversationContext::add_assistant_message()
    ↓
FsSessionStore::save() (atomic persist)
```

### Config Update Flow

```
App Menu UI
    ↓
ConfigService::set_default_provider("openai")
    ↓
    ┌─────────────────────────────────────┐
    │ 1. Get current config (cached)      │
    │ 2. Validate provider exists         │
    │ 3. Mutate config                    │
    │ 4. Validate full config             │
    │ 5. Backup old config                │
    │ 6. Write new config (atomic)        │
    │ 7. Update cache                     │
    └─────────────────────────────────────┘
    ↓
Config persisted to disk (TOML)
```

---

## Key Abstractions

### ProviderAdapter

Normalizes provider-specific APIs to a common streaming interface.

**Key Methods**:
- `stream_completion(messages, tools) → LlmEventStream`

**Implementations**:
- `OpenAiAdapter` — OpenAI Completions API + Responses API
- `AnthropicAdapter` — Anthropic Messages API
- Profile-based adapters (z.ai, MiniMax, DeepSeek) — OpenAI-compatible with quirks

### LlmEvent

Normalized streaming event model across all providers.

**Variants**:
- `StreamStart` — Request initiated
- `ThinkingStart/Delta/End` — Reasoning blocks (Claude thinking, o1 reasoning)
- `TextDelta` — Assistant response text
- `ToolCallStart/ArgsDelta/End` — Tool invocations
- `StreamEnd` — Completion with `FinishReason`
- `Error` — Stream error

### ToolRegistry

Manages tool definitions and execution with mode gating.

**Mode Enforcement**:
- `ReadOnly` → Only `read` tool allowed
- `Full` → All tools (`read`, `bash`, `edit`, `write`) allowed

**Tool Execution**:
1. Validate tool exists
2. Check mode allows tool
3. Validate arguments against JSON schema
4. Execute with timeout
5. Return `ToolResult` (success/error)

### ConversationContext

Wraps a `Session` and `SessionStore` with auto-persistence.

**Lifecycle**:
1. Create new or resume existing session
2. Add messages (user → assistant → user → ...)
3. Auto-persist after each message pair
4. Validate message sequence on resume

---

## Provider Adapters

### OpenAI Adapter

**Supports**:
- Completions API (standard streaming)
- Responses API (reasoning + response separation)

**SSE Parsing**:
```rust
for line in sse_stream {
    if line.starts_with("data: ") {
        let json = parse_json(&line[6..])?;
        let event = map_openai_chunk_to_event(json)?;
        yield event;
    }
}
```

**Reasoning Mode**:
- `o1-*` models emit `response.output_index` to separate reasoning from response
- Mapped to `ThinkingStart/Delta/End` events

### Anthropic Adapter

**Content Block Tracking**:
```rust
struct AnthropicBlockTracker {
    active_block_type: Option<ContentBlockType>,
    active_tool_call_id: Option<String>,
}
```

**Event Mapping**:
- `content_block_start` → Determine block type (text, thinking, tool_use)
- `content_block_delta` → Route to appropriate event (TextDelta, ThinkingDelta, ToolCallArgsDelta)
- `content_block_stop` → Emit end event (ThinkingEnd, ToolCallEnd)

### Compatibility Profiles

**Built-in Profiles**:
- OpenAI default
- z.ai (reasoning mode: native)
- DeepSeek (max_tokens field)
- MiniMax (tokens_to_generate)
- Ollama (no auth)
- llama.cpp (custom endpoints)
- vLLM (custom endpoints)

**Profile Application**:
```rust
fn apply_profile_to_request(request: &mut Value, profile: &CompatibilityProfile) {
    if let Some(field) = &profile.max_tokens_field {
        request["max_tokens"] = request[field].take();
    }
}
```

---

## Agent Loop Engine

### Turn Loop

```rust
for turn in 0..max_turns {
    // 1. Stream completion
    let stream = provider.stream_completion(messages, tools).await?;

    // 2. Accumulate events
    let mut acc = StreamAccumulator::new();
    while let Some(event) = stream.next().await {
        acc.push(event);
    }

    // 3. Check for tool calls
    if acc.has_tool_calls() {
        // Execute tools
        for tool_call in acc.tool_calls() {
            let result = executor.execute(&tool_call).await?;
            messages.push(Message::tool_result(tool_call.id, result));
        }
        // Continue loop
    } else {
        // No tool calls — exit loop
        break;
    }
}
```

### Safety Guards

| Guard | Default | Purpose |
|-------|---------|---------|
| `max_turns` | 25 | Prevent infinite loops |
| `max_tool_calls_per_turn` | 10 | Prevent tool spam |
| `request_timeout_secs` | 120 | HTTP timeout |
| `tool_timeout_secs` | 30 | Per-tool execution timeout |

### Cancellation

All async operations support cancellation via `tokio::CancellationToken`:

```rust
select! {
    result = execute_tool() => result?,
    _ = cancel_token.cancelled() => return Err(Cancelled),
}
```

---

## Session Persistence

### Atomic Writes

```rust
async fn save(&self, session: &Session) -> Result<(), FaeLlmError> {
    let json = serde_json::to_string_pretty(session)?;

    // 1. Write to temp file
    let temp = format!("{}.tmp", session.id);
    tokio::fs::write(&temp, &json).await?;

    // 2. Fsync (flush to disk)
    tokio::fs::File::open(&temp).await?.sync_all().await?;

    // 3. Atomic rename
    tokio::fs::rename(&temp, &session.id).await?;

    Ok(())
}
```

### Session Validation

```rust
fn validate_session(session: &Session) -> Result<(), FaeLlmError> {
    // 1. Must have at least one message
    if session.messages.is_empty() {
        return Err(EmptySession);
    }

    // 2. First message must be user
    if session.messages[0].role != Role::User {
        return Err(InvalidMessageSequence);
    }

    // 3. No consecutive user messages
    for window in session.messages.windows(2) {
        if window[0].role == Role::User && window[1].role == Role::User {
            return Err(ConsecutiveUserMessages);
        }
    }

    Ok(())
}
```

---

## Observability

### Tracing Hierarchy

```
llm_request (span)
    ├── llm_turn (span)
    │   ├── provider_stream (span)
    │   ├── tool_execution (span)
    │   └── tool_execution (span)
    ├── llm_turn (span)
    │   └── provider_stream (span)
    └── ...
```

### Metrics Collection

```rust
pub trait MetricsCollector: Send + Sync {
    fn record_request(&self, meta: &RequestMeta);
    fn record_response(&self, meta: &ResponseMeta);
    fn record_error(&self, error: &str);
    fn record_tool_call(&self, tool_name: &str, duration_ms: u64);
    fn record_retry(&self, attempt: u32);
}
```

### Secret Redaction

```rust
impl Display for RedactedString {
    fn fmt(&self, f: &mut Formatter) -> fmt::Result {
        write!(f, "[REDACTED]")
    }
}

// In logging
debug!("Authorization: {}", RedactedString(&api_key));
// Output: Authorization: [REDACTED]
```

---

## Design Decisions

### Why TOML for Config?

- **Human-readable**: Operators can hand-edit configs
- **Round-trip safe**: `toml_edit` preserves comments and formatting
- **Typed**: Serde deserialization with validation

### Why Normalized Events?

- **Provider independence**: Swap OpenAI ↔ Anthropic without changing application code
- **Consistent streaming**: All providers emit same event types
- **Future-proof**: New providers map to existing event model

### Why Mode Gating?

- **Security**: Prevent untrusted prompts from executing dangerous tools
- **Compliance**: Read-only mode for audit trails
- **Flexibility**: Runtime mode switching without code changes

### Why Atomic Writes?

- **Crash safety**: No partial config/session files on disk
- **Consistency**: Readers never see incomplete state
- **Durability**: Fsync ensures data written to disk

### Why Session Auto-Persistence?

- **Reliability**: No lost conversations on crash
- **Simplicity**: No manual save() calls required
- **Resume**: Sessions can be resumed after restart

---

## Performance Characteristics

| Operation | Complexity | Notes |
|-----------|------------|-------|
| Config load | O(n) | Parse TOML, validate |
| Config update | O(n) | Full re-serialization |
| Tool execution | O(1) | Hashmap lookup |
| Session save | O(n) | JSON serialization + I/O |
| Event accumulation | O(n) | Linear scan |
| Retry backoff | O(1) | Exponential calculation |

---

## Thread Safety

- `ConfigService`: Thread-safe via `Arc<RwLock<FaeLlmConfig>>`
- `ToolRegistry`: Immutable after creation (thread-safe)
- `SessionStore`: Each implementation handles sync (FsSessionStore uses tokio async I/O)
- `ProviderAdapter`: Must implement `Send + Sync`

---

## Future Extensions

1. **Streaming Tools**: Tools that return progressive results
2. **Multi-Provider Fallback**: Auto-switch provider on failure
3. **Caching**: Cache LLM responses for repeated prompts
4. **Rate Limiting**: Per-provider rate limit enforcement
5. **Custom Secret Resolvers**: Plugin system for secret backends

---

**Version**: 1.0
**Last Updated**: 2026-02-12
**Contact**: david@saorsalabs.com
