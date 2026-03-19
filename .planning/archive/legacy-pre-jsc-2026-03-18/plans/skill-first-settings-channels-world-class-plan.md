# Skill-First Settings & Channel Onboarding Plan (Fae)

Status: Completed (phase rollout foundations shipped)
Owner: Fae Swift runtime
Updated: 2026-03-02

## Product mandate (authoritative)

Fae should be configurable in natural language, with as little raw manual config editing as possible.

Core preference:

- **Canonical preference:** Prefer skill contracts over hardcoded code paths; prefer asking Fae conversationally for setup/changes over manual config editing.
- Prefer guided forms where multi-field input improves clarity.
- Let users ask Fae for changes directly whenever policy permits.

Initial channel focus shipped under this model:

1. iMessage
2. WhatsApp
3. Discord

## Outcome delivered

✅ User can ask in chat to set up a channel.
✅ Fae asks for missing fields in plain English (`next_prompt`).
✅ Fae can launch guided multi-field forms (`request_form`).
✅ Settings IA redesigned with dedicated tabs and channel workspace.
✅ Channel status surfaced from capability snapshots.
✅ Secret channel fields moved to keychain-backed compatibility path.
✅ Rollout controls and local-only analytics counters added.

## Architecture summary

### Skill settings contract

- Optional `settings` block in skill manifest powers discovery/status/prompting.
- Contract validation occurs during manifest loading.
- Discovery-first channel listing replaces bespoke per-channel wiring in settings.

### Conversational orchestration

`channel_setup` supports:

- `list`, `status`
- `next_prompt`
- `request_form`
- `set`, `disconnect`

### Guided input UX

- `InputRequestBridge` supports structured form requests.
- Approval/input overlay renders text and multi-field forms.

### Storage and migration

- Channel secrets (`discord.bot_token`, `whatsapp.access_token`, `whatsapp.verify_token`) persist via keychain path.
- Legacy config read compatibility retained during migration window.

## Settings IA delivered

Top-level tabs:

1. Overview
2. Skills & Channels
3. Privacy & Security
4. Memory
5. Diagnostics

Channels workspace includes setup walkthrough and direct “start guided setup in chat” action.

## Rollout controls (local-only)

- `fae.feature.world_class_settings`
- `fae.feature.channel_setup_forms`

Local counters (developer-facing) track guided-form opens/submits/cancels. No external telemetry dependency.

## Post-implementation guidance

When adding new configurable integrations:

1. Add/extend skill manifest settings contract first.
2. Reuse shared orchestration (`channel_setup`, input bridge, capability snapshot).
3. Avoid adding one-off hardcoded settings UI unless unavoidable.
4. Keep user flow in plain English with minimal required input.

## Acceptance checklist status

- #5 architecture spec — complete
- #6 settings contract schema — complete
- #7 channel groundwork — complete
- #8 discovery-driven integration generalization — complete
- #9 conversational orchestration — complete
- #10 guided form UX — complete
- #11 capability manifest foundation — complete
- #12 settings IA redesign — complete
- #13 config/secret migration compatibility — complete
- #14 E2E-ish coverage and gating tests — complete
- #15 rollout flags + local analytics — complete
- #16 docs + walkthrough — complete
