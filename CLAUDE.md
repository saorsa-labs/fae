# CLAUDE.md — Fae Implementation Guide

> **Current default workflow:** Swift-first macOS app development from `native/macos/Fae` using `swift build` and `swift test`.
> 
> **Legacy/archival note:** Rust `libfae` embedding, C-ABI, and host-IPC sections in this document are retained as historical context and for archived branches.

Project-specific implementation notes for AI coding agents.

## Core objective

Fae should be:

- reliable in conversation
- memory-strong over long horizons
- proactive where useful
- quiet by default (no noise/clutter)

## Memory-first architecture

Storage: SQLite + sqlite-vec (`~/.fae/memory/fae.db`)

Key behavior:

- automatic recall before LLM generation (hybrid: semantic + structural)
- automatic capture after each completed turn (with embedding)
- explicit edit operations with audit history
- PRAGMA quick_check integrity verification on startup
- daily automated backups with rotation (7 retained)

Behavioral truth sources:

- `Prompts/system_prompt.md`
- `SOUL.md`
- `~/.fae/memory/fae.db` (SQLite)
- `docs/guides/Memory.md`

Implementation touchpoints (not behavioral truth):

- `src/memory/sqlite.rs` — SQLite repository
- `src/memory/types.rs` — types, hybrid scoring
- `src/memory/jsonl.rs` — MemoryOrchestrator (recall/capture), JSONL migration support
- `src/memory/embedding.rs` — all-MiniLM-L6-v2 ONNX engine
- `src/memory/backup.rs` — VACUUM INTO backup + rotation
- `src/memory/schema.rs` — DDL, vec_embeddings virtual table
- `src/pipeline/coordinator.rs`
- `src/runtime.rs`
- `src/scheduler/tasks.rs`

## Scheduler timing (actual current cadence)

Scheduler loop tick: every 60s. All 11 built-in tasks:

| Task | Schedule | Purpose |
|------|----------|---------|
| `check_fae_update` | every 6h | Check for Fae updates |
| `memory_migrate` | every 1h | Schema migration checks |
| `memory_reflect` | every 6h | Consolidate memory duplicates |
| `memory_reindex` | every 3h | Health check + integrity verification |
| `memory_gc` | daily 03:30 | Retention cleanup |
| `memory_backup` | daily 02:00 | Atomic backup with rotation |
| `noise_budget_reset` | daily 00:00 | Reset proactive noise budget |
| `stale_relationships` | every 7d | Check stale relationships |
| `morning_briefing` | daily 08:00 | Prepare morning briefing |
| `skill_proposals` | daily 11:00 | Check skill opportunities |
| `skill_health_check` | every 5min | Python skill health checks |

## Quiet operation policy

Fae should work continuously without becoming noisy.

- Keep maintenance chatter off the main conversational subtitle/event surface.
- Use canvas/background surfaces for low-priority telemetry.
- Escalate only failures or high-value actionable items.
- Prefer digests over repeated single-event interruptions.

## Personalization and interview direction

Implementation strategy:

1. Add explicit onboarding interview flow with consent.
2. Persist interview outputs as tagged durable memory records with confidence/source.
3. Add periodic re-interview triggers (staleness/conflict/user request).
4. Build low-noise proactive briefings using memory + recency + urgency filters.

Detailed plan:

- `docs/adr/004-fae-identity-and-personality.md`

## Tool system reality

Tools are registered dynamically based on permissions and tool mode. Full inventory:

- **Core**: `read`, `write`, `edit`, `bash`
- **Web**: `web_search`, `fetch_url`
- **Apple**: `calendar`, `contacts`, `mail`, `reminders`, `notes` (permission-gated)
- **Desktop**: screenshots, window management, typing, clicks (via `desktop_automation` skill)
- **Scheduler**: list/create/update/delete/trigger tasks
- **Skills**: `python_skill` (JSON-RPC subprocess for Python skill packages)
- **Canvas**: `canvas_render`, `canvas_interact`, `canvas_export` (when canvas enabled)

Tool modes (configurable via Settings > Tools or `config.patch`):

