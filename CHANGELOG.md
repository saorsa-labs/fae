# Changelog

All notable changes to this project will be documented in this file.

## [v0.8.102] - 2026-03-14

### Changed

- **Local model ladder refreshed for manual testing**:
  - the app now treats `Qwen3.5 27B` as the highest advertised local quality tier
  - the legacy `Qwen3.5-35B-A3B` preset now resolves to `Qwen3.5 27B`
  - `Auto` remains the standard Swift-native `2B` / `4B` / `9B` path
- **PARO benchmark tooling generalized**:
  - PARO comparison scripts now emit size-aware artifact names instead of hardcoded `9B` filenames
  - benchmark result set now includes `2B`, `4B`, `9B`, and `27B` MLX-vs-PARO baselines

### Documented

- **Swift runtime boundary for PARO**:
  - external PARO baselines are now documented as promising for `9B` and `27B`
  - the app docs and release checklists now make clear that Fae's current `mlx-swift-lm` runtime cannot load PARO checkpoints yet, so PARO remains benchmark-only for now

### Cleaned

- Removed stale local training outputs, PARO cache snapshots, duplicate benchmark artifacts, and Python cache directories to recover disk space before manual testing.

## [v0.8.74] - 2026-03-03

### Added

- **Canonical voice lock runtime surfacing** completed end-to-end:
  - `tts.voice_identity_lock` exposed in config patch/get contract.
  - Runtime voice provenance fields surfaced in `config.get("tts")`:
    `runtime_voice_source`, `runtime_voice_lock_applied`.
  - Settings > Models now hydrates and displays canonical/custom/default runtime voice source state.
- **Unified capability snapshot service** (`CapabilitySnapshotService`) shared by pipeline + settings + canvas.
- **Expanded governance voice commands** for high-value runtime controls:
  - thinking mode, barge-in, direct-address policy, vision toggle, voice identity lock,
  - JIT permission requests (camera, screen recording, microphone, contacts, calendar, reminders, accessibility).
- **Governance routing tests and parser tests** for the new voice/canvas control paths.

### Changed

- **Interactive governance canvas** now includes:
  - tool mode chips,
  - behavior chips (thinking/barge-in/direct-address/vision/voice-lock),
  - missing-permission grant chips.
- **Governance mutation bridge** now routes generic `set_setting`, `request_permission`, `open_settings`, and `start_owner_enrollment` actions through `.faeGovernanceActionRequested`.
- **High-risk governance handling** tightened:
  - voice confirmation flow generalized for risky settings,
  - canvas high-risk actions require explicit confirmation dialog.
- **Tool effectiveness UX hardening**:
  - when tools are hidden/blocked or a tool-backed lookup fails to execute tools, canvas now shows actionable fix cards instead of silent fallback.
- **Input orchestration** upgraded with form-field validation metadata (min/max/regex/allowed values/https constraints) and optional secure keychain persistence for `input_request`.

### Improved

- **Voice command observability**:
  - per-command trace log with handled flag + latency,
  - local counters for governance and voice command flows.
- **Degraded mode surfacing**:
  - degraded-mode changes emitted onto pipeline event bus and reflected in pipeline status UI.
- **FaeApp enrollment wait warning fix**:
  - removed non-Sendable observer capture pattern in onboarding enrollment wait path.

## [v0.8.73] - 2026-03-03

### Added

- **Voice governance commands** for auxiliary UX and authority controls:
  - "show/open discussions", "hide/close discussions"
  - "show/open canvas", "hide/close canvas"
  - "open settings"
  - "show tools and permissions" (renders a live governance snapshot on canvas)
- **Unified ToolPermissionSnapshot model** (`Core/ToolPermissionSnapshot.swift`) shared by pipeline canvas rendering and Settings > Tools diagnostics.
- **Canvas quick actions for tool mode** (Off / Read Only / Read/Write / Full / Full No Approval) via `fae-action://` links routed through the governed command path.
- **Governance action bridge**: new `.faeGovernanceActionRequested` notification routed by `HostCommandBridge` into `config.patch` for a single mutation pathway.

