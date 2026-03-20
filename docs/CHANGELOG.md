# Fae Changelog

Detailed version history moved from CLAUDE.md. For current architecture, see `CLAUDE.md`.

## v1.5.0 — Self-Diagnostic + Correction Feedback (2026-03-20)

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
