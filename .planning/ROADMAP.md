# FAE LLM Module — Roadmap

## Vision
Replace the PI subprocess dependency with a pure Rust LLM and tool-calling module (`fae_llm`). Multi-provider support (OpenAI, Anthropic, local, z.ai, MiniMax, DeepSeek), FAE-owned TOML config with round-trip safety, agent loop with tool calling, session persistence, local endpoint probing, and structured observability. No TUI dependency.

## Problem
- Technical debt: PI subprocess dependency is fragile and adds external binary management
- Integration gap: Need native Rust LLM module without subprocess RPC overhead
- Missing functionality: Need multi-provider support beyond what PI provides

## Success Criteria
- Production ready: Complete + tested + documented
- Zero PI references remaining in codebase
- All providers functional with tool-calling agent loop
- Config safe for app-menu updates (round-trip TOML)
- Full observability with tracing/metrics/redaction

---

## Milestone 1: PI Removal & Foundation

Remove the PI dependency entirely and establish the fae_llm crate with core types, config, and tools.

### Phase 1.1: Remove PI Dependency
- Delete `src/pi/` directory (engine.rs, manager.rs, session.rs, tool.rs, mod.rs)
- Delete `src/llm/pi_config.rs` and `src/llm/server.rs` (Pi-only HTTP server)
- Remove all PI references from config.rs, pipeline/coordinator.rs, agent/mod.rs
- Remove PI references from voice_command.rs, startup.rs, bin/gui.rs, memory.rs
- Remove PI-related progress tracking, update logic
- Clean up unused dependencies from Cargo.toml
- Ensure project compiles and all remaining tests pass

### Phase 1.2: Create fae_llm Crate Structure
- Create `fae_llm/` crate with module layout per spec
- Define core types: EndpointType, ModelRef, RequestOptions, ReasoningLevel
- Define normalized event model (start, text_delta, tool_call_start, etc.)
- Define error types with stable codes (ConfigError, AuthError, RequestError, etc.)
- Define usage/cost structs and stop reasons

### Phase 1.3: Config Schema & Persistence
- Define TOML config schema v1 (providers, models, tools, defaults, runtime)
- Implement ConfigService with atomic read/write (temp -> fsync -> rename)
- Implement round-trip TOML editing via toml_edit (preserve comments/unknown fields)
- Implement secret resolution (none, env, literal, command, keychain)
- Implement config validation and safe partial update API for app menu
- Backup last-known-good config

### Phase 1.4: Tool Registry & Implementations
- Define Tool trait and ToolRegistry
- Implement read tool (file content with offset/limit, bounded output)
- Implement bash tool (shell command with timeout/cancel, bounded output)
- Implement edit tool (deterministic text edits)
- Implement write tool (create/overwrite with path validation)
- Implement tool mode gating (read_only vs full)
- Schema validation for tool arguments

---

## Milestone 2: Provider Implementation

Build provider adapters for all supported LLM backends.

### Phase 2.1: OpenAI Adapter
- Implement ProviderAdapter trait
- OpenAI Completions request builder + SSE streaming parser
- OpenAI Responses API support
- Normalize to shared event model
- Tool call streaming with partial JSON parsing

### Phase 2.2: Compatibility Profile Engine
- Implement profile flag system (max_tokens_field, reasoning_mode, etc.)
- Create profiles for z.ai, MiniMax, DeepSeek, local backends
- Single OpenAI-compatible adapter + profile resolution
- Profile-based request/response normalization

### Phase 2.3: Local Probe Service
- Implement LocalProbeService (health check, /v1/models, configurable)
- Typed failures: NotRunning, Timeout, Unhealthy, IncompatibleResponse
- Bounded backoff retry
- Status exposure for app menu diagnostics
- Extension point for future RuntimeManager

### Phase 2.4: Anthropic Adapter
- Implement Anthropic Messages API adapter
- Map thinking/tool_use blocks to shared event model
- Streaming support with content block deltas

---

## Milestone 3: Agent Loop & Sessions

Build the tool-calling agent loop and session persistence.

### Phase 3.1: Agent Loop Engine
- Implement agentic loop: prompt -> stream -> tool calls -> execute -> continue
- Max turn count, max tool calls per turn guards
- Request and tool timeouts
- Abort/cancellation propagation
- Tool argument validation against schemas

### Phase 3.2: Session Persistence & Replay
- Implement session store (persist every completed message)
- Session resume with state validation
- Typed continuation errors
- Conversation context management

### Phase 3.3: Multi-Provider Hardening
- Provider switch during resumed conversation
- Error recovery and retry policies
- End-to-end multi-turn tool loop tests
- Mode switching integration (read_only <-> full)

---

## Milestone 4: Observability & Release

Production hardening with observability and comprehensive testing.

### Phase 4.1: Tracing, Metrics & Redaction
- Structured tracing spans (per request, turn, tool execution)
- Metrics hooks (latency, retry count, tool success/failure, token usage)
- Secret redaction (API keys, auth headers, secret refs)

### Phase 4.2: Full Integration Test Matrix
- OpenAI, Anthropic, local endpoint contract tests
- z.ai/MiniMax/DeepSeek profile tests
- E2E: prompt -> tool -> result -> continue
- Failure injection tests
- Mode gating tests (read_only rejects mutations)

### Phase 4.3: App Integration & Release
- App-menu integration tests
- Config round-trip preservation tests
- Operator and developer documentation
- Release candidate validation

---

## Technical Decisions (Locked)

| Decision | Choice |
|----------|--------|
| Local mode | probe_only (never start/stop model processes in v1) |
| Config format | TOML with toml_edit for round-trip safety |
| Secret modes | none, env, literal (dev), command (off by default), keychain |
| Tool set | read, bash, edit, write (4 tools, stable names) |
| Tool modes | read_only, full (2 modes only) |
| Error handling | thiserror with typed errors + stable codes |
| Async runtime | tokio (match existing) |
| Testing | Unit + Integration + Property-based |
| Streaming | Normalized event model across all providers |

## Providers (v1)

| Provider | Implementation |
|----------|---------------|
| OpenAI | Native adapter (Completions + Responses) |
| Anthropic | Native adapter (Messages API) |
| z.ai | OpenAI-compatible + profile |
| MiniMax | OpenAI-compatible + profile |
| DeepSeek | OpenAI-compatible + profile |
| Local endpoints | OpenAI-compatible + profile |