### Changed

- **Voice authority flow for tool mode changes**: direct voice command parsing now supports tool mode changes and requires explicit yes/no confirmation for `full_no_approval`.
- **Pipeline event surface expanded** with native events for `canvas_content`, `canvas_visibility`, `conversation_visibility`, and `voice_command` from `FaeEventBus`.
- **Self-config parity**: `self_config adjust_setting` now supports `tool_mode` in addition to prior speech/thinking/vision settings.

### Improved

- **Settings > Tools snapshot panel** now shows allowed/blocked tool counts for the active mode and points users to the voice-first governance flow.
- **Governance logging**: bridge-level logs now capture tool-mode mutations and source metadata (`voice`, `canvas`, etc.) for easier manual audit.

## [v0.8.72] - 2026-03-02

### Added

- **Vision + Computer Use** — Fae can now see the screen and interact with apps, all on-device via Qwen3-VL (MLXVLM).
  - **MLXVLMEngine**: on-demand VLM inference actor using `VLMModelFactory` from mlx-swift-lm's MLXVLM module. RAM-tiered model selection: 48+ GB → Qwen3-VL-8B (8-bit), 24-47 GB → Qwen3-VL-4B (4-bit), <24 GB → disabled. VLM loads only when vision tools fire — not at startup.
  - **7 new tools**: `screenshot` (screen capture via ScreenCaptureKit → VLM description), `camera` (webcam via AVCaptureSession → VLM description), `read_screen` (screenshot + Accessibility tree → numbered element list), `click` (AXUIElement press or CGEvent mouse), `type_text` (AXUIElement setValue or CGEvent keystrokes), `scroll` (CGEvent scroll wheel), `find_element` (Accessibility tree search with fuzzy matching).
  - **AccessibilityBridge**: macOS Accessibility API wrapper for querying UI elements, pressing buttons, setting text field values, and recursive tree search. Depth limit 15, max 500 elements.
  - **Computer use step limiter**: max 10 action steps (click/type_text/scroll) per conversation turn to prevent runaway automation.
  - **VisionConfig**: `[vision]` section in config.toml with `enabled` and `modelPreset` fields. Enable via Settings > Models or `self_config(adjust_setting, vision.enabled, true)`.
  - **Settings UI**: Vision section in Models tab with enable toggle, model picker (Auto/8-bit/4-bit), and permission status badges (Screen Recording, Camera, Accessibility).
  - **JIT permissions**: Screen Recording (`CGRequestScreenCaptureAccess()` with polling) and Camera (`AVCaptureDevice.requestAccess(for: .video)`) added to `JitPermissionController`.
  - **TrustedActionBroker policies**: all 7 vision/computer use tools added to `explicitRuleTools`; screenshot, camera, and scroll added to `highImpactMediumTools` for confirmation when intent is ambiguous.
  - **Personality prompts**: expanded `visionPrompt` and new `computerUsePrompt` wired into system prompt assembly when vision is enabled.
  - **PermissionStatusProvider**: Screen Recording and Camera permission tracking added to status snapshot.

## [v0.8.70] - 2026-03-02

### Added

- **Qwen3.5 full model lineup** — granular RAM tiers using the complete Qwen3.5 family (0.8B/2B/4B/9B/27B/35B-A3B), providing Qwen3.5 quality at every RAM tier from 8 GB MacBook Air to 192+ GB Mac Studio.
  - 24-31 GB: **9B@32K** (was 27B@8K) — comfortable context with smaller model
  - 16-23 GB: **4B@16K** (was 27B@4K) — no more memory pressure
  - 12-15 GB: **2B@8K** — new tier for entry-level machines
  - 8-11 GB: **0.8B@4K** — replaces Qwen3-1.7B with Qwen3.5 quality
  - <8 GB: **0.8B@2K** — new minimum viable tier