- `off` — no tools
- `read_only` — `ReadTool` only
- `read_write` — Read + Write + Edit (Write/Edit approval-gated)
- `full` — All tools, dangerous ones wrapped in `ApprovalTool` **(recommended default)**
- `full_no_approval` — All tools, no approval prompts (trusted automation only)

**Current default: `full`** — Fae has access to bash, write, edit, python, desktop but
must ask the user for permission before executing each dangerous action.

### Voice Privilege Escalation (approval system)

Architecture ADR: `docs/adr/006-voice-privilege-escalation.md`

In `full` mode, dangerous tools are wrapped in `ApprovalTool`. When the background
agent tries to use one, the approval flow triggers:

1. **Coordinator speaks prompt** — "I'd like to run a command: `date`. Say yes or no."
2. **Swift overlay appears** — floating card with Yes/No buttons (Enter/Escape shortcuts)
3. **User responds** via voice ("yes"/"no"), button tap, or timeout (58s → auto-deny)
4. **Tool executes or is denied** — result spoken via TTS

Key implementation files:

| File | Role |
|------|------|
| `src/voice_command.rs` | `parse_approval_response()` — yes/no voice parser |
| `src/pipeline/coordinator.rs` | Approval state machine, queue, echo bypass |
| `src/personality.rs` | `format_approval_prompt()`, canned responses |
| `src/agent/mod.rs` | `build_registry()` wraps tools in `ApprovalTool` |
| `src/host/handler.rs` | Approval bridge + response drain |
| `ApprovalOverlayController.swift` | Swift-side approval lifecycle |
| `ApprovalOverlayView.swift` | SwiftUI overlay card |

### Intent-based tool routing

`classify_intent()` in `src/agent/mod.rs` detects tool-needing queries via keyword
matching and routes them to background agents. The voice engine never sees tool schemas.

| User says | Detected tools | Route |
|-----------|---------------|-------|
| "what time is it?" | `bash` | Background agent with bash |
| "search for X" | `web_search`, `fetch_url` | Background agent with web |
| "check my calendar" | calendar tools | Background agent |
| "read this file" | `read` | Background agent |
| "tell me a joke" | (none) | Voice engine directly |

When `needs_tools = true`: canned ack → background agent spawned → approval on tool
use → result spoken. When `needs_tools = false`: voice engine responds directly.

## Skills (builtin)

8 permission-gated builtin skills: calendar, contacts, mail, reminders, files, notifications, location, desktop_automation.

CameraSkill was removed in v0.7.0 (Phase 6.4) — vision capabilities are handled directly by the LLM provider without a dedicated skill gate.

## config.patch keys

The `config.patch` command (Swift → Rust via HostCommandBridge) supports these keys:

| Key | Type | Description |
|-----|------|-------------|
| `tool_mode` | string | Agent tool mode (`off`, `read_only`, `read_write`, `full`, `full_no_approval`) |
| `channels.enabled` | bool | Master toggle for channel integrations |
| `channels.discord.bot_token` | string | Discord bot token (stored as CredentialRef::Plaintext) |
| `channels.discord.guild_id` | string | Discord guild/server ID |
| `channels.discord.allowed_channel_ids` | string | Comma-separated channel IDs |
| `channels.whatsapp.access_token` | string | WhatsApp access token (stored as CredentialRef::Plaintext) |
| `channels.whatsapp.phone_number_id` | string | WhatsApp phone number ID |
| `channels.whatsapp.verify_token` | string | WhatsApp webhook verify token |
| `channels.whatsapp.allowed_numbers` | string | Comma-separated allowed phone numbers |

## Prompt/identity stack

Three prompt variants exist (`src/personality.rs`):

1. **CORE_PROMPT** (~18KB) — Full system prompt with tools, scheduler, skills, coding policy (`Prompts/system_prompt.md`)
2. **VOICE_CORE_PROMPT** (~2KB) — Condensed for voice channel: identity, style, companion presence, memory usage only. Strips tool schemas, scheduler details, skill management, and coding policy.
3. **BACKGROUND_AGENT_PROMPT** — Task-focused prompt for background tool agents. Spoken-friendly output, no follow-up questions, concise results.

