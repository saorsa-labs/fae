# Fae Canvas Integration — Production Roadmap

## Problem
Fae can only output text — no way to show charts, images, or rich visual content.
The saorsa-canvas visual platform exists but isn't connected to the voice assistant.

## Success Criteria
Production-ready: Full canvas pane with rich content rendering, MCP tools wired,
remote canvas-server connectivity, saorsa-canvas published to crates.io, all tested
and documented.

---

## Milestone 1: Canvas Core Integration & Dioxus Pane (COMPLETE VERTICAL SLICE)

### Goal
Get canvas-core embedded in fae, messages rendering as scene graph elements in a
new Dioxus pane, replacing the flat text log with interactive message bubbles.
This is the critical path — everything else builds on it.

### Phase 1.1: Dependency & Shared Types (8 tasks)
1. Add `canvas-core` (path dep → `../saorsa-canvas/canvas-core`) to fae's Cargo.toml
2. Create `src/canvas/mod.rs` — fae's canvas abstraction module
3. Create `src/canvas/types.rs` — `CanvasMessage` enum mapping LogEntry → ElementKind
4. Create `src/canvas/session.rs` — `CanvasSession` wrapping canvas-core `Scene`
5. Implement `CanvasMessage::to_element()` conversion (user speech, assistant reply, tool call, system)
6. Implement `CanvasSession::push_message()` — adds message element to scene with auto-layout
7. Implement `CanvasSession::to_html()` — serializes scene to HTML for webview embedding
8. Tests: round-trip message→element→serialize, session management, auto-layout positions

### Phase 1.2: Message Pipeline Bridge (8 tasks)
1. Create `src/canvas/bridge.rs` — connects pipeline events to canvas session
2. Map `RuntimeEvent` variants to `CanvasMessage` types
3. Implement `CanvasBridge::on_event()` — routes pipeline events to scene updates
4. Add scroll-viewport tracking (auto-focus newest message)
5. Implement message grouping (consecutive same-role messages)
6. Add timestamp rendering for message groups
7. Handle barge-in / message cancellation (visual indication)
8. Tests: event routing, grouping, scroll behavior, cancellation

### Phase 1.3: Dioxus Canvas Pane (8 tasks)
1. Create canvas pane Dioxus component in gui.rs
2. Add split-pane layout: controls on left, canvas on right
3. Implement `CanvasView` component rendering scene as styled HTML in webview
4. Wire `CanvasBridge` to GUI state — scene updates trigger re-render
5. Style message bubbles (user = right-aligned, assistant = left-aligned, system = centered)
6. Add auto-scroll behavior (scroll to bottom on new messages)
7. Add message selection (click to highlight/copy)
8. Tests: component renders, messages display, scroll works, selection works

---

## Milestone 2: Rich Content & MCP Tools

### Goal
Wire MCP tool definitions so Fae's agent backend can push rich content (charts,
images, formatted text) to the canvas. Same tool protocol works locally and will
later work with remote canvas-server.

### Phase 2.1: MCP Tool Integration (8 tasks)
1. Add `canvas-mcp` as dependency in fae
2. Create `src/canvas/tools.rs` — MCP tool executor backed by local CanvasSession
3. Wire `canvas_render` tool — assistant pushes Chart/Image/Text to canvas
4. Wire `canvas_interact` tool — report user interactions back to assistant
5. Wire `canvas_export` tool — export canvas to PNG/SVG/PDF
6. Register canvas tools in agent tool registry (`src/agent/mod.rs`)
7. Add tool approval UI for canvas tools (user confirms before rendering)
8. Tests: tool execution, render pipeline, export output

