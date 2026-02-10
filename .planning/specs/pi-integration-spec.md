# Pi Integration Specification

> **Version**: 1.0
> **Date**: 2026-02-10
> **Status**: Ready for Implementation
> **Worktree**: `~/Desktop/Devel/projects/fae-worktree-pi`
> **Related**: `fae-tool-bundling-spec.md` (v2.0 predecessor, still valid for Pi distribution decisions)

---

## 1. Executive Summary

Fae gains the ability to **do things** on the user's computer by integrating Pi
(the coding agent from `badlogic/pi-mono`). This spec covers seven new capabilities:

1. **Local LLM Server** — Fae exposes Qwen 3 as OpenAI-compatible HTTP API
2. **API Unification** — Drop `saorsa-ai`, use `~/.pi/agent/models.json` as single source
3. **Pi Manager** — Detect, install, and update Pi automatically
4. **Pi RPC Session** — Communicate with Pi via JSON-RPC over stdin/stdout
5. **Self-Update** — Fae updates herself from GitHub releases
6. **Scheduler** — Background task runner for update checks and future user tasks
7. **Installer Integration** — Platform installers bundle Pi for offline first-run

### Why Pi?

Pi is the coding agent that powers OpenClaw (145k+ GitHub stars). Key traits:
- **Minimal**: 4 core tools (read, write, edit, bash) — the LLM writes code to extend itself
- **Self-contained**: Compiled binary embeds Bun runtime (~90MB), no runtime dependencies
- **RPC mode**: JSON protocol over stdin/stdout for embedding in other applications
- **Custom providers**: `~/.pi/agent/models.json` supports any OpenAI-compatible endpoint
- **Active community**: Frequent releases, well-maintained

### Architecture Pattern (inspired by OpenClaw)

OpenClaw uses Pi as its core intelligence engine behind a gateway layer. Fae follows
the same pattern: **Fae is the gateway (voice channel), Pi is the hands.**

```
User speaks → Fae understands (STT + LLM) → Fae delegates to Pi (RPC)
                                            → Pi codes/edits/searches
                                            → Fae narrates result (TTS)
```

---

## 2. Local LLM Server

### Purpose
Fae runs Qwen 3 via mistralrs with Metal GPU acceleration. By exposing this as an
OpenAI-compatible HTTP endpoint, Pi can use Fae's brain for inference — zero cloud
dependency for coding tasks.

### Endpoint
- `POST /v1/chat/completions` — streaming chat completions
- `GET /v1/models` — list available models
- Bind: `127.0.0.1:{auto-assigned port}`

### Pi Configuration
When the server starts, Fae writes to `~/.pi/agent/models.json`:
```json
{
  "providers": {
    "fae-local": {
      "baseUrl": "http://127.0.0.1:{PORT}/v1",
      "api": "openai-completions",
      "apiKey": "fae-local",
      "models": [{
        "id": "fae-qwen3",
        "name": "Fae Local (Qwen 3)",
        "reasoning": false,
        "input": ["text"],
        "contextWindow": 32768,
        "maxTokens": 8192,
        "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
      }]
    }
  }
}
```

