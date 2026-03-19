# Phase 8.8: Channel Migration

**Goal**: Migrate hardcoded Discord/WhatsApp channel adapters to Python skills, preserving all existing functionality while removing ~2000 lines of hardcoded channel code. The generic channel infrastructure (traits, history, rate limiting) is retained.

**Dependencies**: Phase 8.7 (health monitoring for migrated skills)

---

## Existing Code Analysis

**To be removed** (~600 lines):
- `src/channels/discord.rs` (312 lines) — Discord adapter
- `src/channels/whatsapp.rs` (284 lines) — WhatsApp adapter

**To be refactored** (~800 lines):
- `src/channels/mod.rs` (561 lines) — ChannelManager, needs adapter-agnostic version
- `src/channels/gateway.rs` (306 lines) — HTTP gateway, needs Python skill routing

**To be kept** (~560 lines):
- `src/channels/traits.rs` (34 lines) — Channel adapter trait
- `src/channels/history.rs` (274 lines) — Message history
- `src/channels/rate_limit.rs` (251 lines) — Rate limiting
- `src/channels/brain.rs` (69 lines) — LLM routing

**External references**:
- `src/config.rs` — `ChannelRateLimits` type in `ChannelsConfig`
- `src/doctor.rs` — `validate_config()` function
- `src/ui/channel_panel.rs` — `ChannelMessage`, `MessageDirection`

---

## Task 1: Python skill templates for Discord and WhatsApp

**New file**: `src/skills/channel_templates.rs`

Create pre-built Python skill templates (manifest.toml + skill.py) for Discord and WhatsApp that implement the same functionality as the current Rust adapters:

- Discord template: Bot login, message receive/send, guild/channel filtering
- WhatsApp template: Webhook receive, message send, phone number filtering
- Both use the JSON-RPC 2.0 protocol with `handshake`, `invoke`, `health`, `shutdown`
- Both declare credentials in manifest (bot_token, access_token, etc.)
- Templates are stored as const strings and can be installed via `install_channel_skill()`

**Tests**: 6+ unit tests for template validity (contains required methods, valid manifest TOML).

**Files**: `src/skills/channel_templates.rs`, `src/skills/mod.rs`

---

## Task 2: ChannelSkillAdapter — bridge from channel traits to Python skills

**New file**: `src/channels/skill_adapter.rs`

Create `ChannelSkillAdapter` that implements `ChannelAdapter` by delegating to a running `PythonSkillRunner`:

```rust
pub struct ChannelSkillAdapter {
    skill_id: String,
    channel_type: ChannelType,
}
```

- `send_message()` → invokes the skill with `{"action": "send", "message": ...}`
- `start_listening()` → starts the skill daemon
- `stop()` → sends shutdown to the skill

This is the bridge that lets the ChannelManager treat Python skills exactly like the old hardcoded adapters.

**Tests**: 8+ unit tests for adapter construction, message formatting.

**Files**: `src/channels/skill_adapter.rs`, `src/channels/mod.rs`

---

## Task 3: Refactor ChannelManager for adapter-agnostic operation

**File**: `src/channels/mod.rs`

Modify `ChannelManager` to:
- Accept `ChannelSkillAdapter` instead of `DiscordAdapter` / `WhatsAppAdapter`
- Route inbound/outbound messages through the adapter trait
- Keep history, rate limiting, and brain routing unchanged
- Add `register_skill_channel(skill_id, channel_type)` method

**Tests**: 4+ unit tests for skill-based channel registration and routing.

**Files**: `src/channels/mod.rs`

---

## Task 4: Remove hardcoded adapters

**Delete files**:
- `src/channels/discord.rs`
- `src/channels/whatsapp.rs`

**Modify**: `src/channels/mod.rs` — remove `mod discord`, `mod whatsapp` declarations and all references.

**Modify**: `src/channels/gateway.rs` — remove WhatsApp-specific webhook handling, replace with generic skill-based webhook routing.

**Modify**: `src/config.rs` — simplify `ChannelsConfig` to reference skill IDs instead of platform-specific fields.

**Modify**: `src/doctor.rs` — update `validate_config()` to check for skill-based channels.

**Tests**: Ensure all existing tests still compile and pass.

**Files**: delete `discord.rs`, `whatsapp.rs`; modify `mod.rs`, `gateway.rs`, `config.rs`, `doctor.rs`

---

## Task 5: Host commands for channel skill management

**Files**: `src/host/contract.rs`, `src/host/channel.rs`, `src/host/handler.rs`

Add commands:
- `skill.channel.install` — install a channel skill from built-in templates
- `skill.channel.list` — list installed channel skills

**Tests**: 4+ integration tests.

**Files**: host layer + `tests/integration/python_channel_migration.rs`, `tests/integration/main.rs`

---

## Task 6: Integration tests and cleanup

- Full end-to-end test: install Discord channel skill, verify adapter routing
- Verify config migration (old config fields → skill IDs)
- Clean up unused imports/types
- Final clippy + test pass

**Files**: `tests/integration/python_channel_migration.rs`, various cleanup

---

## Summary

| Task | Description | Est. Lines | Files |
|------|-------------|-----------|-------|
| 1 | Channel skill templates (Discord/WhatsApp) | ~250 | channel_templates.rs, mod.rs |
| 2 | ChannelSkillAdapter (trait bridge) | ~150 | skill_adapter.rs, mod.rs |
| 3 | Refactor ChannelManager | ~100 (net -200) | mod.rs |
| 4 | Remove hardcoded adapters | ~-600 | delete 2 files, modify 4 |
| 5 | Host commands for channel skills | ~80 | host layer |
| 6 | Integration tests + cleanup | ~120 | tests/ |

**Net effect**: ~-400 lines (remove ~600 hardcoded, add ~200 new)
