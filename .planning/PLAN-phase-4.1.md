# Phase 4.1: Tracing, Metrics & Redaction

## Overview
Add production observability to the fae_llm module: structured tracing spans for request/turn/tool lifecycles, metrics collection hooks for performance and usage tracking, and secret redaction for API keys and sensitive data in logs.

## Context
- **Dependencies:** tracing = "0.1", tracing-subscriber = "0.3" already in Cargo.toml
- **Existing modules:** provider.rs, providers/, agent/, session/, tools/, events.rs, usage.rs
- **Current test count:** 1,438 passing tests
- **Constraints:** No .unwrap()/.expect()/panic!(), zero clippy warnings

## Tasks

### Task 1: Define tracing span constants and hierarchy
**Files:** `src/fae_llm/observability/mod.rs` (new), `src/fae_llm/observability/spans.rs` (new)

Create observability module with structured span constants for:
- Provider requests (span: "fae_llm.provider.request", fields: provider, model, endpoint_type)
- Agent turns (span: "fae_llm.agent.turn", fields: turn_number, max_turns)
- Tool executions (span: "fae_llm.tool.execute", fields: tool_name, mode)
- Session operations (span: "fae_llm.session.operation", fields: session_id, operation)

Define span hierarchy constants and helper macros for consistent field naming.

**Acceptance:**
- Module compiles with zero warnings
- Span constants are pub and well-documented
- Helper macros follow tracing best practices (instrument attribute patterns)

### Task 2: Define metrics trait and types
**Files:** `src/fae_llm/observability/metrics.rs` (new)

Create MetricsCollector trait and default no-op implementation:
- Record latency (request, turn, tool execution)
- Count events (retry, circuit_breaker_open, tool_success, tool_failure)
- Track usage (input_tokens, output_tokens, reasoning_tokens, cost)

Trait must be Send + Sync, methods take &self (interior mutability for implementors).

**Acceptance:**
- Trait compiles and is well-documented
- NoopMetrics default impl compiles
- All methods are non-blocking (suitable for hot paths)

### Task 3: Define secret redaction types and patterns
**Files:** `src/fae_llm/observability/redact.rs` (new)

Create redaction utilities:
- RedactedString wrapper type with Display that shows "[REDACTED]"
- Redaction patterns: API keys (sk-*, anthropic-key-*), auth headers (Authorization: Bearer *)
- Helper functions: redact_api_key, redact_auth_header, redact_in_json

Use regex crate (already in dependencies) for pattern matching.

**Acceptance:**
- RedactedString never leaks value in Display/Debug
- Pattern matchers correctly identify secrets
- Tests verify redaction in sample JSON payloads

### Task 4: Integrate tracing spans into provider adapters
**Files:** `src/fae_llm/providers/openai.rs`, `src/fae_llm/providers/anthropic.rs`

Add tracing spans to provider request methods:
- Instrument request() method with "fae_llm.provider.request" span
- Record fields: provider name, model, endpoint_type, request_id
- Use tracing::instrument attribute where possible
- Emit events on stream start/end, errors

**Acceptance:**
- All provider request paths emit spans
- Span fields match observability/spans.rs constants
- Tests verify span emission (use tracing-test or similar)
- Zero clippy warnings

### Task 5: Integrate tracing spans into agent loop and tools
**Files:** `src/fae_llm/agent/executor.rs`, `src/fae_llm/tools/registry.rs`

Add tracing spans to agent loop and tool execution:
- Agent turn span wraps each loop iteration (turn_number, max_turns)
- Tool execution span wraps Tool::execute (tool_name, mode, duration)
- Emit events on tool validation, timeout, success, failure

**Acceptance:**
- Agent loop emits turn spans
- Tool execution emits per-tool spans
- Span nesting is correct (turn contains tool spans)
- Tests verify span structure

### Task 6: Add metrics collection hooks
**Files:** `src/fae_llm/agent/mod.rs`, `src/fae_llm/provider.rs`, `src/fae_llm/tools/registry.rs`

Add MetricsCollector parameter to key structs:
- AgentLoop stores Arc<dyn MetricsCollector>
- Call metrics.record_latency(), metrics.count_event() at appropriate points
- Record: request latency, turn count, tool success/failure, retry count, token usage

Use Arc<dyn MetricsCollector> for shared ownership across tasks.

**Acceptance:**
- Metrics hooks compile and are called in hot paths
- Default NoopMetrics has zero runtime cost
- Integration tests can inject mock metrics collector
- Zero clippy warnings

### Task 7: Add secret redaction to event logging
**Files:** `src/fae_llm/events.rs`, `src/fae_llm/providers/sse.rs`

Apply redaction to event Debug/Display implementations:
- Redact API keys in error messages
- Redact auth headers in HTTP request logs
- Redact secret values in config-related events

Use RedactedString wrapper from observability/redact.rs.

**Acceptance:**
- Debug output never leaks API keys or tokens
- Redaction preserves enough info for debugging (e.g., "sk-...{last 4 chars}")
- Tests verify redaction in formatted output

### Task 8: Integration tests and documentation
**Files:** `src/fae_llm/observability/tests.rs` (new), `src/fae_llm/observability/README.md` (new)

Write integration tests:
- End-to-end span emission (mock provider → agent → tool)
- Metrics collection across full request lifecycle
- Secret redaction in real event streams

Add module README documenting:
- How to enable tracing (subscriber setup)
- How to implement custom MetricsCollector
- Span hierarchy and field conventions
- Redaction guarantees

**Acceptance:**
- Integration tests pass and cover key observability paths
- README is clear and has code examples
- Module is exported from src/fae_llm/mod.rs
- `just check` passes (fmt, lint, test, doc)
