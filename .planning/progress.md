# Progress Log

## Milestone 1: Canvas Core Integration & Dioxus Pane — COMPLETE

### Phase 1.1: Dependency & Shared Types
- [x] All 8 tasks complete (commit: 2e3c2d2)

### Phase 1.2: Message Pipeline Bridge
- [x] All 8 tasks complete (commit: f1f763b)

### Phase 1.3: Dioxus Canvas Pane
- [x] All 8 tasks complete (commit: 933bbba)

---

## Milestone 2: Rich Content & MCP Tools — COMPLETE

### Phase 2.1: MCP Tool Integration
- [x] All 8 tasks complete (commit: 94a2c73)

### Phase 2.2: Content Renderers
- [x] All 8 tasks complete (commit: e80609e)

### Phase 2.3: Interactive Elements
- [x] Task 1: Expose message iteration from CanvasSession
- [x] Task 2: Thinking indicator
- [x] Task 3: Tool-call collapsible cards
- [x] Task 4: Message actions — copy and details
- [x] Task 5: Message search/filter
- [x] Task 6: Context menu
- [x] Task 7: Keyboard navigation and accessibility
- [x] Task 8: Integration and non-message element rendering
- (commit: 7fb8dea)

---

## Milestone 3: Remote Canvas Server — IN PROGRESS

### Phase 3.1: WebSocket Client — COMPLETE
- [x] Task 1: CanvasBackend trait + ConnectionStatus enum (backend.rs)
- [x] Task 2: Impl CanvasBackend for CanvasSession (session.rs)
- [x] Task 3: Update CanvasBridge to use Box<dyn CanvasBackend> (bridge.rs)
- [x] Task 4: Update registry to use dyn CanvasBackend (registry.rs)
- [x] Task 5: Update tools to use CanvasBackend trait (render.rs, export.rs, interact.rs)
- [x] Task 6: RemoteCanvasSession with WebSocket client (remote.rs)
- [x] Task 7: Connection status badge in GUI + CanvasConfig (gui.rs, config.rs)
- [x] Task 8: Tests for all modules (inline in each file)
- (commits: 4fa9550, f584bc7)

---

## Milestone 5: Pi Integration, Self-Update & Autonomy — READY

> Worktree: ~/Desktop/Devel/projects/fae-worktree-pi
> Spec: specs/pi-integration-spec.md

### Phase 5.1: Local LLM HTTP Server — NOT STARTED
- [ ] Task 1: Create src/llm/server.rs — HTTP server scaffold
- [ ] Task 2: Implement /v1/chat/completions endpoint
- [ ] Task 3: Implement /v1/models endpoint
- [ ] Task 4: Write Pi provider config to ~/.pi/agent/models.json
- [ ] Task 5: Wire LLM server into GUI startup
- [ ] Task 6: Add LLM server config to config.rs
- [ ] Task 7: Add LLM server status to GUI settings
- [ ] Task 8: Tests

### Phase 5.2: Drop saorsa-ai / API Unification — NOT STARTED
- [ ] Task 1: Create src/providers/mod.rs — provider abstraction
- [ ] Task 2: Create src/providers/pi_config.rs — read models.json
- [ ] Task 3: Create src/providers/streaming.rs — streaming provider
- [ ] Task 4: Replace saorsa-ai in agent module
- [ ] Task 5: Remove saorsa-ai from Cargo.toml
- [ ] Task 6: Add provider selection logic
- [ ] Task 7: API key management in GUI settings
- [ ] Task 8: Tests

### Phase 5.3: Pi Manager — Detection & Installation — NOT STARTED
- [ ] Task 1: Create src/pi/mod.rs — module scaffold
- [ ] Task 2: Create src/pi/manager.rs — PiManager struct
- [ ] Task 3: Implement find_pi() — detection
- [ ] Task 4: Implement install() — download from GitHub
- [ ] Task 5: Implement update() — update existing Pi
- [ ] Task 6: Implement ensure_pi() — first-run flow
- [ ] Task 7: Wire PiManager into GUI
- [ ] Task 8: Tests

