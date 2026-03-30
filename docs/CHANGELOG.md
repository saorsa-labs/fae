# Fae Changelog

Detailed version history moved from CLAUDE.md. For current architecture, see `CLAUDE.md`.

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
