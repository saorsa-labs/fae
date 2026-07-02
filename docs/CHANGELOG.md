# Fae Changelog

Detailed version history moved from CLAUDE.md. For current architecture, see `CLAUDE.md`.

## Unreleased — Production readiness Phase A (green board)

### Fixed
- **Linux release job unblocked**: replaced the fail-closed placeholder SHA-256 sentinels in `.github/workflows/release-linux.yml` with the real digests of the pinned appimagetool 1.9.0 release assets (x86_64 `46fdd785…`, aarch64 `04f45ea4…`), computed from the canonical GitHub release downloads.
- **Restore from Vault is now user-reachable**: rescue mode's Recovery tab gains a "Restore from Vault" section (visible only while rescue mode is active) that lists vault snapshots (date · message · short hash), confirms with a destructive dialog, drives the hardened `GitVaultManager.restore()` copy-then-swap path, and ends with an explicit "Quit Fae to load the restored data" step. `FaeCore` hands the vault to `RescueMode` both when rescue mode is registered and when the vault is created in `start()` (registration happens before `start()`, so the `didSet` alone would hand `nil` and the panel would silently show no backups).

## Unreleased — Connect Account (portable, Python-first)

### New Features
- **Portable `connect-account` executable skill** (`Resources/Skills/connect-account/`): one cross-platform engine that connects the user's mail/calendar/contacts from just their email + ONE app-specific password. Runs anywhere via `uv run --script` (PEP 723 inline metadata; sole dependency is cross-platform `keyring` — macOS Keychain / Linux SecretService). On macOS the keyring items land under the same service/account the existing productivity skills read via `CredentialManager`, so the script and the Swift skills interoperate.
- **Gmail provider** (Stage 1 of the in-app onboarding plan): `gmail.com`/`googlemail.com` → `imap.gmail.com`/`smtp.gmail.com` with the correct `[Gmail]/Sent Mail` etc. folder aliases (the generic aliases break save-to-Sent on Gmail), guidance pointing at the Google App-Passwords page (2-Step Verification required). Gmail is mail-only here — Google calendar/contacts need OAuth (app-password CalDAV/CardDAV is deprecated), reserved for a later method.
- **Two inputs, everything else derived**: detects iCloud (`@icloud.com`/`@me.com`/`@mac.com`), Gmail, or generic from the email domain, opens the provider's app-password page, derives the full config (iCloud servers + the seven keyring keys the productivity skills read + a himalaya `config.toml` whose `auth.cmd` reads the password from `$HIMALAYA_PASSWORD` — never `auth.raw`), stores it, and verifies mail live. Handles iCloud custom domains (mail sent from the alias, authenticated with the primary Apple ID) and spec-compliant TOML escaping.
- **Fae installs the `himalaya` mail CLI herself** — no terminal for the user. Portable on every OS: downloads the pinned himalaya release (v1.2.0), verifies its SHA-256 against embedded digests (fail-closed on mismatch, like models.lock), and drops the binary in `~/.local/bin` (already on Fae's PATH). `connect` auto-installs when himalaya is missing; a failed install (offline/unsupported arch) defers mail verification without rolling back a correct password. New `ensure_tools` action exposes it directly.
- **Actions**: `start` (detect + open page + guidance), `connect` (derive → store in keyring → write himalaya config → auto-install himalaya → verify mail live → transactional rollback on auth failure), `ensure_tools` (install himalaya), `status`, `selftest` (validates derivation with no account/secret/network — 11/11).
- **Secret hygiene**: the password is never read from argv or the request JSON — it arrives via `FAE_APP_PASSWORD` (injected on macOS by `input_request`+`secret_bindings`, i.e. straight to the Keychain) or a no-echo `getpass` terminal prompt on Linux/CLI, and flows only into the system keyring and the himalaya child env. Never printed, logged, or surfaced (himalaya stderr suppressed).
- Ships as an executable skill with `MANIFEST.json` (SHA-256 integrity). macOS calendar/contacts continue to use the built-in `calendar`/`contacts` (EventKit) tools — no password, local access — while off-macOS they use the stored CalDAV/CardDAV credentials.

## Unreleased — Task #11 Prompt budget (levers 2/3 + gate)

### Changed
- Tool-call no-regression gate (the plan's deferred FaeBenchmark gate): added a deterministic `TurnHelpers` coverage battery asserting 11 high-frequency spoken intents (calendar/reminders/mail/web/screenshot/camera/read/bash/session_search) keep a full native schema on cold turns, and that niche tools (roleplay/delegate_agent/agent_session/plugin_manage) stay intentionally index-only. Lever 1 is no longer provisional — no regression on the high-frequency surface, CI-guarded.
- Lever 2 (memory recall budget): the recall block already enforced a hardcoded 2000-char cap; made it the config knob `memory.maxRecallChars` (default 2000, floored at 200) — no behavior change, now tunable.
- Lever 3 (prefix cache): added `FAE_PREFIX_CACHE_N` env knob in fae-engine (`configured_prefix_cache_n`), default OFF (unchanged). Re-enables the prefix cache for live A/B; MUST pass an audio-turn regression suite before any default-on (a cache hit across audio turns previously corrupted output).

## Unreleased — Task #11 Prompt budget

### Changed
- Added native progressive tool disclosure: ordinary turns keep a compact index of all allowed tools but send full JSON schemas only for a conservative working set plus explicit/inferred long-tail tools.
- Added daemon prompt-budget metrics logging (`prompt_budget`) with approximate text-token, payload-byte, and tool-schema counts per turn.
- Added regression coverage for generic/core tool working sets, inferred long-tail expansion, proactive allowlist narrowing, strict-local filtering, and prompt-budget metric reductions.

## Unreleased — Task #10 Thinking liveness

### Fixed
- Silent awareness/proactive generations are now tracked for token-stream isolation without driving the orb's user-visible `assistantGenerating` / "Thinking" indicator.
- Stale or superseded generations can no longer strand the Thinking pill: ending an old generation only removes that generation, while the indicator is forced idle once no visible generation or approval pause remains.
- Added regression coverage for overlapping silent proactive generations, visible-generation guard semantics, and approval pauses.

## Unreleased — Skills-first cross-platform P5

### CI / Build
- Release workflow dry-runs can now build a reviewable macOS bundle without notarization or GitHub Release publishing.
- `release.yml` builds `fae-daemon` and `fae-ui-shell` as Rust auxiliary binaries, embeds them in `Contents/MacOS`, signs helpers, and verifies the embedded daemon with `codesign` plus `fae-daemon --version`.
- The no-Rust-reintroduction guard now allows Rust only in the explicit Linux render-spike workflow and this release auxiliary embedding workflow.

### Security
- Added a generated `models.lock` for the reviewed `google/gemma-4-E4B-it` Hugging Face snapshot and wired daemon startup to fail closed before model load on missing, mismatched, or unpinned artifacts.
- Daemon model loading now passes the verified HF revision into mistral.rs so the runtime cannot silently move to a newer snapshot than the one hashed in `models.lock`.
- Swift installs the bundled lock into `<fae data dir>/models.lock`; `FAE_MODELS_LOCK=off` remains a loud dev-only escape hatch under `FAE_DEV=1`.

## Unreleased — Skills-first cross-platform P4

### CI / Build
- Added a dedicated `linux-render-spike` GitHub Actions workflow for Ubuntu WebKitGTK shell builds and ALSA-backed daemon builds.
- Added an Xvfb smoke mode for the Rust UI shell that opens the opaque Settings panel, captures a WebKitGTK screenshot artifact in CI, and rejects blank captures via ImageMagick color-count validation.
- Folded the P1-deferred Linux `fae-daemon` build proof into the same Ubuntu job with `libasound2-dev`, `pkg-config`, and `cargo zigbuild`.
- Switched Linux `wry` panels to `WebViewBuilderExtUnix::build_gtk` against tao's GTK container after the generic `build(&window)` path produced blank Xvfb captures.

### Docs
- Added `docs/architecture/linux-render-spike-2026-06.md` to track opaque Settings panel, pill transparency, and Linux shell go/no-go findings.

## Unreleased — Skills-first cross-platform P3

### New Features
- Added an orb-owned Settings panel in `fae-ui-shell` with `settings_snapshot` / `settings_set` bridge sync to Swift `FaeCore.patchConfig`.
- Added adjustable Settings controls for tool access, thinking depth, LLM temperature, TTS speed, awareness cadence, and privacy posture, plus informational always-on capability cards.
- Kept the SwiftUI Settings window available as **Settings (legacy)…** during parity migration.

### Tests
- Added Rust bridge protocol coverage for `settings_snapshot` and the legacy settings menu action.
- Live-verified panel-driven `tts.speed` persistence plus Right Option and orb long-press PTT regressions.

## Unreleased — Skills-first cross-platform P2

### New Features
- Added executable built-in skills `mail-himalaya`, `calendar-caldav`, and `contacts-carddav` with agentskills.io-compatible frontmatter plus Fae SHA-256 manifests.
- Added PEP 723 Python CalDAV/CardDAV scripts for portable calendar/contact workflows with Keychain-injected environment variables.
- Added `himalaya` to the extended tool augmentation registry for portable IMAP/SMTP mail.

### Tests
- Extended bundled skill discovery/manifest coverage for the productivity skills and added registry coverage for `himalaya`.

## Unreleased — Skills-first cross-platform P1

### New Features
- Added `fae-audio`, a cpal-backed daemon audio crate for portable PTT capture and WAV playback.
- Added daemon NDJSON commands `audio.devices`, `audio.capture_start`, `audio.capture_stop`, and `audio.play` behind the existing control-plane auth/scopes.
- Added a live repro script at `crates/fae-daemon/scripts/fae_audio_repro.py` for capture → playback → audio turn → TTS → playback validation.
- Added capture gain normalization plus `FAE_AUDIO_INPUT_DEVICE` / `FAE_AUDIO_OUTPUT_DEVICE` overrides for reproducible cpal diagnostics.

### Tests
- Added WAV encode round-trip, 48 kHz → 16 kHz sine resampling, capture gain, capture-cap reaping, audio command scope, and daemon auth rejection coverage.

## v0.8.183 — Autonomous Self-Improvement Loop (2026-03-30)

### New Features
- **Autonomous self-improvement loop**: Fae can now train, evaluate, and deploy LoRA adapters overnight without human intervention. Collects conversation corrections during the day, trains via mlx-tune, evaluates with FaeBenchmark (pure Swift), gets external agent review, and proposes improvements next morning.
- **LoRA adapter loading**: MLXLLMEngine gains `loadAdapter(from:)`, `unloadAdapter()`, and `swapAdapter(to:)` methods via mlx-swift-lm's built-in LoRA support. Supports hot-swap without app restart.
- **Adapter deployment via SelfConfigTool**: New `training.personal_adapter_path` and `training.adapter_auto_load_enabled` adjustable settings. FaeCore.patchConfig hot-swaps adapters on the running pipeline.
- **FaeBenchmark --adapter flag**: Benchmark a LoRA adapter against the base model with per-metric comparison JSON output. Pre-flight path validation.
- **ImprovementStore**: New `improvement.db` SQLite database (separate from fae.db and scheduler.db) with 5 tables: feedback_events, improvement_baselines, improvement_state, capability_gaps, shadow_eval.
- **ImprovementCycleCoordinator**: Deterministic state machine actor (IDLE -> COLLECTING -> TRAINING -> EVALUATING -> PROPOSING -> DEPLOYING) with scheduler integration at 03:00 daily. Minimum data thresholds prevent overfitting on sparse data.
- **Semi-automatic deployment**: Morning proposals tell the user specifically what improved. After 5 user-approved cycles, earns fully automatic deployment. Adapter rollback via current/previous path tracking.
- **ImplicitFeedbackDetector**: 7 signal types captured from every conversation turn: re-ask, abandonment, follow-through, interruption, praise, topic change, silence acceptance. Feeds into ImprovementStore for DPO pair generation.
- **ExternalReviewGate**: 3-provider fallback chain (Codex -> Claude Code -> internal self-review) with PASS/FAIL/CONCERN gate and 3-deferral maximum before force-deploy.
- **DirectiveFastTuner**: Pattern-based directive amendments (every 7th cycle). Detects repeated corrections, persistent re-asks, abandonment clusters, and style preferences. Reversible via Git Vault.
- **ShadowEvaluator**: Overnight-only replay on alternate nights from training. Compares base vs adapter responses. Promotion gate at 60% adapter win rate.
- **ImprovementHealthReporter**: Self-diagnostic integration reports improvement loop health (last cycle, adapter version, eval scores, failed cycles).
- **Git Vault backup**: improvement.db and trained adapter directory added to vault backup manifest.

### Tests
- 168 new improvement-related tests across 8 test suites
- Integration tests covering full feedback -> training -> eval -> deploy round-trip

---

## v0.8.181 — ASR Resilience + Self-Healing Skills + ACP Delegation (2026-03-30)

### Bug fixes
- **ASR pipeline deaf after overnight**: VAD EMA silence threshold, noise floor, echo suppressor baseline, and wake detector state now reset on idle timeout — prevents the pipeline from going "deaf" after long-running sessions
- **Name garbled as "Peer-to-peer"**: `CorrectionDetector` no longer false-triggers on conversational phrases like "it's peer-to-peer"; added `isPlausibleName()` gate that rejects non-name words, oversized strings, and punctuation
- **Name resolution negation bug**: `extractStoredName()` now rejects "Primary user name is not X" patterns that previously resolved as valid names
- **Plugin agent skills reported broken**: health check now recognises plugin-sourced instruction skills (tagged "agent") and marks them healthy without requiring SKILL.md directory structure

### Improvements
- **Self-healing skill system**: `SkillManager.repairSkills()` auto-repairs broken built-in skills (restores SKILL.md from bundle) and degraded executables (generates conservative MANIFEST.json); scheduler and self-diagnostic attempt repair before reporting to user
- **ACP agent delegation expanded**: `delegate_agent` tool now supports 5 providers (codex, claude, pi, gemini, copilot); `ACPSessionManager` auto-installs acpx via bun/npm on first use
- **SKILL.md frontmatter normalised**: `acp-setup` and `huggingface-scout` skills aligned to agentskills.io standard (metadata nesting, removed non-standard top-level fields)
- **Sparkle background check silenced**: scheduler update checks now use `checkForUpdatesInBackground()` — no "you're up to date" dialog when already current

---

## v0.8.147 — Conversational Tool Responses + Orb Performance (2026-03-23)

### Improvements
- **Conversational tool responses**: Apple tool results (calendar, reminders, mail, contacts, notes) now route through the LLM for natural-language interpretation instead of being read back verbatim — Fae analyzes, summarizes, and flags what matters
- **Improved personality prompts**: system prompt updated to guide Fae toward interpreting and presenting information as a thoughtful friend, not a text-to-speech reader
- **Orb shader optimized**: NebulaOrb Metal shader rewritten with half-precision, reduced FBM octaves, and constant folding — significantly lower GPU cost at 120px render size
- **Rate limiter relaxed**: bash tool limit raised from 5 to 30 calls/min; high-risk minimum raised from 3 to 15 to support multi-tool scripting workflows
- **Speech verifier resilience**: speech verifier now logs and continues when model is not loaded rather than silently skipping verification

### Bug fixes
- **Approval manager timeout**: updated test expectations to match 45s timeout (was 20s)
- **Voice pipeline test**: synthetic speech signal strengthened to meet WeSpeaker 2s+ voiced duration threshold
- **Owner auto-approval test**: fixed test that was accidentally auto-approving via voice identity instead of testing the no-approval-manager path

### Tests
- Total: 1616 tests, 0 failures

---

## v0.8.145 — Self-Diagnostic + Correction Feedback (2026-03-20)

### New features
- **Self-diagnostic skill**: instruction skill (`self-diagnostic`) that guides Fae through a comprehensive health check — system resources, pipeline state, security events, tool health, memory status, and speaker profiles
- **Voice command trigger**: say "diagnose", "run diagnostics", "health check", "how are you doing" to activate self-diagnostic
- **Proactive anomaly watcher**: 6-hour scheduler task (`self_diagnostic`) silently checks memory health, skill health, and disk space; queues a spoken alert when anomalies are found
- **User correction detection**: `CorrectionDetector` recognises name errors ("my name is X not Y"), mishearings ("I said X"), interruptions ("you interrupted me"), and wrong actions ("that was wrong")
- **Correction memory capture**: corrections are stored as memory records (profile for names, episode for others) via `MemoryOrchestrator.storeCorrection()`
- **ASR vocabulary learning**: name corrections are fed into `DynamicVocabularyCorrector.addCorrectionPair()` for immediate post-ASR improvement

### Tests
- 27 CorrectionDetector tests (all pattern types, false positives, CorrectionRecord)
- 8 VocabularyLearning tests (addCorrectionPair, deduplication, integration flow)
- 16 SelfDiagnosticSkill tests (voice commands, skill discovery, activation)
- Total: 1395 tests, 0 failures

---

## Completed milestones

- **v0.6.2** — Production hardening: pipeline startup, runtime event routing, settings redesign
- **v0.7.0** — Dogfood readiness: backend cleanup, voice command routing, UX feedback, settings expansion
- **Milestone 7** — Memory Architecture v2: SQLite + semantic retrieval, hybrid scoring, backups
- **v0.8.0** — Pure Swift migration: MLX engines, unified pipeline, no Rust core
- **v0.8.1** — Tool security hardening: 7-layer safety model
- **v0.8.62** — Echo/barge-in fix: prevent garbled speech from self-interruption
- **v0.8.72** — Vision + Computer Use: Fae can see the screen and interact with apps
- **v0.8.74** — Voice Pipeline Overhaul: TTS consistency, timestamps, conversational voice identity
- **v0.8.75** — Native Tool Calling: MLX native tool calling integration for all tools
- **v0.8.82** — Proactive Visual Awareness: camera presence, screen monitoring, overnight research, enhanced briefings
- **v0.9.0** — Memory v2: neural embeddings, ANN search, knowledge graph
- **v1.0.0** — UX overhaul: orb enchantment, streaming, canvas feed, stop, hotkey, input flow
- **v1.1.0** — Data Vault, Skills v2, TrustedActionBroker, security hardening
- **v1.2.0** — Fae Forge, Toolbox & Mesh: tool creation, registry, and peer sharing
- **v1.3.0** — Worker subprocess architecture, CoWork web search, TTS switch to Kokoro
- **v1.4.0** — Thinking crawl, capability discovery, enrollment UX, code quality pass
- **v1.4.1** — CoWork approval flow fixes + camera tool fix
- **v1.4.2** — ACP integration, channel adapters, training pipeline, skill hardening
- **v0.8.125** — Memory inbox: multi-line pastes split into individual memory records; date prefixes and list markers from migration format are stripped automatically
- **v0.8.124** — Tool visibility: conversational follow-ups now correctly show available tools; Discord channel setup fixed