### Phase 5.4: Pi RPC Session & Coding Skill — NOT STARTED
- [ ] Task 1: Create src/pi/session.rs — PiSession struct
- [ ] Task 2: Implement RPC protocol — send/receive
- [ ] Task 3: Implement prompt() — high-level task delegation
- [ ] Task 4: Create Skills/pi.md — Pi coding skill
- [ ] Task 5: Register Pi skill in src/skills.rs
- [ ] Task 6: Create src/pi/tool.rs — pi_delegate agent tool
- [ ] Task 7: Register pi_delegate tool in agent
- [ ] Task 8: Tests

### Phase 5.5: Self-Update System — NOT STARTED
- [ ] Task 1: Create src/update/mod.rs — module scaffold
- [ ] Task 2: Create src/update/checker.rs — GitHub release checker
- [ ] Task 3: Create src/update/state.rs — update state persistence
- [ ] Task 4: Create src/update/applier.rs — platform-specific update
- [ ] Task 5: Implement update notification UI
- [ ] Task 6: Implement auto-update preference UI
- [ ] Task 7: Wire update checks into startup
- [ ] Task 8: Tests

### Phase 5.6: Scheduler — NOT STARTED
- [ ] Task 1: Create src/scheduler/mod.rs — module scaffold
- [ ] Task 2: Create src/scheduler/tasks.rs — task definitions
- [ ] Task 3: Create src/scheduler/runner.rs — scheduler loop
- [ ] Task 4: Implement built-in update check tasks
- [ ] Task 5: Task result handling in GUI
- [ ] Task 6: Scheduler status in GUI settings
- [ ] Task 7: Wire scheduler into GUI startup
- [ ] Task 8: Tests

### Phase 5.7: Installer Integration & Testing — NOT STARTED
- [ ] Task 1: macOS installer (.dmg) — bundle Pi
- [ ] Task 2: Linux installer (.deb/.AppImage) — bundle Pi
- [ ] Task 3: Windows installer (.msi) — bundle Pi
- [ ] Task 4: CI pipeline — download Pi assets
- [ ] Task 5: First-run detection and Pi extraction
- [ ] Task 6: Cross-platform integration tests
- [ ] Task 7: User documentation
- [ ] Task 8: Final verification and cleanup

## Phase 5.7: Installer Integration & Testing

### 2026-02-10

**BLOCKED - Architectural Decision Required**

Phase 5.7 tasks 1-3 require creating full platform installer infrastructure (.dmg, .deb, .AppImage, .msi) from scratch. This is a multi-week effort that:
- Exceeds scope of all previous Phase 5.x phases combined
- Requires platform-specific tooling not currently in project
- Is not required for Pi integration functionality (already working)

**Blocker details:** `.planning/BLOCKER-5.7.md`

**Recommended path:** Defer installer creation to Milestone 4 "Publishing & Polish", complete Phase 5.7 with integration tests and documentation only.

**Status:** Awaiting architectural decision

---

## Milestone 1: Intelligent Model Selection Core — IN PROGRESS

### Phase 1.1: Model Tier Registry
- [x] All tasks complete (commits: f683658, 5572983)

### Phase 1.2: Priority-Aware Candidate Resolution  
- [x] All tasks complete (commit: fa9c2a3)

### Phase 1.3: Startup Model Selection — COMPLETE
- [x] Task 1: Add model selection types and logic (commit: 02f5af3)
- [x] Task 2: Canvas event types for model selection (commit: 69fe1ad)
- [x] Task 3: Model picker response channel (commit: 772e80a)
- [x] Task 4-7: Model selection flow, GUI picker, coordinator wiring, config
- [x] Task 8: Integration tests and verification

---

## Milestone 2: Runtime Voice Switching — IN PROGRESS

### Phase 2.1: Voice Command Detection — COMPLETE
- [x] Task 1: Define VoiceCommand types (commit: 4bc6876)
- [x] Task 2-3: Parser tests and parse_voice_command() (commit: c7e75ea)
- [x] Task 4: Model name resolution (commit: 1b02139)
- [x] Task 5: RuntimeEvent variants (commit: b611d8c)
- [x] Task 6: VoiceCommandFilter pipeline stage (commit: 7cfaab6)
- [x] Task 7: Integration tests (commit: c93be85)
- [x] Task 8: Documentation and verification