Full prompt assembly order (non-voice):

1. Core system prompt (`Prompts/system_prompt.md`)
2. Vision section (when `vision_capable` is true)
3. SOUL contract (`SOUL.md`)
4. User name context (when known)
5. Skills (built-in `.md` + user skills)
6. Builtin capability fragments (permission-gated)
7. User add-on text
8. Memory context (injected by memory orchestrator)

Voice-optimized assembly skips steps 5-6 entirely, using `VOICE_CORE_PROMPT` instead of `CORE_PROMPT`.

Human contract document:

- `SOUL.md`

## Native app architecture (embedded Rust core)

Fae's macOS native app embeds the Rust core directly as a linked library (`libfae`),
not as a subprocess. The app IS the brain — zero IPC overhead for the primary UI.

Architecture ADR: `docs/adr/002-embedded-rust-core.md`

### Two integration modes

| Mode | Description | Latency |
|------|-------------|---------|
| **Embedded (Mode A)** | Swift links `libfae` via C ABI. Rust core runs in-process. | ~0ms (function call) |
| **IPC (Mode B)** | External frontends connect to `~/.fae/fae.sock`. Same JSON protocol. | ~3ms (UDS roundtrip) |

The Fae.app always uses Mode A. Mode B is for third-party UIs, CLI tools, or companion apps.

### Key principles

- The Swift app never spawns a backend subprocess in production.
- The Rust core is compiled as a static library (`crate-type = ["staticlib", "lib"]`).
- FFI surface is thin: `extern "C"` functions in `src/ffi.rs` (or UniFFI bindings).
- The embedded core can optionally listen on a Unix socket for external clients.
- Scheduler authority, memory, pipeline, and safety policy all live in the Rust core.
- macOS sandbox and entitlements apply naturally to the in-process Rust code.

### Current state

`EmbeddedCoreSender.swift` calls `extern "C"` functions in `src/ffi.rs` directly.
The Rust core runs in-process — no subprocess for the primary path.

### Swift-side files (50 files)

All paths below are under `native/macos/Fae/Sources/Fae/`.

**Core App**

| File | Role |
|------|------|
| `FaeApp.swift` | App entry, environment wiring, embedded core init |
| `ContentView.swift` | Main view, window state, orb context menu |
| `EmbeddedCoreSender.swift` | C ABI bridge to `libfae` (production sender) |
| `BackendEventRouter.swift` | Routes raw backend events to typed notifications |
| `HostCommandBridge.swift` | NotificationCenter → command sender |

**Orb & Window**

| File | Role |
|------|------|
| `NativeOrbView.swift` | Native orb rendering (replaces WebView orb) |
| `OrbAnimationState.swift` | Orb animation state machine |
| `OrbTypes.swift` | OrbMode, OrbFeeling, OrbPalette enums |
| `OrbStateBridgeController.swift` | Maps pipeline/runtime events to orb visual state |
| `WindowStateController.swift` | Adaptive window (collapsed/compact), hide/show |
| `NSWindowAccessor.swift` | NSWindow property access from SwiftUI |
| `VisualEffectBlur.swift` | NSVisualEffectView wrapper for blur |

**Conversation & Canvas**

| File | Role |
|------|------|
| `ConversationController.swift` | Conversation state (messages, listening) |
| `ConversationBridgeController.swift` | Routes backend events to conversation UI |
| `ConversationWindowView.swift` | Conversation NSPanel content view |
| `InputBarView.swift` | Text input bar for conversation |
| `SubtitleOverlayView.swift` | Floating subtitle overlay |
| `SubtitleStateController.swift` | Subtitle display state management |
| `CanvasController.swift` | Canvas rendering controller |
| `CanvasWindowView.swift` | Canvas NSPanel content view |
| `LoadingCanvasContent.swift` | Canvas loading placeholder |

**Auxiliary Windows & Approval**

