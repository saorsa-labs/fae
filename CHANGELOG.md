# Changelog

All notable changes to this project will be documented in this file.

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