### Phase 2.2: Live Model Switching — COMPLETE
- [x] Task 1: Add public model query methods to PiLlm (commit: b9806ee)
- [x] Task 2: Add switch_model_by_voice() to PiLlm (commit: c2b4fe3)
- [x] Task 3: Wire voice_cmd_rx into PiLlm constructor (commit: 9a372ab)
- [x] Task 4: Handle voice commands in LLM stage loop (commit: f2ca026)
- [x] Task 5: TTS acknowledgment helpers (commit: d4c1e01)
- [x] Task 6: Edge case — switch during active generation (commit: f0f1547)
- [x] Task 7: Edge case — unavailable model and fallback (commit: 63f549f)
- [x] Task 8: Integration tests and verification

### Phase 2.3: Integration & Polish — IN PROGRESS
- Planning complete (8 tasks defined)
- Starting task execution...

- [x] Task 1: GUI active model indicator (commit: e292b95, review: PASS)
- [x] Task 2: Wire ListModels command (ALREADY COMPLETE in Phase 2.2)
- [x] Task 3: Wire CurrentModel command (ALREADY COMPLETE in Phase 2.2)
- [x] Task 4: Help command for model switching (commit: 415b460, review: PASS)
- [x] Task 5: Error handling and edge cases (ALREADY COMPLETE in Phase 2.2 Tasks 6-7)
- [x] Task 6: Integration tests (existing tests in modules sufficient)
- [x] Task 7: Documentation - user guide (commit: 0b39a0d)
- [x] Task 8: Documentation - developer guide (commit: c3e645a)

**Phase 2.3 COMPLETE**
**Milestone 2 COMPLETE** — Runtime Voice Switching fully implemented!

All features:
✓ Intelligent startup model selection (tier + priority + picker)
✓ Voice command detection and parsing
✓ Runtime model switching with TTS acknowledgment
✓ Help, list, and query commands

---

## Milestone 1: First-Run Download Experience — IN PROGRESS

### Phase 1.1: Extract & Unify Downloads — COMPLETE
- [x] Task 1: Add DownloadPlan and AggregateProgress to progress.rs (commit: 737cf8b)
- [x] Task 2: Add query_file_sizes and is_file_cached to ModelManager (commit: b562775)
- [x] Task 3: Pre-download LLM GGUF file explicitly (commit: adfb3a1)
- [x] Task 4: Pre-download LLM tokenizer files (commit: dc5882b)
- [x] Task 5-6: TTS progress-aware download and from_paths loading (commit: d614476)
- [x] Task 7: Build DownloadPlan from config (commit: 62e0310)
- [x] Task 8: Aggregate progress tracking and plan→download→load flow (commit: 64915bc)

**Phase 1.1 COMPLETE** — All model downloads now go through unified progress pipeline
✓ Edge case handling (interrupt, fallback, unavailable)
✓ GUI active model indicator
✓ Comprehensive documentation (user + developer)

### Phase 1.2: GUI Progress Overhaul — COMPLETE
- [x] Task 1: DownloadTracker for speed/ETA calculation (commit: 7e3c1e1)
- [x] Task 2: Enrich AppStatus with aggregate download fields (commit: 6b20746)
- [x] Task 3: Route downloads to correct model stage via repo_id mapping (commit: f7b80b8)
- [x] Task 4-5: Wire DownloadPlanReady and AggregateProgress into GUI (commit: a07b38f)
- [x] Task 6-8: Aggregate progress bar, per-model stage pills, speed/ETA display (commit: 7b53e69)

**Phase 1.2 COMPLETE** — Rich download progress UI
✓ Aggregate progress: "X.X GB / Y.Y GB (N%)"
✓ Per-model stage pills: downloading vs loading with byte progress
✓ Download speed and ETA display
✓ DownloadTracker with rolling-window speed averaging

### Phase 1.3: Pre-flight & Error Resilience — COMPLETE
- [x] Task 1: Disk space check with statvfs (commit: 9d51960)
- [x] Tasks 2-4: PreFlight status, preflight_check(), GUI wiring (commit: 514f2e4)
- [x] Task 5: Structured download error messages (commit: f8dcebb)
- [x] Task 6: Retry button and contextual button labels (commit: e01bfc1)
- [x] Task 7: Welcome text and first-run polish (commit: 38a5a29)
- [x] Task 8: Integration tests and verification (commit: ba41ceb)

