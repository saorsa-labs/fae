# Changelog

All notable changes to this project will be documented in this file.

## [v0.8.56] - 2026-03-01

### Fixed

- **Thinking content still spoken** — root cause identified: Qwen3 emits `<think>` as a **special token** that mlx-swift-lm decodes to empty string, so `ThinkTagStripper` never sees it and `insideThink` is never set. `</think>` IS emitted as literal text. The v0.8.55 system-prompt directive ("Thinking mode: DISABLED") caused the model to output reasoning as plain text with no tags, making it unfilterable. Fix: removed the backfiring system-prompt directive; added `thinkEndSeen` logic in `PipelineCoordinator.generateWithTools()` that buffers all tokens until `</think>` is seen (or a 5K-char safety timeout), discards the think block, and only then routes tokens to TTS.
- **Think content polluting conversation history** — `fullResponse` (containing all think reasoning) was stored via `conversationState.addAssistantMessage()`, corrupting the context for recursive tool calls (e.g. calendar tool result never spoken). Fixed with `stripThinkContent()` applied before storing to history.
- **Voice enrollment buttons non-functional** — Settings > Speaker "Enroll Now" and "Re-enroll" buttons set `showEnrollmentSheet = true` but no `.sheet()` modifier existed in the view — the sheet never appeared. Fixed: buttons now send `speaker.start_enrollment` command to `FaeCore`, which triggers `runVoiceEnrollmentFlow()` with the current pipeline coordinator.

## [v0.8.55] - 2026-03-01

### Fixed

