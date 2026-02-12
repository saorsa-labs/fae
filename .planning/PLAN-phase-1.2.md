# Phase 1.2: Create fae_llm Module Structure — Task Plan

## Goal
Create the foundational `fae_llm` module within the existing `fae` crate. Define core types, normalized streaming events, error types with stable codes, and usage/cost tracking structs. This establishes the type system foundation for multi-provider LLM support.

## Strategy
Build types bottom-up in dependency order: error types first (no deps), then core domain types (EndpointType, ModelRef), then event model (depends on core types), then usage/cost structs. Each task is TDD-first with unit tests.

---

## Tasks

### Task 1: Create fae_llm module structure and error types

**Files to create:**
- `src/fae_llm/mod.rs` — module declarations and re-exports
- `src/fae_llm/error.rs` — FaeLlmError enum with stable codes

**Files to modify:**
- `src/lib.rs` — add `pub mod fae_llm;`

**Details:**
- FaeLlmError with variants: ConfigError, AuthError, RequestError, StreamError, ToolError, Timeout, ProviderError
- Each variant stores a String message
- `code()` method returns stable SCREAMING_SNAKE_CASE code (e.g. "CONFIG_INVALID")
- `Display` impl includes the code prefix: `[CONFIG_INVALID] message`
- Use thiserror for derive
- 8+ unit tests: creation, code extraction, display format, From conversions

---

### Task 2: Define EndpointType and ModelRef core types

**Files to create:**
- `src/fae_llm/types.rs` — EndpointType, ModelRef

**Files to modify:**
- `src/fae_llm/mod.rs` — add `pub mod types;` and re-export key types

**Details:**
- EndpointType: OpenAI, Anthropic, Local, Custom — with Serialize/Deserialize (rename_all lowercase)
- ModelRef: model_id (String) + optional version — builder pattern: `new()` + `with_version()`
- `full_name()` returns `"model@version"` or just `"model"`
- Display impl delegates to full_name()
- 8+ unit tests: construction, equality, serialization round-trip, Display

---

### Task 3: Define RequestOptions and ReasoningLevel

**Files to modify:**
- `src/fae_llm/types.rs` — add RequestOptions, ReasoningLevel

**Details:**
- ReasoningLevel: Off, Low, Medium, High — serde rename_all lowercase
- RequestOptions: max_tokens (Option<usize>), temperature (Option<f64>), top_p (Option<f64>), reasoning_level, stream (bool)
- Default: max_tokens=2048, temperature=0.7, top_p=0.9, reasoning=Off, stream=true
- Builder: `with_max_tokens()`, `with_temperature()`, `with_reasoning()`, `with_stream()`
- 8+ unit tests: defaults, builder, serialization round-trip

---

### Task 4: Define normalized event model (stream lifecycle + text)

**Files to create:**
- `src/fae_llm/events.rs` — LlmEvent, FinishReason

**Files to modify:**
- `src/fae_llm/mod.rs` — add `pub mod events;`

**Details:**
- LlmEvent variants: StreamStart { request_id, model: ModelRef }, TextDelta { text }, ThinkingStart, ThinkingDelta { text }, ThinkingEnd, StreamEnd { finish_reason }, StreamError { error }
- FinishReason: Stop, Length, ToolCalls, ContentFilter, Cancelled, Other
- All events are Debug + Clone + PartialEq
- 8+ unit tests: event construction, equality, pattern matching

---

### Task 5: Add tool call events to event model

**Files to modify:**
- `src/fae_llm/events.rs` — add ToolCallStart, ToolCallArgsDelta, ToolCallEnd variants

**Details:**
- ToolCallStart { call_id, function_name } — marks start of a tool call
- ToolCallArgsDelta { call_id, args_fragment } — streaming JSON argument chunks
- ToolCallEnd { call_id } — arguments complete
- call_id links all deltas for the same tool call
- 8+ unit tests: tool call event sequences, multi-tool interleaving

---

### Task 6: Define usage and cost tracking structs

**Files to create:**
- `src/fae_llm/usage.rs` — TokenUsage, CostEstimate, TokenPricing

**Files to modify:**
- `src/fae_llm/mod.rs` — add `pub mod usage;`

**Details:**
- TokenUsage: prompt_tokens (u64), completion_tokens (u64), reasoning_tokens (Option<u64>)
- `total()` method sums all tokens
- `add()` method accumulates from another TokenUsage
- TokenPricing: input_per_1m (f64), output_per_1m (f64) — USD per 1M tokens
- CostEstimate: usd (f64), pricing — with `calculate(usage, pricing)` constructor
- Serde support for all types
- 10+ unit tests: total calculation, accumulation, cost math

---

### Task 7: Define request/response metadata types

**Files to create:**
- `src/fae_llm/metadata.rs` — RequestMeta, ResponseMeta

**Files to modify:**
- `src/fae_llm/mod.rs` — add `pub mod metadata;`

**Details:**
- RequestMeta: request_id (String), model (ModelRef), created_at (std::time::Instant)
- ResponseMeta: request_id (String), model_id (String), usage (Option<TokenUsage>), latency_ms (u64), finish_reason (FinishReason)
- ResponseMeta stores model_id (String) not ModelRef for simplicity when returned from providers
- 6+ unit tests: construction, latency tracking

---

### Task 8: Integration tests and module documentation

**Files to modify:**
- `src/fae_llm/mod.rs` — comprehensive module-level doc comments with examples
- All type files — verify doc comments on every public item

**Tests to add (in relevant modules):**
- Integration test: simulate full event stream (start -> text -> tool call -> text -> end)
- Integration test: accumulate TokenUsage across multi-turn conversation
- Integration test: serialize all types to JSON and back
- Integration test: error code stability (all codes are SCREAMING_SNAKE_CASE)
- Run `just check` — zero warnings, all tests pass, docs build

---

## Quality Gates
- `just check` passes (fmt, lint, build, test, doc, panic-scan)
- Zero `.unwrap()` or `.expect()` in production code
- 100% doc coverage on public items in fae_llm module
- 60+ total tests across all tasks
- All types implement Debug, Clone at minimum
- Serde support on types that need config/persistence