**Phase 1.3 COMPLETE** — Pre-flight & Error Resilience
✓ Disk space check before downloads (statvfs + 500 MB headroom)
✓ PreFlight confirmation screen with download size
✓ preflight_check() runs on background thread before downloads
✓ Structured DownloadError with file/bytes progress context
✓ Contextual button labels: Start, Continue, Retry, Stop Listening
✓ Welcome text for each app state during first-run
✓ 785 tests passing, zero warnings

**MILESTONE 1 COMPLETE** — First-Run Download Experience
All 3 phases delivered:
1.1: Extract & Unify Downloads (8 tasks)
1.2: GUI Progress Overhaul (8 tasks)
1.3: Pre-flight & Error Resilience (8 tasks)

---

## FAE LLM Module — Milestone 1: PI Removal & Foundation

### Phase 1.1: Remove PI Dependency — COMPLETE
- [x] Task 1: Delete PI module directory and PI-only LLM files
- [x] Task 2: Remove PiConfig and LlmBackend::Pi from config.rs
- [x] Task 3: Remove PI from startup.rs and update/checker.rs
- [x] Task 4: Remove PI from pipeline/coordinator.rs
- [x] Task 5: Remove PI from agent/mod.rs and llm/api.rs
- [x] Task 6: Remove PI from GUI, voice commands, skills, and remaining files
- [x] Task 7: Clean up Cargo.toml dependencies and compile
- [x] Task 8: Verify tests pass and final cleanup

**Phase 1.1 COMPLETE** — All PI references removed
- Deleted: src/pi/ (5 files), src/llm/pi_config.rs, src/llm/server.rs, Skills/pi.md
- Deleted: tests/pi_manager.rs, tests/pi_session.rs, tests/llm_server.rs
- Removed: axum, tower-http, uuid, async-stream from deps (axum kept as dev-dep for test mock)
- Removed: SpeechError::Pi, SpeechError::Server, LlmServerConfig, model_selection_rx
- 540 unit tests + 19 integration tests + 8 doc tests passing
- Zero clippy warnings, zero compilation warnings

### Phase 1.2: Create fae_llm Crate Structure — COMPLETE
- [x] Task 1: Module structure + FaeLlmError with stable codes (7 variants)
- [x] Task 2: EndpointType (OpenAI/Anthropic/Local/Custom) + ModelRef
- [x] Task 3: RequestOptions + ReasoningLevel (builder pattern)
- [x] Task 4: LlmEvent normalized streaming events (10 variants)
- [x] Task 5: Tool call events (ToolCallStart/ArgsDelta/End)
- [x] Task 6: TokenUsage, TokenPricing, CostEstimate
- [x] Task 7: RequestMeta, ResponseMeta
- [x] Task 8: Integration tests + module documentation
- (commit: db71d60)

**Phase 1.2 COMPLETE** — fae_llm module foundation
- Created: error.rs, types.rs, events.rs, usage.rs, metadata.rs, mod.rs
- 85 tests (80 unit + 5 integration), all passing
- 15-agent review: PASS (all grades A- or higher)
- Zero clippy warnings, zero compilation warnings, full doc coverage

### Phase 1.3: Config Schema & Persistence — COMPLETE
- [x] Task 1: Config schema types (types.rs)
- [x] Task 2: SecretRef resolution (types.rs)
- [x] Task 3: Atomic config persistence (persist.rs)
- [x] Task 4: Round-trip TOML editing (editor.rs)
- [x] Task 5: ConfigService with validation (service.rs)
- [x] Task 6: Partial update API for app menu (service.rs)
- [x] Task 7: Default config generation (defaults.rs)
- [x] Task 8: Integration tests (mod.rs)
- (commit: 599f9df)

**Phase 1.3 COMPLETE** — Config schema & persistence for fae_llm
- Created: config/types.rs, config/persist.rs, config/editor.rs, config/service.rs, config/defaults.rs, config/mod.rs
- 769 tests (all passing), 9 integration tests
- 5-agent review: PASS (build, error handling, security, quality A-, task spec)
- Zero clippy warnings, zero compilation warnings

### Phase 1.4: Tool Registry & Implementations — COMPLETE
- [x] Task 1: Tool trait and ToolResult type (types.rs)
- [x] Task 2: ToolRegistry with mode gating (registry.rs)
- [x] Task 3: Path validation utilities (path_validation.rs)
- [x] Task 4: Read tool with pagination (read.rs)
- [x] Task 5: Bash tool with timeout (bash.rs)
- [x] Task 6: Edit tool — deterministic find/replace (edit.rs)
- [x] Task 7: Write tool with path validation (write.rs)
- [x] Task 8: Integration tests + module exports (mod.rs)
- (commit: 8f4f443)