- **4 new manual presets** — `qwen3_5_9b`, `qwen3_5_4b`, `qwen3_5_2b`, `qwen3_5_0_8b` in config.toml
- **Settings UI updated** — model picker shows all Qwen3.5 options with accurate RAM requirements

### Improved

- **STT/TTS on lower-RAM machines** — threshold lowered from 32 GB to 16 GB, giving 16-31 GB machines the full 1.7B STT/TTS stack (was 0.6B)
- **maxTokens safety cap** — generation budget now capped at `contextSize / 2` to prevent tiny context tiers (2K/4K) from having maxTokens larger than context

## [v0.8.69] - 2026-03-02

### Added

- **Conversational self-configuration** — Fae can now adjust her own behavior settings through natural conversation. "Speak faster", "be more creative", "think step by step" all work via the `self_config` tool's new `adjust_setting` action. Settings are bidirectional: changes made conversationally appear in the Settings UI and vice versa.
  - 8 adjustable settings: `tts.speed`, `tts.warmth`, `tts.emotional_prosody`, `llm.temperature`, `llm.thinking_enabled`, `barge_in.enabled`, `conversation.require_direct_address`, `conversation.direct_address_followup_s`
  - `get_settings` action returns all current values with human-readable descriptions
  - Type-safe validation with range enforcement (e.g., speed must be 0.8–1.4)
  - Changes route through the same `patchConfig` pathway as the Settings UI — fully bidirectional
  - New `patchConfig` handlers for `llm.temperature`, `conversation.require_direct_address`, and `conversation.direct_address_followup_s`

### Improved

- **Self-modification prompt clarity** — rewritten to clearly distinguish `adjust_setting` (live behavior changes) from directive actions (standing orders). Removed stale `set_instructions`/`append_instructions` references.

## [v0.8.68] - 2026-03-02

### Fixed

- **Tool gating false-blocks on unrecognized voice** — when speaker verification failed (encoder not loaded, no match above threshold), `currentSpeakerIsOwner` defaulted to `false` which caused `requireOwnerForTools` to hide ALL tool schemas from the LLM. Fae would say "I'll look into it" but never emit `<tool_call>` markup because she literally couldn't see any tools. Fixed by distinguishing "unknown speaker" (no match — tools allowed, physical access is trusted) from "known non-owner" (positively matched as a different person — tools blocked). Text input continues to always trust tools.
- **Onboarding waits for voice enrollment** — `completeOnboarding()` no longer fires on a 4-second timer regardless of enrollment state. Now waits up to 120s for the `pipeline.enrollment_complete` notification (owner voiceprint registered) before marking onboarding as done. If enrollment was already complete or times out, proceeds anyway.
- **Config migration for maxTokens** — enforces minimum `maxTokens=2048` at startup. Early configs persisted `maxTokens=512` which was too low for the LLM to emit speech + `<tool_call>` JSON. Migration detects the legacy value, bumps to 4096, and saves back to config.toml. Fixes tool calls never firing on existing installations.
- **TTS text normalization** — improved `stripNonSpeechChars()` to handle punctuation edge cases that confused Qwen3-TTS:
  - Ellipsis (`…` and `...`) → single period
  - Em-dash/en-dash (`—`/`–`) → comma (natural pause)
  - Repeated punctuation (`!!`, `,,`) → single character
  - Smart quotes → removed or converted to apostrophe
  - Parentheses and asterisks stripped
  - Prevents garbled pronunciation from stacked punctuation

### Improved

- **Comprehensive debug console logging** — added diagnostic events throughout the pipeline for live debugging:
  - Speaker identity: match result, similarity score, owner status, or why verification was skipped
  - Tool gating: explicit log when tools are hidden from LLM, with reason (mode=off, owner not verified)
  - Tool schema count and size in chars
  - Context budget: system prompt token estimate, context window size, maxTokens
  - LLM warnings: 0-token generation, low throughput (<2 t/s) indicating memory pressure
  - LLM errors now routed to debug console (were NSLog-only)
  - TTS: text chunks being synthesized (first 80 chars), final flag, not-loaded warning