| File | Role |
|------|------|
| `AuxiliaryWindowManager.swift` | Independent conversation, canvas & approval NSPanels |
| `PipelineAuxBridgeController.swift` | Routes voice commands to auxiliary windows |
| `ProgressOverlayView.swift` | Model download/load progress overlay |
| `ApprovalOverlayController.swift` | Tool approval lifecycle (observe/approve/deny) |
| `ApprovalOverlayView.swift` | Floating approval card (Yes/No + keyboard shortcuts) |

**Onboarding**

| File | Role |
|------|------|
| `OnboardingController.swift` | Onboarding flow state machine |
| `OnboardingNativeView.swift` | Onboarding native container view |
| `OnboardingWelcomeScreen.swift` | Welcome screen |
| `OnboardingPermissionsScreen.swift` | Permission grants screen |
| `OnboardingReadyScreen.swift` | Ready/completion screen |
| `OnboardingTTSHelper.swift` | TTS voice test during onboarding |
| `OnboardingWindowController.swift` | Onboarding window management |

**Settings**

| File | Role |
|------|------|
| `SettingsView.swift` | TabView settings (General, Models, Tools, Skills, Channels, About, Developer) |
| `SettingsGeneralTab.swift` | General settings (listening, theme, updates) |
| `SettingsModelsTab.swift` | Model selection and download |
| `SettingsToolsTab.swift` | Tool mode picker with config.patch sync |
| `SettingsSkillsTab.swift` | Skill management and review |
| `SettingsChannelsTab.swift` | Discord/WhatsApp channel configuration |
| `SettingsAboutTab.swift` | About, version, reset onboarding |
| `SettingsDeveloperTab.swift` | Developer diagnostics and debug |

**Skills & Handoff**

| File | Role |
|------|------|
| `SkillImportView.swift` | Skill file import UI |
| `DeviceHandoff.swift` | Apple Handoff support |
| `HandoffKVStore.swift` | Key-value store for Handoff state |
| `HandoffToolbarButton.swift` | Toolbar button for Handoff status |

**System**

| File | Role |
|------|------|
| `AudioDevices.swift` | Audio input/output device enumeration |
| `DockIconAnimator.swift` | Dock icon animation controller |
| `SparkleUpdaterController.swift` | Sparkle auto-update integration |
| `JitPermissionController.swift` | Just-in-time macOS permission requests |
| `HelpWindowController.swift` | Help HTML pages in native window |
| `ProcessCommandSender.swift` | Process-level command dispatch |
| `ResourceBundle.swift` | Bundle resource access helpers |

### Rust-side host layer

| File | Role |
|------|------|
| `src/ffi.rs` | C ABI entry points (`extern "C"` functions) |
| `src/host/mod.rs` | Host module root |
| `src/host/contract.rs` | Command/event envelope schemas |
| `src/host/handler.rs` | Runtime lifecycle, pipeline management |
| `src/host/channel.rs` | Command channel, router, handler trait |
| `src/host/latency.rs` | Latency instrumentation and timing metrics |
| `src/host/stdio.rs` | Stdin/stdout JSON bridge (Mode B / IPC only) |
| `src/bin/host_bridge.rs` | Headless bridge binary (Mode B / `faed` daemon) |

### Adaptive window system

The native app uses a two-mode adaptive window:

| Mode | Size | Style |
|------|------|-------|
| Collapsed | 80x80 | Borderless floating orb, always-on-top |
| Compact | 340x500 | Normal titled window |

Conversation and canvas are independent native `NSPanel` windows managed by
`AuxiliaryWindowManager`, positioned adjacent to the orb. Auto-hide after 30s
inactivity. Click orb to restore. See `WindowStateController.swift`.

## Linker anchor (anti-dead-strip)

SPM's `-dead_strip` removes Rust subsystems not reachable from FFI entry points.
`src/linker_anchor.rs` prevents this with a `black_box`-guarded anchor function.

Key files:

| File | Role |
|------|------|
| `src/linker_anchor.rs` | `fae_keep_alive` anchor + compile-time tests |
| `src/ffi.rs` | `fae_core_init` references the anchor via `black_box` |
| `include/fae.h` | C header declares `fae_keep_alive` |
| `native/macos/.../include/fae.h` | Swift module map copy |