### Merge Behavior
- Read existing models.json
- Add/update `fae-local` provider entry
- Preserve all other providers (user's cloud API keys, etc.)
- Write back atomically

### Implementation
- HTTP server: `axum` (already transitive dep via dioxus)
- Share the same `mistralrs` model instance used by the voice pipeline
- Server starts after model loads, before pipeline starts
- Port stored in config for display in GUI settings

---

## 3. API Unification — Drop saorsa-ai

### Current State
- `saorsa-ai` provides `MistralrsProvider` and `StreamingProvider` trait
- Agent module (`src/agent/mod.rs`) imports from `saorsa_ai`
- API keys are configured... somewhere (saorsa-ai's own config)

### Target State
- `saorsa-ai` removed from Cargo.toml
- All AI provider config read from `~/.pi/agent/models.json`
- New `src/providers/` module replaces saorsa-ai functionality
- Local mistralrs provider remains for voice pipeline (no HTTP overhead)
- Cloud providers available as fallback if configured in Pi's models.json

### Provider Resolution
1. **Voice pipeline**: Always uses local mistralrs (direct, no HTTP)
2. **Agent tools**: Use local mistralrs via ToolingMistralrsProvider (existing)
3. **Cloud fallback**: If user has cloud keys in models.json, available for tasks
   requiring larger context or capabilities

### models.json Schema (Pi's format)
```json
{
  "providers": {
    "provider-name": {
      "baseUrl": "https://api.example.com/v1",
      "api": "openai-completions | openai-responses | anthropic-messages | google",
      "apiKey": "sk-...",
      "headers": { "optional": "custom headers" },
      "models": [
        {
          "id": "model-id",
          "name": "Display Name",
          "reasoning": false,
          "input": ["text"],
          "contextWindow": 128000,
          "maxTokens": 32000,
          "cost": { "input": 0.001, "output": 0.003, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}
```

---

## 4. Pi Manager

### Detection Strategy
1. Check PATH: `which pi` (Unix) / `where pi` (Windows)
2. Check standard locations:
   - Linux: `~/.local/bin/pi`, `/usr/local/bin/pi`
   - macOS: `~/.local/bin/pi`, `/usr/local/bin/pi`, `/opt/homebrew/bin/pi`
   - Windows: `%LOCALAPPDATA%\Programs\pi\pi.exe`, `%APPDATA%\npm\pi.cmd`
3. Verify: `pi --version` captures version string
4. Detect Fae-managed: `.fae-managed` marker file adjacent to binary

### Installation
- Source: `https://api.github.com/repos/badlogic/pi-mono/releases/latest`
- Assets: `pi-coding-agent-darwin-arm64`, `pi-coding-agent-darwin-x64`,
  `pi-coding-agent-linux-x64`, `pi-coding-agent-linux-arm64`,
  `pi-coding-agent-windows-x64.exe`
- Install to: `~/.local/bin/pi` (Linux/Mac) or `%LOCALAPPDATA%\Programs\pi\pi.exe` (Windows)
- Post-install: `chmod +x` (Unix), `xattr -c` (macOS), add to PATH (Windows)
- Marker: create `.fae-managed` next to binary

### First-Run Flow
```
User asks Fae to do a coding task
  → Fae checks: is Pi installed?
  → If yes: proceed with PiSession
  → If no: "I need Pi to help with coding. Would you like me to install it?"
    → User agrees: download + install (progress in GUI)
    → User declines: "I can't do coding tasks without Pi. Let me know if you change your mind."
```

### Bundled Pi (installer)
- Platform installers include Pi binary at build time
- On first run, if Pi not found: check bundled location first
- Copy bundled Pi to standard install location
- Saves download time and works offline

---

## 5. Pi RPC Session

### Protocol
Pi's RPC mode (`pi --mode rpc --no-session`) communicates via line-delimited JSON
over stdin/stdout.

**Send request** (write to stdin):
```json
{"jsonrpc":"2.0","id":1,"method":"prompt","params":{"text":"fix the login bug"}}
```

**Receive events** (read from stdout):
```json
{"jsonrpc":"2.0","id":1,"event":"progress","data":{"text":"Reading src/auth.rs..."}}
{"jsonrpc":"2.0","id":1,"event":"tool_call","data":{"tool":"read","input":{"path":"src/auth.rs"}}}
{"jsonrpc":"2.0","id":1,"event":"tool_result","data":{"tool":"read","output":"..."}}
{"jsonrpc":"2.0","id":1,"event":"progress","data":{"text":"Found the bug..."}}
{"jsonrpc":"2.0","id":1,"event":"result","data":{"text":"Fixed: the session token was not being refreshed..."}}
```

### PiSession Lifecycle
1. `PiSession::start(pi_path)` — spawn subprocess
2. `session.prompt(task, on_event)` — send task, stream events
3. Events routed to Fae's TTS for narration ("Reading your auth file... Found the bug...")
4. Final result spoken to user
5. Session can handle multiple sequential prompts
6. `session.stop()` — graceful shutdown (send exit, wait, then kill)

### Pi Skill (Skills/pi.md)
Behavioral guide for Fae's LLM (40-60 lines):
- **Delegate to Pi**: coding, file editing, config changes, bash commands, web research
- **Don't delegate**: questions Fae can answer, conversation, knowledge queries
- **Formulate requests**: be specific, include context, describe desired outcome
- **Progress narration**: summarize Pi's actions for TTS
- **Error handling**: explain failures simply

### Agent Integration
New `pi_delegate` tool in agent registry:
- Input: `{ "task": "description", "working_dir": "optional" }`
- Execution: ensure_pi → start session → prompt → collect result
- Output: Pi's final result text
- Requires ReadWrite tool_mode
- Gets approval wrapper (user confirms before Pi starts)

---

## 6. Self-Update System

### GitHub Releases Polling
- `UpdateChecker::for_fae()` — checks `saorsa-labs/fae` releases
- `UpdateChecker::for_pi()` — checks `badlogic/pi-mono` releases
- Uses conditional requests (ETag/If-None-Match) to minimize API calls
- Parses semver tags for version comparison

### Update Application (platform-specific)
- **Linux**: Download to temp → `mv` to replace current binary → `chmod +x`
- **macOS**: Download to temp → replace in .app bundle or standalone → `xattr -c`
- **Windows**: Download to temp → write .bat (wait for exit, replace, relaunch) → execute .bat

### User Preferences
```rust
enum AutoUpdatePreference {
    Ask,     // Show notification, user decides (default)
    Always,  // Auto-apply updates silently
    Never,   // Log availability but don't prompt
}
```

### State Persistence
`~/.config/fae/update-state.json`:
```json
{
  "fae_version": "0.1.0",
  "pi_version": "1.2.3",
  "pi_managed": true,
  "auto_update": "ask",
  "last_check": "2026-02-10T09:00:00Z",
  "dismissed_release": null,
  "etag_fae": "W/\"abc123\"",
  "etag_pi": "W/\"def456\""
}
```

---

## 7. Scheduler

### Design
Background loop checking every 60 seconds for due tasks. Built-in tasks for
update checking. Infrastructure for future user-defined tasks.

### Built-in Tasks
| Task | Schedule | Action |
|------|----------|--------|
| Check Fae updates | Daily | Poll GitHub releases |
| Check Pi updates | Daily | Poll GitHub releases |

### Future Tasks (not in scope for M5, but infrastructure ready)
- Calendar check (connect to user's calendar, remind of events)
- Research tasks (Pi-powered background research)
- File monitoring (watch directories for changes)
- Reminders (user-set timed reminders via voice)

### State Persistence
`~/.config/fae/scheduler.json`:
```json
{
  "tasks": [
    {
      "id": "check-fae-update",
      "name": "Check for Fae updates",
      "schedule": { "type": "daily", "hour": 9, "min": 0 },
      "last_run": "2026-02-10T09:00:00Z",
      "enabled": true
    }
  ]
}
```

---

## 8. Module Structure

New Rust modules added to Fae:

```
src/
├── llm/
│   ├── mod.rs          (existing)
│   ├── api.rs          (existing)
│   └── server.rs       (NEW — OpenAI-compatible HTTP server)
├── providers/
│   ├── mod.rs          (NEW — provider abstraction)
│   ├── pi_config.rs    (NEW — read ~/.pi/agent/models.json)
│   └── streaming.rs    (NEW — HTTP streaming provider)
├── pi/
│   ├── mod.rs          (NEW — module root)
│   ├── manager.rs      (NEW — PiManager detect/install/update)
│   ├── session.rs      (NEW — PiSession RPC)
│   └── tool.rs         (NEW — pi_delegate agent tool)
├── update/
│   ├── mod.rs          (NEW — module root)
│   ├── checker.rs      (NEW — GitHub release checker)
│   ├── applier.rs      (NEW — platform-specific update application)
│   └── state.rs        (NEW — update state persistence)
├── scheduler/
│   ├── mod.rs          (NEW — module root)
│   ├── runner.rs       (NEW — scheduler loop)
│   └── tasks.rs        (NEW — task definitions)
├── skills.rs           (EDIT — add PI_SKILL)
├── agent/
│   └── mod.rs          (EDIT — register pi_delegate, remove saorsa-ai)
└── config.rs           (EDIT — add llm_server, update config sections)
```

### New files in Skills/
```
Skills/
├── canvas.md    (existing)
└── pi.md        (NEW — Pi coding skill)
```

---

## 9. Dependency Changes

### Add
- `axum` — HTTP server for LLM endpoint (may already be transitive)
- `reqwest` — HTTP client for GitHub API and streaming providers (if not present)
- `semver` — version comparison

### Remove
- `saorsa-ai` — replaced by `src/providers/` + direct mistralrs usage

### Keep
- `saorsa-agent` — tool registry, agent loop, tool trait (still used)
- `mistralrs` — local LLM inference (core dependency)
- All canvas deps — unaffected by this milestone

---

## 10. Phase Execution Order

```
Phase 5.1 (LLM Server) ──→ Phase 5.2 (Drop saorsa-ai)
                                      │
Phase 5.3 (Pi Manager)  ──→ Phase 5.4 (Pi RPC + Skill)
                         ──→ Phase 5.5 (Self-Update)
                                      │
                              Phase 5.6 (Scheduler)
                                      │
                              Phase 5.7 (Integration + Testing)
```

**Parallelizable**: Phases 5.1 and 5.3 have no shared dependencies — they can
be developed concurrently by different engineers or in separate worktrees.

---

## 11. Risk Assessment

| Risk | Mitigation |
|------|------------|
| Pi RPC protocol changes | Pin Pi version in state, test against specific versions |
| mistralrs + axum conflict | axum is transitive via dioxus, version should align |
| models.json format changes | Deserialize leniently with `#[serde(default)]` |
| macOS Gatekeeper blocks Pi | `xattr -c` in installer and PiManager |
| Windows PATH not updated | Use `setx` or registry for per-user PATH modification |
| Large binary size (~90MB Pi + ~100MB Fae) | Expected for desktop app, compress in installer |
| Pi subprocess crashes | PiSession catches exit, reports error, offers retry |
| GitHub API rate limiting | ETag caching, exponential backoff, 60 req/hr unauthenticated |
