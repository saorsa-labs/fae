# Channels Setup (Current Status)

External channels are currently in an incremental rollout state in the Swift runtime.

## What exists today

- Channel configuration keys are persisted in `config.toml` under `[channels]`.
- `ChannelManager` provides runtime gating, allowlist checks, and message routing hooks.
- Settings UI includes channel toggles and disconnect controls.

## What is not yet shipped as turnkey in-app setup

- Fully managed Discord bot onboarding flow
- Fully managed WhatsApp Business webhook provisioning flow
- End-to-end production adapters bundled in this repo

## Current recommended usage

Use channel settings as configuration scaffolding while adapters are integrated.

Config keys currently used:

- `channels.enabled`
- `channels.discord.bot_token`
- `channels.discord.guild_id`
- `channels.discord.allowed_channel_ids`
- `channels.whatsapp.access_token`
- `channels.whatsapp.phone_number_id`
- `channels.whatsapp.verify_token`
- `channels.whatsapp.allowed_numbers`

## Source files

- `native/macos/Fae/Sources/Fae/Channels/ChannelManager.swift`
- `native/macos/Fae/Sources/Fae/SettingsChannelsTab.swift`
- `native/macos/Fae/Sources/Fae/Core/FaeCore.swift`