When adding a new subsystem, add a `black_box` reference in the `if black_box(false)` block.

Verification: `just check-binary-size` (asserts libfae.a > 50 MB).

Full docs: `docs/guides/linker-anchor.md`

## Platform module (App Sandbox)

`src/platform/` provides cross-platform security-scoped bookmark support:

- `mod.rs`: `BookmarkManager` trait, `create_manager()` factory, `bookmark_and_persist()`, `restore_all_bookmarks()`
- `macos.rs`: Real implementation using `objc2-foundation` NSURL bookmark APIs
- `stub.rs`: No-op for non-macOS (bookmark create/restore return errors, access ops are no-ops)

Bookmarks are persisted in `config.toml` under `[[bookmarks]]` (base64-encoded, labeled).
On startup, `restore_all_bookmarks()` re-establishes access; stale bookmarks are refreshed, invalid ones pruned.

File picker flows call `bookmark_and_persist()` after user selection.

## NotificationCenter names

| Name | Purpose |
|------|---------|
| `.faeBackendEvent` | Raw backend events from Rust core |
| `.faeOrbStateChanged` | Orb visual state changes (mode, feeling, palette) |
| `.faePipelineState` | Pipeline lifecycle (stopped/starting/running/stopping/error) |
| `.faeRuntimeState` | Runtime lifecycle (starting/started/stopped/error) |
| `.faeRuntimeProgress` | Model download/load progress |
| `.faeAssistantGenerating` | LLM generation active/inactive |
| `.faeAudioLevel` | Audio level updates for orb visualization |
| `.faeApprovalRequested` | Tool approval request (shows overlay) |
| `.faeApprovalResolved` | Tool approval resolved (dismisses overlay) |
| `.faeApprovalRespond` | Button-based approval response (Swift → Rust) |

## Delivery quality requirements

### Current default (Swift app)

Always run from `native/macos/Fae`:

```bash
swift build
swift test
```

Known blockers:
- Dependency/submodule fetch requires working network access to GitHub.
- First runtime readiness may require substantial model downloads.

### Legacy / archival (Rust core)

For legacy Rust-core paths or archival branches, use:

```bash
cargo fmt --all
cargo clippy --all-features -- -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
cargo test
```

When changing memory logic, add tests first (TDD), then implementation.

## ⚠️ CLEAN BUILD POLICY — MANDATORY

**ALWAYS use `cargo clean` before building when testing changes to Fae.**

The static library build chain (Rust → `libfae.a` → Swift link) does NOT reliably
detect all changes through incremental compilation. Stale binaries have repeatedly
caused confusion where code changes appeared not to work.

**MANDATORY build sequence for testing:**

```bash
just clean                     # cargo clean — remove ALL cached Rust artifacts
just build-staticlib           # Rebuild libfae.a from scratch
just bundle-native             # Clean Swift + build + bundle + sign + verify
                               # (also kills any running Fae process automatically)
just run-native                # Launch Fae (kills stale process, opens with log capture)
```

Or as a single pipeline:

```bash
just clean && just build-staticlib && just bundle-native && just run-native
```

Monitor logs: `tail -f /tmp/fae-test.log`

**TWO failure modes to watch for:**

1. **Stale binary** — Swift SPM caches the linked binary. Even a fresh `libfae.a`
   won't take effect unless `native/macos/Fae/.build` is also removed. The
   `bundle-native` recipe handles this automatically (runs `clean-native` first).

2. **Stale process** — macOS `open` reactivates an already-running Fae process
   instead of launching the new binary. This silently ignores your fresh build.
   The `run-native` and `bundle-native` recipes now kill any existing Fae process
   automatically via `_kill-fae`. If launching manually, always kill first:

   ```bash
   pkill -f "Fae.app/Contents/MacOS/Fae" 2>/dev/null; sleep 1
   open "$FAE_APP" --stdout /tmp/fae-test.log --stderr /tmp/fae-test.log
   ```