## [v0.8.67] - 2026-03-02

### Fixed

- **Conversation reset trigger + sleep gate** — saying "that will do Fae" (and apostrophe/spacing variants) now performs a hard conversation reset in both voice and text input paths. Fae clears turn history/system-prompt cache, sleeps, and ignores follow-up input until directly addressed again.
- **Drift from false name capture** — memory name extraction no longer treats generic "I'm ..." phrases as identity updates. Added stricter name validation to prevent spurious profile rewrites.
- **Tool mode semantics** — `off` now truly disables all tools. `read_only` no longer allows executable `run_skill`.
- **Settings write-through gaps** — wired missing `config.patch` handlers for `tts.speed`, `tts.emotional_prosody`, `tts.warmth`, `tts.custom_voice_path`, and `tts.custom_reference_text`.
- **Settings hydration gap** — added `config.get("tts")` response payload so the Models tab reflects persisted TTS settings correctly.

### Improved

- **Live settings application** — tool mode and TTS playback speed now update in the running pipeline without requiring restart.
- **Context stability under long sessions** — tool result payloads are now bounded before entering conversation history, and reserved-token budgeting is recalculated dynamically from the real assembled system prompt size each turn.
- **Context budget honoring user cap** — runtime context budget now respects the configured `llm.contextSizeTokens` cap while still using model-tier recommendations as an upper bound.
- **Tool mode regression tests updated** — test suite now enforces true-off mode behavior and read-only execution restrictions.

## [v0.8.66] - 2026-03-02

### Fixed

- **LLM max tokens too low for tool calls** — default `maxTokens` was 512, which caused the model to hit the token limit before it could emit `<tool_call>` markup. The LLM would say "Let me search for..." but run out of tokens before producing the actual tool call JSON. Increased default to 2048, which gives the model enough room for thinking + speech + tool call markup.

### Improved

- **Debug console logging** — added pipeline-level events to the debug console for better diagnostics:
  - LLM generation start (maxTokens, history count, turn number)
  - LLM generation complete (token count, elapsed time, throughput)
  - Tool call detection (count and names)
  - Echo suppression events (audio-level and text-overlap with details)

## [v0.8.65] - 2026-03-01

### Fixed

- **Turn-transition TTS deadlock** — after the first successful turn, all subsequent turns produced zero LLM output because `pendingTTSTask` from the previous turn was never cancelled. When a new user utterance interrupted the assistant, `processTranscription` set `interrupted = true` but left stale TTS tasks in the queue. The new turn reset `interrupted = false`, causing old tasks to resume and block the pipeline. Now cancels `pendingTTSTask` both in the interruption path and at the start of each new generation turn.

## [v0.8.64] - 2026-03-01

### Fixed

- **Non-blocking TTS streaming** — TTS synthesis no longer blocks the LLM token stream. Previously, `await speakText()` inside the token generation loop caused 3-5 second gaps between spoken sentences while TTS synthesized each one. Now uses a chained `enqueueTTS()` task queue that runs TTS concurrently with continued LLM token generation, eliminating inter-sentence pauses.
- **TTS text normalization** — enhanced `stripNonSpeechChars()` to clean up text that was confusing the TTS model and causing garbled/drunk-sounding speech:
  - Strip ALL XML-style tags (not just voice/think) — catches any leaked markup
  - Remove markdown heading markers (`# `, `## `, etc.)
  - Remove markdown list markers (`- `, `* `, `1. `, etc.)
  - Remove bare URLs (they sound terrible when spoken)
  - Remove square brackets (markdown link remnants)
  - Collapse all whitespace (spaces, tabs, newlines) into single spaces

## [v0.8.63] - 2026-03-01

### Added