- **Thinking content spoken aloud** — removed `/no_think` text injection from user messages entirely. mlx-swift-lm has no chat-template-level `enable_thinking` support, so injecting `/no_think` as literal user text caused the model to reason about the string conversationally (no `<think>` wrapper, so `ThinkTagStripper` couldn't catch it), output visible reasoning as plain text, and break tool calls. Thinking suppression now moves to the system prompt via `PersonalityManager.assemblePrompt(suppressThinking:)`.
- **Tool use broken** — same root cause as above. With `/no_think` polluting user messages the model responded with reasoning text instead of `<tool_call>` markup. Fixed by the same change.
- **Voice XML tags spoken literally in normal chat** — `PersonalityManager.roleplayPrompt` instructed the LLM to use `<voice character="Anchor">` tags for news without starting a roleplay session. Since `VoiceTagStripper` only runs when `roleplayActive`, the tags passed through to TTS as raw markup. Fixed: instruction now requires a roleplay session even for news. Added `<voice ...>` tag stripping in `TextProcessing.stripNonSpeechChars` as a safety net.

## [v0.8.54] - 2026-03-01

### Fixed

- **Appcast validation** — release workflow now validates `appcast.xml` before uploading: parses as XML, extracts `sparkle:edSignature` via the XML parser, and asserts it is non-empty, space-free, and valid base64. Prevents the `sign_update` output-embedding bug from shipping a broken update feed to users.

## [v0.8.53] - 2026-03-01

### Added

- **Debug Console** — floating `NSPanel` (Cmd+Shift+L) showing real-time pipeline internals: raw STT transcriptions, LLM tokens, speaker scores, tool calls/results, and memory recall. Color-coded by event kind; auto-scroll, Clear, and Copy All buttons.
- **Thinking mode toggle** — `FaeConfig.llm.thinkingEnabled` (default: off) controls whether Qwen3's `/no_think` directive is appended. Togglable in Settings > Models.

### Fixed

- **Enrollment canvas overwrite** — `transitionToReadyCanvas()` no longer fires while the enrollment card is visible. An `enrollmentModeActive` guard prevents the canvas from being replaced by the ready state during the voice enrollment flow.
- **Enrollment intro shortened** — replaced the 3-sentence verbose intro (which could confuse the echo suppressor) with a brief 2-sentence version: *"Hi, I'm Fae. Please read the phrase on the canvas aloud to register your voice."*
- **Dark halo around collapsed orb** — `window.hasShadow` is now disabled in collapsed (120×120) mode to remove the dark circle that appeared around the circular orb; shadow is restored when expanding to compact mode.

## [v0.8.52] - 2026-02-28

### Fixed

- **App Sandbox removed from release build** — the sandbox (`com.apple.security.app-sandbox = true`) was blocking MLX/Metal GPU allocations, causing crashes during model loading. The sandbox also isolated the HuggingFace model cache to `~/Library/Containers/com.saorsalabs.fae/Data/Library/Caches/huggingface/hub/` instead of the shared `~/.cache/huggingface/hub/`, causing models to be re-downloaded on first run even if already present. Fae is a Developer ID app (not App Store) and its tool system requires unrestricted file access — the sandbox was incorrect here.

## [v0.8.3] - 2026-02-28

### Added

- **Memory v2 — neural embeddings, ANN search, knowledge graph** — `NeuralEmbeddingEngine` with tiered Qwen3-Embedding (8B / 4B / 0.6B / hash-384 fallback); sqlite-vec `vec0` virtual tables (`memory_vec`, `fact_vec`) for ANN recall; hybrid 60% ANN + 40% FTS5 lexical scoring.
- **Entity graph** — typed entity store (persons, organisations, locations, skills, projects, concepts) with bidirectional relationships, temporal facts, and `EntityLinker` auto-extraction of `works_at` / `lives_in` edges.
- **PersonQueryDetector** — graph queries like "who works at X?" or "who lives in X?" routed through the entity store.
- **EmbeddingBackfillRunner** — background paged backfill of all existing memory records into the ANN index after a model upgrade.
- **Speaker identity (ECAPA-TDNN)** — `CoreMLSpeakerEncoder` runs the ECAPA-TDNN speaker model on the Neural Engine, producing 1024-dim x-vectors for speaker verification. First-launch auto-enrollment, progressive profile averaging (up to 50 embeddings), owner gating.
- **Multi-voice roleplay** — `RoleplayTool` manages character voice sessions; `VoiceTagStripper` extracts `<voice character="Name">` tags from the token stream; each character routes to TTS with its own voice description.
- **Conversation streaming** — per-token live bubble with blinking cursor in the conversation panel; replaces the three-dot typing indicator.
- **Canvas activity feed** — glassmorphic tool-call cards with live spinner → checkmark transitions; archived turn history with collapsible summaries.
- **Stop button** — prominent stop control in the input bar (replaces send while generating) + Cmd+. menu item.
- **Global hotkey** — `GlobalHotkeyManager` registers Ctrl+Shift+A system-wide to summon Fae from any app (requires Accessibility permission).
- **Input-required flow** — `input_request` tool lets the LLM ask for credentials; the input bar transforms into a secure-field prompt with purple border.
- **Message box expansion** — input window grows with text (up to 700pt), orb stays untouched.
- **Orb enchantment** — sparkle intensity, tremor, liquid flow, and radius bias shader params; strongly differentiated presets per `OrbFeeling` (curiosity sparkles, concern tremor, delight bounce).
- **Settings Personality tab** — soul contract editor, custom instructions editor, rescue mode toggle.
- **`input_request` tool** — LLM can request user input (text or password) without failing silently on missing credentials.
- **JIT Apple tool permissions** — when an Apple tool call lacks a macOS permission, the permission request fires automatically and the tool retries on grant.
- **Python skills** — `SkillManager`, `run_skill` tool, `SkillImportView`; skills run via `uv run --script` with PEP 723 inline metadata.
- **`self_config` tool** — Fae can persist personality preferences (`custom_instructions.txt`) across sessions.

### Changed

- **Pure Swift migration** — MLX-based STT / LLM / TTS engines; no Rust core, no `libfae.a`.
- **Unified pipeline** — single `PipelineCoordinator` with inline `<tool_call>` markup; no separate intent classifier or agent loop.
- **Tool security (4-layer)** — schema filtering, execution guard, `PathPolicy` write-path blocklist, per-tool rate limiting.
- **`SelfConfigTool`** — requires approval, jailbreak pattern detection, 2000-char limit.
- **`BashTool`** — process-group kill on timeout, stderr filtered from LLM.
- **Approval timeout** — reduced from 58s to 20s.
- **Canvas** — replaced Star Wars crawl with native SwiftUI glassmorphic activity feed.

### Fixed

- **GRDB/SQLiteVec module conflict** — replaced upstream `SQLiteVec` SPM dep with local `CSQLiteVecCore` C target to eliminate the GRDB ambiguity error.
- **CI build** — switched from `xcodebuild` to `swift build` for the main CI job; `FaeBenchmark` entry-point corrected.

## [v0.7.4] - 2026-02-25

### Fixed

- **JIT permission timeout mismatch** — Tool-side `JIT_TIMEOUT` was 1200ms while the handler polled for up to 60s. JIT permission grants could never succeed because the tool returned "timed out" to the LLM long before the user saw the dialog. Both sides now use 20 seconds: `JIT_TIMEOUT` in `availability_gate.rs` and `JIT_HANDLER_TIMEOUT_SECS` in `handler.rs`.

## [v0.7.3] - 2026-02-25

### Added

- **Scheduled task execution via embedded LLM** — `execute_scheduled_conversation()` is now fully implemented. When a user-created scheduled task fires, it runs a background agent against the embedded Qwen3 model and speaks the result. Previously a stub.
- **`start_scheduler_with_llm()`** — new startup function wires the loaded `LocalLlm` into the scheduler so background agents can run without an external API.
- **`select_tool_allowlist_for_prompt()`** — tool routing for scheduled tasks excludes scheduler management tools (prevents recursive task creation); defaults to `web_search + fetch_url` when no intent is detected.
- **`GateCommand::Engage`** — new gate command resets the follow-up engagement window on demand. Prevents long Fae responses from consuming the user's 30-second reply window.
- **`conversation.engage` host command** — Swift can now send `conversation.engage` to refresh the follow-up window after the user interacts (e.g. clicks the orb to expand).
- **Pending transcription buffer** (`ConversationBridgeController`) — user speech is held until the coordinator confirms it routed to the LLM (`AssistantGenerating { active: true }`), preventing ghost bubbles for noise-dropped segments.
- **`SettingsSchedulesTab`** — new Settings tab showing all scheduled tasks (built-in and user-created) with next/last run times, failure streaks, manual trigger, and swipe-to-delete for user tasks.
- **In-place orb collapse** (`WindowStateController`) — when the canvas opens, the orb collapses at its current position rather than jumping to a corner; frame is saved and restored when canvas closes.
- **Input field auto-focus** — conversation input bar receives focus automatically after the window expands.
- **Expanded scheduler intent keywords** — 56 natural-speech patterns now trigger scheduler routing (up from 9), catching phrases like "tell me daily", "notify me every morning", "check for me each week".

### Changed

- **Reasoning level tuning** — background agents default to `Low` reasoning for multi-tool tasks; `Medium` only for explicitly analytical queries. Prevents 100+ second thinking loops on simple tool calls (e.g. "list reminders").
- **Background task fallback** — if streamed and final text are both empty, the agent synthesises "Done." so the coordinator always has something to speak.
- **`ApprovalTool` blocking** — uses `tokio::task::block_in_place()` with a dedicated response-wait thread to prevent tokio worker starvation when waiting for user approval.
- **Executor async semantics** — `executor_bridge.rs` now detects existing tokio runtimes and spawns a dedicated wait thread (`handle.block_on()`) instead of creating a nested runtime (fixes "Cannot start a runtime from within a runtime" panic).
- **`TaskExecutor` type** — changed from `Box<dyn Fn>` to `Arc<dyn Fn>` for shared ownership across scheduler and executor.
- **Scheduler persists across model reloads** — scheduler is started once per runtime session; subsequent pipeline restarts (model reload) skip re-starting the scheduler.
- **`AssistantGenerating` on background task complete** — coordinator now emits `active: false` when a background agent finishes, keeping the orb state correct.
- **Ack bubbles in conversation panel** — acknowledgment phrases (e.g. "on it") now appear as assistant messages in the conversation view.
- **Channels tab simplified** — `SettingsChannelsTab` replaced detailed credential forms with a skills-first approach: master kill switch, per-channel summary, and disconnect buttons.
- **`max_tokens` 128 → 512** — allows longer responses.
- **TTS speed 1.0 → 1.1** — slightly faster speech cadence.
- **SOUL.md rewritten** — character described as warm, upbeat, and playful rather than calm and restrained; sections restructured for clarity.
- **Opening style** — one-word/short greeting rule: if user says hi/hello/hey, respond with a single short phrase only (e.g. "hey!", "what's up?").
- **`create_scheduled_task` guidance** — system prompt now documents how to write self-contained task prompts with the correct JSON payload format.

### Fixed

- **Tokio-within-runtime panic** — `executor_bridge.rs` and `ApprovalTool` no longer call `Runtime::new().block_on()` from inside a tokio worker thread.
- **Follow-up window starvation** — `GateCommand::Engage` resets `engaged_until` after Fae finishes speaking, giving the user a fresh 30-second reply window even after long responses.
- **Partial streamed text lost on interruption** — `ConversationBridgeController` commits any partial assistant text when barge-in occurs, so interrupted responses appear in the conversation panel.
- **`withAnimation` return value warning** in `SettingsSchedulesTab` (Swift compiler warning resolved).

## [v0.7.1] - 2026-02-24

### Added

- **AppleScript Apple integration** — new `applescript.rs` implements all five Apple ecosystem stores (Contacts, Calendar, Reminders, Notes, Mail) via `osascript`/JXA with no Objective-C bindings required. Works under App Sandbox with appropriate entitlements.
- **Live skill health checks** — `run_skill_health_check()` now issues real JSON-RPC pings to skill subprocesses instead of checking process liveness only. Detects unresponsive skills before they fail in conversation.
- **JIT permission channel** — Just-in-time macOS permission requests are now wired through the coordinator → handler → Swift event pipeline, giving users a native prompt at first use rather than at launch.
- **`SkillProposalStore`** — skill opportunity analysis integrated into morning briefings and the `skill_proposals` scheduler task.
- **Qwen3-8B preset** — new `Qwen3_8b` forced preset for systems with ≥48 GiB RAM; auto-mode now selects 8B at ≥48 GiB.
- **`AgentChannels` struct** — spawn API refactored from positional arguments into a typed struct, eliminating a class of argument-order bugs.

### Changed

- **Intent keyword refinement** — tool-routing keyword sets tuned to reduce false positives (e.g. canvas/vision queries no longer misrouted to bash).
- **`OnceLock`-backed store registry** — Apple ecosystem store instances are now registered once at handler startup via `register_apple_stores()`, replacing per-call construction.
- **CI/release workflows** — `--features metal` added to all macOS build steps; ensures GPU-accelerated inference is included in release binaries.
- **Warm thinking tone** — A3→C4 ascending two-note tone replaces the flat sine burst; volume and fade tuned for natural feel.
- **Orb breath dynamics** — idle orb now breathes with subtle amplitude variation.

### Removed

- `src/agent/approval_tool.rs` — `ApprovalTool` inlined into `src/agent/mod.rs` to reduce indirection.

## [v0.7.0] - 2026-02-20

### Added

- **Vision Model Support (Qwen3-VL)** — Fae now uses Qwen3-VL vision-language models instead of text-only Qwen3-4B. Models are selected automatically based on system RAM:
  - 24 GiB+ RAM: Qwen3-VL-8B-Instruct (stronger tool calling, coding, GUI understanding)
  - < 24 GiB RAM: Qwen3-VL-4B-Instruct (same vision capabilities, lighter footprint)
- **VisionModelBuilder integration** — uses `mistralrs` VisionModelBuilder with ISQ Q4K quantization for efficient inference. Falls back to Qwen3-4B GGUF text-only if vision model fails to load.
- **HistoryEntry enum** — conversation history now supports both text and image captures, enabling future camera-to-LLM pipelines.
- **Conditional vision prompt** — vision understanding instructions are injected into the system prompt only when the loaded model is vision-capable, preventing false claims about image understanding.
- **Vision-aware download accounting** — preflight disk space checks now estimate vision model download sizes (8-16 GB) with HF cache detection.

### Changed

- **RAM-based model selection** — `LlmConfig::default()` detects system memory and selects the appropriate model automatically. User-customized model IDs are never overwritten.
- **CameraSkill prompt** — updated to reflect genuine vision capabilities when available.
- **VisionMessages replaces TextMessages** — LLM inference uses `VisionMessages` which handles both text-only and image-carrying turns.

### Removed

- `src/model_picker.rs` — dead code, never called from any code path.
- `src/model_selection.rs` — dead code, replaced by embedded-only model policy.

## [v0.5.0] - 2026-02-17

### Changed

- **Always-On Companion Mode** — Fae now starts listening immediately. The wake word system (MFCC+DTW keyword spotter) has been completely removed. The conversation gate starts in Active state; no wake word is needed. Sleep phrases and the stop/start listening button are preserved.
- **Faster Response Times** — VAD silence detection reduced from 2200ms to 1000ms, barge-in silence reduced from 1200ms to 800ms. This saves ~1.2 seconds per conversational turn.

### Added

- **Real-Time Tool Feedback** — when Fae uses tools, she now shows live progress in the canvas (tool name + "running..." indicator). Tool events are emitted as they happen instead of in a batch after completion. The canvas auto-opens for all tool calls.
- **ToolExecuting runtime event** — new `RuntimeEvent::ToolExecuting` variant for live tool progress indication.

### Fixed

- **Canvas Blank Messages** — whitespace-only assistant text, empty tool names, and empty chunk text no longer produce blank canvas messages. Guards added at multiple levels (chunk acceptance, flush, push, push_tool).

### Removed

- `src/wakeword.rs` — MFCC+DTW wake word spotter module (632 lines).
- `src/bin/record_wakeword.rs` — wake word recording utility binary.
- `WakewordDetected` event variant from the pipeline.

## [v0.4.1] - 2026-02-17

### Fixed

- **macOS Self-Update: Staged Download + Relaunch Helper** — replaces in-place binary replacement with a Sparkle-style staged update flow that works reliably on macOS.
  - New `StagedUpdate` state persisted across sessions
  - Background download to staging directory (`~/Library/Application Support/fae/staged-update/`)
  - Detached shell helper script waits for app exit, replaces binary, removes quarantine, relaunches
  - Automatic cleanup of staging files on next successful startup
  - Banner text updates: "Fae vX.Y.Z ready — Relaunch to install" when staged
  - Falls back to legacy inline download if staging was skipped
- Filter empty strings from sleep phrase list in conversation config
- Block path-traversal attacks in zip import (diagnostics)

## [v0.4.0] - 2026-02-16

### Added

- **Proactive Intelligence System** — Fae now extracts actionable intelligence (dates, people, interests, commitments) from every conversation and acts on them autonomously.
  - Intelligence extraction engine with LLM-based conversation mining
  - Noise controller with daily budget, cooldown, deduplication, and quiet hours
  - Intelligence store wrapping memory repository for typed queries
- **Morning Briefings** — say "good morning" or "what's new" and Fae delivers a summary of upcoming events, stale relationships, and research she's done.
  - Priority-ranked briefing items (Urgent, High, Normal, Low)
  - Greeting detection triggers briefing context injection
- **Relationship Tracking** — Fae remembers people you mention, tracks last contact, and gently surfaces stale relationships.
  - Automatic relationship upsert from conversation mentions
  - Stale relationship detection (30-day threshold)
- **Background Research** — when Fae detects your interests, she researches topics and prepares summaries.
  - Research task creation with daily budget (default 3)
  - Freshness-aware deduplication (7-day default)
- **Adaptive Skill Proposals** — Fae proposes new skills when she detects patterns (frequent calendar mentions, email discussions, etc).
  - Skill proposal lifecycle: Proposed → Accepted/Rejected → Installed
  - 30-day rejection cooldown to avoid nagging
- **Companion Presence Mode** — always-listening mode where Fae decides when to speak based on conversation context.
  - Sleep/wake detection with multi-phrase matching
  - Conversation gate with ambient noise filtering
- **Cross-Platform Desktop Automation** — Fae can manage applications, files, and system settings on your computer.
  - Tool modes: off, read_only, read_write, full, full_no_approval
- **New Scheduler Tasks** — noise budget reset, stale relationships check, morning briefing, skill proposals.
- **Proactivity Controls** — Off, Digest Only, Gentle (default), Active levels with quiet hours and daily budgets.
- **SOUL.md** updated with proactive intelligence behavioral principles.
- **System prompt** updated with proactive intelligence instructions.

## [v0.3.8] - 2026-02-16

### Added

- Cross-platform desktop automation tool
- Companion presence mode (phases 1.1-1.4)
- Sleep/wake phrase detection
- Conversation gate for ambient filtering

## [v0.3.7] - 2026-02-15

### Changed

- Stream LLM clauses to TTS during generation with parallel visemes
- Flush VAD buffer on echo suppression transition
- Add 15s duration cap for audio segments
