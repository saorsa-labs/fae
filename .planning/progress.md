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