### Phase 2.2: Content Renderers (8 tasks)
1. Implement chart rendering via plotters (bar, line, pie, scatter) → SVG in canvas
2. Implement image rendering (display base64/URL images in canvas)
3. Implement formatted text rendering (markdown → styled HTML in canvas)
4. Implement code block rendering (syntax-highlighted code snippets)
5. Implement table rendering (structured data display)
6. Add content resize/reflow when pane size changes
7. Add content caching (don't re-render unchanged elements)
8. Tests: each renderer type, resize behavior, cache invalidation

### Phase 2.3: Interactive Elements (8 tasks)
1. Add clickable message actions (copy text, replay audio, view details)
2. Implement message context menu (right-click)
3. Add "thinking" indicator for assistant (animated dots while generating)
4. Add tool-call visualization (collapsible tool invocation cards)
5. Implement message search/filter (find in conversation)
6. Add conversation fork visualization (when barge-in creates a new branch)
7. Add accessibility: keyboard navigation, screen reader labels
8. Tests: actions fire, context menu, search, keyboard nav

---

## Milestone 3: Remote Canvas Server

### Goal
Connect fae to remote canvas-server instances via WebSocket. Same MCP protocol
works locally and remotely. Enable future multi-device scenarios.

### Phase 3.1: WebSocket Client (8 tasks)
1. Create `src/canvas/remote.rs` — WebSocket client for canvas-server
2. Implement `RemoteCanvasSession` — same API as `CanvasSession` but proxies to server
3. Add session negotiation (create/join/resume sessions)
4. Implement scene sync (server pushes scene updates, client renders)
5. Add reconnection logic with exponential backoff
6. Add connection status indicator in GUI
7. Create `CanvasBackend` trait — unifies local `CanvasSession` and `RemoteCanvasSession`
8. Tests: connect/disconnect, sync, reconnection, trait dispatch

### Phase 3.2: Server-Side Rendering (8 tasks)
1. Update canvas-server to handle fae-specific message elements
2. Implement server-side scene persistence (sessions survive restarts)
3. Add multi-client support (multiple fae instances viewing same canvas)
4. Implement canvas-server health endpoint for fae connection management
5. Add session expiry and cleanup
6. Implement server-side export (canvas_export runs on server)
7. Add WebSocket authentication (API key or session token)
8. Tests: persistence, multi-client, expiry, auth

---

## Milestone 4: Publishing & Polish

### Goal
Publish saorsa-canvas crates to crates.io. Polish the integration. Documentation.

### Phase 4.1: crates.io Publishing (8 tasks)
1. Audit saorsa-canvas workspace for crates.io readiness (docs, metadata, license)
2. Fix any warnings/issues in saorsa-canvas crates
3. Create GitHub Actions workflow for saorsa-canvas CI (fmt, clippy, test)
4. Create GitHub Actions workflow for crates.io publish (canvas-core → canvas-mcp → canvas-server)
5. Publish canvas-core to crates.io
6. Publish canvas-mcp to crates.io
7. Publish canvas-server to crates.io
8. Update fae's Cargo.toml to use crates.io deps (with path override for local dev)

### Phase 4.2: Documentation & Polish (8 tasks)
1. Update fae README.md with canvas integration docs
2. Update saorsa-canvas README.md with fae integration examples
3. Add canvas configuration section to fae's GUI settings
4. Add "canvas server URL" setting for remote connectivity
5. Write API documentation for all new public types
6. Create integration test suite (fae + canvas-core end-to-end)
7. Performance profiling (canvas rendering overhead in voice pipeline)
8. Final review and cleanup

---

## Architecture Notes

### Shared Protocol
Both local and remote canvas use the same types:
- `canvas_core::Scene` — the scene graph
- `canvas_core::Element` / `ElementKind` — scene elements
- `canvas_mcp::tools::RenderContent` — MCP render payload
- `canvas_mcp::ToolResponse` — MCP response format

### Data Flow (Local)
```
Pipeline → RuntimeEvent → CanvasBridge → CanvasSession → Scene → HTML render → Dioxus pane
                                              ↑
                              Agent → MCP Tool → canvas_render()
```

### Data Flow (Remote)
```
Pipeline → RuntimeEvent → CanvasBridge → RemoteCanvasSession → WebSocket → canvas-server
                                                                              ↓
                                                                         Scene (server)
                                                                              ↓
                                                                    WebSocket push → client render
```

### Key Design Decisions
- canvas-core is a **path dependency** during dev, crates.io in release
- Scene graph is the **single source of truth** — both local and remote use it
- MCP tools are **the same** whether running locally or against a remote server
- Dioxus renders canvas via **HTML/CSS in the webview** (no wgpu needed for v1)
- Messages are `ElementKind::Text` elements with metadata for role/timestamp
- Rich content uses existing `ElementKind` variants (Chart, Image, Model3D)
- `CanvasBackend` trait abstracts local vs remote — code doesn't care which

---

## Milestone 5: Pi Integration, Self-Update & Autonomy

> **Worktree**: `~/Desktop/Devel/projects/fae-worktree-pi`
> **Spec**: `specs/pi-integration-spec.md`
> **Archived predecessor**: `archive/ROADMAP-milestone2-self-update.md`

### Problem
Fae can think and speak, but she can't **do things** — she can't write code, edit
configs, manage files, or automate tasks on the user's computer. Pi is the coding
agent that gives her hands. Additionally, Fae has no self-update capability and
depends on `saorsa-ai` for LLM providers when Pi's `~/.pi/agent/models.json`
already handles multi-provider configuration.

### Design Philosophy (inspired by OpenClaw)
- **Pi is the hands, Fae is the brain.** Fae delegates coding/file tasks to Pi via
  RPC, just as OpenClaw uses Pi as its core intelligence engine.
- **Self-extension over plugins.** Following Pi/OpenClaw's philosophy: the LLM
  writes code to extend its own capabilities rather than downloading pre-built plugins.
- **Gateway pattern.** Fae acts as the gateway (voice channel) routing user intent
  to Pi's agent tools, similar to OpenClaw's multi-channel gateway architecture.
- **Single source of truth for AI config.** `~/.pi/agent/models.json` is the one
  place for API keys, model providers, and endpoints. No separate saorsa-ai config.
- **Local-first intelligence.** Fae's Qwen 3 (via mistralrs) is exposed as an
  OpenAI-compatible HTTP endpoint so Pi can use it — zero cloud dependency for
  coding tasks.
- **Install tools properly.** Pi is installed as `pi` in the standard system
  location. Standard config at `~/.pi/agent/`. Interoperates with user-installed Pi.
- **Fae is for non-technical users.** They don't have Node.js, Homebrew, or a
  terminal. Everything must be handled by the installer and the app itself.

### Success Criteria
- Fae exposes local Qwen 3 as OpenAI-compatible endpoint; Pi uses it for inference
- saorsa-ai removed; all API keys managed via `~/.pi/agent/models.json`
- Pi detected/installed to standard location on all platforms
- Pi coding tasks delegated via RPC from voice commands
- Fae self-updates from GitHub releases (Mac, Linux, Windows)
- Pi auto-updates via scheduler with user preference control
- Scheduler infrastructure ready for future user tasks
- Zero terminal interaction required from the user

### Phase 5.1: Local LLM HTTP Server (8 tasks)
Expose Fae's Qwen 3 (mistralrs GGUF) as an OpenAI-compatible HTTP endpoint on
localhost. This lets Pi (and any other local tool) use Fae's brain without cloud
API keys. Write a `"fae-local"` provider entry to `~/.pi/agent/models.json`.

### Phase 5.2: API Key Unification — Drop saorsa-ai (8 tasks)
Replace `saorsa-ai` dependency with direct `~/.pi/agent/models.json` parsing.
Read provider configs, API keys, and base URLs from Pi's config. Fae's agent
backend uses a new `PiConfigProvider` that loads from this single source.

### Phase 5.3: Pi Manager — Detection & Installation (8 tasks)
`PiManager` finds or installs Pi. Check PATH → check standard locations → download
from GitHub releases → install to `~/.local/bin/pi` (Linux/Mac) or
`%LOCALAPPDATA%\pi\pi.exe` (Windows). Track managed vs user-installed. Verify via
`pi --version`.

### Phase 5.4: Pi RPC Session & Coding Skill (8 tasks)
`PiSession` spawns `pi --mode rpc --no-session`, communicates via JSON over
stdin/stdout. New `Skills/pi.md` tells Fae when to delegate tasks to Pi (coding,
file management, config editing, research). Register as agent tool so Fae can
invoke Pi from voice commands.

### Phase 5.5: Self-Update System (8 tasks)
`UpdateChecker` polls GitHub releases API for both Fae and Pi. Platform-specific
binary replacement (Linux: rename+replace, macOS: +xattr, Windows: .bat script).
Update notification UI in Dioxus. User preferences: Ask / Always / Never.

### Phase 5.6: Scheduler (8 tasks)
Background `Scheduler` running periodic tasks. Built-in: daily Fae update check,
daily Pi update check. Future: user-defined scheduled tasks (calendar, research,
reminders). Persisted task definitions in `~/.config/fae/scheduler.json`.

### Phase 5.7: Installer Integration & Testing (8 tasks)
Platform installers (macOS .dmg, Linux .deb/.AppImage, Windows .msi) bundle Pi
binary at build time. Post-install places Pi in standard location. Cross-platform
testing of full lifecycle. Documentation.

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              FAE                                        │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                    Voice Pipeline                                  │  │
│  │  Mic → AEC → VAD → STT → LLM (Qwen 3 via mistralrs) → TTS → Spk │  │
│  └──────────────────────────┬────────────────────────────────────────┘  │
│                              │                                          │
│              ┌───────────────┼───────────────┐                          │
│              ▼               ▼               ▼                          │
│  ┌───────────────┐ ┌─────────────────┐ ┌──────────────────┐           │
│  │  Canvas Tools  │ │  Pi Delegator   │ │  Local LLM HTTP  │           │
│  │  (MCP render)  │ │  (RPC session)  │ │  (OpenAI compat) │           │
│  └───────────────┘ └────────┬────────┘ └────────┬─────────┘           │
│                              │                    │                     │
│  ┌───────────────────────────┼────────────────────┼──────────────────┐ │
│  │                    Pi Manager                                      │ │
│  │  find_pi() → install() → spawn pi --mode rpc                     │ │
│  │  Pi reads ~/.pi/agent/models.json → uses fae-local provider       │ │
│  └───────────────────────────────────────────────────────────────────┘ │
│                                                                         │
│  ┌──────────────────┐  ┌──────────────────┐                           │
│  │  Self-Updater     │  │  Scheduler        │                           │
│  │  (GitHub releases)│  │  (cron-like tasks) │                           │
│  └──────────────────┘  └──────────────────┘                           │
└─────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     System (user's machine)                              │
│                                                                         │
│  ~/.local/bin/pi             ← Pi binary (standard location)            │
│  ~/.pi/agent/models.json     ← ALL AI config: keys, providers, Fae     │
│  ~/.pi/agent/                ← Pi config, auth, extensions, skills      │
│  ~/.config/fae/              ← Fae config, state, scheduler             │
│  ~/.fae/skills/              ← User skill .md files                     │
│  http://localhost:PORT/v1    ← Fae's local LLM endpoint (when running) │
└─────────────────────────────────────────────────────────────────────────┘
```

### Data Flow: Voice → Pi Coding Task
```
User speaks "fix the login bug in my website"
  → STT → "fix the login bug in my website"
  → LLM (Qwen 3) reads Pi skill → decides to delegate to Pi
  → Agent invokes pi_delegate tool with task description
  → PiSession sends JSON-RPC request to Pi subprocess
  → Pi uses Fae's local LLM (http://localhost:PORT/v1) for reasoning
  → Pi executes: read files, edit code, run tests via bash
  → Pi streams progress events back via stdout
  → Fae narrates progress to user via TTS
  → Pi returns final result
  → Fae speaks summary to user
```

### Key Integration Points
- **Pi reads `~/.pi/agent/models.json`** — Fae writes a `"fae-local"` provider
  entry pointing to `http://localhost:{PORT}/v1` with `api: "openai-completions"`
- **No saorsa-ai** — Fae reads the same `models.json` for any cloud API keys
  it needs (fallback providers, etc.)
- **Fae's skill system** already supports dynamic skills — `Skills/pi.md` is
  compiled in, users can add more in `~/.fae/skills/`
- **Scheduler** uses same infrastructure as OpenClaw's system-level scheduling
