# CLAUDE.md — Fae Implementation Guide

Project-specific implementation notes for AI coding agents.

## Core objective

Fae should be:

- reliable in conversation
- memory-strong over long horizons
- proactive where useful
- quiet by default (no noise/clutter)

## Memory-first architecture

Key behavior:

- automatic recall before LLM generation
- automatic capture after each completed turn
- explicit edit operations with audit history
- migration-safe storage evolution with rollback

Behavioral truth sources:

- `Prompts/system_prompt.md`
- `SOUL.md`
- `~/.fae/memory/`
- `docs/Memory.md`

Implementation touchpoints (not behavioral truth):

- `src/memory.rs`
- `src/pipeline/coordinator.rs`
- `src/runtime.rs`
- `src/scheduler/tasks.rs`

## Scheduler timing (actual current cadence)

- Scheduler loop tick: every 60s
- Update check: every 6h
- Memory migrate: every 1h
- Memory reindex: every 3h
- Memory reflect: every 6h
- Memory GC: daily at 03:30 local time

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

- `docs/personalization-interviews-and-proactive-plan.md`

## Tool system reality

Current core toolset:

- `read`
- `write`
- `edit`
- `bash`
- canvas tools when registered

Tool modes (configurable via Settings > Tools or `config.patch`):

- `off`
- `read_only`
- `read_write`
- `full`
- `full_no_approval`

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

Prompt assembly order:

1. system prompt (`Prompts/system_prompt.md`)
2. SOUL contract (`SOUL.md`)
3. memory context (from `~/.fae/memory/`)
4. skills/tool instructions
5. user message/add-on

Human contract document:

- `SOUL.md`

## Native app architecture (embedded Rust core)

Fae's macOS native app embeds the Rust core directly as a linked library (`libfae`),
not as a subprocess. The app IS the brain — zero IPC overhead for the primary UI.

Architecture doc: `docs/architecture/native-app-v0.md`
Detailed embedding plan: `docs/architecture/embedded-core.md`

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

### Swift-side files

| File | Role |
|------|------|
| `native/macos/.../FaeNativeApp.swift` | App entry, environment wiring, embedded core init |
| `native/macos/.../EmbeddedCoreSender.swift` | C ABI bridge to `libfae` (production sender) |
| `native/macos/.../ContentView.swift` | Main view, window state, orb context menu |
| `native/macos/.../ConversationWebView.swift` | WKWebView bridge (orb animation + input bar) |
| `native/macos/.../ConversationController.swift` | Conversation state (messages, listening) |
| `native/macos/.../ConversationBridgeController.swift` | Routes backend events to conversation WebView (JS injection) |
| `native/macos/.../OrbStateBridgeController.swift` | Maps pipeline/runtime events to orb visual state |
| `native/macos/.../PipelineAuxBridgeController.swift` | Routes voice commands to auxiliary windows (canvas/conversation) |
| `native/macos/.../AuxiliaryWindowManager.swift` | Independent conversation & canvas NSPanels |
| `native/macos/.../WindowStateController.swift` | Adaptive window (collapsed/compact), hide/show |
| `native/macos/.../HostCommandBridge.swift` | NotificationCenter → command sender |
| `native/macos/.../SettingsView.swift` | TabView settings (General, Models, Tools, Channels, About, Developer) |
| `native/macos/.../SettingsToolsTab.swift` | Tool mode picker with config.patch sync |
| `native/macos/.../SettingsChannelsTab.swift` | Discord/WhatsApp channel configuration |
| `native/macos/.../JitPermissionController.swift` | Just-in-time macOS permission requests |
| `native/macos/.../HelpWindowController.swift` | Help HTML pages in native window |

### Rust-side host layer

| File | Role |
|------|------|
| `src/ffi.rs` | C ABI entry points (`extern "C"` functions) |
| `src/host/mod.rs` | Host module root |
| `src/host/contract.rs` | Command/event envelope schemas |
| `src/host/handler.rs` | Runtime lifecycle, pipeline management |
| `src/host/channel.rs` | Command channel, router, handler trait |
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

Full docs: `docs/linker-anchor.md`

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

## Delivery quality requirements

Always run:

```bash
cargo fmt --all
cargo clippy --all-features -- -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
cargo test
```

**Important:** Use plain `cargo test`, NOT `cargo test --all-features`. The `--all-features` flag enables feature combinations that cause excessive memory usage (300GB+).

When changing memory logic, add tests first (TDD), then implementation.

## Completed milestones

- **v0.6.2** — Production hardening: pipeline startup fix, runtime event routing, settings redesign (TabView), help menu, onboarding reset, config.patch implementation
- **v0.7.0 (Milestone 6: Dogfood Readiness):**
  - Phase 6.1: Backend cleanup — removed API/Agent code, non-embedded providers
  - Phase 6.2: Voice command routing — PipelineAuxBridgeController for "show conversation"/"show canvas"
  - Phase 6.3: UX feedback — download progress bar, partial STT, streaming assistant text, orb audio level, right-click context menu
  - Phase 6.4: Settings expansion — tool mode tab, channel config tab, CameraSkill removal
  - Phase 6.5: Integration validation — full Rust/Swift build verification, all 11 dogfood findings confirmed resolved
