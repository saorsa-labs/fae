# G2 Fallback Proof Plan — Engine Parity Harness Design

> **Phase 0 Gate G2:** A passing harness test demonstrating that the **same prompt + same tool schema → equivalent tool call** on **mistral.rs (primary) AND llama.cpp (fallback)**, behind one `ProviderAdapter`. Includes an STT parity test if the paths differ.

**Status:** PLANNING (not started)  
**Output artifact:** `bench/engine-parity/` + results doc  
**Owner:** Phase 0 validation team

---

## 1. Context and Goal

### 1.1 What G2 Proves

The implementation plan (`docs/architecture/headless-core-impl-plan-2026-06-01.md`) requires **G2** to demonstrate that:

1. **Mistral.rs and llama.cpp produce functionally equivalent outputs** for the same prompt+tool schema — the fallback isn't just "something that runs" but actually interchangeable for Fae's workload.
2. **The `ProviderAdapter` abstraction works** — both engines hide behind the same trait, so the agent loop is engine-agnostic.
3. **(Optional) STT parity** — if the STT path differs (Gemma-4 E4B unified vs llama.cpp + cascaded Parakeet), demonstrate that transcriptions are equivalent enough for tool routing.

### 1.2 Why This Matters

The Rev 13 decision is to use **mistral.rs** as the primary engine with **llama.cpp as the verified fallback**. But "fallback" is only meaningful if the engines are interchangeable for Fae's workload (tool calling, conversational generation). G2 proves this before committing to production code.

---

## 2. Existing Infrastructure

### 2.1 S13 Harness (`bench/mistralrs-eval/`)

A throwaway spike crate already exists:

```
bench/mistralrs-eval/
├── Cargo.toml      # mistralrs = "0.8", features = ["metal"]
├── Cargo.lock
└── src/
    └── main.rs     # ~300 LOC: text/gguf/auto loading, streaming, tool calling, audio
```

**What it proves (S13 results):**
- ✅ mistral.rs 0.8.1 builds on Metal
- ✅ Gemma-4 E4B generates (~65 tok/s), tool calling works (`get_weather`)
- ✅ Audio STT works in-process
- ✅ Qwen3-14B dense runs (~42 tok/s) with tool calling
- ❌ Gemma-4 26B-A4B MoE does NOT run (candle gather unsupported)

**What it doesn't prove:**
- llama.cpp parity
- Same prompt → same output
- Behind a unified adapter

### 2.2 Legacy `ProviderAdapter` Trait (`legacy/rust-core/src/fae_llm/provider.rs`)

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
    
    async fn stream(
        &self,
        model: &ModelRef,
        context: &ConversationContext,
        options: &RequestOptions,
    ) -> Result<AssistantEventStream, LlmError>;
}
```

**Existing implementations:**
- `LocalMistralrsAdapter` (`providers/local.rs`) — **mistral.rs 0.7**, ~300 LOC, streaming, tool calling, thinking mode, channel-backed stream
- `FallbackChain` (`llm/fallback.rs`) — retry/fallback logic for provider failures

**No llama.cpp adapter exists** — this is the gap G2 must fill.

### 2.3 Shared Types (`legacy/rust-core/src/fae_llm/`)

```
fae_llm/
├── provider.rs        # ProviderAdapter trait, ToolDefinition, ConversationContext
├── providers/
│   ├── local.rs       # LocalMistralrsAdapter (mistralrs 0.7)
│   └── message.rs     # Message, Role, MessageContent
├── events.rs          # LlmEvent, AssistantEvent, FinishReason
├── types.rs           # ModelRef, EndpointType, RequestOptions, ReasoningLevel
├── error.rs           # FaeLlmError
└── ...
```

---

## 3. Proposed `bench/engine-parity/` Structure

```
bench/engine-parity/
├── Cargo.toml
├── README.md                      # G2 acceptance criteria and results
├── src/
│   ├── main.rs                    # CLI harness: runs parity tests
│   ├── lib.rs                     # Shared types and test contract
│   ├── adapters/
│   │   ├── mod.rs
│   │   ├── mistralrs_adapter.rs   # ProviderAdapter for mistralrs 0.8
│   │   └── llamacpp_adapter.rs    # ProviderAdapter for llama.cpp (NEW)
│   ├── tests/
│   │   ├── mod.rs
│   │   ├── tool_calling.rs        # Same prompt → equivalent tool call
│   │   ├── generation.rs          # Same prompt → coherent text
│   │   └── stt_parity.rs          # (optional) STT equivalence
│   └── fixtures/
│       ├── weather_tool.json      # get_weather tool schema
│       ├── prompts.toml           # Test prompts
│       └── audio/                 # Test WAV clips for STT
├── results/
│   └── .gitkeep                   # Results docs go here
└── scripts/
    └── run_parity.sh              # Convenience script
```

### 3.1 Minimal Test Contract

```rust
/// A parity test case.
pub struct ParityTest {
    /// Test name for reporting.
    pub name: String,
    /// System prompt.
    pub system: String,
    /// User prompt.
    pub user: String,
    /// Tools available (JSON schema).
    pub tools: Vec<ToolDefinition>,
    /// Expected outcome type.
    pub expected: ExpectedOutcome,
}