**If Fae "isn't working" after a code change**, check BOTH: is the binary stale?
Is a stale process still running? (`pgrep -fl Fae`)

## Build memory optimization

Integration tests use the **matklad single-binary pattern** to avoid OOM during `cargo test`.

### Why

Each `tests/*.rs` file compiles to a separate binary linking the full ML stack (mistralrs + candle + ort + 14 gemm crates). With 29 files that meant 29 binaries × ~7GB link-time RAM = 200GB+ peak. Consolidating into `tests/integration/main.rs` reduces this to 1 binary.

### Test structure

```
tests/
  integration/
    main.rs          ← single binary entry point, #![allow(clippy::unwrap_used, ...)]
    helpers.rs       ← shared test utilities (temp_handler, temp_root, etc.)
    *.rs             ← one module per original test file
  fixtures/          ← test data (unchanged)
```

### Adding new integration tests

New integration tests go as modules in `tests/integration/`, NOT as new top-level `tests/*.rs` files:

1. Create `tests/integration/my_new_test.rs`
2. Add `mod my_new_test;` to `tests/integration/main.rs`
3. Use shared helpers from `super::helpers`

### Profile overrides

`.cargo/config.toml` contains test-specific overrides:
- `[profile.test]` — `opt-level = 1`, `debug = false`, `codegen-units = 1`
- `[profile.test.package."*"]` — `opt-level = 0` (prevents SIMD explosion in gemm/candle deps)

### CI memory cap

CI runners (7-14GB) use `CARGO_BUILD_JOBS=2` to cap parallel rustc processes. Locally, `just test-ci` does the same.

## Testing Fae with Chatterbox TTS

Chatterbox is a local TTS server used for voice-testing Fae's pipeline and for Claude Code notification hooks.

### Chatterbox location and startup

```bash
# Server lives at:
/Users/davidirvine/Desktop/Devel/projects/chatterbox/

# Start the service (default port 8000):
cd /Users/davidirvine/Desktop/Devel/projects/chatterbox
./start_service.sh
# Or directly:
python3 tts_service.py --host 127.0.0.1 --port 8000

# Health check:
curl -s http://127.0.0.1:8000/health
```

### Speaking to Fae via Chatterbox

Use the `/speak` endpoint with `play: true` — Chatterbox synthesizes speech AND plays it through system speakers. Fae hears it via the built-in mic.

```bash
# Speak to Fae (plays through speakers → mic → Fae pipeline):
curl -s -X POST http://127.0.0.1:8000/speak \
  -H "Content-Type: application/json" \
  -d '{"text": "Fae, what time is it?", "voice": "jarvis", "play": true}'

# Response: {"status": "playing", "message": "Audio is being played", "text": "..."}
```

Key parameters:
- `text`: What to say
- `voice`: Voice name (default: "jarvis")
- `play`: Must be `true` to play through speakers (otherwise just synthesizes)

### Claude Code hooks integration

Chatterbox is wired into Claude Code via notification hooks (`~/.claude/settings.json`):
- **Notification hook**: `~/.claude/hooks/notify_chatterbox.py` — speaks when Claude needs user input
- **Stop hook**: `~/.claude/hooks/stop_chatterbox.py` — speaks on GSD milestone completion
- Environment: `CHATTERBOX_URL=http://127.0.0.1:8000`, `USE_CHATTERBOX=true`

### Launching Fae with log capture for testing

**Preferred: use the justfile recipe** (kills stale process, signs, launches with logs):

```bash
just run-native                # Build + sign + kill stale + launch with log capture
tail -f /tmp/fae-test.log      # Monitor in another terminal
```

**Manual launch** (if you already have a signed bundle):

```bash
# ALWAYS kill any existing Fae process first — macOS `open` reactivates
# the running process instead of launching your new binary!
pkill -f "Fae.app/Contents/MacOS/Fae" 2>/dev/null; sleep 1

FAE_APP="native/macos/Fae/.build/arm64-apple-macosx/debug/Fae.app"
open "$FAE_APP" --stdout /tmp/fae-test.log --stderr /tmp/fae-test.log

# Monitor pipeline timing:
tail -f /tmp/fae-test.log | grep -E "pipeline_timing|dropping|transcrib"
```

