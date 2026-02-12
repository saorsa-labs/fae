# Phase 3.3: Multi-Provider Hardening

## Overview
Harden the agent loop and session system for production use. Enable provider switching during resumed conversations, implement error recovery with retry policies, add comprehensive end-to-end tests, and integrate tool mode switching between read_only and full modes.

## Tasks

### Task 1: Provider switch validation for resumed sessions
**Files:** `src/fae_llm/session/validation.rs`, `src/fae_llm/session/types.rs`, `src/fae_llm/agent/loop_engine.rs`

Add validation logic to detect and handle provider switches during session resume:
- Detect when resuming session uses different provider than original
- Validate that new provider supports same capabilities (tool calling, streaming, etc.)
- Add `provider_id` field to Session metadata
- Log warnings when provider switches occur
- Add tests for provider switch scenarios

**Acceptance:**
- Can resume session with different provider (OpenAI → Anthropic or vice versa)
- Warning logged when provider switch detected
- Session metadata tracks original and current provider
- Tests pass with zero warnings

### Task 2: Request retry policy implementation
**Files:** `src/fae_llm/agent/loop_engine.rs`, `src/fae_llm/agent/types.rs`, `src/fae_llm/error.rs`

Implement retry logic for transient failures:
- Add `RetryPolicy` struct with configurable max_attempts, base_delay, max_delay, backoff_multiplier
- Implement exponential backoff with jitter
- Retry on network errors, rate limits (429), server errors (5xx)
- Do NOT retry on auth errors (401, 403) or bad requests (400)
- Add retry counters to RequestMeta
- Add `is_retryable()` method to FaeLlmError

**Acceptance:**
- Retry logic retries transient errors up to max_attempts
- Exponential backoff delays between retries
- Non-retryable errors fail immediately
- Retry count tracked in metadata
- Tests verify retry behavior

### Task 3: Circuit breaker for provider failures
**Files:** `src/fae_llm/agent/loop_engine.rs`, `src/fae_llm/agent/types.rs`

Add circuit breaker pattern to prevent cascade failures:
- Track consecutive failures per provider
- Open circuit after N consecutive failures (default: 5)
- Half-open state after cooldown period (default: 60s)
- Close circuit after successful request in half-open state
- Add circuit breaker state to AgentLoop
- Log circuit breaker state changes

**Acceptance:**
- Circuit opens after consecutive failures
- No requests sent while circuit open
- Circuit tests recovery via half-open state
- State transitions logged
- Tests verify circuit breaker logic

### Task 4: Tool mode switching enforcement
**Files:** `src/fae_llm/agent/executor.rs`, `src/fae_llm/tools/registry.rs`, `src/fae_llm/tools/types.rs`

Integrate tool mode switching (read_only vs full) into agent loop:
- Add `tool_mode` field to AgentLoop and Session
- Reject mutation tools (bash, write, edit) in read_only mode
- Return clear error when tool blocked by mode
- Add `allowed_in_mode()` method to Tool trait
- Update ToolRegistry to filter by mode

**Acceptance:**
- read_only mode blocks bash, write, edit tools
- read_only mode allows read tool
- full mode allows all tools
- Clear error message when tool rejected
- Session persists tool_mode
- Tests verify mode enforcement

### Task 5: Error recovery with partial results
**Files:** `src/fae_llm/agent/loop_engine.rs`, `src/fae_llm/agent/accumulator.rs`

Handle partial results gracefully when requests fail mid-stream:
- Preserve accumulated text/tool calls on stream error
- Add `partial` flag to StreamAccumulator result
- Allow continuation from partial state
- Save partial results to session on error
- Add recovery tests with simulated stream failures

**Acceptance:**
- Partial text preserved on stream error
- Partial tool calls preserved on stream error
- Session can resume from partial state
- Tests verify partial result recovery
- No data loss on stream interruption

### Task 6: End-to-end multi-turn tool loop tests (OpenAI)
**Files:** `tests/fae_llm/e2e_openai.rs` (new file)

Comprehensive integration tests for OpenAI provider:
- Test 1: Simple prompt → response (no tools)
- Test 2: Prompt → tool call → execute → continue → final response
- Test 3: Multi-turn with multiple tool calls per turn
- Test 4: Session save → resume → continue conversation
- Test 5: Provider switch (mock OpenAI → mock Anthropic)
- Test 6: Error recovery with retry
- Test 7: Tool mode switch (start full, switch to read_only, verify rejection)
- Test 8: Circuit breaker triggers on failures

Use mock HTTP server for reproducible tests (don't call real API).

**Acceptance:**
- All 8 tests pass
- Tests use mock server (no real API calls)
- Tests cover happy path and error cases
- Zero warnings

### Task 7: End-to-end multi-turn tool loop tests (Anthropic)
**Files:** `tests/fae_llm/e2e_anthropic.rs` (new file)

Comprehensive integration tests for Anthropic provider:
- Test 1: Simple prompt → response (no tools)
- Test 2: Prompt → thinking block → tool use → continue → response
- Test 3: Multi-turn with tool calls
- Test 4: Session persistence and resume
- Test 5: Provider switch
- Test 6: Error recovery
- Test 7: Tool mode enforcement
- Test 8: Stream interruption recovery

Use mock HTTP server for reproducible tests.

**Acceptance:**
- All 8 tests pass
- Tests use mock server
- Tests verify Anthropic-specific behavior (thinking blocks)
- Zero warnings

### Task 8: Cross-provider compatibility test matrix
**Files:** `tests/fae_llm/cross_provider.rs` (new file)

Test compatibility and switching between providers:
- Matrix test: OpenAI → Anthropic → OpenAI (same session)
- Test tool call format compatibility across providers
- Test that session format is provider-agnostic
- Test mode switching with different providers
- Verify retry policy works with both providers
- Test circuit breaker per-provider isolation

**Acceptance:**
- Can switch between providers mid-conversation
- Session data compatible across providers
- Retry and circuit breaker work with all providers
- Tests pass with zero warnings
- Documentation updated with provider compatibility notes