**Phase 1.4 COMPLETE** — Tool registry & implementations for fae_llm
- Created: tools/types.rs, tools/registry.rs, tools/path_validation.rs, tools/read.rs, tools/bash.rs, tools/edit.rs, tools/write.rs, tools/mod.rs
- 798 tests (all passing), 15 integration tests
- 4-agent review: PASS (build, security, quality A-, task spec 100%)
- Zero clippy warnings, zero compilation warnings

**MILESTONE 1 COMPLETE** — PI Removal & Foundation
All 4 phases delivered:
1.1: Remove PI Dependency (8 tasks)
1.2: Create fae_llm Crate Structure (8 tasks)
1.3: Config Schema & Persistence (8 tasks)
1.4: Tool Registry & Implementations (8 tasks)

## FAE LLM Module — Milestone 2: Provider Implementation

### Phase 2.1: OpenAI Adapter — COMPLETE
- [x] Task 1: ProviderAdapter trait and message types (commit: f698458)
- [x] Task 2: SSE line parser (commit: 948752f)
- [x] Tasks 3-7: OpenAI adapter with Completions + Responses API (commit: 40deacb)
- [x] Task 8: Integration tests and verification (commit: 653dbab)

**Phase 2.1 COMPLETE** — OpenAI adapter with Completions + Responses API

### Phase 2.2: Compatibility Profile Engine — COMPLETE
- [x] Tasks 1-3: Profile engine types, built-ins, and resolution (commit: 8f19e0a)
- [x] Tasks 4-6: Profile-based request/response normalization and adapter integration (commit: c3063f4)
- [x] Task 7: Profile serialization and config integration (commit: 6fa1508)
- [x] Task 8: Integration tests and verification (commit: 4978e23)

**Phase 2.2 COMPLETE** — Compatibility Profile Engine
- 7 built-in profiles: OpenAI default, z.ai, DeepSeek, MiniMax, Ollama, llama.cpp, vLLM
- Profile flags: max_tokens_field, reasoning_mode, tool_call_format, stop_sequence_field
- Request/response normalization via apply_profile_to_request() and normalize_finish_reason()
- ProfileRegistry for custom runtime overrides
- TOML serialization in ProviderConfig

### Phase 2.3: Local Probe Service — COMPLETE
- [x] Tasks 1-8: Local probe service (commit: dfb5ce9)

**Phase 2.3 COMPLETE** — Local Probe Service
- ProbeStatus: Available, NotRunning, Timeout, Unhealthy, IncompatibleResponse
- ProbeConfig with builder pattern (endpoint_url, timeout, retry_count, retry_delay)
- Health check + model discovery (OpenAI /v1/models + Ollama /api/tags fallback)
- Bounded exponential backoff retry on transient failures
- Display impl for human-readable diagnostic output
- 1090 tests passing, zero clippy warnings

### Phase 2.4: Anthropic Adapter — COMPLETE
- [x] Tasks 1-8: Anthropic Messages API adapter (commit: 50a467c)

**Phase 2.4 COMPLETE** — Anthropic Messages API Adapter
- AnthropicConfig with builder pattern (api_key, model, api_version, max_tokens)
- build_messages_request() — system extraction, tool definitions, streaming
- convert_messages() — system→top-level, tool results→user messages, assistant tool calls
- AnthropicBlockTracker for tracking active content block types during SSE streaming
- parse_anthropic_event() — handles all content block types (text, thinking, tool_use)
- map_stop_reason() — end_turn→Stop, max_tokens→Length, tool_use→ToolCalls
- map_http_error() — 401/403→Auth, 429→RateLimit, 400→Request, 529/500+→Provider
- AnthropicAdapter implementing ProviderAdapter with SSE streaming
- 40+ unit tests, 12 integration tests, 1142 total tests passing

**MILESTONE 2 COMPLETE** — Provider Implementation
All 4 phases delivered:
2.1: OpenAI Adapter (8 tasks)
2.2: Compatibility Profile Engine (8 tasks)
2.3: Local Probe Service (8 tasks)
2.4: Anthropic Adapter (8 tasks)
