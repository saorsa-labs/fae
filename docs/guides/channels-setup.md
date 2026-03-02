# Channels Setup (Skill-First, Current Runtime)

Fae now supports **skill-first channel onboarding** for Discord, WhatsApp, and iMessage with conversational setup and guided forms.

## Project preference (important)

**Canonical preference:** Prefer skill contracts over hardcoded code paths; prefer asking Fae conversationally for setup/changes over manual config editing.

- Channel behavior should be declared in skill manifests/contracts.
- Setup should happen through conversation and guided forms.
- Users should be able to ask Fae for changes directly, rather than editing raw config keys.
- App code should provide shared orchestration primitives, while channel specifics live in skills.

## What ships today

- Channel skills are bundled under:
  - `native/macos/Fae/Sources/Fae/Resources/Skills/channel-discord/`
  - `native/macos/Fae/Sources/Fae/Resources/Skills/channel-whatsapp/`
  - `native/macos/Fae/Sources/Fae/Resources/Skills/channel-imessage/`
- Settings contract (`settings` in skill manifest) drives discovery, required fields, and setup prompts.
- `channel_setup` tool supports:
  - `list`
  - `status`
  - `next_prompt` (plain-English one-field-at-a-time)
  - `request_form` (guided multi-field input card)
  - `set`
  - `disconnect`
- Channels screen includes an in-app walkthrough and a one-click “Start guided setup in chat” action.

## Secret handling and migration

- Sensitive channel fields are migrated toward Keychain-backed storage.
- Fae now writes channel secrets to Keychain for:
  - `channels.discord.bot_token`
  - `channels.whatsapp.access_token`
  - `channels.whatsapp.verify_token`
- Legacy config compatibility remains: discovery/status can still read old inline values while migration completes.

## Feature flags (local rollout)

Rollout is controlled via local flags (no telemetry):

- `fae.feature.world_class_settings` — enable redesigned settings IA.
- `fae.feature.channel_setup_forms` — enable guided channel forms from chat.

Developer tab exposes both toggles and local form-usage counters.

## What users can ask Fae

Examples:

- "Set up Discord for me"
- "What channel setup is missing right now?"
- "Switch me to form-based setup"
- "Disconnect WhatsApp"

## In-app walkthrough (user flow)

1. Open **Settings → Skills & Channels → Channels**.
2. Click **Start guided setup in chat**.
3. Tell Fae which channel to configure.
4. Follow either:
   - chat prompts (`next_prompt`) for one-field setup, or
   - guided form input (`request_form`) for multi-field setup.
5. Fae saves values, re-checks missing fields, and confirms configured state.

## Source files

- `native/macos/Fae/Sources/Fae/Tools/ChannelSetupTool.swift`
- `native/macos/Fae/Sources/Fae/Tools/BuiltinTools.swift` (`InputRequestBridge`)
- `native/macos/Fae/Sources/Fae/ApprovalOverlayController.swift`
- `native/macos/Fae/Sources/Fae/ApprovalOverlayView.swift`
- `native/macos/Fae/Sources/Fae/Core/SettingsCapabilityManifest.swift`
- `native/macos/Fae/Sources/Fae/Core/FaeCore.swift`
- `native/macos/Fae/Sources/Fae/SettingsChannelsTab.swift`
- `native/macos/Fae/Sources/Fae/SettingsView.swift`
- `native/macos/Fae/Sources/Fae/SettingsDeveloperTab.swift`

## Planning references

- `.planning/plans/skill-first-settings-channels-world-class-plan.md`
- `.planning/specs/skill-settings-contract-v1.md`