- **Skills v2 — Agent Skills standard** — directory-based skill system following the [Agent Skills](https://agentskills.io/specification) open standard. Skills are directories with `SKILL.md` (YAML frontmatter + markdown body) and optional `scripts/` for Python executables. Three tiers: built-in (app bundle), personal (user directory), community (imported). Progressive disclosure: system prompt shows only names + descriptions (~50-100 tokens each); full body loaded on activation.
  - `SkillTypes.swift` — `SkillMetadata`, `SkillRecord`, `SkillType` (.instruction/.executable), `SkillTier`, `SkillHealthStatus`
  - `SkillParser.swift` — YAML frontmatter parser with validation
  - `SkillMigrator.swift` — one-time migration of legacy flat `.py` files to directory format
  - `SkillTools.swift` — `ActivateSkillTool` (low risk), `RunSkillTool` (medium, multi-script support), `ManageSkillTool` (high, create/delete/list)
- **Built-in voice-tools skill** — migrated 4 Python scripts from `SkillTemplates/` to `Resources/Skills/voice-tools/` with proper `SKILL.md` frontmatter: `audio_normalize`, `prepare_voice_sample`, `voice_compare`, `voice_quality_check`.
- **Git Vault — rolling backup** — `GitVaultManager` actor backs up all Fae data (SQLite databases, config, directive, soul, speakers, skills) to `~/.fae-vault/` using system git. Survives app deletion. Daily 02:30 scheduled backup, config-change triggers, pre-shutdown snapshot. `PathPolicy` blocks LLM writes to vault directory.
- **SkillsConfig** — new `[skills]` config section with `promptBudgetTokens` and `disabledBuiltins` settings.
- **TrustedActionBroker — default-deny policy chokepoint** — every tool call routes through a central broker that evaluates `ActionIntent` → `BrokerDecision` (allow/allowWithTransform/confirm/deny). 22 explicitly modeled tools. Three `PolicyProfile` modes: balanced (default), moreAutonomous, moreCautious. Configurable via Settings > Tools.
- **CapabilityTicket** — task-scoped temporary grants with TTL. Tools must hold a valid ticket to pass the broker. Issued per conversation turn, expires automatically.
- **ReversibilityEngine** — pre-mutation file checkpoints in `~/Library/.../fae/recovery/`. `allowWithTransform(.checkpointBeforeMutation)` creates a snapshot before writes; supports rollback and automatic 24h pruning.
- **SafeBashExecutor** — denylist of 8 dangerous patterns (`rm -rf /`, `chmod 777`, etc.); minimal constrained environment; process-group SIGTERM/SIGKILL on timeout.
- **SafeSkillExecutor** — ulimit constraints (CPU, memory 1GB, 64 file descriptors); restricted working directory to skill's `scripts/` directory.
- **NetworkTargetPolicy** — shared policy blocking localhost, cloud metadata endpoints, all RFC1918/loopback/link-local IPv4+IPv6. Replaces per-tool inline checks.
- **OutboundExfiltrationGuard** — novel recipient confirmation using SHA256 hash set (persisted JSON). Sensitive payload detection via keyword matching + high-entropy heuristic.
- **SecurityEventLogger** — append-only JSONL at `.../fae/security-events.jsonl`. SHA256 argument hashing. 5MB rotation with 3 archives. Forensic mode toggle. Redaction via `SensitiveDataRedactor`.
- **SensitiveDataRedactor** — regex-based redaction for API keys, tokens, passwords (OpenAI sk-, Slack xox, GitHub ghp_, Google AIza). Length/entropy heuristic for opaque tokens.
- **SkillManifest** — `MANIFEST.json` schema with capabilities, allowedTools, allowedDomains, riskTier, and SHA-256 per-file integrity checksums for tamper detection.
- **Security dashboard** — Developer tab (Option-held) shows live allow/confirm/deny stats from `SecurityEventLogger`.
- **PolicyProfile picker** — Settings > Tools includes profile selector (balanced/moreAutonomous/moreCautious).

### Changed

- **Directive rename** — `custom_instructions.txt` renamed to `directive.md` across the codebase. Auto-migration on startup. `SelfConfigTool` actions renamed to `get_directive`/`set_directive`/`append_directive`/`clear_directive` with legacy aliases preserved. Prompt label updated to "User directive (critical instructions)". Settings UI updated with clearer helper text.
- **SkillManager rewrite** — now supports directory-based discovery, progressive disclosure metadata, multi-script execution routing, and activation/deactivation lifecycle.
- **ToolRegistry** — registers 3 new skill tools (`activate_skill`, `run_skill`, `manage_skill`), accepts `SkillManager` dependency.
- **PersonalityManager** — progressive disclosure prompt replaces flat skill name list; directive label updated.
- **FaeScheduler** — 13th built-in task `vault_backup` at 02:30 daily; expanded skill health check for directory-based skills.
- **PipelineCoordinator** — wired to `SkillManager` for progressive disclosure in system prompt.
- **PathPolicy** — blocks writes to `/.fae-vault` (vault protection).

## [v0.8.59] - 2026-03-01

### Fixed
- **Canvas shown on every launch** — startup canvas (Star Wars crawl + ready FAQ) now only auto-opens on the very first launch; subsequent launches leave the canvas closed. Persisted via `UserDefaults` key `fae.hasShownStartupCanvas`.
- **"Ready too soon" announcement** — Fae now runs a one-token LLM warmup inference after models load but before speaking the greeting. Metal shader compilation (30–60s on cold GPU cache) now happens silently before "Hello, I'm Fae" plays, so she is actually responsive when she announces ready.
- **LLM not generating / no speech bubble** — root cause was the Metal JIT warmup freeze on first inference after launch. After warmup completes, typed and spoken queries both generate LLM tokens as expected, and the speech bubble appears correctly on the main window.

## [v0.8.58] - 2026-03-01

### Fixed
- Speaking in tongues: LLM meta-commentary ("The user says...") suppressed before TTS via system prompt instruction and first-sentence pipeline filter
- Thinking toggle pill: simplified to "Thinking" + green/red dot indicator (cleaner, narrower)
- Sparkle cache-busting: timestamp query parameter on feed URL prevents stale NSURLCache hits after releases

## [v0.8.57] - 2026-03-01

### Fixed

- **Speaking in tongues (again, root fix)** — `thinkEndSeen` was hardcoded to `false` every call, meaning ALL tokens were buffered as a think block on every generation. Now initialised to `true` when thinking mode is disabled OR on tool follow-up turns, so non-thinking responses route directly to TTS. Safety timeout raised from 5 K → 80 K chars so long reasoning blocks no longer trigger premature flush-through.
- **Orb window covered by large text overlay** — `SubtitleStateController.appendStreamingSentence` accumulated all sentences into one growing string that grew to cover the orb. Now replaces with the latest sentence only. `ConversationBridgeController` was also passing the fully-accumulated text to `finalizeAssistantMessage`; now passes only the final sentence.
- **Debug console showing only STT events** — no `debugLog` calls existed in the LLM token loop. Added `.llmThink` logging inside the think-suppression buffer and `.llmToken` logging on the normal TTS path so all LLM output is visible in real time.
- **PersonalityManager thinking suppression** — the `suppressThinking` parameter was accepted but never used; re-added a concise "Thinking mode: OFF" system-prompt directive when thinking is disabled.
- **`</think>` tags reaching TTS** — added belt-and-suspenders stripping of `<think>` and `</think>` in `TextProcessing.stripNonSpeechChars`.

### Added

- **Thinking mode toggle button** — a "brain" pill button in the main window input bar (alongside Show Discussions / Show Canvas). Tap to toggle Fae's extended reasoning on/off. State is highlighted in heather/purple when on, persists to `config.toml`, and takes effect on the next query with no restart required.

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
- **`self_config` tool** — Fae can persist personality preferences (`directive.md`, formerly `custom_instructions.txt`) across sessions.

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
