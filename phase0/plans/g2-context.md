# G2 Fallback Proof — Context for Implementation

## Relevant Files

### Core Infrastructure (to reuse/port)

| File | Lines | Purpose |
|------|-------|---------|
| `legacy/rust-core/src/fae_llm/provider.rs` | 1-145 | `ProviderAdapter` trait, `ToolDefinition`, `ConversationContext` |
| `legacy/rust-core/src/fae_llm/providers/local.rs` | 1-350 | `LocalMistralrsAdapter` for mistral.rs 0.7 (port to 0.8) |
| `legacy/rust-core/src/fae_llm/providers/message.rs` | — | `Message`, `Role`, `MessageContent` types |
| `legacy/rust-core/src/fae_llm/events.rs` | — | `LlmEvent`, `AssistantEvent`, `FinishReason` |
| `legacy/rust-core/src/fae_llm/types.rs` | — | `ModelRef`, `EndpointType`, `RequestOptions` |
| `legacy/rust-core/src/llm/fallback.rs` | 1-200 | `FallbackChain` retry logic (can reuse) |

### Existing Spike (reference only)

| File | Lines | Purpose |
|------|-------|---------|
| `bench/mistralrs-eval/Cargo.toml` | 1-20 | Dependencies: mistralrs 0.8 + metal |
| `bench/mistralrs-eval/src/main.rs` | 1-200 | S13 harness: loading, streaming, tool calling, audio |

### Design Documents

| File | Key Sections |
|------|--------------|
| `docs/architecture/cross-platform-engine-plan-2026-05-30.md` | §8a (engine decision), §9 (model strategy) |
| `docs/architecture/headless-core-impl-plan-2026-06-01.md` | Phase 0 gates, G2 definition |
| `docs/spikes/S13-mistralrs-eval.md` | S13 results table, verdict |

## Key Code Patterns

### ProviderAdapter Trait (from legacy)

```rust
#[async_trait]
pub trait ProviderAdapter: Send + Sync {
    fn name(&self) -> &str;
    fn endpoint_type(&self) -> EndpointType;
    
    async fn send(
        &self,
        messages: &[Message],
        options: &RequestOptions,
        tools: &[ToolDefinition],
    ) -> Result<LlmEventStream, FaeLlmError>;
}
```

### mistralrs 0.7→0.8 API Drift (trivial)

```rust
// 0.7: choice.delta.content is String
// 0.8: choice.delta.content is Option<String>
let content = choice.delta.content.as_deref().unwrap_or_default();

// 0.7: InternalError(String)
// 0.8: InternalError(Box<dyn Error>)
Response::InternalError(e) => e.to_string()

// 0.7: stream.next() via StreamExt
// 0.8: stream has inherent .next()
```

### Tool Calling (mistralrs)

```rust
request = request
    .set_tools(mistral_tools)
    .set_tool_choice(mistralrs::ToolChoice::Auto);

// Response contains:
choice.delta.tool_calls // Vec<ToolCallResponse>
// Each has: id, function.name, function.arguments
```

### llama-server HTTP API (OpenAI-compatible)

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3",
    "messages": [{"role": "user", "content": "What is the weather in Paris?"}],
    "tools": [...],
    "tool_choice": "auto"
  }'
```

## Dependencies

### Cargo.toml for bench/engine-parity

```toml
[dependencies]
mistralrs = { version = "0.8", features = ["metal"] }
tokio = { version = "1", features = ["full"] }
reqwest = { version = "0.12", features = ["json", "stream"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
anyhow = "1"
async-trait = "0.1"
futures-util = "0.3"
tokio-stream = "0.1"
```

### llama-server (external)

```bash
# Install: brew install llama.cpp OR build from source
llama-server -m <model.gguf> --port 8080 --chat-template qwen3
```

## Constraints

1. **No production code changes** — G2 is validation only
2. **Use HTTP for llama.cpp** — FFI is a later optimization
3. **Same ProviderAdapter trait** — proves the abstraction
4. **Document results** — output to `bench/engine-parity/results/`

## Implementation Risks

| Risk | Mitigation |
|------|------------|
| llama-server subprocess management | Use `tokio::process::Command`, explicit start/stop |
| Tool call format differences | Normalize JSON; accept semantic equivalence |
| Model download time | Start with Qwen3-0.6B (~0.5 GB), not Gemma-4 E4B (16 GB) |
| Metal-only on macOS | Build with `--features metal` only on macOS |

## Success Criteria

1. ✅ Harness runs both engines via `ProviderAdapter`
2. ✅ `get_weather` tool call works on both
3. ✅ Results document produced
4. ✅ No panics, no crashes
