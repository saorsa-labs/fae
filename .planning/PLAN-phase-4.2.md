# Phase 4.2: Full Integration Test Matrix

## Overview
Comprehensive integration testing for the fae_llm module covering all providers, compatibility profiles, failure modes, and security boundaries. Builds on Phase 3.3's E2E tests by adding contract tests, profile verification, failure injection, and mode gating.

## Context
- Phase 3.3 created basic E2E tests for OpenAI and Anthropic providers
- Phase 4.2 expands coverage with contract tests, profile tests, and edge cases
- Focus: Provider compatibility, failure resilience, security boundaries

## Tasks

### Task 1: OpenAI provider contract tests
**Files:** `src/fae_llm/providers/openai/tests.rs` (new)

Create contract tests verifying OpenAI adapter behavior:
- Request format validation (chat completions endpoint)
- Response parsing (streaming SSE + non-streaming)
- Tool call formatting (function calling schema)
- Error response handling (400, 401, 429, 500 status codes)
- Reasoning mode support (o1-preview extended_thinking parameter)
- Max tokens field handling (different models use different field names)

Use mock HTTP server (mockito or wiremock) for deterministic testing.

**Acceptance:**
- Contract tests cover all request/response patterns
- Mock server validates exact API format
- Tests pass with zero warnings

### Task 2: Anthropic provider contract tests
**Files:** `src/fae_llm/providers/anthropic/tests.rs` (new)

Create contract tests verifying Anthropic adapter behavior:
- Request format validation (messages endpoint)
- Response parsing (streaming + non-streaming)
- Tool use block handling (tool_use content blocks)
- Thinking block extraction (extended_thinking parameter)
- Error response handling (400, 401, 429, 500)
- Stop reason mapping (end_turn, max_tokens, tool_use)

Use mock HTTP server for deterministic testing.

**Acceptance:**
- Contract tests cover all request/response patterns
- Mock server validates exact API format
- Tests pass with zero warnings

### Task 3: Local endpoint probing tests
**Files:** `src/fae_llm/providers/openai_compatible/probe_tests.rs` (new)

Test LocalProbeService with various backend scenarios:
- Health check success (200 OK with expected response)
- Health check failure (timeout, connection refused, 500 error)
- Model list parsing (/v1/models endpoint)
- Incompatible response detection (non-OpenAI format)
- Backoff retry logic (verify exponential backoff + max attempts)
- Concurrent probe safety (multiple probes don't interfere)

Use mock HTTP server with configurable delays and responses.

**Acceptance:**
- All probe scenarios tested
- Typed failure modes verified
- Backoff logic validated
- Tests pass with zero warnings

### Task 4: Compatibility profile tests (z.ai, MiniMax, DeepSeek)
**Files:** `src/fae_llm/providers/openai_compatible/profile_tests.rs` (new)

Test profile flag resolution for OpenAI-compatible providers:
- z.ai profile (verify request transformations)
- MiniMax profile (verify field mappings)
- DeepSeek profile (verify reasoning mode handling)
- Profile flag application (max_tokens_field, reasoning_mode, etc.)
- Request normalization based on profile
- Response normalization based on profile

Use CompatibilityProfile test fixtures with mock adapters.

**Acceptance:**
- Each provider profile has dedicated tests
- Profile flags correctly transform requests
- Tests pass with zero warnings

### Task 5: E2E multi-turn tool workflow tests
**Files:** `src/fae_llm/agent/e2e_workflow_tests.rs` (new)

End-to-end tests covering complete agent workflows:
- Prompt → tool call → execute → continue → final answer
- Multi-turn conversation (3+ turns with tool use)
- Mixed tools (read + bash + write in single conversation)
- Tool argument validation (reject invalid schemas)
- Max turn limit enforcement (verify loop termination)
- Max tools per turn limit (verify guard behavior)

Use mock providers to control responses deterministically.

**Acceptance:**
- E2E workflows cover realistic scenarios
- Guard limits tested and enforced
- Tests pass with zero warnings

### Task 6: Failure injection tests
**Files:** `src/fae_llm/agent/failure_tests.rs` (new)

Test error recovery and resilience:
- Provider timeout during streaming (partial results recovery)
- Provider 5xx error (retry with backoff)
- Provider 429 rate limit (retry with exponential backoff)
- Tool execution timeout (abort and report)
- Tool execution failure (non-zero exit, exception)
- Network interruption mid-stream (reconnect or fail gracefully)
- Circuit breaker activation (after N consecutive failures)

Use mock providers with controlled failure injection.

**Acceptance:**
- All failure modes tested
- Recovery behaviors verified
- Circuit breaker integration tested
- Tests pass with zero warnings

### Task 7: Mode gating security tests
**Files:** `src/fae_llm/tools/mode_gating_tests.rs` (new)

Test tool mode enforcement (read_only vs full):
- read_only mode allows: read, bash (read-only commands)
- read_only mode rejects: write, edit, bash (write commands)
- full mode allows: all tools
- Mode switching during session (read_only → full → read_only)
- Tool registry mode validation
- Error messages for rejected tools (clear security boundary)

Use ToolRegistry with different modes and verify enforcement.

**Acceptance:**
- All mode gating rules tested
- Security boundaries enforced
- Clear error messages on rejection
- Tests pass with zero warnings

### Task 8: Integration test documentation and cleanup
**Files:** `src/fae_llm/mod.rs`, `src/fae_llm/providers/*/tests.rs`, `src/fae_llm/agent/*_tests.rs`, `src/fae_llm/tools/*_tests.rs`

Final review and documentation:
- Add module-level doc comments explaining test structure
- Document test helpers and mock utilities
- Ensure consistent naming conventions (test_provider_scenario_expected_behavior)
- Remove any TODO/FIXME comments from test code
- Verify no test warnings (unused imports, dead code, etc.)
- Run full test suite: `just test`
- Update progress.md with task completion

**Acceptance:**
- All integration tests documented
- Zero test warnings
- Full test suite passes (1,500+ tests)
- progress.md updated with Phase 4.2 completion