pub enum ExpectedOutcome {
    /// Model should emit a tool call with this function name.
    ToolCall { function: String },
    /// Model should generate coherent text (no tool call).
    TextGeneration,
    /// Model should transcribe audio matching this expected text.
    Transcription { expected_text: String, tolerance: f32 },
}

/// Result from running a test on one engine.
pub struct EngineResult {
    pub engine: String,
    pub success: bool,
    pub tool_calls: Vec<ToolCallResult>,
    pub generated_text: String,
    pub tok_s: f64,
    pub ttft_s: f64,
    pub error: Option<String>,
}

/// Parity check: do two engine results match?
pub fn check_parity(a: &EngineResult, b: &EngineResult) -> ParityVerdict {
    // For ToolCall: same function name, arguments parse to equivalent JSON
    // For TextGeneration: both produced non-empty coherent text
    // For Transcription: WER below tolerance
}
```

### 3.2 Core Test Cases

| Test | Prompt | Tools | Success Criterion |
|------|--------|-------|-------------------|
| **tool_weather** | "What's the weather in Paris?" | `get_weather(city)` | Both engines emit `get_weather({"city": "Paris"})` |
| **tool_read_file** | "Read the file /tmp/test.txt" | `read(path)` | Both emit `read({"path": "/tmp/test.txt"})` |
| **tool_multi** | "Search for 'rust' and read /tmp/x.txt" | `web_search`, `read` | Both emit both tool calls (order may vary) |
| **no_tool** | "Explain what a tide is." | `get_weather` | Neither uses the tool; both generate coherent text |
| **stt_basic** | (audio clip) | none | Both transcribe to similar text (WER < 10%) |

---

## 4. Dependencies and Risks

### 4.1 Dependencies

| Dependency | Source | Status | Risk |
|------------|--------|--------|------|
| **mistralrs 0.8** | crates.io | ✅ S13 confirmed | Low — known to work |
| **llama-cpp-2** | crates.io (v0.1.146+) | ⚠️ Not yet integrated | Medium — FFI, build complexity |
| **llama-server** | llama.cpp binary | ✅ Available | Low — HTTP API, mature |
| **ProviderAdapter trait** | `legacy/rust-core/` | ✅ Exists for mistralrs 0.7 | Low — port to 0.8 is trivial |
| **Test models** | HuggingFace | ⚠️ Large downloads | Medium — network, disk space |

### 4.2 Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| **llama.cpp sidecar vs FFI complexity** | Medium | Start with llama-server HTTP (simpler); FFI is optional optimization |
| **Model download time** | Medium | Use smallest viable models (Qwen3-0.6B for smoke, Gemma-4 E4B for full) |
| **Tool call format differences** | Medium | Normalize to JSON; accept minor formatting differences if semantically equivalent |
| **Flaky tok/s measurements** | Low | Run multiple iterations; report median; don't gate on perf parity |
| **Audio STT path differs** | Medium | Accept WER < 10% as "parity"; unified vs cascaded is architecturally different |

### 4.3 llama.cpp Integration Options

**Option A: llama-server sidecar (RECOMMENDED for G2)**
- Start `llama-server` as subprocess
- Use OpenAI-compatible HTTP API (`/v1/chat/completions`)
- Pro: Simple, proven, matches production architecture
- Con: Extra process, subprocess management

**Option B: llama-cpp-2 FFI crate**
- Direct Rust bindings to libllama
- Pro: In-process, no subprocess
- Con: Build complexity (cmake, libllama), less mature

**Recommendation:** Use llama-server HTTP for G2. It's the path the design doc (`cross-platform-engine-plan-2026-05-30.md` §8) recommends for v1 anyway. FFI is a later optimization.

---

## 5. What Can Be Implemented Locally Now vs Requires Model Downloads/Hardware

### 5.1 Implementable Locally Now (no model downloads)

| Component | LOC Estimate | Notes |
|-----------|--------------|-------|
| Harness scaffold (`Cargo.toml`, `main.rs`, CLI) | ~100 | Reuse S13 structure |
| `ProviderAdapter` trait copy/port | ~50 | From `legacy/rust-core/` |
| `MistralrsAdapter` (0.7→0.8 port) | ~50 | Trivial API drift per S13 |
| `LlamaCppAdapter` (HTTP client) | ~150 | reqwest to llama-server |
| Test framework (`ParityTest`, `check_parity`) | ~100 | Pure Rust logic |
| Fixture files (prompts, tool schemas) | ~50 | JSON/TOML |
| **Total scaffold** | **~500** | |

### 5.2 Requires Model Downloads

| Model | Size | Required For |
|-------|------|--------------|
| Qwen3-0.6B GGUF | ~0.5 GB | Smoke tests (fastest) |
| Gemma-4 E4B safetensors | ~16 GB | Full tool calling + STT |
| Qwen3-14B GGUF | ~8 GB | Dense driver parity |

**Minimum for G2:** Qwen3-0.6B GGUF (both engines) — proves the adapter abstraction works.

### 5.3 Hardware Requirements

| Requirement | Min | Recommended |
|-------------|-----|-------------|
| RAM | 8 GB | 32+ GB (for E4B ISQ) |
| GPU | Apple Metal or CUDA | Apple Silicon M1+ |
| Disk | 20 GB | 50 GB (multiple models) |

---

## 6. Implementation Steps

### Phase 0a: Scaffold (no models, ~2-4 hours)

1. Create `bench/engine-parity/Cargo.toml`:
   ```toml
   [package]
   name = "engine-parity"
   version = "0.1.0"
   edition = "2021"
   publish = false
   
   [dependencies]
   mistralrs = { version = "0.8", features = ["metal"] }
   tokio = { version = "1", features = ["full"] }
   reqwest = { version = "0.12", features = ["json"] }
   serde = { version = "1", features = ["derive"] }
   serde_json = "1"
   anyhow = "1"
   async-trait = "0.1"
   ```

2. Copy/adapt `ProviderAdapter` trait from `legacy/rust-core/`
3. Implement `MistralrsAdapter` (port 0.7→0.8)
4. Implement `LlamaCppAdapter` (HTTP client to llama-server)
5. Create test fixtures (prompts, tools)
6. Build harness CLI

### Phase 0b: Smoke Test (Qwen3-0.6B, ~1-2 hours)

1. Download Qwen3-0.6B GGUF
2. Start llama-server with the model
3. Run parity tests: `engine-parity test --model qwen3-0.6b`
4. Document results

### Phase 0c: Full Test (Gemma-4 E4B, ~4-8 hours first run)

1. Download Gemma-4 E4B (16 GB, one-time)
2. Run full tool calling parity
3. Run STT parity (if E4B audio-in works in llama.cpp)
4. Document results in `bench/engine-parity/results/g2-results.md`

---

## 7. Commands

### Build
```bash
cargo build --release --manifest-path bench/engine-parity/Cargo.toml
```

### Run with llama-server
```bash
# Terminal 1: Start llama-server
llama-server -m ~/.cache/huggingface/hub/Qwen3-0.6B-Q4_K_M.gguf \
  --port 8080 --chat-template qwen3

