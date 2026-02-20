# Fae Native macOS App — Production Readiness Roadmap

## Previous Milestones (Complete)

- Milestone 1: Core Pipeline & Linker Fix
- Milestone 2: Event Flow & UI Wiring
- Milestone 3: Apple Ecosystem Tools
- Milestone 4: Onboarding Redesign
- Milestone 5: Handoff & Production Polish

---

## Milestone 6: Dogfood Readiness

**Goal:** Fix all 11 validated findings from the dogfood review. Production-ready: fully tested, documented, zero warnings.

**Source:** Dogfood readiness review (2026-02-20), all 11 findings validated against codebase.

**Key Design Decisions:**
- "show conversation" opens the **conversation panel** (not canvas)
- WhatsApp/Discord requires **native Settings UI**
- Embedded-only models enforced — **REMOVE all API/Agent backend code entirely**
- No Ollama/LM Studio/external API servers — **REMOVE fae_llm OpenAI/Anthropic providers**

---

### Phase 6.1: Backend Cleanup

**Rationale:** Foundational changes that touch many files. Must land first to avoid conflicts.

| Task | Description | Key Files |
|------|-------------|-----------|
| Remove LlmBackend::Api and LlmBackend::Agent | Delete enum variants, api_url/api_key/api_model/api_type/cloud_provider config fields, build_remote_provider(), API fallback logic | `config.rs`, `startup.rs`, `agent/mod.rs`, `agent/http_provider.rs`, `llm/api.rs`, `external_llm.rs`, `intelligence/mod.rs`, `channels/brain.rs` |
| Remove/update API-dependent tests | Remove or adapt tests exercising Api/Agent backends | `tests/e2e_anthropic.rs`, `tests/e2e_openai.rs`, `tests/anthropic_contract.rs`, `tests/openai_contract.rs`, `tests/cross_provider.rs`, `tests/llm_config_integration.rs` |
| Fix fae_dirs test flake | Serialize env-mutating tests with `serial_test` crate | `fae_dirs.rs`, `Cargo.toml` |
| Clean up Models settings tab | Remove non-local model backend references | `SettingsModelsTab.swift` |

**Exit:** `just check` passes, zero Api/Agent references, fae_dirs tests reliable.

---

### Phase 6.1b: fae_llm Provider Cleanup

**Rationale:** User directive — Fae only uses downloaded embedded models. No Ollama, LM Studio, or external API servers. Remove unused provider infrastructure.

| Task | Description | Key Files |
|------|-------------|-----------|
| Remove OpenAI provider | Delete openai.rs, remove pub use/re-exports | `fae_llm/providers/openai.rs`, `fae_llm/mod.rs` |
| Remove Anthropic provider | Delete anthropic.rs, remove pub use/re-exports | `fae_llm/providers/anthropic.rs`, `fae_llm/mod.rs` |
| Remove fallback provider | Delete fallback.rs (only used for API→local fallback) | `fae_llm/providers/fallback.rs`, `fae_llm/providers/mod.rs` |
| Clean fae_llm config | Remove provider API key fields, simplify config types | `fae_llm/config/types.rs`, `fae_llm/config/defaults.rs`, `fae_llm/config/service.rs` |
| Remove credential API key support | Clean llm.api_key from credential examples/doc comments | `credentials/types.rs`, `credentials/mod.rs`, `diagnostics/mod.rs` |
| Clean observability redaction | Remove API key redaction helpers if unused | `fae_llm/observability/redact.rs` |

**Exit:** `fae_llm` only contains local/embedded provider. No OpenAI/Anthropic/fallback code. `just check` green.

---

### Phase 6.2: Event Wiring

**Rationale:** Critical event chain fixes — Rust emits events but Swift doesn't act.

| Task | Description | Key Files |
|------|-------------|-----------|
| Wire canvas/conversation window show/hide | PipelineAuxBridgeController calls AuxiliaryWindowManager show/hide. Add conversation_visibility event. "show conversation" opens conversation panel. | `PipelineAuxBridgeController.swift`, `AuxiliaryWindowManager.swift`, `FaeNativeApp.swift`, `coordinator.rs`, `handler.rs` |
| Complete JIT permission flow | Extend JitPermissionController for calendar/reminders/notes/mail. Wire OnboardingController.onPermissionResult. Connect AvailabilityGatedTool JIT channel. | `JitPermissionController.swift`, `OnboardingController.swift`, `agent/mod.rs`, `availability_gate.rs` |
| Wire device handoff end-to-end | Handler emits events for device.move/go_home. Swift observer processes device.transfer_requested. NSUserActivity handoff. | `handler.rs`, new `DeviceHandoffController.swift`, `FaeHandoffKit/` |

**Exit:** "Show conversation" opens conversation. "Show canvas" opens canvas. JIT permissions for all Apple tools. Device handoff emits NSUserActivity.

---

### Phase 6.3: UX Feedback

**Rationale:** User-facing feedback improvements for polished dogfood experience.

| Task | Description | Key Files |
|------|-------------|-----------|
| Startup progress display | Handle aggregate_progress in ConversationBridgeController. JS progress indicator with download % and load stage. | `ConversationBridgeController.swift`, `conversation.html` |
| Real-time streaming bubbles | Partial STT to subtitle. Stream assistant text incrementally. | `ConversationBridgeController.swift`, `conversation.html` |
| Audio level JS handler | Add window.setAudioLevel() to drive orb RMS visualization. | `conversation.html` |
| Orb right-click context menu | contextmenu handler on collapsed orb for hide/show. | `conversation.html`, `WindowStateController.swift` |

**Exit:** Download progress visible. Real-time streaming text. Orb reacts to audio. Right-click context menu works.

---

### Phase 6.4: Settings Expansion

**Rationale:** Missing Settings UI prevents users from configuring tools and channels.

| Task | Description | Key Files |
|------|-------------|-----------|
| Add Tools settings tab | SettingsToolsTab with tool mode picker (Off/ReadOnly/ReadWrite/Full). Uses config.patch. | New `SettingsToolsTab.swift`, `SettingsView.swift` |
| Add Channels settings tab | SettingsChannelsTab with Discord/WhatsApp config forms. | New `SettingsChannelsTab.swift`, `SettingsView.swift` |
| Remove false CameraSkill claim | Remove CameraSkill from builtins — no camera tool exists. Update system prompt. | `builtins.rs`, `system_prompt.md` |

**Exit:** Tools tab allows tool mode changes. Channels tab configures Discord/WhatsApp. No false capability claims.

---

### Phase 6.5: Integration Validation

**Rationale:** End-to-end verification before team-wide dogfood release.

| Task | Description | Key Files |
|------|-------------|-----------|
| End-to-end smoke tests | Test all 11 fixed paths | New integration tests |
| Documentation updates | Update CLAUDE.md, architecture docs, system prompt | Doc files |
| Swift test suite | Tests for new controllers and settings tabs | `Tests/` |
| Release prep | Version bump, changelog, `just check` | `Cargo.toml`, `CHANGELOG.md` |

**Exit:** All tests pass (Rust + Swift). `just check` green. All 11 findings resolved. v0.7.0 ready.