### Pipeline timing events in logs

The pipeline emits `pipeline_timing` events at each stage boundary:
- `pipeline_timing: VAD segment complete` — `vad_ms`, `duration_s`
- `pipeline_timing: STT completed` — `stt_ms`, `vad_to_stt_ms`
- `pipeline_timing: LLM generation completed` — `llm_ms`, `interrupted`
- `pipeline_timing: TTS synthesis completed` — `tts_ms`, `chars`
- `pipeline_timing: playback completed` — `playback_ms`

Echo suppression logs: `dropping N.Ns speech segment (echo suppression)` — these are correctly filtered.

## LLM model evaluation

Benchmarks and findings live in `docs/benchmarks/llm-benchmarks.md`. When evaluating a new model
for Fae, follow this process.

### Running the eval

1. **Install mistral.rs CLI** (one-time): `cargo install mistralrs-cli --features metal --git https://github.com/EricLBuehler/mistral.rs` (build from master for latest arch support)
2. **Check GGUF compatibility** first — the model's `general.architecture` must be in mistral.rs GGUF enum (see incompatibility table in `docs/benchmarks/llm-benchmarks.md`)
3. **Download the GGUF** + tokenizer via `huggingface_hub` (see benchmark doc for pattern)
4. **Add the model** to the `MODELS` list in the benchmark script in `docs/benchmarks/llm-benchmarks.md`
5. **Run the full benchmark** — the script tests 7 context sizes with `/no_think`, tracks
   RAM, visible vs thinking chars, and T/s. Takes ~3 min per model.
6. **Update `docs/benchmarks/llm-benchmarks.md`** with the new rows in all tables (summary, speed-by-context,
   detailed results, compliance table)

### Important: mistral.rs GGUF arch limitations

As of Feb 2026, mistral.rs GGUF only supports: Llama, Mistral3, Phi2, Phi3, Starcoder2,
Qwen2, Qwen3, Qwen3MoE. On Metal (Apple Silicon), MoE models don't work. We exhaustively
tested every current-gen sub-4B model and found **only Qwen3 delivers usable voice T/s
on Metal**. See the full incompatibility table in `docs/benchmarks/llm-benchmarks.md` for details
on Ministral-3, SmolLM3, Phi-4, Granite, EXAONE, Gemma 3, and Liquid LFM2.

### What to measure

| Metric | Why it matters |
|--------|----------------|
| T/s at short context (~20-200 tok) | Voice responsiveness — needs >60 T/s |
| T/s at 1K-2K context | Realistic voice prompt with history |
| T/s at 8.5K context | Background/tool channel feasibility |
| `/no_think` compliance | Does the model respect the instruction? Check Think column for 0c |
| Idle RSS RAM | Does it fit alongside TTS + STT + embedding models? |
| Answer quality (subjective) | Send 5-10 voice-style questions, read the visible output |

### Vision-capable models

The 4B and 8B Qwen3 variants have VL (Vision-Language) counterparts that accept image
inputs. This is significant for Fae — it gives her eyes. With a vision model, Fae can:

- Describe what's on the user's screen (screenshot analysis)
- Read documents, receipts, photos shared by the user
- Understand visual context in conversations ("what's in this picture?")
- Power the canvas rendering pipeline with visual understanding

**Current vision support in code:**

- `src/config.rs`: `enable_vision` field on `LlmConfig`, `recommended_local_model()` returns
  `(model_id, gguf_file, tokenizer_id, enable_vision)` tuple
- `src/llm/mod.rs`: Dual loading path — `VisionModelBuilder` (ISQ Q4K) for VL models,
  `GgufModelBuilder` for text-only GGUF. Falls back to GGUF if vision load fails.
- `src/llm/mod.rs:CapturedImage`: Image capture struct passed to the vision encoder
- `src/personality.rs`: System prompt adapts when `vision_capable` is true