# Terminal 2: Run parity tests
./target/release/engine-parity test \
  --mistralrs-model Qwen/Qwen3-0.6B \
  --llama-endpoint http://localhost:8080 \
  --output results/qwen3-0.6b-parity.md
```

### Acceptance Check
```bash
./target/release/engine-parity check results/qwen3-0.6b-parity.md
# Exit 0 = G2 passes; Exit 1 = parity failures
```

---

## 8. Acceptance Criteria (G2 Pass)

| Criterion | Threshold |
|-----------|-----------|
| **Tool call parity** | Same function name + semantically equivalent arguments for ≥90% of test cases |
| **Text generation parity** | Both engines produce non-empty, non-garbled output |
| **STT parity** (optional) | WER < 10% on test clips |
| **No crashes** | Both engines complete all tests without error |
| **Adapter abstraction** | Tests run unchanged when swapping `--engine mistralrs` ↔ `--engine llamacpp` |

---

## 9. Related Documents

- **S13 Spike:** `docs/spikes/S13-mistralrs-eval.md` — mistral.rs confirmed working
- **Design Doc:** `docs/architecture/cross-platform-engine-plan-2026-05-30.md` (Rev 13)
- **Impl Plan:** `docs/architecture/headless-core-impl-plan-2026-06-01.md` — defines G2
- **Legacy Adapter:** `legacy/rust-core/src/fae_llm/providers/local.rs` — mistral.rs 0.7 impl
- **S13 Harness:** `bench/mistralrs-eval/` — throwaway spike (reuse structure)

---

## 10. Open Questions

1. **llama-server vs llama-cpp-2 FFI:** Use HTTP for G2 (simpler), defer FFI?
   - **Recommendation:** Yes, HTTP for G2.

2. **Model selection:** Qwen3-0.6B (fast) or Gemma-4 E4B (production-representative)?
   - **Recommendation:** Both. Qwen3-0.6B for smoke; E4B for full validation.

3. **STT parity scope:** Is STT parity required for G2, or just tool calling?
   - **Recommendation:** Tool calling is required; STT is optional (design doc says E4B unified STT in mistral.rs, cascaded Parakeet fallback for llama.cpp — different architectures).

4. **Performance parity:** Should tok/s be equivalent?
   - **Recommendation:** No. Measure and report, but don't gate G2 on perf parity. The engines are architecturally different (in-process vs sidecar).

---

## 11. Summary

**G2 proves the fallback is real, not theoretical.** By running the same prompts and tool schemas through both mistral.rs and llama.cpp behind the `ProviderAdapter` abstraction, we validate that:

1. The adapter pattern works
2. Tool calling is interchangeable
3. llama.cpp is a viable fallback if mistral.rs fails

The scaffold can be built locally without model downloads (~500 LOC). Full validation requires ~1-2 hours for smoke tests (Qwen3-0.6B) and ~4-8 hours for production-representative tests (Gemma-4 E4B).
