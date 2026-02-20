# Code Simplification Review
**Date**: 2026-02-20
**Mode**: gsd-task
**Scope**: src/host/handler.rs, native/macos/*.swift

## Findings

- [LOW] src/host/handler.rs:231-310 — The 7 match arms in `patch_channel_config` each call `get_or_insert_with(DiscordChannelConfig::default)` or `get_or_insert_with(WhatsAppChannelConfig::default)` independently. A minor simplification: acquire the Discord or WhatsApp sub-guard once at the top of each group, then set fields. However, the current approach is readable and the repetition is structurally clear in a config patching context.

- [LOW] src/host/handler.rs:1502-1504 — The `serde_json::from_value::<AgentToolMode>(serde_json::Value::String(s.to_owned()))` construction is slightly verbose. Could write `s.parse::<AgentToolMode>()` if `AgentToolMode` implements `FromStr`, or could use `serde_json::from_str::<AgentToolMode>(&format!(r#"\"{}\"", s))`. The current form is explicit and correct.

- [OK] native/.../SettingsToolsTab.swift — Very clean, minimal. No simplification opportunities.

- [OK] native/.../SettingsChannelsTab.swift — Clear section separation. The two save functions are similar but concise. Could be generalized to a generic `sendPatch(key:value:ifNonEmpty:)` helper, but current form is readable.

- [OK] CameraSkill removal: clean — no remnants, no dead code.

## Simplification Opportunities

### Opportunity 1: Shared Discord/WhatsApp guard in `patch_channel_config`

Before (current):
```rust
"channels.discord.bot_token" => {
    if let Some(s) = value.as_str() {
        let dc = guard.channels.discord.get_or_insert_with(DiscordChannelConfig::default);
        dc.bot_token = CredentialRef::Plaintext(s.to_owned());
    }
}
"channels.discord.guild_id" => {
    if let Some(s) = value.as_str() {
        let dc = guard.channels.discord.get_or_insert_with(DiscordChannelConfig::default);
        // ...
    }
}
```

Alternative (still readable, not necessarily simpler):
```rust
// Acquire discord ref once per key, set field based on suffix
```
This would add indirection without clear benefit. Current form preferred.

## Grade: A