**Vision model tradeoffs:**

| Aspect | Text-only GGUF | Vision (VL + ISQ) |
|--------|----------------|-------------------|
| Loading | Fast (pre-quantized) | Slow (ISQ quantizes at startup) |
| Speed | Higher T/s | ~10-20% slower (vision encoder overhead) |
| RAM | Lower | Higher (vision encoder + cross-attention) |
| Capabilities | Text only | Text + image understanding |

**When evaluating a vision model**, additionally test:
- Startup time (ISQ quantization can take 30-60s for larger models)
- T/s with and without an image in the prompt
- Image description quality (send a screenshot, check the response)
- RAM overhead vs the text-only variant

Vision models are currently off by default (`enable_vision = false` in managed presets).
They can be enabled via `config.toml` (`enable_vision = true`) or a future Settings toggle.
The architecture supports hot-switching — if vision load fails, it falls back to GGUF
text-only automatically.

### Model selection guidance (current)

**Auto mode** (`VoiceModelPreset::Auto` in `src/config.rs`): `recommended_local_model()` always returns text-only GGUF:
- `>=48 GiB` RAM → Qwen3-8B (Q4_K_M)
- `>=32 GiB` RAM → Qwen3-4B (Q4_K_M)
- `<32 GiB` RAM → Qwen3-1.7B (Q4_K_M)

Forced presets: `Qwen3_8b`, `Qwen3_4b`, `Qwen3_1_7b`, `Qwen3_0_6b` (ignores RAM).

| System RAM | Voice (auto) | Background (async) | Notes |
|---|---|---|---|
| 8-16 GB | 0.6B text | 0.6B text | Only option that fits |
| 16-32 GB | 1.7B text | 1.7B text | Best voice quality at ~85 T/s |
| 32-48 GB | 4B text | 4B text | Auto selects 4B at >=32 GiB |
| 48+ GB | 8B text | 8B text | Auto selects 8B at >=48 GiB |

Vision is only enabled by explicit `enable_vision = true` in `config.toml`. Auto mode never selects a VL model. Vision models (Qwen3-VL-4B/8B) require ISQ quantization at startup and are better suited for the background channel.

## Completed milestones

- **v0.6.2** — Production hardening: pipeline startup fix, runtime event routing, settings redesign (TabView), help menu, onboarding reset, config.patch implementation
- **v0.7.0 (Milestone 6: Dogfood Readiness):**
  - Phase 6.1: Backend cleanup — removed API/Agent code, non-embedded providers
  - Phase 6.2: Voice command routing — PipelineAuxBridgeController for "show conversation"/"show canvas"
  - Phase 6.3: UX feedback — download progress bar, partial STT, streaming assistant text, orb audio level, right-click context menu
  - Phase 6.4: Settings expansion — tool mode tab, channel config tab, CameraSkill removal
  - Phase 6.5: Integration validation — full Rust/Swift build verification, all 11 dogfood findings confirmed resolved
- **Milestone 7: Memory Architecture v2 — SQLite + Semantic Retrieval:**
  - Phase 7.1: SQLite foundation (rusqlite + sqlite-vec, schema, SqliteMemoryRepository)
  - Phase 7.2: JSONL → SQLite migration (automatic on startup, backup preserved)
  - Phase 7.3: Embedding engine (all-MiniLM-L6-v2, 384-dim vectors via ort)
  - Phase 7.4: Hybrid retrieval (semantic 0.6 + confidence 0.2 + freshness 0.1 + kind bonus 0.1)
  - Phase 7.5: Backup, recovery & hardening (integrity check, VACUUM INTO backups, rotation)
- **Voice Privilege Escalation (tool approval system):**
  - 7-phase implementation: voice parser, notification channel, coordinator state machine, echo bypass, TTS prompts, Swift UI overlay, response drain
  - `ApprovalTool` wrapping for bash/write/edit/python/desktop in `full` mode
  - Intent-based routing: keyword classifier routes tool queries to background agents
  - Default tool mode changed from `read_only` to `full` with approval gating
  - ADR-006 documents the full architecture
